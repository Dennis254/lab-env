#!/usr/bin/env bash
#
# windows-join-domain.sh - join a Windows clone to an AD domain via QGA
# ---------------------------------------------------------------------------
# Runs from the host after the domain controller has been promoted. QEMU guest
# agent executes PowerShell as LocalSystem, so the local endpoint does not need
# WinRM to be reachable before the join.
#
# Usage:
#   WINDOWS_ADMIN_PASSWORD=... scripts/windows-join-domain.sh \
#     <domain> <hostname> <domain_fqdn> <netbios_name> <dc_ip> <mgmt_mac>
# ---------------------------------------------------------------------------

set -euo pipefail

DOMAIN="${1:?domain saknas}"
HOSTNAME="${2:?hostname saknas}"
DOMAIN_FQDN="${3:?domain_fqdn saknas}"
NETBIOS_NAME="${4:?netbios_name saknas}"
DC_IP="${5:?dc_ip saknas}"
MGMT_MAC="${6:?mgmt_mac saknas}"

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

read -r -d '' JOIN_PS <<'EOF' || true
$ErrorActionPreference = "Stop"

$hostname = "__HOSTNAME__"
$domainName = "__DOMAIN_FQDN__"
$netbiosName = "__NETBIOS_NAME__"
$dcIp = "__DC_IP__"
$mgmtMac = "__MGMT_MAC__".Replace(":","-").ToUpperInvariant()
$domainAdminPassword = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("__PASSWORD_B64__"))
$logDir = "C:\ProgramData\LabEnv"
$markerPath = Join-Path $logDir "domain-join.json"
$logPath = Join-Path $logDir "domain-join.log"

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
Start-Transcript -Path $logPath -Append -Force | Out-Null

try {
    Write-Output "[domain-join] Checking current domain membership..."
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.PartOfDomain -and $cs.Domain -ieq $domainName) {
        Write-Output "[domain-join] Already joined to $domainName."
        [pscustomobject]@{
            hostname = $hostname
            domain = $domainName
            dc_ip = $dcIp
            configured_at = (Get-Date).ToString("o")
            already_configured = $true
        } | ConvertTo-Json | Set-Content -Path $markerPath -Encoding UTF8
        exit 0
    }

    $mgmtAdapter = Get-NetAdapter | Where-Object { $_.MacAddress -eq $mgmtMac } | Select-Object -First 1
    if (-not $mgmtAdapter) {
        $mgmtAdapter = Get-NetAdapter -Name "mgmt" -ErrorAction SilentlyContinue
    }
    if (-not $mgmtAdapter) {
        throw "Management NIC with MAC $mgmtMac was not found."
    }

    Write-Output "[domain-join] Pointing mgmt DNS to $dcIp."
    Set-DnsClientServerAddress -InterfaceIndex $mgmtAdapter.InterfaceIndex -ServerAddresses $dcIp
    Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object {
        Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private -ErrorAction SilentlyContinue
    }

    Write-Output "[domain-join] Waiting for AD DNS $domainName on $dcIp..."
    $dnsReady = $false
    for ($i = 0; $i -lt 120; $i++) {
        if (Resolve-DnsName -Name $domainName -Server $dcIp -ErrorAction SilentlyContinue) {
            $dnsReady = $true
            break
        }
        Start-Sleep -Seconds 5
    }
    if (-not $dnsReady) {
        throw "Domain DNS did not become ready for $domainName on $dcIp."
    }

    $securePassword = ConvertTo-SecureString $domainAdminPassword -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential("$netbiosName\Administrator", $securePassword)

    Write-Output "[domain-join] Joining $hostname to $domainName..."
    Add-Computer -DomainName $domainName -Credential $credential -Force

    [pscustomobject]@{
        hostname = $hostname
        domain = $domainName
        dc_ip = $dcIp
        configured_at = (Get-Date).ToString("o")
        reboot_scheduled = $true
    } | ConvertTo-Json | Set-Content -Path $markerPath -Encoding UTF8

    Write-Output "[domain-join] Join complete; rebooting."
    shutdown.exe /r /t 10 /f /c "LabEnv AD domain join"
} finally {
    Stop-Transcript | Out-Null
}
EOF

read -r -d '' VERIFY_PS <<'EOF' || true
$ErrorActionPreference = "Stop"
$domainName = "__DOMAIN_FQDN__"
$cs = Get-CimInstance Win32_ComputerSystem
if (-not $cs.PartOfDomain -or $cs.Domain -ine $domainName) {
    throw "Not joined to $domainName. Current domain: $($cs.Domain)"
}
Write-Output "[domain-join] Verified membership in $domainName."
EOF

JOIN_PS="${JOIN_PS//__HOSTNAME__/$HOSTNAME}"
JOIN_PS="${JOIN_PS//__DOMAIN_FQDN__/$DOMAIN_FQDN}"
JOIN_PS="${JOIN_PS//__NETBIOS_NAME__/$NETBIOS_NAME}"
JOIN_PS="${JOIN_PS//__DC_IP__/$DC_IP}"
JOIN_PS="${JOIN_PS//__MGMT_MAC__/$MGMT_MAC}"
JOIN_PS="${JOIN_PS//__PASSWORD_B64__/$PASSWORD_B64}"
VERIFY_PS="${VERIFY_PS//__DOMAIN_FQDN__/$DOMAIN_FQDN}"

printf '==> Waiting for QEMU guest agent in %s\n' "$DOMAIN"
wait_for_agent

printf '==> Joining %s to %s\n' "$DOMAIN" "$DOMAIN_FQDN"
guest_exec_encoded_powershell "$JOIN_PS" || true

printf '==> Waiting for %s after domain-join reboot\n' "$DOMAIN"
sleep 30
wait_for_agent

printf '==> Verifying domain membership on %s\n' "$DOMAIN"
for _ in $(seq 1 120); do
    if guest_exec_encoded_powershell "$VERIFY_PS" >/dev/null 2>&1; then
        printf '==> Domain join complete for %s (%s)\n' "$DOMAIN" "$DOMAIN_FQDN"
        exit 0
    fi
    sleep 10
done

printf 'Domain join verification failed for %s\n' "$DOMAIN" >&2
exit 1
