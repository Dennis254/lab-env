# install-virtio-tools.ps1 - install virtio-win-guest-tools.
# ---------------------------------------------------------------------------
# Run virtio-win-guest-tools.exe from the PROVISION CD. This avoids sending
# the 30 MB installer through slow WinRM file upload. Installs qemu-ga + virtio-
# enhanced drivers (Balloon, Serial, RNG, etc.) - not boot-critical
# drivers (disk and NIC use IDE/e1000 during the build).
#
# qemu-guest-agent lets libvirt take coherent snapshots (fs-freeze)
# and query in-guest state.
# ---------------------------------------------------------------------------

$ErrorActionPreference = "Stop"

$cd = Get-Volume |
    Where-Object { $_.FileSystemLabel -eq 'PROVISION' -and $_.DriveLetter } |
    Select-Object -First 1

$candidates = @()
if ($cd) {
    $candidates += "$($cd.DriveLetter):\virtio-win-guest-tools.exe"
}
$candidates += "C:\Windows\Temp\virtio-win-guest-tools.exe"

$installer = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not (Test-Path $installer)) {
    throw "virtio-win-guest-tools.exe missing. Tried: $($candidates -join ', ')"
}

Write-Output "[virtio-tools] Installing from $installer ..."
$proc = Start-Process -FilePath $installer -ArgumentList "/install","/quiet","/norestart" -Wait -PassThru
if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
    # 3010 = success, reboot needed. We do not reboot between provisioners.
    throw "virtio-tools installer exit code $($proc.ExitCode)"
}
Write-Output "[virtio-tools] Installed (exit code $($proc.ExitCode))."

# Confirm that qemu-ga is registered and running.
$svc = Get-Service -Name "QEMU-GA" -ErrorAction SilentlyContinue
if ($svc) {
    Set-Service -Name "QEMU-GA" -StartupType Automatic -ErrorAction SilentlyContinue
    if ($svc.Status -ne "Running") {
        Start-Service -Name "QEMU-GA" -ErrorAction SilentlyContinue
        $svc = Get-Service -Name "QEMU-GA" -ErrorAction SilentlyContinue
    }
    Write-Output "[virtio-tools] QEMU-GA service status: $($svc.Status)"
} else {
    Write-Warning "[virtio-tools] QEMU-GA service was not found - check the installer log."
}

if ($installer -like "C:\Windows\Temp\*") {
    Remove-Item -Path $installer -Force -ErrorAction SilentlyContinue
}
