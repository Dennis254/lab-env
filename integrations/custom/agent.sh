#!/usr/bin/env bash
#
# Generic private-agent hook for the custom SIEM profile.

set -euo pipefail

ACTION="${1:?action saknas}"
TARGET_OS="${2:?target os saknas}"
TARGET_NAME="${3:?target name saknas}"
TARGET_ADDR="${4:-}"

PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${INTEGRATION_CONFIG:-$PROFILE_DIR/config.env}"
CONNECT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
QGA_TIMEOUT="${LAB_ENV_QGA_TIMEOUT:-60}"
LAB_ADMIN_USER="${LAB_ADMIN_USER:-${USER:-labadmin}}"

SSH_OPTS=(
    -F /dev/null
    -o BatchMode=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=10
)

c_reset=$'\e[0m'; c_green=$'\e[1;32m'; c_yellow=$'\e[1;33m'; c_red=$'\e[1;31m'
ok()    { printf '%s  ✓%s %s\n' "$c_green" "$c_reset" "$*"; }
warn()  { printf '%s  !%s %s\n' "$c_yellow" "$c_reset" "$*"; }
die()   { printf '%s  ✗%s %s\n' "$c_red" "$c_reset" "$*" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Saknar kommando: $1"
}

[[ -f "$CONFIG_FILE" ]] || die "Saknar config: $CONFIG_FILE. Kopiera config.env.example till config.env."
# shellcheck disable=SC1090
source "$CONFIG_FILE"
CUSTOM_SIEM_URL="${CUSTOM_SIEM_URL:-}"
CUSTOM_SIEM_TENANT="${CUSTOM_SIEM_TENANT:-}"
CUSTOM_AGENT_MODE="${CUSTOM_AGENT_MODE:-observe}"

shell_quote() {
    printf '%q' "$1"
}

ps_single_quote() {
    local value="$1"
    value="${value//\'/\'\'}"
    printf "'%s'" "$value"
}

run_linux_command() {
    local command_text="$1"
    [[ -n "$TARGET_ADDR" ]] || die "$TARGET_NAME saknar IP-adress"
    if [[ -z "$command_text" ]]; then
        warn "$TARGET_NAME saknar Linux-kommando för $ACTION - hoppar över"
        return 0
    fi
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        warn "Dry-run: skulle köra custom Linux-agent $ACTION på $TARGET_NAME"
        return 0
    fi
    {
        printf 'export CUSTOM_SIEM_URL=%s\n' "$(shell_quote "$CUSTOM_SIEM_URL")"
        printf 'export CUSTOM_SIEM_TENANT=%s\n' "$(shell_quote "$CUSTOM_SIEM_TENANT")"
        printf 'export CUSTOM_AGENT_MODE=%s\n' "$(shell_quote "$CUSTOM_AGENT_MODE")"
        printf '%s\n' "$command_text"
    } | ssh "${SSH_OPTS[@]}" "$LAB_ADMIN_USER@$TARGET_ADDR" 'sudo bash -s'
}

qga() {
    local domain="$1" payload="$2"
    virsh --connect "$CONNECT_URI" qemu-agent-command "$domain" --timeout "$QGA_TIMEOUT" "$payload"
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

run_windows_command() {
    local command_text="$1"
    if [[ -z "$command_text" ]]; then
        warn "$TARGET_NAME saknar Windows-kommando för $ACTION - hoppar över"
        return 0
    fi
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        warn "Dry-run: skulle köra custom Windows-agent $ACTION på $TARGET_NAME"
        return 0
    fi
    require_cmd virsh
    require_cmd jq
    require_cmd iconv
    require_cmd base64
    if [[ "$(virsh --connect "$CONNECT_URI" domstate "$TARGET_NAME" 2>/dev/null | tr -d '\r')" != "running" ]]; then
        warn "$TARGET_NAME är inte igång - hoppar över"
        return 0
    fi
    wait_for_agent "$TARGET_NAME" || die "$TARGET_NAME QGA svarar inte"
    guest_exec_encoded_powershell "$TARGET_NAME" "\$env:CUSTOM_SIEM_URL = $(ps_single_quote "$CUSTOM_SIEM_URL")
\$env:CUSTOM_SIEM_TENANT = $(ps_single_quote "$CUSTOM_SIEM_TENANT")
\$env:CUSTOM_AGENT_MODE = $(ps_single_quote "$CUSTOM_AGENT_MODE")
$command_text"
}

case "$TARGET_OS:$ACTION" in
    linux:install)  run_linux_command "${CUSTOM_AGENT_LINUX_INSTALL_COMMAND:-}" ;;
    linux:verify)   run_linux_command "${CUSTOM_AGENT_LINUX_VERIFY_COMMAND:-}" ;;
    linux:remove)   run_linux_command "${CUSTOM_AGENT_LINUX_REMOVE_COMMAND:-}" ;;
    windows:install) run_windows_command "${CUSTOM_AGENT_WINDOWS_INSTALL_COMMAND:-}" ;;
    windows:verify)  run_windows_command "${CUSTOM_AGENT_WINDOWS_VERIFY_COMMAND:-}" ;;
    windows:remove)  run_windows_command "${CUSTOM_AGENT_WINDOWS_REMOVE_COMMAND:-}" ;;
    *) die "Okänd kombination: $TARGET_OS:$ACTION" ;;
esac

ok "$TARGET_NAME custom agent action klar: $ACTION"
