# setup-winrm.ps1 - runs as a FirstLogon command during the Packer build.
# ---------------------------------------------------------------------------
# Enables WinRM over HTTP (5985) with Basic + unencrypted auth so Packer
# can connect from the host through qemu user-mode NAT.
#
# Build-only posture. Later phases should harden this to HTTPS/cert auth.
# ---------------------------------------------------------------------------

$ErrorActionPreference = "Stop"

New-Item -ItemType Directory -Path "C:\Windows\Temp" -Force | Out-Null
Start-Transcript -Path "C:\Windows\Temp\setup-winrm.log" -Force

try {
Write-Output "[setup-winrm] Running as: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"

Write-Output "[setup-winrm] Setting network profiles to Private when possible..."
Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private -ErrorAction Stop
        Write-Output "[setup-winrm] Network profile $($_.Name) set to Private"
    } catch {
        Write-Output "[setup-winrm] Could not change network profile $($_.Name): $($_.Exception.Message)"
    }
}

Write-Output "[setup-winrm] Enabling PowerShell remoting..."
Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null

Write-Output "[setup-winrm] Configuring WinRM listener and auth..."
Set-Item WSMan:\localhost\Service\Auth\Basic       $true
Set-Item WSMan:\localhost\Service\Auth\Negotiate   $true
Set-Item WSMan:\localhost\Service\AllowUnencrypted $true
Set-Item WSMan:\localhost\Service\MaxConcurrentOperationsPerUser 4294967295
Set-Item WSMan:\localhost\Shell\MaxMemoryPerShellMB  1024
winrm set winrm/config/service/auth '@{Basic="true"}' | Out-Null
winrm set winrm/config/service/auth '@{Negotiate="true"}' | Out-Null
winrm set winrm/config/service '@{AllowUnencrypted="true"}' | Out-Null

$listeners = @(Get-ChildItem WSMan:\localhost\Listener -ErrorAction SilentlyContinue)
if ($listeners.Count -eq 0) {
    Write-Output "[setup-winrm] Creating HTTP listener..."
    New-Item -Path WSMan:\localhost\Listener -Transport HTTP -Address * -Force | Out-Null
}

Write-Output "[setup-winrm] Allowing remote admin token for local build account..."
New-ItemProperty `
    -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
    -Name "LocalAccountTokenFilterPolicy" `
    -Value 1 `
    -PropertyType DWord `
    -Force | Out-Null

Write-Output "[setup-winrm] Opening firewall for WinRM (any remote address)..."
# The default rule can be scoped too narrowly. Open it to Any so Packer
# can connect through NAT during the isolated image build.
Set-NetFirewallRule -Name 'WINRM-HTTP-In-TCP' -RemoteAddress Any -ErrorAction SilentlyContinue
Set-NetFirewallRule -Name 'WINRM-HTTP-In-TCP-PUBLIC' -RemoteAddress Any -ErrorAction SilentlyContinue
Set-NetFirewallRule -Name 'WINRM-HTTP-In-TCP' -Enabled True -Profile Any -ErrorAction SilentlyContinue
Set-NetFirewallRule -Name 'WINRM-HTTP-In-TCP-PUBLIC' -Enabled True -Profile Any -ErrorAction SilentlyContinue

Write-Output "[setup-winrm] WinRM ready. Restarting service..."
Restart-Service WinRM

Write-Output "[setup-winrm] Effective WinRM listeners:"
winrm enumerate winrm/config/listener
Write-Output "[setup-winrm] Effective WinRM service auth:"
winrm get winrm/config/service/auth
Write-Output "[setup-winrm] Local self-test:"
Test-WSMan localhost

New-Item -ItemType File -Path "C:\Windows\Temp\setup-winrm.done" -Force | Out-Null
Write-Output "[setup-winrm] Done."
} finally {
    Stop-Transcript
}
