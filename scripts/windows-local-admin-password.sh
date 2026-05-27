#!/usr/bin/env bash
#
# windows-local-admin-password.sh - sync local Administrator password via QGA
# ---------------------------------------------------------------------------
# Usage:
#   WINDOWS_ADMIN_PASSWORD=... scripts/windows-local-admin-password.sh <domain>
# ---------------------------------------------------------------------------

set -euo pipefail

DOMAIN="${1:?domain saknas}"
ADMIN_PASSWORD="${WINDOWS_ADMIN_PASSWORD:?WINDOWS_ADMIN_PASSWORD saknas}"
LIBVIRT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Saknar kommando: %s\n' "$1" >&2
        exit 1
    }
}

require_cmd virsh
require_cmd jq
require_cmd iconv
require_cmd base64

qga() {
    local payload="$1"
    virsh --connect "$LIBVIRT_URI" qemu-agent-command "$DOMAIN" "$payload"
}

wait_for_agent() {
    local i
    for i in $(seq 1 120); do
        if qga '{"execute":"guest-ping"}' >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
    done
    printf 'QEMU guest agent svarade inte i %s\n' "$DOMAIN" >&2
    return 1
}

guest_exec_encoded_powershell() {
    local ps="$1"
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

    response="$(qga "$payload")"
    pid="$(jq -r '.return.pid' <<<"$response")"
    if [[ -z "$pid" || "$pid" == "null" ]]; then
        printf 'Kunde inte starta PowerShell via QGA: %s\n' "$response" >&2
        return 1
    fi

    while true; do
        status="$(qga "$(jq -nc --argjson pid "$pid" '{"execute":"guest-exec-status","arguments":{"pid":$pid}}')")" || return 1
        exited="$(jq -r '.return.exited // false' <<<"$status")"
        [[ "$exited" == "true" ]] && break
        sleep 2
    done

    exitcode="$(jq -r '.return.exitcode // 0' <<<"$status")"
    out="$(jq -r '.return."out-data" // empty' <<<"$status")"
    err="$(jq -r '.return."err-data" // empty' <<<"$status")"

    if [[ -n "$out" ]]; then
        printf '%s' "$out" | base64 -d 2>/dev/null || true
    fi
    if [[ -n "$err" ]]; then
        printf '%s' "$err" | base64 -d >&2 2>/dev/null || true
    fi

    if [[ "$exitcode" != "0" ]]; then
        printf 'PowerShell via QGA returnerade exit code %s\n' "$exitcode" >&2
        return "$exitcode"
    fi
}

PASSWORD_B64="$(printf '%s' "$ADMIN_PASSWORD" | base64 -w0)"

read -r -d '' PASSWORD_PS <<'EOF' || true
$ErrorActionPreference = "Stop"

$password = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("__PASSWORD_B64__"))
$securePassword = ConvertTo-SecureString $password -AsPlainText -Force
$logDir = "C:\ProgramData\Aegis"
$markerPath = Join-Path $logDir "local-admin-password.json"
$logPath = Join-Path $logDir "local-admin-password.log"

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
Start-Transcript -Path $logPath -Append -Force | Out-Null

try {
    $admin = Get-LocalUser -Name "Administrator" -ErrorAction SilentlyContinue
    if (-not $admin) {
        Write-Output "[local-admin] Local Administrator account not present; skipping."
        exit 0
    }

    Set-LocalUser -Name "Administrator" -Password $securePassword
    Enable-LocalUser -Name "Administrator"

    [pscustomobject]@{
        account = ".\Administrator"
        configured_at = (Get-Date).ToString("o")
    } | ConvertTo-Json | Set-Content -Path $markerPath -Encoding UTF8

    Write-Output "[local-admin] Local Administrator password synced."
} finally {
    Stop-Transcript | Out-Null
}
EOF

PASSWORD_PS="${PASSWORD_PS//__PASSWORD_B64__/$PASSWORD_B64}"

printf '==> Waiting for QEMU guest agent in %s\n' "$DOMAIN"
wait_for_agent

printf '==> Syncing local Administrator password on %s\n' "$DOMAIN"
guest_exec_encoded_powershell "$PASSWORD_PS"
printf '==> Local Administrator password complete for %s\n' "$DOMAIN"
