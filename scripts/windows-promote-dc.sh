#!/usr/bin/env bash
#
# windows-promote-dc.sh - promote a Windows Server clone to a domain controller
# ---------------------------------------------------------------------------
# Runs AD DS forest promotion through QEMU guest agent. This avoids depending
# on WinRM during the bootstrap phase where Windows may reboot or reconfigure
# firewall/network services.
#
# Usage:
#   WINDOWS_ADMIN_PASSWORD=... scripts/windows-promote-dc.sh \
#     <domain> <domain_fqdn> <netbios_name> <dc_ip>
# ---------------------------------------------------------------------------

set -euo pipefail

DOMAIN="${1:?domain saknas}"
DOMAIN_FQDN="${2:?domain_fqdn saknas}"
NETBIOS_NAME="${3:?netbios_name saknas}"
DC_IP="${4:?dc_ip saknas}"

ADMIN_PASSWORD="${WINDOWS_ADMIN_PASSWORD:?WINDOWS_ADMIN_PASSWORD saknas}"
LIBVIRT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
QGA_TIMEOUT="${LAB_ENV_QGA_TIMEOUT:-60}"

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
    virsh --connect "$LIBVIRT_URI" qemu-agent-command "$DOMAIN" --timeout "$QGA_TIMEOUT" "$payload"
}

wait_for_agent() {
    local i
    for i in $(seq 1 180); do
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

read -r -d '' PROMOTE_PS <<'EOF' || true
$ErrorActionPreference = "Stop"

$domainName = "__DOMAIN_FQDN__"
$netbiosName = "__NETBIOS_NAME__"
$dcIp = "__DC_IP__"
$safeModePassword = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("__PASSWORD_B64__"))
$logDir = "C:\ProgramData\LabEnv"
$markerPath = Join-Path $logDir "ad-dc.json"
$logPath = Join-Path $logDir "ad-dc-promotion.log"

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
Start-Transcript -Path $logPath -Append -Force | Out-Null

try {
    Write-Output "[ad-dc] Checking current domain controller state..."
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $domain = Get-ADDomain -ErrorAction Stop
        if ($domain.DNSRoot -ieq $domainName) {
            Write-Output "[ad-dc] Already promoted for $domainName."
            [pscustomobject]@{
                domain = $domainName
                netbios = $domain.NetBIOSName
                dc_ip = $dcIp
                configured_at = (Get-Date).ToString("o")
                already_configured = $true
            } | ConvertTo-Json | Set-Content -Path $markerPath -Encoding UTF8
            exit 0
        }
    } catch {
        Write-Output "[ad-dc] Active Directory domain not present yet."
    }

    Write-Output "[ad-dc] Installing AD DS role..."
    Install-WindowsFeature AD-Domain-Services -IncludeManagementTools | Out-String | Write-Output

    $secureSafeModePassword = ConvertTo-SecureString $safeModePassword -AsPlainText -Force
    Write-Output "[ad-dc] Promoting forest $domainName ($netbiosName)..."
    Install-ADDSForest `
        -DomainName $domainName `
        -DomainNetbiosName $netbiosName `
        -SafeModeAdministratorPassword $secureSafeModePassword `
        -InstallDns `
        -CreateDnsDelegation:$false `
        -NoRebootOnCompletion:$true `
        -Force

    Set-DnsClientServerAddress -InterfaceAlias "mgmt" -ServerAddresses "127.0.0.1" -ErrorAction SilentlyContinue

    [pscustomobject]@{
        domain = $domainName
        netbios = $netbiosName
        dc_ip = $dcIp
        configured_at = (Get-Date).ToString("o")
        reboot_scheduled = $true
    } | ConvertTo-Json | Set-Content -Path $markerPath -Encoding UTF8

    Write-Output "[ad-dc] Promotion complete; rebooting."
    shutdown.exe /r /t 10 /f /c "LabEnv AD DS promotion"
} finally {
    Stop-Transcript | Out-Null
}
EOF

read -r -d '' VERIFY_PS <<'EOF' || true
$ErrorActionPreference = "Stop"
$domainName = "__DOMAIN_FQDN__"
Import-Module ActiveDirectory -ErrorAction Stop
$domain = Get-ADDomain -ErrorAction Stop
if ($domain.DNSRoot -ine $domainName) {
    throw "Unexpected AD domain: $($domain.DNSRoot)"
}
Write-Output "[ad-dc] Verified domain controller for $($domain.DNSRoot)."
EOF

PROMOTE_PS="${PROMOTE_PS//__DOMAIN_FQDN__/$DOMAIN_FQDN}"
PROMOTE_PS="${PROMOTE_PS//__NETBIOS_NAME__/$NETBIOS_NAME}"
PROMOTE_PS="${PROMOTE_PS//__DC_IP__/$DC_IP}"
PROMOTE_PS="${PROMOTE_PS//__PASSWORD_B64__/$PASSWORD_B64}"
VERIFY_PS="${VERIFY_PS//__DOMAIN_FQDN__/$DOMAIN_FQDN}"

printf '==> Waiting for QEMU guest agent in %s\n' "$DOMAIN"
wait_for_agent

printf '==> Promoting %s to AD DS forest %s\n' "$DOMAIN" "$DOMAIN_FQDN"
guest_exec_encoded_powershell "$PROMOTE_PS" || true

printf '==> Waiting for %s after AD DS reboot\n' "$DOMAIN"
sleep 30
wait_for_agent

printf '==> Verifying AD DS on %s\n' "$DOMAIN"
for _ in $(seq 1 120); do
    if guest_exec_encoded_powershell "$VERIFY_PS" >/dev/null 2>&1; then
        printf '==> AD DS promotion complete for %s (%s)\n' "$DOMAIN" "$DOMAIN_FQDN"
        exit 0
    fi
    sleep 10
done

printf 'AD DS promotion verification failed for %s\n' "$DOMAIN" >&2
exit 1
