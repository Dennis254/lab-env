#!/usr/bin/env bash
#
# test-flow.sh - generate benign endpoint events and verify them in Splunk
#
# Usage:
#   ./scripts/splunk/test-flow.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="${SPLUNK_CONFIG:-$LAB_ROOT/integrations/splunk/config.env}"
CONNECT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

SSH_OPTS=(
    -F /dev/null
    -o BatchMode=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=10
)

c_reset=$'\e[0m'; c_blue=$'\e[1;34m'; c_green=$'\e[1;32m'
c_yellow=$'\e[1;33m'; c_red=$'\e[1;31m'
info()  { printf '%s==>%s %s\n' "$c_blue" "$c_reset" "$*"; }
ok()    { printf '%s  ✓%s %s\n' "$c_green" "$c_reset" "$*"; }
warn()  { printf '%s  !%s %s\n' "$c_yellow" "$c_reset" "$*"; }
err()   { printf '%s  ✗%s %s\n' "$c_red" "$c_reset" "$*" >&2; }
die()   { err "$*"; exit 1; }

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Saknar kommando: $1"
}

shell_quote() {
    printf '%q' "$1"
}

require_cmd base64
require_cmd iconv
require_cmd jq
require_cmd ssh
require_cmd virsh

[[ -f "$CONFIG_FILE" ]] || die "Saknar Splunk config: $CONFIG_FILE"
# shellcheck disable=SC1090
source "$CONFIG_FILE"

SPLUNK_SERVER_HOST="${SPLUNK_SERVER_HOST:-10.20.0.30}"
SPLUNK_SERVER_SSH_USER="${SPLUNK_SERVER_SSH_USER:-dennis}"
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
SPLUNK_ADMIN_USER="${SPLUNK_ADMIN_USER:-admin}"
SPLUNK_ADMIN_PASSWORD="${SPLUNK_ADMIN_PASSWORD:-}"
[[ -n "$SPLUNK_ADMIN_PASSWORD" ]] || die "SPLUNK_ADMIN_PASSWORD måste sättas i $CONFIG_FILE"

LINUX_TARGETS=(
    "linux-srv:10.20.0.11"
    "linux-dev:10.20.0.12"
    "kali:10.40.0.20"
)

WINDOWS_TARGETS=(
    "win-srv"
    "win-ep1"
)

qga() {
    local domain="$1" payload="$2"
    virsh --connect "$CONNECT_URI" qemu-agent-command "$domain" "$payload"
}

wait_for_agent() {
    local domain="$1" i
    for i in $(seq 1 60); do
        if qga "$domain" '{"execute":"guest-ping"}' >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

guest_exec_encoded_powershell() {
    local domain="$1" ps="$2"
    local encoded payload response pid status exited exitcode out err

    encoded="$(printf '%s' "$ps" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)"
    payload="$(
        jq -nc --arg encoded "$encoded" '{
          "execute": "guest-exec",
          "arguments": {
            "path": "powershell.exe",
            "arg": [
              "-NoProfile",
              "-NonInteractive",
              "-ExecutionPolicy",
              "Bypass",
              "-EncodedCommand",
              $encoded
            ],
            "capture-output": true
          }
        }'
    )"

    response="$(qga "$domain" "$payload")"
    pid="$(jq -r '.return.pid' <<<"$response")"
    [[ -n "$pid" && "$pid" != "null" ]] || die "Kunde inte starta PowerShell i $domain: $response"

    while true; do
        status="$(qga "$domain" "$(jq -nc --argjson pid "$pid" '{"execute":"guest-exec-status","arguments":{"pid":$pid}}')")"
        exited="$(jq -r '.return.exited // false' <<<"$status")"
        [[ "$exited" == "true" ]] && break
        sleep 2
    done

    exitcode="$(jq -r '.return.exitcode // 0' <<<"$status")"
    out="$(jq -r '.return."out-data" // empty' <<<"$status")"
    err="$(jq -r '.return."err-data" // empty' <<<"$status")"

    [[ -n "$out" ]] && printf '%s' "$out" | base64 -d 2>/dev/null || true
    [[ -n "$err" ]] && printf '%s' "$err" | base64 -d >&2 2>/dev/null || true
    [[ "$exitcode" == "0" ]] || return "$exitcode"
}

