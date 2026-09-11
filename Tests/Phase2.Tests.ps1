#requires -version 5.1
# Isolated tests: registry/installer operations are mocked; only a unique local
# test directory is written. Dingo's startup and embedded tests never execute.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'Dingo.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors.Message -join '; ') }
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) { Invoke-Expression $statement.Extent.Text }
}
$script:LogFile=$null
$script:RemoveValue='__REMOVE_VALUE__'
$script:SettingHandlers=@{}
$script:ToolCatalogWarning=''
$script:DeviceIsManaged=$false
$script:AssociationProgIdPrefix='Dingo.'
$script:ShimDirectory='C:\DFIR\Tools\bin'
$script:StartMenuShortcutDirectory='C:\Unused-Test-Folder'
$script:DesktopShortcutDirectory='C:\Unused-Test-Folder'
$script:ToolCatalogCache=@(Get-BuiltInToolCatalog | ForEach-Object { ConvertTo-ToolDefinition $_ })
Initialize-SettingHandlers
$script:Settings=Get-Settings
$script:Passed=0
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Test-Case([string]$Name,[scriptblock]$Body) { & $Body; $script:Passed++; "PASS $Name" }
function Assert-Throws([scriptblock]$Body,[string]$Pattern) {
    $message=''; try { & $Body } catch { $message=$_.Exception.Message }
    Assert ($message -match $Pattern -and [bool]$message) "Expected '$Pattern'; got '$message'."
}
function New-TestTool($Mode,$Paths) {
    ConvertTo-ToolDefinition ([pscustomobject]@{
        id='tool-probe'; name='Probe'; install=[pscustomobject]@{package='Test.Probe'}; detectMode=$Mode
        detect=@($Paths | ForEach-Object { [pscustomobject]@{kind='file';path=$_} })
    })
}
function New-TestPackage($Tool) { New-Setting $Tool.Id Tools $Tool.Name Test Installed $null Package @($Tool) }
function New-TestAssociation([string]$Extension) { [pscustomobject]@{Scope='User';Extension=$Extension;Target=$probe;Description='Test file'} }
function Invoke-AssociationFixture([scriptblock]$Body) {
    $store=@{Choices=@{};Current=@{};Commands=@{};OpenWith=@{};ExplorerOpenWith=@{};Backups=@{}}
    function Get-ExtensionUserChoice($Extension) { [string]$store.Choices[$Extension] }
    function Get-ExtensionHandlerName($Extension) { [string]$store.Current[$Extension] }
    function Get-AssociationRegistration($Association) {
        $configured=[bool]$store.OpenWith[$Association.Extension]
        $explorer=[bool]$store.ExplorerOpenWith[$Association.Extension]
        [pscustomobject]@{
            Command=[string]$store.Commands[(Get-AssociationProgId $Association)]
            OpenWithRegistered=($configured -or $explorer)
            ConfiguredOpenWithRegistered=$configured
            ExplorerOpenWithRegistered=$explorer
        }
    }
    function Register-AssociationProgId($Association) { $store.Commands[(Get-AssociationProgId $Association)]='"{0}" "%1"' -f (Get-AssociationTarget $Association) }
    function Add-AssociationOpenWithEntry($Association) { $store.OpenWith[$Association.Extension]=$true }
    function Remove-AssociationOpenWithEntry($Association) {
        [void]$store.OpenWith.Remove($Association.Extension)
        [void]$store.ExplorerOpenWith.Remove($Association.Extension)
    }
    function Save-AssociationBackup($Extension,$PreviousHandler) { if (-not $store.Backups.ContainsKey($Extension)) { $store.Backups[$Extension]=$PreviousHandler } }
    function Get-AssociationBackup($Extension) { [string]$store.Backups[$Extension] }
    function Remove-AssociationBackup($Extension) { [void]$store.Backups.Remove($Extension) }
    function Remove-ExtensionHandlerName($Extension) { [void]$store.Current.Remove($Extension) }
    function Remove-EmptyExtensionKey {}
    function Send-AssociationChange {}
    function New-Item {
        param($Path,[switch]$Force,$ErrorAction)
        if ($Path -notlike 'HKCU:*') { throw 'Unexpected write' }
        # Model the Windows PowerShell 5.1 registry-provider behavior found in
        # the VM: forcing the parent after OpenWithProgids removes that child.
        if ($Force -and $Path -match 'HKCU:\\Software\\Classes\\(\.[^\\]+)$') { [void]$store.OpenWith.Remove($Matches[1]) }
    }
    function Set-ItemProperty {
        param($Path,$Name,$Value,$ErrorAction)
        if ($Path -notlike 'HKCU:\Software\Classes\.*' -or $Name -ne '(default)') { throw 'Unexpected registry write' }
        $extension=$Path.Substring($Path.LastIndexOf('\')+1); $store.Current[$extension]=$Value
    }
    function Remove-Item { throw 'Unexpected deletion of shared ProgID' }
    & $Body
}
function Invoke-RegistryFixture([scriptblock]$Body) {
    $values=@{}
    $attempts=New-Object Collections.ArrayList
    foreach ($name in @('First','Second','Third')) { $values[$name]=[pscustomobject]@{Status='Present';Exists=$true;Value=0;ValueType='DWord';ErrorMessage=''} }
    function Get-EntryValue($Entry) { $values[$Entry.Name] }
    function Set-EntryValue($Entry,$DesiredState,$Setting) {
        [void]$attempts.Add($Entry.Name)
        if ($Entry.Name -eq 'Second') { throw 'Simulated denied write' }
        $values[$Entry.Name]=[pscustomobject]@{Status='Present';Exists=$true;Value=1;ValueType='DWord';ErrorMessage=''}
    }
    $setting=New-Setting 'registry-probe' Test Probe Test Enabled Disabled Registry @(
        (New-Entry User 'Software\DingoTest' First 1 0),
        (New-Entry User 'Software\DingoTest' Second 1 0),
        (New-Entry User 'Software\DingoTest' Third 1 0)
    )
    & $Body
}
$scratch=Join-Path $PSScriptRoot ('.phase2-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$probe=Join-Path $scratch 'Probe.exe'
[IO.File]::WriteAllText($probe,'presence fixture, never executed')
try {
    Test-Case 'Wildcard detection handles zero one and multiple matching folders' {
        $pattern=Join-Path $scratch '9.*'
        $rule=[pscustomobject]@{Kind='file';Path=$pattern}
        Assert (-not (Find-ToolDetectionRule $rule)) 'Empty wildcard must mean missing.'
        [void](New-Item -ItemType Directory -Path (Join-Path $scratch '9.0.1'))
        Assert ((Find-ToolDetectionRule $rule).Version -eq '9.0.1') 'Single wildcard match failed.'
        [void](New-Item -ItemType Directory -Path (Join-Path $scratch '9.0.2'))
        Assert ([bool](Find-ToolDetectionRule $rule)) 'Multiple wildcard matches failed.'
    }
    Test-Case 'Any detection preserves alternatives; all detection requires every target' {
        $missing=Join-Path $scratch 'Missing.exe'
        $any=New-TestTool any @($probe,$missing)
        $all=New-TestTool all @($probe,$missing)
        Assert ([bool](Find-InstalledTool $any)) 'Any detection did not accept a matching alternative.'
        Assert (-not (Find-InstalledTool $all)) 'All detection accepted a partial inventory.'
        $state=Get-PackageKindState (New-TestPackage $all)
        Assert ($state.Status -eq 'Partial' -and $state.DisplayText -eq 'Incomplete installation' -and $state.Detection.Missing -contains $missing) 'Missing inventory not disclosed.'
        [IO.File]::WriteAllText($missing,'fixture')
        Assert ((Get-PackageKindState (New-TestPackage $all)).Status -eq 'Preferred') 'Complete minimum inventory was not accepted.'
    }
    Test-Case 'EZTools requires the two GUI tools and two core command-line tools' {
        $ez=Get-ToolCatalog | Where-Object Id -eq 'tool-eztools'
        Assert ($ez.DetectMode -eq 'all' -and $ez.Detect.Count -eq 4) 'EZTools inventory requirement missing.'
        foreach ($name in @('TimelineExplorer.exe','RegistryExplorer.exe','EvtxECmd.exe','RECmd.exe')) {
            Assert (@($ez.Detect | Where-Object { $_.Path -like "*/$name" }).Count -eq 1) "Missing $name rule."
        }
    }
    Test-Case 'Malformed detection mode and empty rule targets are rejected' {
        Assert-Throws { New-TestTool sometimes @($probe) } 'detectMode'
        Assert-Throws { New-TestTool all @('') } 'without'
    }
    Test-Case 'Detection read errors become Error rather than Not installed' {
        function Find-ToolDetectionRule { throw 'Access denied while inspecting inventory' }
        $state=Get-SettingState (New-TestPackage (New-TestTool all @($probe)))
        Assert ($state.Status -eq 'Error' -and $state.Details -match 'Access denied') 'Read failure looked like missing installation.'
    }
    Test-Case 'Missing prerequisites are separate from a complete tool inventory' {
        $tool=New-TestTool all @($probe)
        $tool.Requires=@('tool-absent-runtime')
        $state=Get-PackageKindState (New-TestPackage $tool)
        Assert ($state.Detection.Complete -and $state.Status -eq 'Partial' -and $state.MissingPrerequisites -contains 'tool-absent-runtime') 'Runtime readiness was overstated.'
    }
    Test-Case 'All protected extensions succeed with verified Open With fallback' {
        Invoke-AssociationFixture {
            $a=New-TestAssociation '.aaa'; $b=New-TestAssociation '.bbb'
            $store.Choices['.aaa']='Other.App'; $store.Choices['.bbb']='Other.App'
            $setting=New-Setting 'assoc-probe' Test Probe Test Configure Remove Association @($a,$b)
            $result=Invoke-SettingChange $setting @{}
            Assert ($result.Success -and $setting.CurrentState.Status -eq 'Preferred') 'Fallback was reported as failure.'
            Assert ($setting.CurrentState.DisplayText -match 'fallback for 2') 'Fallback was described as a changed default.'
            Assert ($store.Current.Count -eq 0 -and $store.Choices['.aaa'] -eq 'Other.App') 'Protected defaults were changed.'
            Assert (@($result.Components | Where-Object { $_.Name -in @('.aaa','.bbb') }).Count -eq 2) 'Per-extension results missing.'
        }
    }
    Test-Case 'Mixed default and protected extensions report different verified actions' {
        Invoke-AssociationFixture {
            $a=New-TestAssociation '.aaa'; $b=New-TestAssociation '.bbb'
            $store.Choices['.bbb']='Other.App'
            $setting=New-Setting 'assoc-probe' Test Probe Test Configure Remove Association @($a,$b)
            $result=Invoke-SettingChange $setting @{}
            Assert ($result.Success -and $store.Current['.aaa'] -eq (Get-AssociationProgId $a)) ("Default registration failed: " + ($result | ConvertTo-Json -Depth 8 -Compress))
            $states=@($setting.CurrentState.Associations | ForEach-Object State)
            Assert ($states -contains 'DefaultRegistered' -and $states -contains 'OpenWithOnly') 'Mixed outcomes collapsed.'
        }
    }
    Test-Case 'Correct handler name with a wrong open command is not preferred' {
        Invoke-AssociationFixture {
            $a=New-TestAssociation '.aaa'; $id=Get-AssociationProgId $a
            $store.Current['.aaa']=$id; $store.OpenWith['.aaa']=$true; $store.Commands[$id]='"wrong.exe" "%1"'
            Assert ((Get-AssociationStatus $a).State -eq 'BrokenRegistration') 'Broken command was accepted.'
            $setting=New-Setting 'assoc-probe' Test Probe Test Configure Remove Association @($a)
            Assert ((Invoke-SettingChange $setting @{}).Success) 'Broken registration could not be repaired.'
        }
    }
    Test-Case 'Association targets are stored as native Windows paths' {
        $a=[pscustomobject]@{ Scope='User'; Extension='.aaa'; Target='C:/Program Files/Test Tool/Test.exe'; Description='Test file' }
        $target=Get-AssociationTarget $a
        Assert ($target -eq 'C:\Program Files\Test Tool\Test.exe') "Association target was not normalized: $target"
        Invoke-AssociationFixture {
            Register-AssociationProgId $a
            $command=$store.Commands[(Get-AssociationProgId $a)]
            Assert ($command -eq '"C:\Program Files\Test Tool\Test.exe" "%1"') "Association command used a non-native path: $command"
        }
    }
    Test-Case 'Missing one target cannot be hidden by another successful association' {
        Invoke-AssociationFixture {
            $a=New-TestAssociation '.aaa'; $b=New-TestAssociation '.bbb'; $b.Target=Join-Path $scratch 'AbsentProgram.exe'
            $setting=New-Setting 'assoc-probe' Test Probe Test Configure Remove Association @($a,$b)
            $result=Invoke-SettingChange $setting @{}
            Assert ($result.Outcome -eq 'PartiallyApplied' -and $setting.CurrentState.Status -eq 'Partial') 'Missing target was silently omitted.'
            Assert (@($result.Components | Where-Object { $_.Name -eq '.bbb' -and $_.Outcome -eq 'Failed' }).Count -eq 1) 'Missing target result absent.'
        }
    }
    Test-Case 'Open With write failure does not become a successful fallback' {
        Invoke-AssociationFixture {
            function Add-AssociationOpenWithEntry { throw 'Open With denied' }
            $a=New-TestAssociation '.aaa'; $store.Choices['.aaa']='Other.App'
            $setting=New-Setting 'assoc-probe' Test Probe Test Configure Remove Association @($a)
            $result=Invoke-SettingChange $setting @{}
            Assert (-not $result.Success -and -not (Get-AssociationStatus $a).PreferredSatisfied) 'Missing fallback accepted.'
        }
    }
    Test-Case 'Removal preserves a program referenced by protected UserChoice' {
        Invoke-AssociationFixture {
            $a=New-TestAssociation '.aaa'; $id=Get-AssociationProgId $a
            Register-AssociationProgId $a; Add-AssociationOpenWithEntry $a
            $store.Current['.aaa']=$id; $store.Choices['.aaa']=$id
            $setting=New-Setting 'assoc-probe' Test Probe Test Configure Remove Association @($a)
            $setting.DesiredState='Remove'
            $result=Invoke-SettingChange $setting @{}
            Assert (-not $result.Success -and $result.Message -match 'UserChoice') 'Removal falsely succeeded.'
            Assert ($store.Current['.aaa'] -eq $id -and $store.Commands.ContainsKey($id)) 'Protected default was broken.'
        }
    }
    Test-Case 'Removal restores previous extension choice and retains shared command' {
        Invoke-AssociationFixture {
            $a=New-TestAssociation '.aaa'; $b=New-TestAssociation '.bbb'; $id=Get-AssociationProgId $a
            Register-AssociationProgId $a; Add-AssociationOpenWithEntry $a
            $store.Current['.aaa']=$id; $store.Backups['.aaa']='Old.App'; $store.Choices['.bbb']=$id
            $setting=New-Setting 'assoc-probe' Test Probe Test Configure Remove Association @($a)
            $setting.DesiredState='Remove'
            $result=Invoke-SettingChange $setting @{}
            Assert ($result.Success -and $store.Current['.aaa'] -eq 'Old.App' -and -not $store.OpenWith.ContainsKey('.aaa')) 'Previous choice not restored.'
            Assert ($store.Commands.ContainsKey($id) -and $store.Choices['.bbb'] -eq $id) 'Shared program registration lost.'
        }
    }
    Test-Case 'Removal clears the Explorer FileExts copy of a used Open With handler' {
        Invoke-AssociationFixture {
            $a=New-TestAssociation '.aaa'; $id=Get-AssociationProgId $a
            Register-AssociationProgId $a
            $store.ExplorerOpenWith['.aaa']=$true
            $before=Get-AssociationStatus $a
            Assert ($before.State -eq 'OpenWithOnly' -and -not $before.AlternateSatisfied) 'Explorer reference was not detected.'
            $setting=New-Setting 'assoc-probe' Test Probe Test Configure Remove Association @($a)
            $setting.DesiredState='Remove'
            $result=Invoke-SettingChange $setting @{}
            Assert ($result.Success -and (Get-AssociationStatus $a).AlternateSatisfied) 'Explorer reference survived removal.'
        }
    }
    Test-Case 'Association read errors remain Error and block safe action' {
        Invoke-AssociationFixture {
            function Get-AssociationRegistration { throw 'Registration inaccessible' }
            $setting=New-Setting 'assoc-probe' Test Probe Test Configure Remove Association @((New-TestAssociation '.aaa'))
            $state=Get-SettingState $setting
            Assert ($state.Status -eq 'Error') 'Read error was interpreted as unclaimed extension.'
        }
    }
    Test-Case 'Registry writes preserve successful failed and skipped entry outcomes' {
        Invoke-RegistryFixture {
            $result=Invoke-SettingChange $setting @{}
            Assert ($result.Outcome -eq 'PartiallyApplied') 'Partial registry change was reported as total failure.'
            $rows=@($result.Components | Where-Object { $_.PSObject.Properties['Before'] })
            Assert ($rows.Count -eq 3 -and $rows[0].Outcome -eq 'Succeeded' -and $rows[1].Outcome -eq 'Failed' -and $rows[2].Outcome -eq 'Skipped') 'Per-entry ordering or outcome lost.'
            Assert ($rows[0].Before.Value -eq 0 -and $rows[0].After.Value -eq 1 -and $rows[0].After.ValueType -eq 'DWord') 'Before/after values or type lost.'
            Assert ($attempts.Count -eq 2 -and $rows[2].ChangeStatus -eq 'NotAttempted') 'Later writes were not stopped.'
            $json=$result | ConvertTo-Json -Depth 9 | ConvertFrom-Json
            Assert ($json.Components[0].Before.Value -eq 0 -and $json.Components[0].After.Value -eq 1) 'Serialization lost evidence.'
        }
    }
    Test-Case 'Elevated registry results preserve entry evidence through worker JSON' {
        Invoke-RegistryFixture {
            foreach ($entry in $setting.Entries) { $entry.Scope='Machine' }
            $results=Invoke-AdministratorPlan @([pscustomobject]@{Id=$setting.Id;DesiredState='Enabled'}) @($setting)
            Assert ($results[0].Outcome -eq 'PartiallyApplied' -and $results[0].Components.Count -eq 3) 'Worker collapsed entry results.'
            $path=Join-Path $scratch 'worker-results.json'
            Write-WorkerResults $results $path
            $decoded=ConvertFrom-JsonList ([IO.File]::ReadAllText($path))
            Assert ($decoded[0].Components[0].Scope -eq 'Machine' -and $decoded[0].Components[2].Outcome -eq 'Skipped') 'Worker JSON lost component detail.'
        }
    }
    Test-Case 'Write followed by failed verification still reports known mutation' {
        Invoke-RegistryFixture {
            function Set-EntryValue($Entry,$DesiredState,$Setting) {
                $values[$Entry.Name]=[pscustomobject]@{Status='Present';Exists=$true;Value=7;ValueType='DWord';ErrorMessage=''}
                throw 'Readback mismatch'
            }
            $result=Invoke-SettingChange $setting @{}
            Assert ($result.Outcome -eq 'PartiallyApplied' -and $result.Components[0].ChangeStatus -eq 'Changed') 'Known mutation hidden behind failure.'
        }
    }
    Test-Case 'Unreadable registry before-state prevents the write' {
        Invoke-RegistryFixture {
            $values['First']=[pscustomobject]@{Status='Error';Exists=$false;Value=$null;ValueType='';ErrorMessage='denied'}
            $result=Invoke-SettingChange $setting @{}
            Assert ($attempts.Count -eq 0 -and $result.Components[0].ChangeStatus -eq 'Unknown') 'Unreadable entry was modified or claimed unchanged.'
        }
    }
    Test-Case 'Same registry data with wrong value type fails verification' {
        function Get-EntryValue { [pscustomobject]@{Status='Present';Exists=$true;Value='1';ValueType='String';ErrorMessage=''} }
        Assert (-not (Test-EntryValue (New-Entry User Software\Probe Test 1 0 DWord) 1)) 'REG_SZ accepted as REG_DWORD.'
    }
    Test-Case 'Update policy reports configured values and disclaims restart guarantees' {
        function Test-EntryValue { $true }
        $setting=$script:Settings | Where-Object Id -eq 'windows-update-continuity'
        $state=Get-SettingState $setting
        Assert ($state.Status -eq 'Preferred' -and $state.DisplayText -eq 'Configured; manual maintenance') 'Old protected claim remains.'
        Assert ($state.VerificationBasis -match 'not verified' -and $state.Details -match 'automatic-restart prevention is not verified') 'Verification limit missing.'
        Assert ($setting.Description -notmatch 'Prevents automatic|blocks update restarts') 'Description promises protection.'
    }
    Test-Case 'Successful registry result names its verification basis' {
        function Set-SettingPart {}
        function Get-SettingState { New-StateResult Preferred 'Configured: Disabled' }
        $setting=$script:Settings | Where-Object Id -eq 'task-view'
        $result=Invoke-SettingChange $setting @{}
        Assert ($result.Success -and $result.Message -match 'Registry value, type, or absence checked') 'Result lacks concrete verification basis.'
        Assert ($result.Message -notmatch 'Applied and verified') 'Unqualified verification claim remains.'
    }
    "Passed $script:Passed phase 2 tests on PowerShell $($PSVersionTable.PSVersion)."
} finally {
    $full=[IO.Path]::GetFullPath($scratch)
    $parent=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')+'\'
    if (-not $full.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^\.phase2-[0-9a-f]{32}$') { throw 'Unsafe test cleanup path.' }
    Remove-Item -LiteralPath $full -Recurse -Force
}
