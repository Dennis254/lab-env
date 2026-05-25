# cleanup.ps1 - image cleanup before sysprep.
# ---------------------------------------------------------------------------
# Goals:
#   1. Remove temp files, setup logs and Windows Update cache.
#   2. Disable power states that are awkward for cloned lab VMs.
#   3. Keep the image build reliable; host-side compaction can be added later.
#
# Security note: do not remove Defender updates or event logs.
# ---------------------------------------------------------------------------

$ErrorActionPreference = "Continue"  # cleanup should not fail the build

Write-Output "[cleanup] Stopping non-essential update services for cleanup phase..."
Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
Stop-Service -Name BITS     -Force -ErrorAction SilentlyContinue

Write-Output "[cleanup] Disabling hibernate, fast startup and sleep timers..."
powercfg.exe /hibernate off | Out-Null
powercfg.exe /change standby-timeout-ac 0 | Out-Null
powercfg.exe /change standby-timeout-dc 0 | Out-Null
powercfg.exe /change monitor-timeout-ac 0 | Out-Null
powercfg.exe /change monitor-timeout-dc 0 | Out-Null
New-ItemProperty `
    -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" `
    -Name "HiberbootEnabled" `
    -Value 0 `
    -PropertyType DWord `
    -Force | Out-Null

Write-Output "[cleanup] Removing Windows Update cache..."
Remove-Item -Path "C:\Windows\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue

Write-Output "[cleanup] Removing setup logs and temp files..."
Remove-Item -Path "C:\Windows\Panther\*"     -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "C:\Windows\Logs\CBS\*"    -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path "C:\Windows\Temp" -Force -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -notlike "packer-*" -and
        $_.Name -notlike "script-*" -and
        $_.Name -notlike "setup-winrm*" -and
        $_.Name -notlike "firstlogon-winrm*"
    } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$env:LOCALAPPDATA\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue

# Restart services we stopped so post-clone Windows is normal.
Write-Output "[cleanup] Restarting services..."
Start-Service -Name wuauserv -ErrorAction SilentlyContinue
Start-Service -Name BITS     -ErrorAction SilentlyContinue

Write-Output "[cleanup] Skipping in-guest zero-fill during iterative image builds."
Write-Output "[cleanup] Done."
exit 0
