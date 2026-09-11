#requires -version 5.1
<# Reads configuration without applying Dingo. Only the evidence folder is written. #>
[CmdletBinding()]
param([ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Label='baseline', [string]$OutputRoot='')
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
if (-not $OutputRoot) { $OutputRoot=Join-Path $PSScriptRoot 'Evidence' }
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$source=Join-Path $repoRoot 'Dingo.ps1'
$tokens=$null; $parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors.Message -join '; ') }
# Import definitions only: never dot-source Dingo's startup, installers or self-tests.
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) { Invoke-Expression $statement.Extent.Text }
}
$script:LogFile=$null
$script:RemoveValue='__REMOVE_VALUE__'
$script:SettingHandlers=@{}
$script:DeviceIsManaged=$null
$script:ToolCatalogWarning=''
$script:ToolCatalogCache=$null
$script:ShimDirectory='C:\DFIR\Tools\bin'
$script:ShimMarker='REM Written by Dingo. Safe to delete.'
$script:MachineEnvironmentSubKey='SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
$script:StartMenuShortcutDirectory=Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\DFIR Tools'
$script:DesktopShortcutDirectory=Join-Path $env:PUBLIC 'Desktop'
$script:ShortcutMarker='Created by Dingo. Safe to delete.'
$script:AssociationProgIdPrefix='Dingo.'
$script:AssociationBackupSubKey='Software\Dingo\FileAssociations'
$TargetUserSid=''
$MachineWorker=$false
function Get-ToolCatalogPath { Join-Path $repoRoot 'Tools.json' }
Initialize-SettingHandlers
$settings=Get-Settings
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$principal=New-Object Security.Principal.WindowsPrincipal($identity)
$elevated=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$destination=Join-Path ([IO.Path]::GetFullPath($OutputRoot)) ((Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+$Label+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void](New-Item -ItemType Directory -Path $destination)
function Save-Evidence($Name,$Value) {
    $json=ConvertTo-Json -InputObject $Value -Depth 20
    [IO.File]::WriteAllText((Join-Path $destination $Name),$json,(New-Object Text.UTF8Encoding($false)))
}
$os=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Save-Evidence 'environment.json' ([ordered]@{
    CapturedUtc=[DateTime]::UtcNow.ToString('o'); Label=$Label; Computer=$env:COMPUTERNAME
    Account=$identity.Name; Sid=$identity.User.Value; Profile=$env:USERPROFILE; Elevated=$elevated
    WindowsVersion=$os.DisplayVersion; Build="$($os.CurrentBuild).$($os.UBR)"; Edition=$os.EditionID
    PowerShell=[string]$PSVersionTable.PSVersion; ScriptSha256=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    UserPath=[Environment]::GetEnvironmentVariable('Path','User'); MachinePath=[Environment]::GetEnvironmentVariable('Path','Machine')
})
$states=@(foreach ($setting in $settings) {
    Write-Host "Reading $($setting.Id)..."
    $state=Get-SettingState $setting
    [pscustomobject]@{ Id=$setting.Id; Name=$setting.Name; Kind=$setting.Kind; Preferred=$setting.PreferredState; State=$state }
})
Save-Evidence 'settings.json' $states
$inventory=@(foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')) {
    try {
        if (Test-Path -LiteralPath $root) {
            foreach ($key in Get-ChildItem -LiteralPath $root -ErrorAction Stop) {
                try {
                    $entry=Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
                    if ($entry.PSObject.Properties['DisplayName']) {
                        [pscustomobject]@{ RegistryKey=$key.Name; Name=$entry.DisplayName; Version=Get-JsonField $entry 'DisplayVersion' ''; Publisher=Get-JsonField $entry 'Publisher' ''; Status='Read' }
                    }
                } catch { [pscustomobject]@{ RegistryKey=$key.Name; Status='Error'; Message=$_.Exception.Message } }
            }
        }
    } catch { [pscustomobject]@{ RegistryKey=$root; Status='Error'; Message=$_.Exception.Message } }
})
Save-Evidence 'installed-software.json' $inventory
$files=@(foreach ($directory in @($script:ShimDirectory,$script:StartMenuShortcutDirectory,$script:DesktopShortcutDirectory)) {
    try {
        if (Test-Path -LiteralPath $directory) {
            foreach ($file in Get-ChildItem -LiteralPath $directory -File -ErrorAction Stop) {
                try { [pscustomobject]@{ Path=$file.FullName; Length=$file.Length; Sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash; Status='Read' } }
                catch { [pscustomobject]@{ Path=$file.FullName; Status='Error'; Message=$_.Exception.Message } }
            }
        }
    } catch { [pscustomobject]@{ Path=$directory; Status='Error'; Message=$_.Exception.Message } }
})
Save-Evidence 'shortcut-launcher-files.json' $files
Save-Evidence 'catalog-warning.json' $script:ToolCatalogWarning
$states | Select-Object Id,Kind,@{n='Status';e={$_.State.Status}},@{n='Display';e={$_.State.DisplayText}} | Export-Csv -LiteralPath (Join-Path $destination 'settings-summary.csv') -NoTypeInformation -Encoding UTF8
Write-Host "Evidence saved to $destination"
if ($elevated) { Write-Warning 'This collector ran elevated. Capture the primary baseline again from a normal console so it matches the intended Dingo launch context.' }
Write-Host 'Read errors and partial states are evidence, not a reason to apply changes. No settings were applied and no applications were launched.'
