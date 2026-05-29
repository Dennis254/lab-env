#!/usr/bin/env bash
#
# windows-qga-config.sh — configure a sysprepped Windows VM via QEMU guest agent
# ---------------------------------------------------------------------------
# Runs from the host after Terraform has created a Windows clone from a Packer
# image. QEMU guest agent executes the PowerShell payload as LocalSystem, so
# this does not depend on WinRM already working.
#
# Usage:
#   WINDOWS_ADMIN_PASSWORD=... scripts/windows-qga-config.sh \
#     <domain> <hostname> <mgmt_mac> <mgmt_ip> <prefix> <gateway> <dns> <deto_mac> <deto_ip>
# ---------------------------------------------------------------------------

set -euo pipefail

DOMAIN="${1:?domain saknas}"
HOSTNAME="${2:?hostname saknas}"
MGMT_MAC="${3:?mgmt_mac saknas}"
MGMT_IP="${4:?mgmt_ip saknas}"
MGMT_PREFIX="${5:?mgmt_prefix saknas}"
MGMT_GATEWAY="${6:?mgmt_gateway saknas}"
MGMT_DNS="${7:?mgmt_dns saknas}"
DETO_MAC="${8:-}"
DETO_IP="${9:-}"

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
        status="$(qga "$(jq -nc --argjson pid "$pid" '{"execute":"guest-exec-status","arguments":{"pid":$pid}}')")"
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

CONFIG_JSON="$(
    jq -nc \
      --arg hostname "$HOSTNAME" \
      --arg mgmt_mac "$MGMT_MAC" \
      --arg mgmt_ip "$MGMT_IP" \
      --argjson mgmt_prefix "$MGMT_PREFIX" \
      --arg mgmt_gateway "$MGMT_GATEWAY" \
      --arg mgmt_dns "$MGMT_DNS" \
      --arg deto_mac "$DETO_MAC" \
      --arg deto_ip "$DETO_IP" \
      '{
        hostname: $hostname,
        mgmt_mac: $mgmt_mac,
        mgmt_ip: $mgmt_ip,
        mgmt_prefix: $mgmt_prefix,
        mgmt_gateway: $mgmt_gateway,
        mgmt_dns: $mgmt_dns,
        deto_mac: $deto_mac,
        deto_ip: $deto_ip
      }'
)"
CONFIG_B64="$(printf '%s' "$CONFIG_JSON" | base64 -w0)"
PASSWORD_B64="$(printf '%s' "$ADMIN_PASSWORD" | base64 -w0)"

read -r -d '' POWERSHELL <<'EOF' || true
$ErrorActionPreference = "Stop"

$configJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("__CONFIG_B64__"))
$config = $configJson | ConvertFrom-Json
$adminPassword = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("__PASSWORD_B64__"))
$logDir = "C:\ProgramData\LabEnv"
$logPath = Join-Path $logDir "windows-qga-config.log"
$markerPath = Join-Path $logDir "windows-qga-config.json"
$needsReboot = $false

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
Start-Transcript -Path $logPath -Append -Force | Out-Null

