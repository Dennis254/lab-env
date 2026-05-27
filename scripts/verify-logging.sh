#!/usr/bin/env bash
#
# verify-logging.sh - verify local Windows/Linux logging baseline
#
# Usage:
#   ./scripts/verify-logging.sh

set -euo pipefail

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

verify_linux() {
    local name="$1" ip="$2"
    info "$name Linux logging verify"
    ssh "${SSH_OPTS[@]}" "dennis@$ip" 'sudo bash -s' <<'EOF'
set -euo pipefail
test_id="lab-env-verify-$(date +%s)"
/bin/true
logger "$test_id"

audit_state="$(systemctl is-active auditd 2>/dev/null || true)"
rsyslog_state="$(systemctl is-active rsyslog 2>/dev/null || true)"
test -d /var/log/journal
test -f /etc/audit/rules.d/99-lab-env.rules
journalctl -n 200 --no-pager | grep -q "$test_id"

printf "auditd=%s rsyslog=%s journal=persistent audit_rules=present\n" "$audit_state" "$rsyslog_state"
EOF
}

windows_verify_payload() {
    cat <<'EOF'
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$testId = "lab-env-verify-" + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
cmd.exe /c "echo $testId > C:\ProgramData\LabEnv\Telemetry\verify.txt" | Out-Null
powershell.exe -NoProfile -Command "Write-Output '$testId'" | Out-Null

Start-Sleep -Seconds 3

$sysmonService = Get-Service -Name "Sysmon*" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $sysmonService) { throw "Sysmon service missing" }

$sysmonEvent = Get-WinEvent -FilterHashtable @{LogName="Microsoft-Windows-Sysmon/Operational"; Id=1; StartTime=(Get-Date).AddMinutes(-10)} -MaxEvents 20 -ErrorAction Stop |
    Where-Object { $_.Message -match "cmd.exe|powershell.exe" } |
    Select-Object -First 1
if (-not $sysmonEvent) { throw "No recent Sysmon process event found" }

$psEvent = Get-WinEvent -FilterHashtable @{LogName="Microsoft-Windows-PowerShell/Operational"; StartTime=(Get-Date).AddMinutes(-10)} -MaxEvents 20 -ErrorAction SilentlyContinue |
    Select-Object -First 1

[pscustomobject]@{
    computer = $env:COMPUTERNAME
    sysmon_service = $sysmonService.Name
    sysmon_event_id = $sysmonEvent.Id
    powershell_operational_event = [bool]$psEvent
} | ConvertTo-Json -Compress
EOF
}

verify_windows() {
    local domain="$1"
    info "$domain Windows logging verify"
    if [[ "$(virsh --connect "$CONNECT_URI" domstate "$domain" 2>/dev/null | tr -d '\r')" != "running" ]]; then
        warn "$domain är inte igång - hoppar över"
        return 0
    fi
    if ! wait_for_agent "$domain"; then
        warn "$domain QGA svarar inte - hoppar över"
        return 0
    fi
    guest_exec_encoded_powershell "$domain" "$(windows_verify_payload)"
}

for entry in "${LINUX_TARGETS[@]}"; do
    IFS=: read -r name ip <<< "$entry"
    verify_linux "$name" "$ip"
done

for domain in "${WINDOWS_TARGETS[@]}"; do
    verify_windows "$domain"
done

ok "Local logging verified."
