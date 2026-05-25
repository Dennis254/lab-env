#!/usr/bin/env bash
#
# configure-logging.sh - configure local endpoint logging on lab guests
#
# Usage:
#   ./scripts/configure-logging.sh
#   ./scripts/configure-logging.sh --linux-only
#   ./scripts/configure-logging.sh --windows-only
#
# This configures local telemetry only. It does not forward logs to a central
# collector.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONNECT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

CONFIGURE_LINUX=true
CONFIGURE_WINDOWS=true

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

usage() {
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
    case "$arg" in
        --linux-only) CONFIGURE_WINDOWS=false ;;
        --windows-only) CONFIGURE_LINUX=false ;;
        -h|--help) usage; exit 0 ;;
        *) die "Okänt argument: $arg" ;;
    esac
done

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Saknar kommando: $1"
}

require_cmd base64
require_cmd iconv
require_cmd jq
require_cmd ssh
require_cmd virsh

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
    for i in $(seq 1 90); do
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

windows_payload() {
    local script_b64 config_b64
    script_b64="$(base64 -w0 "$LAB_ROOT/telemetry/windows/configure-windows-logging.ps1")"
    config_b64="$(base64 -w0 "$LAB_ROOT/telemetry/windows/sysmonconfig.xml")"

    cat <<EOF
\$ErrorActionPreference = "Stop"
\$ProgressPreference = "SilentlyContinue"
\$root = "C:\ProgramData\Aegis\Telemetry"
New-Item -ItemType Directory -Path \$root -Force | Out-Null
[IO.File]::WriteAllBytes((Join-Path \$root "configure-windows-logging.ps1"), [Convert]::FromBase64String("$script_b64"))
[IO.File]::WriteAllBytes((Join-Path \$root "sysmonconfig.xml"), [Convert]::FromBase64String("$config_b64"))
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path \$root "configure-windows-logging.ps1")
EOF
}

configure_windows() {
    local domain="$1"
    info "$domain Windows local logging"
    if [[ "$(virsh --connect "$CONNECT_URI" domstate "$domain" 2>/dev/null | tr -d '\r')" != "running" ]]; then
        warn "$domain är inte igång - hoppar över"
        return 0
    fi
    if ! wait_for_agent "$domain"; then
        warn "$domain QGA svarar inte - hoppar över"
        return 0
    fi
    guest_exec_encoded_powershell "$domain" "$(windows_payload)"
}

configure_linux() {
    local name="$1" ip="$2"
    info "$name Linux local logging"
    ssh "${SSH_OPTS[@]}" "dennis@$ip" 'sudo install -d -m 0755 /opt/aegis/telemetry'
    ssh "${SSH_OPTS[@]}" "dennis@$ip" 'sudo tee /opt/aegis/telemetry/audit.rules >/dev/null' < "$LAB_ROOT/telemetry/linux/audit.rules"
    ssh "${SSH_OPTS[@]}" "dennis@$ip" 'sudo tee /opt/aegis/telemetry/configure-linux-logging.sh >/dev/null && sudo chmod +x /opt/aegis/telemetry/configure-linux-logging.sh && sudo /opt/aegis/telemetry/configure-linux-logging.sh' < "$LAB_ROOT/telemetry/linux/configure-linux-logging.sh"
}

if $CONFIGURE_LINUX; then
    for entry in "${LINUX_TARGETS[@]}"; do
        IFS=: read -r name ip <<< "$entry"
        configure_linux "$name" "$ip"
    done
fi

if $CONFIGURE_WINDOWS; then
    for domain in "${WINDOWS_TARGETS[@]}"; do
        configure_windows "$domain"
    done
fi

ok "Local logging configured."
