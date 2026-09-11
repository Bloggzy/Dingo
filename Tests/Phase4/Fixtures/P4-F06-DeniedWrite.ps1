#requires -version 5.1
[CmdletBinding()]
param(
    [string]$DingoPath = (Join-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) 'Dingo.ps1'),
    [string]$OutputPath = 'C:\Temp\p4-f06-result.json'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$source = (Resolve-Path -LiteralPath $DingoPath -ErrorAction Stop).Path
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors.Message -join '; ') }
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) {
        Invoke-Expression $statement.Extent.Text
    }
}

$script:RemoveValue = '__REMOVE_VALUE__'
$script:LanguageChangePending = $false
$script:SettingHandlers = @{}
$script:DeviceIsManaged = $false
Initialize-SettingHandlers
$fixtureRoot = 'HKCU:\Software\Dingo\Phase4\P4-F06'
$fixtureParentSubKey = 'Software\Dingo\Phase4'
$fixtureName = 'P4-F06'
$fixtureSubKey = "$fixtureParentSubKey\$fixtureName"
$deniedSubKey = "$fixtureSubKey\Denied"

function Test-RegistrySubKeyExists {
    param([Parameter(Mandatory)][string]$SubKey)

    $probeKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKey)
    if ($null -eq $probeKey) { return $false }
    try { return $true }
    finally { $probeKey.Dispose() }
}