trigger_linux() {
    local name="$1" ip="$2" test_id="$3"
    info "Skapar Linux-testevent på $name"
    ssh "${SSH_OPTS[@]}" "dennis@$ip" \
        "logger --tag aegis-splunk-test $(shell_quote "$test_id target=$name")"
}

trigger_windows() {
    local domain="$1" test_id="$2"
    info "Skapar Windows-testevent på $domain"

    if [[ "$(virsh --connect "$CONNECT_URI" domstate "$domain" 2>/dev/null | tr -d '\r')" != "running" ]]; then
        warn "$domain är inte igång - hoppar över"
        return 1
    fi
    wait_for_agent "$domain" || die "$domain QGA svarar inte"

    guest_exec_encoded_powershell "$domain" "\$ErrorActionPreference = 'Stop'
\$ProgressPreference = 'SilentlyContinue'
\$testId = '$test_id'
\$msg = \"Aegis Splunk flow test \$testId host=\$env:COMPUTERNAME\"
eventcreate.exe /T INFORMATION /ID 100 /L APPLICATION /SO AegisSplunkFlow /D \$msg | Out-Null
powershell.exe -NoProfile -Command \"Write-Output '\$testId'\" | Out-Null
Write-Output \$msg"
}

splunk_search() {
    local search="$1"
    ssh "${SSH_OPTS[@]}" "${SPLUNK_SERVER_SSH_USER}@${SPLUNK_SERVER_HOST}" \
        "curl -ks -u $(shell_quote "$SPLUNK_ADMIN_USER:$SPLUNK_ADMIN_PASSWORD") https://127.0.0.1:8089/services/search/jobs/export --data-urlencode $(shell_quote "search=$search") -d output_mode=json"
}

verify_in_splunk() {
    local test_id="$1"; shift
    local expected_hosts=("$@")
    local i output rows host missing
    local search="search (index=linux OR index=wineventlog OR index=sysmon) \"$test_id\" _index_earliest=-30m | stats count by host index | sort host index"

    info "Väntar på att Splunk indexerar testevents"
    for i in $(seq 1 24); do
        output="$(splunk_search "$search" 2>/dev/null || true)"
        rows="$(jq -r 'select(.result) | [.result.host, .result.index, .result.count] | @tsv' <<<"$output" 2>/dev/null || true)"
        missing=0
        for host in "${expected_hosts[@]}"; do
            if ! grep -qE "^${host}[[:space:]]" <<<"$rows"; then
                missing=1
                break
            fi
        done
        if [[ "$missing" -eq 0 && -n "$rows" ]]; then
            printf 'host\tindex\tcount\n%s\n' "$rows"
            return 0
        fi
        sleep 5
    done

    [[ -n "${rows:-}" ]] && printf 'host\tindex\tcount\n%s\n' "$rows"
    return 1
}

main() {
    local test_id entry name ip
    local expected_hosts=()
    test_id="aegis-splunk-flow-$(date +%s)"

    info "Test-id: $test_id"
    for entry in "${LINUX_TARGETS[@]}"; do
        IFS=: read -r name ip <<< "$entry"
        trigger_linux "$name" "$ip" "$test_id"
        expected_hosts+=("$name")
    done

    for name in "${WINDOWS_TARGETS[@]}"; do
        if trigger_windows "$name" "$test_id"; then
            expected_hosts+=("$name")
        fi
    done

    verify_in_splunk "$test_id" "${expected_hosts[@]}" || die "Splunk hittade inte testevents för $test_id"
    ok "Splunk end-to-end flow verifierat: $test_id"
}

main "$@"
