#!/usr/bin/env bash
#
# windows-ad-users.sh - seed fictitious AD users through QEMU guest agent
# ---------------------------------------------------------------------------
# Usage:
#   AD_LAB_USERS_JSON='[...]' WINDOWS_ADMIN_PASSWORD=... \
#     scripts/windows-ad-users.sh <domain> <domain_fqdn> <netbios_name>
# ---------------------------------------------------------------------------

set -euo pipefail

DOMAIN="${1:?domain saknas}"
DOMAIN_FQDN="${2:?domain_fqdn saknas}"
NETBIOS_NAME="${3:?netbios_name saknas}"

ADMIN_PASSWORD="${WINDOWS_ADMIN_PASSWORD:?WINDOWS_ADMIN_PASSWORD saknas}"
USERS_JSON="${AD_LAB_USERS_JSON:?AD_LAB_USERS_JSON saknas}"
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
USERS_B64="$(printf '%s' "$USERS_JSON" | base64 -w0)"

read -r -d '' USERS_PS <<'EOF' || true
$ErrorActionPreference = "Stop"

$domainName = "__DOMAIN_FQDN__"
$netbiosName = "__NETBIOS_NAME__"
$password = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("__PASSWORD_B64__"))
$usersJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("__USERS_B64__"))
$users = $usersJson | ConvertFrom-Json
$logDir = "C:\ProgramData\Aegis"
$markerPath = Join-Path $logDir "ad-users.json"
$logPath = Join-Path $logDir "ad-users.log"

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
Start-Transcript -Path $logPath -Append -Force | Out-Null

function Ensure-OU {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$Path
    )

    $existing = Get-ADOrganizationalUnit -LDAPFilter "(ou=$Name)" -SearchBase $Path -SearchScope OneLevel -ErrorAction SilentlyContinue
    if ($existing) {
        return $existing.DistinguishedName
    }

    New-ADOrganizationalUnit -Name $Name -Path $Path -ProtectedFromAccidentalDeletion $false | Out-Null
    return "OU=$Name,$Path"
}

try {
    Import-Module ActiveDirectory -ErrorAction Stop
    $domain = Get-ADDomain -ErrorAction Stop
    if ($domain.DNSRoot -ine $domainName) {
        throw "Unexpected AD domain: $($domain.DNSRoot)"
    }

    $baseDn = $domain.DistinguishedName
    $rootOu = Ensure-OU -Name "Aegis Lab" -Path $baseDn
    $usersOu = Ensure-OU -Name "Users" -Path $rootOu
    $groupsOu = Ensure-OU -Name "Groups" -Path $rootOu

    $groupName = "Lab Workstation Users"
    $group = Get-ADGroup -LDAPFilter "(sAMAccountName=LabWorkstationUsers)" -ErrorAction SilentlyContinue
    if (-not $group) {
        New-ADGroup `
            -Name $groupName `
            -SamAccountName "LabWorkstationUsers" `
            -GroupScope Global `
            -GroupCategory Security `
            -Path $groupsOu `
            -Description "Fiktiva labbanvändare för klientinloggning och telemetri" | Out-Null
    }

    $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
    Set-ADAccountPassword -Identity "Administrator" -NewPassword $securePassword -Reset
    Enable-ADAccount -Identity "Administrator"

    $created = @()

    foreach ($user in $users) {
        $sam = [string]$user.sam_account_name
        $upn = "$sam@$domainName"
        $existing = Get-ADUser -LDAPFilter "(sAMAccountName=$sam)" -ErrorAction SilentlyContinue

        if ($existing) {
            Set-ADUser `
                -Identity $existing `
                -GivenName $user.given_name `
                -Surname $user.surname `
                -DisplayName $user.display_name `
                -Department $user.department `
                -Title $user.title `
                -EmailAddress $upn `
                -Enabled $true | Out-Null
            Enable-ADAccount -Identity $existing | Out-Null
            Set-ADAccountPassword -Identity $sam -NewPassword $securePassword -Reset
            $created += "$($sam):updated"
        } else {
            New-ADUser `
                -Name $user.display_name `
                -SamAccountName $sam `
                -UserPrincipalName $upn `
                -GivenName $user.given_name `
                -Surname $user.surname `
                -DisplayName $user.display_name `
                -Department $user.department `
                -Title $user.title `
                -EmailAddress $upn `
                -Path $usersOu `
                -AccountPassword $securePassword `
                -Enabled $true `
                -ChangePasswordAtLogon $false `
                -PasswordNeverExpires $true | Out-Null
            $created += "$($sam):created"
        }

        Add-ADGroupMember -Identity "LabWorkstationUsers" -Members $sam -ErrorAction SilentlyContinue
        Unlock-ADAccount -Identity $sam -ErrorAction SilentlyContinue
    }

    [pscustomobject]@{
        domain = $domainName
        netbios = $netbiosName
        users = $created
        password_source = "windows_admin_password"
        domain_admin_password_synced = $true
        configured_at = (Get-Date).ToString("o")
    } | ConvertTo-Json | Set-Content -Path $markerPath -Encoding UTF8

    Write-Output "[ad-users] Seeded $($users.Count) lab users in $domainName."
} finally {
    Stop-Transcript | Out-Null
}
EOF

USERS_PS="${USERS_PS//__DOMAIN_FQDN__/$DOMAIN_FQDN}"
USERS_PS="${USERS_PS//__NETBIOS_NAME__/$NETBIOS_NAME}"
USERS_PS="${USERS_PS//__PASSWORD_B64__/$PASSWORD_B64}"
USERS_PS="${USERS_PS//__USERS_B64__/$USERS_B64}"

printf '==> Waiting for QEMU guest agent in %s\n' "$DOMAIN"
wait_for_agent

printf '==> Seeding AD lab users in %s\n' "$DOMAIN_FQDN"
guest_exec_encoded_powershell "$USERS_PS"
printf '==> AD lab users complete for %s\n' "$DOMAIN_FQDN"
