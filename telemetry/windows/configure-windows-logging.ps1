$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$Root = "C:\ProgramData\Aegis\Telemetry"
$SysmonConfig = Join-Path $Root "sysmonconfig.xml"
$TranscriptDir = "C:\ProgramData\Aegis\PowerShellTranscripts"
$Marker = Join-Path $Root "windows-logging.json"

New-Item -ItemType Directory -Path $Root -Force | Out-Null
New-Item -ItemType Directory -Path $TranscriptDir -Force | Out-Null

function Set-Dword {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Value
    )
    New-Item -Path $Path -Force | Out-Null
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
}

function Set-StringValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )
    New-Item -Path $Path -Force | Out-Null
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType String -Force | Out-Null
}

Write-Output "[logging] Configuring Windows audit policy"
Set-Dword "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit" "ProcessCreationIncludeCmdLine_Enabled" 1

$AuditSubcategories = @(
    "Process Creation",
    "Process Termination",
    "Logon",
    "Logoff",
    "Account Lockout",
    "User Account Management",
    "Security Group Management",
    "Computer Account Management",
    "Security System Extension",
    "System Integrity",
    "Filtering Platform Connection",
    "Other Object Access Events"
)

foreach ($Subcategory in $AuditSubcategories) {
    auditpol.exe /set /subcategory:"$Subcategory" /success:enable /failure:enable | Out-Null
}

Write-Output "[logging] Enabling PowerShell logging"
$PowerShellPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell"
Set-Dword "$PowerShellPolicy\ScriptBlockLogging" "EnableScriptBlockLogging" 1
Set-Dword "$PowerShellPolicy\ModuleLogging" "EnableModuleLogging" 1
Set-StringValue "$PowerShellPolicy\ModuleLogging\ModuleNames" "*" "*"
Set-Dword "$PowerShellPolicy\Transcription" "EnableTranscripting" 1
Set-Dword "$PowerShellPolicy\Transcription" "EnableInvocationHeader" 1
Set-StringValue "$PowerShellPolicy\Transcription" "OutputDirectory" $TranscriptDir

wevtutil.exe sl "Microsoft-Windows-PowerShell/Operational" /e:true /ms:134217728
wevtutil.exe sl "Windows PowerShell" /ms:67108864
wevtutil.exe sl "Security" /ms:268435456
wevtutil.exe sl "System" /ms:134217728
wevtutil.exe sl "Application" /ms:134217728

Write-Output "[logging] Enabling Sysmon"
$SysmonCommand = Get-Command sysmon.exe -ErrorAction SilentlyContinue
if (-not $SysmonCommand) {
    $Feature = Get-WindowsOptionalFeature -Online -FeatureName Sysmon -ErrorAction SilentlyContinue
    if ($Feature -and $Feature.State -ne "Enabled") {
        Enable-WindowsOptionalFeature -Online -FeatureName Sysmon -NoRestart | Out-Null
    }
    $SysmonCommand = Get-Command sysmon.exe -ErrorAction SilentlyContinue
}

if (-not $SysmonCommand) {
    $Fallback = Join-Path $Root "Sysmon64.exe"
    if (Test-Path $Fallback) {
        $SysmonCommand = Get-Item $Fallback
    }
}

if (-not $SysmonCommand) {
    $ZipPath = Join-Path $Root "Sysmon.zip"
    $ExtractPath = Join-Path $Root "Sysmon"
    $SysmonUrl = "https://download.sysinternals.com/files/Sysmon.zip"

    Write-Output "[logging] Built-in Sysmon not found; downloading Sysinternals Sysmon from Microsoft."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $SysmonUrl -OutFile $ZipPath -UseBasicParsing
    if (Test-Path $ExtractPath) {
        Remove-Item -Path $ExtractPath -Recurse -Force
    }
    Expand-Archive -Path $ZipPath -DestinationPath $ExtractPath -Force
    $Fallback = Get-ChildItem -Path $ExtractPath -Filter "Sysmon64.exe" -Recurse | Select-Object -First 1
    if ($Fallback) {
        Copy-Item -Path $Fallback.FullName -Destination (Join-Path $Root "Sysmon64.exe") -Force
        $SysmonCommand = Get-Item (Join-Path $Root "Sysmon64.exe")
    }
}

if (-not $SysmonCommand) {
    throw "Sysmon is not available as a built-in feature and no fallback Sysmon64.exe exists in $Root"
}

$SysmonPath = if ($SysmonCommand.Source) { $SysmonCommand.Source } else { $SysmonCommand.FullName }
$SysmonService = Get-Service -Name "Sysmon*" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($SysmonService) {
    & $SysmonPath -c $SysmonConfig | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Sysmon configuration update failed with exit code $LASTEXITCODE"
    }
} else {
    & $SysmonPath -accepteula -i $SysmonConfig | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Sysmon install failed with exit code $LASTEXITCODE"
    }
}

wevtutil.exe sl "Microsoft-Windows-Sysmon/Operational" /e:true /ms:268435456

$Result = [pscustomobject]@{
    configured_at = (Get-Date).ToString("o")
    computer_name = $env:COMPUTERNAME
    sysmon_path = $SysmonPath
    sysmon_service = (Get-Service -Name "Sysmon*" -ErrorAction SilentlyContinue | Select-Object -First 1).Name
    sysmon_log = "Microsoft-Windows-Sysmon/Operational"
    powershell_transcription = $TranscriptDir
}

$Result | ConvertTo-Json | Set-Content -Path $Marker -Encoding UTF8
$Result | ConvertTo-Json -Compress
