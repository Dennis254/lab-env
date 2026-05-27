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

$toolsCandidates = @()
$gaCandidates = @()
if ($cd) {
    $toolsCandidates += "$($cd.DriveLetter):\virtio-win-guest-tools.exe"
    $gaCandidates += "$($cd.DriveLetter):\qemu-ga-x86_64.msi"
}
$toolsCandidates += "C:\Windows\Temp\virtio-win-guest-tools.exe"
$gaCandidates += "C:\Windows\Temp\qemu-ga-x86_64.msi"

function Test-SuccessExitCode {
    param([int] $ExitCode)
    return ($ExitCode -eq 0 -or $ExitCode -eq 3010)
}

function Start-QemuGa {
    $svc = Get-Service -Name "QEMU-GA" -ErrorAction SilentlyContinue
    if (-not $svc) {
        return $null
    }

    Set-Service -Name "QEMU-GA" -StartupType Automatic -ErrorAction SilentlyContinue
    if ($svc.Status -ne "Running") {
        Start-Service -Name "QEMU-GA" -ErrorAction SilentlyContinue
        $svc = Get-Service -Name "QEMU-GA" -ErrorAction SilentlyContinue
    }
    return $svc
}

function Install-QemuGaMsi {
    param([string] $MsiPath)

    Write-Output "[virtio-tools] Installing QEMU-GA fallback from $MsiPath ..."
    $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i",$MsiPath,"/qn","/norestart" -Wait -PassThru
    if (-not (Test-SuccessExitCode $proc.ExitCode)) {
        throw "qemu-ga MSI installer exit code $($proc.ExitCode)"
    }
    Write-Output "[virtio-tools] QEMU-GA fallback installed (exit code $($proc.ExitCode))."
}

$toolsInstaller = $toolsCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
$gaInstaller = $gaCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $toolsInstaller) {
    throw "virtio-win-guest-tools.exe missing. Tried: $($toolsCandidates -join ', ')"
}

Write-Output "[virtio-tools] Installing from $toolsInstaller ..."
$proc = Start-Process -FilePath $toolsInstaller -ArgumentList "/install","/quiet","/norestart" -Wait -PassThru
if (Test-SuccessExitCode $proc.ExitCode) {
    Write-Output "[virtio-tools] Installed (exit code $($proc.ExitCode))."
} else {
    Write-Warning "[virtio-tools] Full installer exit code $($proc.ExitCode). Checking QEMU-GA before fallback."
    $svc = Start-QemuGa
    if ($svc) {
        Write-Warning "[virtio-tools] Continuing because QEMU-GA is installed despite full installer failure."
    } elseif ($gaInstaller) {
        Install-QemuGaMsi $gaInstaller
    } else {
        throw "virtio-tools installer exit code $($proc.ExitCode); qemu-ga fallback missing. Tried: $($gaCandidates -join ', ')"
    }
}

$svc = Start-QemuGa
if ($svc) {
    Write-Output "[virtio-tools] QEMU-GA service status: $($svc.Status)"
} else {
    throw "[virtio-tools] QEMU-GA service was not found after installation."
}

foreach ($path in @($toolsInstaller, $gaInstaller)) {
    if ($path -and $path -like "C:\Windows\Temp\*") {
        Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
    }
}