$firstPath = Join-Path $fixtureRoot 'First'
$deniedPath = Join-Path $fixtureRoot 'Denied'
$skippedPath = Join-Path $fixtureRoot 'Skipped'
$logDirectory = Join-Path (Split-Path $source -Parent) 'Logs'
New-Item -ItemType Directory -Path $logDirectory -Force -ErrorAction Stop | Out-Null
$script:LogFile = Join-Path $logDirectory ("P4-F06-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
$deniedKeyHandle = $null
$denyRule = $null
$result = $null
$valuesAfterApply = $null
$denyRulePresent = $false
$cleanupError = ''
$fixtureExistsAfterCleanup = $true

if (Test-RegistrySubKeyExists -SubKey $fixtureSubKey) {
    throw "Refusing to reuse the existing fixture key: $fixtureRoot"
}

try {
    $fixtureKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($fixtureSubKey)
    if ($null -eq $fixtureKey) {
        throw "Could not create the fixture key: $fixtureSubKey"
    }
    try {
        foreach ($name in @('First', 'Denied', 'Skipped')) {
            $entryKey = $fixtureKey.CreateSubKey($name)
            if ($null -eq $entryKey) {
                throw "Could not create the fixture entry key: $fixtureSubKey\$name"
            }
            try {
                $entryKey.SetValue('Value', 0, [Microsoft.Win32.RegistryValueKind]::DWord)
            }
            finally {
                $entryKey.Dispose()
            }
        }
    }
    finally {
        $fixtureKey.Dispose()
    }

    $aclRights = (
        [Security.AccessControl.RegistryRights]::ReadKey -bor
        [Security.AccessControl.RegistryRights]::ChangePermissions
    )
    $deniedKeyHandle = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
        $deniedSubKey,
        [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
        $aclRights
    )
    if ($null -eq $deniedKeyHandle) {
        throw "Could not open the denied fixture key for ACL changes: $deniedSubKey"
    }

    $deniedAcl = $deniedKeyHandle.GetAccessControl()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $denyRule = [Security.AccessControl.RegistryAccessRule]::new(
        $identity,
        [Security.AccessControl.RegistryRights]::SetValue,
        [Security.AccessControl.AccessControlType]::Deny
    )
    [void]$deniedAcl.AddAccessRule($denyRule)
    $deniedKeyHandle.SetAccessControl($deniedAcl)
    $accountName = $identity.Translate([Security.Principal.NTAccount]).Value
    $denyRulePresent = [bool](@($deniedKeyHandle.GetAccessControl().GetAccessRules(
        $true,
        $false,
        [Security.Principal.NTAccount]
    ) | Where-Object {
        [string]$_.IdentityReference -eq $accountName -and
        $_.AccessControlType -eq 'Deny' -and
        ($_.RegistryRights -band [Security.AccessControl.RegistryRights]::SetValue)
    }).Count)

    $entries = @(
        (New-Entry User 'Software\Dingo\Phase4\P4-F06\First' 'Value' 1 0 DWord),
        (New-Entry User 'Software\Dingo\Phase4\P4-F06\Denied' 'Value' 1 0 DWord),
        (New-Entry User 'Software\Dingo\Phase4\P4-F06\Skipped' 'Value' 1 0 DWord)
    )
    $setting = New-Setting 'p4-f06-denied-write' 'Phase 4 fixtures' 'P4-F06 denied write' 'Disposable registry fixture.' 'Enabled' 'Disabled' 'Registry' $entries
    $setting.DesiredState = $setting.PreferredState
    $setting.CurrentState = Get-SettingState $setting
    $result = Invoke-SettingChange $setting @{}
    $valuesAfterApply = [ordered]@{
        First = (Get-ItemPropertyValue -LiteralPath $firstPath -Name Value)
        Denied = (Get-ItemPropertyValue -LiteralPath $deniedPath -Name Value)
        Skipped = (Get-ItemPropertyValue -LiteralPath $skippedPath -Name Value)
    }
}
finally {
    try {
        if ($null -ne $denyRule -and $null -ne $deniedKeyHandle) {
            $cleanupAcl = $deniedKeyHandle.GetAccessControl()
            $cleanupAcl.RemoveAccessRuleSpecific($denyRule)
            $deniedKeyHandle.SetAccessControl($cleanupAcl)
        }
    }
    catch {
        $cleanupError = $_.Exception.Message
    }
    if ($null -ne $deniedKeyHandle) {
        $deniedKeyHandle.Dispose()
    }
    $deleteError = ''
    try {
        $fixtureParentKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
            $fixtureParentSubKey,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [Security.AccessControl.RegistryRights]::FullControl
        )
        if ($null -eq $fixtureParentKey) {
            throw "Could not open the fixture parent key for cleanup: $fixtureParentSubKey"
        }
        try {
            $fixtureParentKey.DeleteSubKeyTree($fixtureName, $false)
        }
        finally {
            $fixtureParentKey.Dispose()
        }
    }
    catch {
        $deleteError = $_.Exception.Message
    }

    $fixtureExistsAfterCleanup = Test-RegistrySubKeyExists -SubKey $fixtureSubKey
    if ($fixtureExistsAfterCleanup) {
        if (-not $deleteError) {
            $deleteError = "Fixture key still exists after cleanup: $fixtureSubKey"
        }
        $cleanupMessages = @($cleanupError, $deleteError) | Where-Object { $_ }
        $cleanupError = $cleanupMessages -join '; '
    }
}

$entryComponents = @($result.Components | Where-Object { $_.PSObject.Properties['Before'] })
$expectedOutcomes = @($entryComponents | ForEach-Object Outcome) -join ','
$success = (
    $denyRulePresent -and
    $result.Outcome -eq 'PartiallyApplied' -and
    $expectedOutcomes -eq 'Succeeded,Failed,Skipped' -and
    $valuesAfterApply.First -eq 1 -and
    $valuesAfterApply.Denied -eq 0 -and
    $valuesAfterApply.Skipped -eq 0 -and
    -not $fixtureExistsAfterCleanup -and
    -not $cleanupError
)

$payload = [ordered]@{
    HarnessSuccess = $success
    DenyRulePresent = $denyRulePresent
    ValuesAfterApply = $valuesAfterApply
    FixtureRootExistsAfterCleanup = $fixtureExistsAfterCleanup
    CleanupError = $cleanupError
    LogPath = $script:LogFile
    JournalPath = "$($script:LogFile).$PID.journal.jsonl"
    DingoResult = $result
}
$json = ConvertTo-Json -InputObject $payload -Depth 12
[IO.File]::WriteAllText($OutputPath, $json, (New-Object Text.UTF8Encoding($false)))
[Console]::Out.WriteLine($json)
if ($success) { exit 0 }
exit 1