try {
    Write-Output "[qga-config] Starting configuration for $($config.hostname)"

    $securePassword = ConvertTo-SecureString $adminPassword -AsPlainText -Force
    if (Get-LocalUser -Name "Administrator" -ErrorAction SilentlyContinue) {
        Set-LocalUser -Name "Administrator" -Password $securePassword
        Enable-LocalUser -Name "Administrator"
        Write-Output "[qga-config] Administrator enabled and password set."
    }

    if (Get-LocalUser -Name "packer" -ErrorAction SilentlyContinue) {
        Disable-LocalUser -Name "packer"
        Write-Output "[qga-config] Disabled build-only packer account."
    }

    $mgmtMac = $config.mgmt_mac.Replace(":","-").ToUpperInvariant()
    $mgmtAdapter = Get-NetAdapter | Where-Object { $_.MacAddress -eq $mgmtMac } | Select-Object -First 1
    if (-not $mgmtAdapter) {
        throw "Management NIC with MAC $mgmtMac was not found."
    }

    if ($mgmtAdapter.Name -ne "mgmt") {
        if (-not (Get-NetAdapter -Name "mgmt" -ErrorAction SilentlyContinue)) {
            Rename-NetAdapter -Name $mgmtAdapter.Name -NewName "mgmt"
            Write-Output "[qga-config] Renamed management NIC to mgmt."
        }
        $mgmtAdapter = Get-NetAdapter -Name "mgmt"
    }

    Set-NetIPInterface -InterfaceIndex $mgmtAdapter.InterfaceIndex -Dhcp Disabled -ErrorAction SilentlyContinue

    Get-NetIPAddress -InterfaceIndex $mgmtAdapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -ne $config.mgmt_ip } |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

    $currentMgmtIp = Get-NetIPAddress -InterfaceIndex $mgmtAdapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq $config.mgmt_ip } |
        Select-Object -First 1

    if (-not $currentMgmtIp) {
        New-NetIPAddress `
            -InterfaceIndex $mgmtAdapter.InterfaceIndex `
            -IPAddress $config.mgmt_ip `
            -PrefixLength ([int]$config.mgmt_prefix) `
            -DefaultGateway $config.mgmt_gateway | Out-Null
        Write-Output "[qga-config] Set mgmt IP $($config.mgmt_ip)/$($config.mgmt_prefix)."
    } else {
        Get-NetRoute -InterfaceIndex $mgmtAdapter.InterfaceIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
            Where-Object { $_.NextHop -ne $config.mgmt_gateway } |
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        if (-not (Get-NetRoute -InterfaceIndex $mgmtAdapter.InterfaceIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -eq $config.mgmt_gateway })) {
            New-NetRoute -InterfaceIndex $mgmtAdapter.InterfaceIndex -DestinationPrefix "0.0.0.0/0" -NextHop $config.mgmt_gateway | Out-Null
        }
    }

    Set-DnsClientServerAddress -InterfaceIndex $mgmtAdapter.InterfaceIndex -ServerAddresses $config.mgmt_dns

    try {
        $languageList = New-WinUserLanguageList -Language "sv-SE"
        $languageList.Add("en-US")
        Set-WinUserLanguageList -LanguageList $languageList -Force
        Set-WinDefaultInputMethodOverride -InputTip "041D:0000041D"
        Set-Culture -CultureInfo "sv-SE"
        Set-WinHomeLocation -GeoId 221
        Set-WinSystemLocale -SystemLocale "en-US"
        New-Item -Path "Registry::HKEY_USERS\.DEFAULT\Keyboard Layout\Preload" -Force | Out-Null
        Set-ItemProperty -Path "Registry::HKEY_USERS\.DEFAULT\Keyboard Layout\Preload" -Name "1" -Value "0000041d"
        if (Get-Command Copy-UserInternationalSettingsToSystem -ErrorAction SilentlyContinue) {
            Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true
        }
        Write-Output "[qga-config] Swedish keyboard/input configured."
    } catch {
        Write-Warning "[qga-config] Swedish keyboard/input configuration failed: $($_.Exception.Message)"
    }

    if ($config.deto_mac) {
        $detoMac = $config.deto_mac.Replace(":","-").ToUpperInvariant()
        $detoAdapter = Get-NetAdapter | Where-Object { $_.MacAddress -eq $detoMac } | Select-Object -First 1
        if ($detoAdapter -and $detoAdapter.Name -ne "deto" -and -not (Get-NetAdapter -Name "deto" -ErrorAction SilentlyContinue)) {
            Rename-NetAdapter -Name $detoAdapter.Name -NewName "deto"
            Write-Output "[qga-config] Renamed detonation NIC to deto."
        }
        $detoAdapter = Get-NetAdapter -Name "deto" -ErrorAction SilentlyContinue
        if ($detoAdapter -and $config.deto_ip) {
            Set-NetIPInterface -InterfaceIndex $detoAdapter.InterfaceIndex -Dhcp Disabled -ErrorAction SilentlyContinue

            Get-NetIPAddress -InterfaceIndex $detoAdapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -ne $config.deto_ip } |
                Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

            $currentDetoIp = Get-NetIPAddress -InterfaceIndex $detoAdapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -eq $config.deto_ip } |
                Select-Object -First 1

            if (-not $currentDetoIp) {
                New-NetIPAddress `
                    -InterfaceIndex $detoAdapter.InterfaceIndex `
                    -IPAddress $config.deto_ip `
                    -PrefixLength 24 | Out-Null
                Write-Output "[qga-config] Set deto IP $($config.deto_ip)/24."
            }
        }
    }

    Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object {
        Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private -ErrorAction SilentlyContinue
    }

    Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
    Set-Item WSMan:\localhost\Service\Auth\Basic $true
    Set-Item WSMan:\localhost\Service\Auth\Negotiate $true
    Set-Item WSMan:\localhost\Service\AllowUnencrypted $true
    winrm set winrm/config/service/auth '@{Basic="true"}' | Out-Null
    winrm set winrm/config/service/auth '@{Negotiate="true"}' | Out-Null
    winrm set winrm/config/service '@{AllowUnencrypted="true"}' | Out-Null

    New-ItemProperty `
        -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
        -Name "LocalAccountTokenFilterPolicy" `
        -Value 1 `
        -PropertyType DWord `
        -Force | Out-Null

    Set-NetFirewallRule -Name 'WINRM-HTTP-In-TCP' -RemoteAddress Any -Enabled True -Profile Any -ErrorAction SilentlyContinue
    Set-NetFirewallRule -Name 'WINRM-HTTP-In-TCP-PUBLIC' -RemoteAddress Any -Enabled True -Profile Any -ErrorAction SilentlyContinue
    Restart-Service WinRM
    Write-Output "[qga-config] WinRM configured."

    if ($env:COMPUTERNAME -ne $config.hostname) {
        Rename-Computer -NewName $config.hostname -Force
        $needsReboot = $true
        Write-Output "[qga-config] Rename scheduled: $env:COMPUTERNAME -> $($config.hostname)"
    }

    [pscustomobject]@{
        hostname = $config.hostname
        mgmt_ip = $config.mgmt_ip
        mgmt_mac = $config.mgmt_mac
        deto_ip = $config.deto_ip
        deto_mac = $config.deto_mac
        configured_at = (Get-Date).ToString("o")
        needs_reboot = $needsReboot
    } | ConvertTo-Json | Set-Content -Path $markerPath -Encoding UTF8

    Write-Output "[qga-config] Done."
    if ($needsReboot) {
        shutdown.exe /r /t 10 /f /c "LabEnv Terraform Windows config"
    }
} finally {
    Stop-Transcript | Out-Null
}
EOF

POWERSHELL="${POWERSHELL//__CONFIG_B64__/$CONFIG_B64}"
POWERSHELL="${POWERSHELL//__PASSWORD_B64__/$PASSWORD_B64}"

printf '==> Waiting for QEMU guest agent in %s\n' "$DOMAIN"
wait_for_agent

printf '==> Running Windows configuration in %s\n' "$DOMAIN"
guest_exec_encoded_powershell "$POWERSHELL"

printf '==> Waiting for post-config guest agent availability in %s\n' "$DOMAIN"
sleep 15
wait_for_agent
printf '==> Windows QGA configuration complete for %s\n' "$DOMAIN"
