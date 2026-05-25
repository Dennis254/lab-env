# sysprep.ps1 - prepare sysprep unattend file.
# ---------------------------------------------------------------------------
# Generalizes Windows:
#   - Resets hostname, SID, hardware cache and event logs
#   - Leaves the OS in factory state so next boot triggers OOBE
# Packer runs sysprep itself as shutdown_command. Keeping the shutdown step
# in Packer avoids a race where sysprep stops WinRM before Packer can send
# its own shutdown command.
#
# Uses sysprep-unattend.xml from A:\ or from the PROVISION CD.
# ---------------------------------------------------------------------------

$ErrorActionPreference = "Stop"

$candidates = @(
    "A:\sysprep-unattend.xml"
)

$cd = Get-Volume |
    Where-Object { $_.FileSystemLabel -eq 'PROVISION' -and $_.DriveLetter } |
    Select-Object -First 1
if ($cd) {
    $candidates += "$($cd.DriveLetter):\sysprep-unattend.xml"
}

$src = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
$dst = "C:\Windows\System32\Sysprep\unattend.xml"

if (-not $src) {
    throw "sysprep-unattend.xml missing. Tried: $($candidates -join ', ')"
}

Copy-Item -Path $src -Destination $dst -Force
Write-Output "[sysprep] Copied unattend file to $dst"

Write-Output "[sysprep] Prepared unattend file. Packer shutdown_command will run sysprep."
exit 0
