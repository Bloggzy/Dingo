#requires -version 5.1
<#
Records how a clean Windows install sets up its services, diagnostic data, and
Defender sample submission, so Dingo's choices rest on a real baseline rather
than on a machine that has already been tuned. Read-only: the only thing it
writes is a new folder under Tests\Phase4\Evidence. It does not need Dingo.ps1
and does not need administrator rights.
#>
[CmdletBinding()]
param([ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Label='clean-defaults', [string]$OutputRoot='')
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
if (-not $OutputRoot) { $OutputRoot=Join-Path $PSScriptRoot 'Evidence' }
$destination=Join-Path ([IO.Path]::GetFullPath($OutputRoot)) ((Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+$Label+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void](New-Item -ItemType Directory -Path $destination)
function Save-Evidence($Name,$Value) {
    $json=ConvertTo-Json -InputObject $Value -Depth 10
    [IO.File]::WriteAllText((Join-Path $destination $Name),$json,(New-Object Text.UTF8Encoding($false)))
}
function Read-Value([string]$Path,[string]$Name) {
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return [ordered]@{ Path=$Path; Name=$Name; Exists=$false; Value=$null } }
        $property=(Get-ItemProperty -LiteralPath $Path -ErrorAction Stop).PSObject.Properties[$Name]
        if (-not $property) { return [ordered]@{ Path=$Path; Name=$Name; Exists=$false; Value=$null } }
        return [ordered]@{ Path=$Path; Name=$Name; Exists=$true; Value=$property.Value }
    } catch { return [ordered]@{ Path=$Path; Name=$Name; Exists=$false; Value=$null; Error=$_.Exception.Message } }
}

# No computer or account names: the files are meant to be shared.
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$elevated=(New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$os=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$memoryKb=[int64]((Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum / 1KB)
Save-Evidence 'environment.json' ([ordered]@{
    CapturedUtc=[DateTime]::UtcNow.ToString('o'); Label=$Label; Elevated=$elevated
    ProductName=$os.ProductName; EditionID=$os.EditionID; DisplayVersion=$os.DisplayVersion; Build="$($os.CurrentBuild).$($os.UBR)"
    InstallDateUtc=([DateTimeOffset]::FromUnixTimeSeconds([int64]$os.InstallDate)).UtcDateTime.ToString('o')
    PhysicalMemoryKB=$memoryKb; PowerShell=[string]$PSVersionTable.PSVersion
})

Write-Host 'Reading services...'
$servicesRoot='HKLM:\SYSTEM\CurrentControlSet\Services'
$services=@(foreach ($service in (Get-CimInstance Win32_Service | Sort-Object Name)) {
    $key=Join-Path $servicesRoot $service.Name
    $type=$null; $triggered=$false
    try {
        $type=[int](Get-ItemProperty -LiteralPath $key -Name Type -ErrorAction Stop).Type
        $triggered=Test-Path -LiteralPath (Join-Path $key 'TriggerInfo')
    } catch { }
    [pscustomobject]@{
        Name=$service.Name; DisplayName=$service.DisplayName; StartMode=$service.StartMode
        DelayedAutoStart=$service.DelayedAutoStart; TriggerStart=$triggered; State=$service.State
        # 0x40 marks the template of a per-user service, such as CDPUserSvc.
        PerUserTemplate=[bool]($null -ne $type -and ($type -band 0x40)); Account=$service.StartName
    }
})
$services | Export-Csv -LiteralPath (Join-Path $destination 'services.csv') -NoTypeInformation -Encoding UTF8

Write-Host 'Reading diagnostic data and privacy values...'
$advanced='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$values=@(
    (Read-Value 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry'),
    (Read-Value 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications'),
    (Read-Value 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry'),
    (Read-Value 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'MaxTelemetryAllowed'),
    (Read-Value 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities'),
    (Read-Value 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities'),
    (Read-Value 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' 'POWERSHELL_TELEMETRY_OPTOUT'),
    (Read-Value 'HKLM:\SYSTEM\CurrentControlSet\Control' 'SvcHostSplitThresholdInKB'),
    (Read-Value 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled'),
    (Read-Value 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled'),
    (Read-Value 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted'),
    (Read-Value 'HKCU:\Software\Microsoft\Input\TIPC' 'Enabled'),
    (Read-Value 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection'),
    (Read-Value 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection'),
    (Read-Value 'HKCU:\Software\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts'),
    (Read-Value 'HKCU:\Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy'),
    (Read-Value 'HKCU:\Software\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod'),
    (Read-Value $advanced 'Start_TrackProgs'),
    (Read-Value 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet' 'SubmitSamplesConsent')
)

Write-Host 'Reading Microsoft Defender...'
$defender=[ordered]@{}
try {
    $status=Get-MpComputerStatus -ErrorAction Stop
    $defender.AMRunningMode=$status.AMRunningMode; $defender.IsTamperProtected=$status.IsTamperProtected
} catch { $defender.StatusError=$_.Exception.Message }
try {
    $preference=Get-MpPreference -ErrorAction Stop
    $defender.SubmitSamplesConsent=$preference.SubmitSamplesConsent; $defender.MAPSReporting=$preference.MAPSReporting
    $defender.DisableBlockAtFirstSeen=$preference.DisableBlockAtFirstSeen
} catch { $defender.PreferenceError=$_.Exception.Message }
Save-Evidence 'privacy.json' ([ordered]@{ RegistryValues=$values; Defender=$defender })

Write-Host ''
Write-Host "Done. $($services.Count) services recorded in:"
Write-Host $destination
