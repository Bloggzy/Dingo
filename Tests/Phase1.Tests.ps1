#requires -version 5.1
# Standalone regression checks: no installers, elevation, or registry writes.
# Only GUID-scoped files beneath this test directory are created and removed.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'Dingo.ps1'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors.Message -join '; ') }
# Import definitions only, never Dingo's startup, self-tests, GUI, or CLI dispatch.
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) {
        Invoke-Expression $statement.Extent.Text
    }
}
$script:LogFile = $null
$script:DingoVersion = '0.0.0-test'
$script:RemoveValue = '__REMOVE_VALUE__'
$script:SettingHandlers = @{}
$script:ToolCatalogWarning = ''
$script:DeviceIsManaged = $false
$script:ShimMarker = 'REM Written by Dingo. Safe to delete.'
$script:ShortcutMarker = 'Created by Dingo. Safe to delete.'
$script:AssociationProgIdPrefix = 'Dingo.'
$script:AssociationBackupSubKey = 'Software\Dingo\FileAssociations'
$script:MachineEnvironmentSubKey = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
$script:ShimDirectory = 'C:\DFIR\Tools\bin'
$script:StartMenuShortcutDirectory = 'C:\Dingo-Test-Not-Used'
$script:DesktopShortcutDirectory = 'C:\Dingo-Test-Not-Used'
$script:ToolCatalogCache = @(Get-BuiltInToolCatalog | ForEach-Object { ConvertTo-ToolDefinition $_ })
Initialize-SettingHandlers
$script:Settings = Get-Settings
$script:Passed = 0
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Body, [string]$Pattern) {
    $caught = $null
    try { & $Body } catch { $caught = $_.Exception.Message }
    Assert ([bool]$caught -and $caught -match $Pattern) "Expected failure matching '$Pattern'; got '$caught'."
}
function Test-Case([string]$Name, [scriptblock]$Body) {
    & $Body
    $script:Passed++
    Write-Output "PASS $Name"
}
$scratch = Join-Path $PSScriptRoot ('.phase1-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    Test-Case 'JSONC preserves all quoted values while removing comments and trailing commas' {
        $strings = @('keep,}', 'keep,]', 'keep,   }', 'https://host/path', '/*keep*/', 'say "x,}"', 'C:\folder\', ('Unicode: ' + [char]0x03A9))
        foreach ($value in $strings) {
            $encoded = ConvertTo-Json -InputObject $value -Compress
            $inputText = '{ /* before */ "text":' + $encoded + ',"array":[' + $encoded + ', /* end */ ], }'
            $parsed = ConvertTo-StrictJson $inputText | ConvertFrom-Json
            Assert ($parsed.text -ceq $value -and $parsed.array[0] -ceq $value) "Changed string: $value"
        }
        $parsed = ConvertTo-StrictJson "{`n // comment`n `"a`": [1,2,], }" | ConvertFrom-Json
        Assert ($parsed.a.Count -eq 2 -and $parsed.a[1] -eq 2) 'Lost array elements.'
        Assert-Throws { ConvertTo-StrictJson '{"a":1} /* unfinished' } 'Unterminated'
        Assert-Throws { ConvertTo-StrictJson '{"a":1,,}' | ConvertFrom-Json } '.'
    }
    Test-Case 'Terminal and catalog JSONC readers preserve punctuation through serialization' {
        $path = Join-Path $scratch 'settings.json'
        [IO.File]::WriteAllText($path, '{// note' + "`n" + '"profiles":{"list":[{"name":"Windows PowerShell","commandline":"powershell.exe","tabTitle":"keep,}",},]},"tools":[{"name":"keep,]",}],}')
        $original = Read-TerminalJson $path
        $roundTrip = $original | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        Assert ($roundTrip.profiles.list[0].tabTitle -ceq 'keep,}') 'Terminal title changed.'
        Assert ($roundTrip.tools[0].name -ceq 'keep,]') 'Catalog field changed.'
    }
    Test-Case 'Apply plan deep-copies mutable model fields and excludes controls' {
        $card = $script:Settings | Where-Object Id -eq 'resume'
        $card.Selected = $true
        $card | Add-Member NoteProperty ApplyControl ([pscustomobject]@{ IsEnabled = $true }) -Force
        $plan = @(New-ApplyPlan @($card))
        $before = $plan[0].Entries[0].Preferred
        $card.DesiredState = $card.AlternateState
        $card.Entries[0].Preferred = 999
        $card.Requirements['Probe'] = 'changed'
        Assert ($plan.Count -eq 1 -and $plan[0].DesiredState -eq $plan[0].PreferredState) 'Desired choice was shared.'
        Assert ($plan[0].Entries[0].Preferred -eq $before) 'Nested entries were shared.'
        Assert (-not $plan[0].Requirements.ContainsKey('Probe')) 'Requirements were shared or lost their hashtable type.'
        Assert (-not $plan[0].PSObject.Properties['ApplyControl']) 'A WPF control entered the plan.'
        $plan[0].Status = 'Succeeded'; $plan[0].Details = 'snapshot result'
        Publish-PlanState $plan[0]
        Assert ($card.Status -eq 'Succeeded' -and $card.DesiredState -eq $card.AlternateState) 'Publishing overwrote a choice or lost results.'
        $card.Entries[0].Preferred = $before
        $card.Requirements.Remove('Probe')
    }
    Test-Case 'Machine and account execution both use the captured choice after a card edit' {
        $card = $script:Settings | Where-Object Id -eq 'resume'
        $card.DesiredState = $card.PreferredState
        $plan = @(New-ApplyPlan @($card))
        $requests = @($plan | ForEach-Object { [pscustomobject]@{Id=$_.Id;DesiredState=$_.DesiredState} })
        $card.DesiredState = $card.AlternateState
        $calls = New-Object System.Collections.ArrayList
        function Set-SettingPart($Setting, $DesiredState, $Scope) { [void]$calls.Add("${Scope}:$DesiredState") }
        function Get-SettingState($Setting) { New-StateResult Preferred $Setting.PreferredState }
        $admin = Invoke-AdministratorPlan $requests $script:Settings
        $map = @{}; foreach ($row in $admin) { $map[$row.Id] = $row }
        $result = Invoke-SettingChange $plan[0] $map
        Assert ($result.Success -and $calls.Count -eq 2) 'Mixed execution did not complete.'
        Assert ($calls[0] -eq 'Machine:Disabled' -and $calls[1] -eq 'User:Disabled') 'Phases used different choices.'
    }
    Test-Case 'Busy controls include cards and restart choice, and re-enable together' {
        $script:ActionButtons = @([pscustomobject]@{IsEnabled=$true})
        $SectionTabs = [pscustomobject]@{IsEnabled=$true}
        $RestartExplorerCheckBox = [pscustomobject]@{IsEnabled=$true}
        Set-ActionButtonsEnabled $false
        Assert (-not $RestartExplorerCheckBox.IsEnabled -and -not $script:ActionButtons[0].IsEnabled) 'Some plan controls remain enabled.'
        # The sections stay live so a run can be watched: a locked tab control
        # also blocks scrolling and tab switching, which hid the cards finishing.
        Assert ($SectionTabs.IsEnabled) 'The sections are locked, so a running plan cannot be watched.'
        Set-ActionButtonsEnabled $true
        Assert ($SectionTabs.IsEnabled -and $RestartExplorerCheckBox.IsEnabled -and $script:ActionButtons[0].IsEnabled) 'Controls did not recover.'
    }
    Test-Case 'Foreign same-name launcher survives write refusal byte-for-byte' {
        $script:ShimDirectory = $scratch
        $path = Join-Path $scratch 'foreign.cmd'
        [IO.File]::WriteAllText($path, "@echo off`r`necho user launcher`r`n")
        $before = (Get-FileHash -LiteralPath $path).Hash
        Assert-Throws { Write-ToolShim foreign 'C:\Windows\notepad.exe' } 'not created by Dingo'
        Assert ((Get-FileHash -LiteralPath $path).Hash -eq $before) 'Foreign launcher was modified.'
        Assert (@(Get-DingoShimFiles | Where-Object Name -eq 'foreign.cmd').Count -eq 0) 'Foreign launcher became Dingo-owned.'
    }
    Test-Case 'Owned launchers can be created and updated' {
        Write-ToolShim owned 'C:\Windows\notepad.exe'
        Write-ToolShim owned 'C:\Windows\System32\notepad.exe'
        Assert (Test-ShimIsCurrent (Join-Path $scratch 'owned.cmd') 'C:\Windows\System32\notepad.exe') 'Owned launcher did not update.'
    }
    Test-Case 'Launcher batch rejects a later collision before writing earlier files or PATH' {
        function Get-ExpectedShims { $m = New-Object Collections.Specialized.OrderedDictionary; $m.Add('new-first','C:\Windows\notepad.exe'); $m.Add('foreign','C:\Windows\notepad.exe'); return ,$m }
        function Add-FolderToMachinePath { throw 'Unexpected PATH write' }
        $setting = $script:Settings | Where-Object Kind -eq ToolPath
        $setting.CurrentState = New-StateResult Partial 'Not set'
        $setting.DesiredState = $setting.PreferredState
        $check = Test-SettingPreflight $setting
        Assert (-not $check.Available -and $check.Message -match 'not created by Dingo') 'Preflight missed collision.'
        Assert-Throws { Set-ToolPathKindPart $setting $setting.PreferredState Machine } 'not created by Dingo'
        Assert (-not (Test-Path -LiteralPath (Join-Path $scratch 'new-first.cmd'))) 'Batch partially overwrote files before collision.'
    }
    Test-Case 'Foreign same-name shortcut survives and owned shortcut updates' {
        $path = Join-Path $scratch 'Foreign Link.lnk'
        $shell = New-Object -ComObject WScript.Shell
        try {
            $link = $shell.CreateShortcut($path)
            $link.TargetPath = Join-Path $env:WINDIR 'System32\notepad.exe'
            $link.Description = 'User shortcut'
            $link.Save()
        } finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
        $before = (Get-FileHash -LiteralPath $path).Hash
        $spec = [pscustomobject]@{Target=(Join-Path $env:WINDIR 'System32\notepad.exe'); Arguments=''}
        Assert-Throws { Write-ToolShortcut $scratch 'Foreign Link' $spec } 'not created by Dingo'
        Assert ((Get-FileHash -LiteralPath $path).Hash -eq $before) 'Foreign shortcut was modified.'
        Write-ToolShortcut $scratch 'Owned Link' $spec
        $spec.Arguments = 'example.txt'
        Write-ToolShortcut $scratch 'Owned Link' $spec
        Assert (Test-ShortcutIsCurrent (Join-Path $scratch 'Owned Link.lnk') $spec) 'Owned shortcut did not update.'
        Assert (@(Get-DingoShortcutFiles $scratch | Where-Object Name -eq 'Foreign Link.lnk').Count -eq 0) 'Foreign shortcut became Dingo-owned.'
    }
    Test-Case 'Shortcut batch detects collision before creating other shortcuts' {
        function Get-ExpectedShortcuts {
            $m = New-Object Collections.Specialized.OrderedDictionary
            $spec = [pscustomobject]@{Target=(Join-Path $env:WINDIR 'System32\notepad.exe');Arguments=''}
            $m.Add('New First Link',$spec); $m.Add('Foreign Link',$spec); return ,$m
        }
        $setting = New-Setting 'test-shortcuts' Tools Test Test Created Absent Shortcut @([pscustomobject]@{Scope='Machine';Folder=$scratch})
        $setting.CurrentState = New-StateResult Partial 'Not set'
        Assert (-not (Test-SettingPreflight $setting).Available) 'Shortcut preflight missed collision.'
        Assert-Throws { Set-ShortcutKindPart $setting Created Machine } 'not created by Dingo'
        Assert (-not (Test-Path -LiteralPath (Join-Path $scratch 'New First Link.lnk'))) 'Earlier shortcut was created before conflict detection.'
    }
    Test-Case 'Install skips detected tools in both scopes and for both installer kinds' {
        function Find-InstalledTool { [pscustomobject]@{Version='old-but-approved'} }
        function Install-WingetPackage { throw 'Unexpected winget install' }
        function Install-ScriptPackage { throw 'Unexpected script install' }
        foreach ($id in @('tool-7zip','tool-ripgrep','tool-eztools')) {
            $setting = $script:Settings | Where-Object Id -eq $id
            Set-PackageKindPart $setting Installed $setting.Entries[0].Scope
        }
    }
    Test-Case 'Missing tools install; explicit updates run only for installed tools' {
        $calls = New-Object Collections.ArrayList
        $present = $false
        function Find-InstalledTool { if ($present) { [pscustomobject]@{Version='1'} } }
        function Install-WingetPackage($Tool, $AllowUpgrade) { [void]$calls.Add("winget:$AllowUpgrade") }
        function Install-ScriptPackage { [void]$calls.Add('script') }
        $winget = $script:Settings | Where-Object Id -eq 'tool-7zip'
        $scriptTool = $script:Settings | Where-Object Id -eq 'tool-eztools'
        Set-PackageKindPart $winget Installed Machine
        Set-PackageKindPart $scriptTool Installed Machine
        Assert-Throws { Set-PackageKindPart $winget 'Update installed tool' Machine } 'not installed'
        $present = $true
        Set-PackageKindPart $winget 'Update installed tool' Machine
        Set-PackageKindPart $scriptTool 'Update installed tool' Machine
        Assert (($calls -join ',') -eq 'winget:False,script,winget:True,script') 'Wrong install/update dispatch.'
    }
    Test-Case 'Winget install suppresses implicit upgrades; explicit update permits them' {
        function Resolve-UsableWinget($WingetPath) { $WingetPath }
        $seen = New-Object Collections.ArrayList
        function Get-WingetPath { 'mock-winget.exe' }
        function Invoke-ChildProcess($FilePath,$Arguments,$TimeoutSeconds,$Label) {
            [void]$seen.Add(@($Arguments)); [pscustomobject]@{ExitCode=0;Output='test'}
        }
        $tool = ($script:Settings | Where-Object Id -eq 'tool-7zip').Entries[0]
        Install-WingetPackage $tool
        Install-WingetPackage $tool $true
        Assert ($seen[0] -contains '--no-upgrade' -and $seen[1] -notcontains '--no-upgrade') 'Implicit upgrades not controlled.'
    }
    Test-Case 'Winget version is read from the client and compared with the floor' {
        $reported = 'v1.11.400'
        function Get-WingetPath { 'mock-winget.exe' }
        function Invoke-ChildProcess { [pscustomobject]@{ExitCode=0;Output=$reported} }
        Assert ((Get-WingetVersion) -eq [version]'1.11.400') 'Release version was misread.'
        $reported = 'v1.2.10691'
        Assert ((Get-WingetVersion) -eq [version]'1.2.10691') 'Old version was misread.'
        $reported = 'v1.7'
        Assert ((Get-WingetVersion) -eq [version]'1.7.0') 'Two-part version was misread.'
        $reported = 'v1.9.25180-preview'
        Assert ((Get-WingetVersion) -eq [version]'1.9.25180') 'Preview suffix broke the version.'
        $reported = 'Unknown'
        Assert ($null -eq (Get-WingetVersion)) 'An unreadable version was invented.'
        # An unreadable client must never block an install that would have worked.
        Assert ((Test-WingetVersionSupported).Supported) 'Unreadable version was treated as too old.'
        $reported = 'v1.5.2201'
        Assert (-not (Test-WingetVersionSupported).Supported) 'A version below the floor passed.'
        $reported = 'v1.6.0'
        Assert ((Test-WingetVersionSupported).Supported) 'The floor version itself was rejected.'
    }
    Test-Case 'The repair refuses to run without rights, and insists on a module that has the command' {
        function Test-IsAdministrator { $false }
        Assert-Throws { Repair-WingetClient } 'administrator rights'
        $source = (Get-Command Repair-WingetClient).Definition
        # The module can be present but too old to carry the command, so being
        # installed is never taken as proof that the command exists.
        Assert ($source -match 'MinimumVersion') 'The repair accepts any module version.'
        Assert ($source -match "Get-Command Repair-WinGetPackageManager") 'The repair never checks the command exists.'
    }
    Test-Case 'The gallery is only required when the module is missing or too old' {
        function Get-Module { $null }
        Assert ((Get-WingetRepairEndpoints).Count -eq 2) 'A missing module did not require the gallery.'
        function Get-Module { [pscustomobject]@{Version=[version]'1.2.0'} }
        Assert ((Get-WingetRepairEndpoints).Count -eq 2) 'An old module did not require the gallery.'
        function Get-Module { [pscustomobject]@{Version=[version]'1.9.0'} }
        $endpoints = Get-WingetRepairEndpoints
        Assert ($endpoints.Count -eq 1) 'A new enough module still required the gallery.'
        Assert ($endpoints['the App Installer download'] -match 'aka.ms/getwinget') 'The App Installer address is never checked.'
    }
    Test-Case 'A repair stops before it starts when the network it needs is out of reach' {
        function Test-IsAdministrator { $true }
        function Get-Module { $null }
        function Test-EndpointReachable { $false }
        function Invoke-ChildProcess { throw 'The repair started without a network.' }
        Assert-Throws { Repair-WingetClient } 'cannot reach'
        Assert-Throws { Repair-WingetClient } 'powershellgallery'
    }
    Test-Case 'A server that answers with an error status still counts as reachable' {
        function Invoke-WebRequest { throw (New-Object Net.WebException 'Not found', $null, 'ProtocolError', (New-Object Net.HttpWebResponse)) }
        Assert (Test-EndpointReachable 'https://example.invalid/') 'An answering server was called unreachable.'
        function Invoke-WebRequest { throw 'The remote name could not be resolved' }
        Assert (-not (Test-EndpointReachable 'https://example.invalid/')) 'A dead name was called reachable.'
    }
    Test-Case 'A supported winget is checked once and never repaired' {
        Set-RunScopedFlag 'WingetVersionVerified' $false
        Set-RunScopedFlag 'WingetRepairAttempted' $false
        $checks = New-Object Collections.ArrayList
        function Get-WingetVersion { [void]$checks.Add(1); [version]'1.11.400' }
        function Repair-WingetClient { throw 'Unexpected repair' }
        Assert ((Resolve-UsableWinget 'mock-winget.exe') -eq 'mock-winget.exe') 'A good winget path was changed.'
        Assert ((Resolve-UsableWinget 'mock-winget.exe') -eq 'mock-winget.exe') 'A verified winget was rechecked.'
        Assert ($checks.Count -eq 1) "Version was read $($checks.Count) times instead of once."
    }
    Test-Case 'An old winget is repaired once, and the repaired client is used' {
        Set-RunScopedFlag 'WingetVersionVerified' $false
        Set-RunScopedFlag 'WingetRepairAttempted' $false
        $repairs = New-Object Collections.ArrayList
        $state = @{ Version = [version]'1.2.10691' }
        function Test-IsAdministrator { $true }
        function Get-WingetVersion { $state.Version }
        function Get-WingetPath { 'repaired-winget.exe' }
        function Repair-WingetClient { [void]$repairs.Add(1); $state.Version = [version]'1.11.400' }
        Assert ((Resolve-UsableWinget 'old-winget.exe') -eq 'repaired-winget.exe') 'The repaired client was not picked up.'
        Assert ($repairs.Count -eq 1) "Repair ran $($repairs.Count) times instead of once."
    }
    Test-Case 'A repair that does not raise the version fails with advice, and never runs twice' {
        Set-RunScopedFlag 'WingetVersionVerified' $false
        Set-RunScopedFlag 'WingetRepairAttempted' $false
        $repairs = New-Object Collections.ArrayList
        function Test-IsAdministrator { $true }
        function Get-WingetVersion { [version]'1.2.10691' }
        function Get-WingetPath { 'still-old-winget.exe' }
        function Repair-WingetClient { [void]$repairs.Add(1) }
        Assert-Throws { Resolve-UsableWinget 'old-winget.exe' } 'aka.ms/getwinget'
        Assert-Throws { Resolve-UsableWinget 'old-winget.exe' } 'did not fix it'
        Assert ($repairs.Count -eq 1) "Repair ran $($repairs.Count) times instead of once."
    }
    Test-Case 'A winget that Windows will not start is repaired, not treated as supported' {
        # On a VDI image the administrator worker can be a different account
        # that App Installer was never registered to. Windows then refuses to
        # start winget.exe, and the version check must not wave that through.
        Set-RunScopedFlag 'WingetVersionVerified' $false
        Set-RunScopedFlag 'WingetRepairAttempted' $false
        $repairs = New-Object Collections.ArrayList
        $state = @{ Denied = $true }
        function Test-IsAdministrator { $true }
        function Invoke-ChildProcess { if ($state.Denied) { throw 'Exception calling "Start" with "1" argument(s): "Access is denied"' } [pscustomobject]@{ExitCode=0;Output='v1.11.400'} }
        function Get-WingetPath { 'registered-winget.exe' }
        function Repair-WingetClient { [void]$repairs.Add(1); $state.Denied = $false }
        Assert (-not (Test-WingetVersionSupported 'denied-winget.exe').Supported) 'A winget Windows refuses to start was called supported.'
        Assert ((Resolve-UsableWinget 'denied-winget.exe') -eq 'registered-winget.exe') 'The repaired client was not picked up.'
        Assert ($repairs.Count -eq 1) "Repair ran $($repairs.Count) times instead of once."
    }
    Test-Case 'A winget that stays refused after repair says to sign in as that account' {
        Set-RunScopedFlag 'WingetVersionVerified' $false
        Set-RunScopedFlag 'WingetRepairAttempted' $false
        function Test-IsAdministrator { $true }
        function Invoke-ChildProcess { throw 'Exception calling "Start" with "1" argument(s): "Access is denied"' }
        function Get-WingetPath { 'denied-winget.exe' }
        function Repair-WingetClient { }
        Assert-Throws { Resolve-UsableWinget 'denied-winget.exe' } 'Sign in once as'
    }
    Test-Case 'An old winget without administrator rights explains what to do instead' {
        Set-RunScopedFlag 'WingetVersionVerified' $false
        Set-RunScopedFlag 'WingetRepairAttempted' $false
        function Test-IsAdministrator { $false }
        function Get-WingetVersion { [version]'1.2.10691' }
        function Repair-WingetClient { throw 'Unexpected repair' }
        Assert-Throws { Resolve-UsableWinget 'old-winget.exe' } 'administrator'
    }
    Test-Case 'A missing package source is reported with the command that fixes it' {
        function Get-WingetPath { 'mock-winget.exe' }
        function Resolve-UsableWinget($WingetPath) { $WingetPath }
        function Invoke-ChildProcess { [pscustomobject]@{ExitCode=-1978335217;Output='Failed when opening source(s)'} }
        $script:SourceRepairs = 0
        function Repair-WingetSource { $script:SourceRepairs++; $false }
        Set-RunScopedFlag 'WingetSourceRepairAttempted' $false
        $tool = ($script:Settings | Where-Object Id -eq 'tool-7zip').Entries[0]
        Assert-Throws { Install-WingetPackage $tool } 'winget source reset --force'
        Assert-Throws { Install-WingetPackage $tool } 'winget source reset --force'
        Assert ($script:SourceRepairs -eq 1) "The source repair ran $($script:SourceRepairs) times instead of once per run."
    }
    Test-Case 'A package source that is mended lets the same install run again' {
        # On a VDI image App Installer had just been registered for the
        # administrator account, and its package source was missing.
        function Resolve-UsableWinget($WingetPath) { $WingetPath }
        function Get-WingetPath { 'mock-winget.exe' }
        $script:Runs = New-Object Collections.ArrayList
        function Invoke-ChildProcess { param($Path, $Arguments) [void]$script:Runs.Add(($Arguments -join ' ')); if ($script:Runs.Count -eq 1) { [pscustomobject]@{ExitCode=-1978335217;Output='Data required by the source is missing'} } else { [pscustomobject]@{ExitCode=0;Output='Successfully installed'} } }
        function Repair-WingetSource { $true }
        Set-RunScopedFlag 'WingetSourceRepairAttempted' $false
        $tool = ($script:Settings | Where-Object Id -eq 'tool-7zip').Entries[0]
        Install-WingetPackage $tool
        Assert ($script:Runs.Count -eq 2) "winget install ran $($script:Runs.Count) times instead of twice."
        Set-RunScopedFlag 'WingetSourceRepairAttempted' $false
    }
    Test-Case 'The winget source repair falls back to the source package and needs no network in tests' {
        $script:Steps = New-Object Collections.ArrayList
        function Invoke-ChildProcess { param($Path, $Arguments) [void]$script:Steps.Add($Arguments[0] + ' ' + $Arguments[1]); if ($Arguments[0] -eq 'search' -and $script:Steps -notcontains 'add package') { [pscustomobject]@{ExitCode=-1978335217;Output=''} } else { [pscustomobject]@{ExitCode=0;Output=''} } }
        function Invoke-WebRequest { param($Uri, $OutFile) Set-Content -LiteralPath $OutFile -Value 'x' }
        function Add-AppxPackage { param($Path, $ErrorAction) [void]$script:Steps.Add('add package') }
        Assert (Repair-WingetSource 'mock-winget.exe') 'A source that reads after the package was added was called broken.'
        Assert (($script:Steps -join ',') -eq 'source reset,search --id,add package,search --id') "The repair steps ran as: $($script:Steps -join ', ')."
        function Add-AppxPackage { param($Path, $ErrorAction) throw 'Deployment failed' }
        function Invoke-ChildProcess { [pscustomobject]@{ExitCode=-1978335217;Output=''} }
        Assert (-not (Repair-WingetSource 'mock-winget.exe')) 'A source that never reads was called mended.'
    }
    Test-Case 'Winget no-upgrade refusal is accepted only for ensure-installed' {
        function Resolve-UsableWinget($WingetPath) { $WingetPath }
        function Get-WingetPath { 'mock-winget.exe' }
        function Invoke-ChildProcess { [pscustomobject]@{ExitCode=-1978335135;Output='already installed'} }
        $tool = ($script:Settings | Where-Object Id -eq 'tool-7zip').Entries[0]
        Install-WingetPackage $tool
        Assert-Throws { Install-WingetPackage $tool $true } 'winget exited'
    }
    Test-Case 'A missing winget stops an account-scope update that cannot install one' {
        function Get-WingetPath { '' }
        function Test-IsAdministrator { $false }
        function Find-InstalledTool { [pscustomobject]@{Version='1'} }
        # ripgrep installs into the signed-in account, so its card never runs
        # elevated. Without rights Dingo cannot supply winget, so it must stop.
        $setting = @(New-ApplyPlan @(($script:Settings | Where-Object Id -eq 'tool-ripgrep')))[0]
        Assert (-not $setting.RequiresAdmin) 'The account-scope tool asks for elevation.'
        $setting.CurrentState = New-StateResult Preferred Installed
        Assert ((Test-SettingPreflight $setting).Available) 'Already installed tool unnecessarily requires winget.'
        $setting.DesiredState = 'Update installed tool'
        $check = Test-SettingPreflight $setting
        Assert (-not $check.Available) 'Update can pass preflight without winget.'
        Assert ($check.Message -match 'administrator rights to install it') 'The block never says what would fix it.'
    }
    Test-Case 'A missing winget lets an elevated card through, because Dingo can install one' {
        function Get-WingetPath { '' }
        function Test-IsAdministrator { $false }
        function Find-InstalledTool { [pscustomobject]@{Version='1'} }
        # 7-Zip installs for the whole computer, so its card runs elevated and
        # the worker will hold the rights the winget install needs.
        $setting = @(New-ApplyPlan @(($script:Settings | Where-Object Id -eq 'tool-7zip')))[0]
        Assert ($setting.RequiresAdmin) 'The computer-wide tool does not ask for elevation.'
        $setting.CurrentState = New-StateResult Preferred Installed
        $setting.DesiredState = 'Update installed tool'
        Assert ((Test-SettingPreflight $setting).Available) 'An elevated card was blocked by a winget Dingo can install.'
    }
    Test-Case 'An absent winget is installed once, and the new client is used' {
        Set-RunScopedFlag 'WingetVersionVerified' $false
        Set-RunScopedFlag 'WingetRepairAttempted' $false
        $repairs = New-Object Collections.ArrayList
        $state = @{ Path = '' }
        function Test-IsAdministrator { $true }
        function Get-WingetPath { $state.Path }
        function Get-WingetVersion { [version]'1.11.400' }
        function Repair-WingetClient { [void]$repairs.Add(1); $state.Path = 'new-winget.exe' }
        Assert ((Resolve-UsableWinget '') -eq 'new-winget.exe') 'The installed client was not picked up.'
        Assert ($repairs.Count -eq 1) "Repair ran $($repairs.Count) times instead of once."
    }
    Test-Case 'An absent winget that cannot be installed explains what to do instead' {
        Set-RunScopedFlag 'WingetVersionVerified' $false
        Set-RunScopedFlag 'WingetRepairAttempted' $false
        function Test-IsAdministrator { $false }
        function Repair-WingetClient { throw 'Unexpected repair' }
        Assert-Throws { Resolve-UsableWinget '' } 'administrator'
        Assert-Throws { Resolve-UsableWinget '' } 'aka.ms/getwinget'
    }
    Test-Case 'An install that leaves no winget behind is reported, and never retried' {
        Set-RunScopedFlag 'WingetVersionVerified' $false
        Set-RunScopedFlag 'WingetRepairAttempted' $false
        $repairs = New-Object Collections.ArrayList
        function Test-IsAdministrator { $true }
        function Get-WingetPath { '' }
        function Repair-WingetClient { [void]$repairs.Add(1) }
        Assert-Throws { Resolve-UsableWinget '' } 'still not on this computer'
        Assert-Throws { Resolve-UsableWinget '' } 'did not supply it'
        Assert ($repairs.Count -eq 1) "Repair ran $($repairs.Count) times instead of once."
    }
    Test-Case 'A download that cannot leave the computer names the network, not the library' {
        function Test-EndpointReachable { $false }
        $record = $null
        try { throw 'The remote name could not be resolved' } catch { $record = $_ }
        $message = New-DownloadFailure 'The test file' 'https://example.invalid/file.zip' $record
        Assert ($message -match 'cannot reach https://example.invalid/file.zip') 'The unreachable address is not named.'
        Assert ($message -match 'proxy') 'The proxy is never mentioned as a cause.'
        # A server that answers has been reached, so the network is not blamed.
        function Test-EndpointReachable { $true }
        $plain = New-DownloadFailure 'The test file' 'https://example.invalid/file.zip' $record
        Assert ($plain -notmatch 'cannot reach') 'A reachable server was blamed on the network.'
        Assert ($plain -match 'could not be resolved') 'The original fault was lost.'
    }
    Test-Case 'A proxy sign-in and a too-busy server are each named' {
        function Test-EndpointReachable { throw 'The status should answer before the network is asked.' }
        function Get-WebErrorStatus { 407 }
        Assert ((Get-DownloadFailureAdvice 'https://example.invalid/' $null) -match 'proxy asked for a sign-in') 'A 407 was not explained.'
        function Get-WebErrorStatus { 429 }
        Assert ((Get-DownloadFailureAdvice 'https://example.invalid/' $null) -match 'Wait a while') 'A 429 was not explained.'
    }
    Test-Case 'A GitHub refusal is explained as a rate limit, with a way round it' {
        function Invoke-RestMethod { throw 'Response status code does not indicate success: 403 (rate limit exceeded).' }
        function Get-WebErrorStatus { 403 }
        Assert-Throws { Get-GitHubLatestRelease 'ufrisk/MemProcFS' } 'asked too many times this hour'
        Assert-Throws { Get-GitHubLatestRelease 'ufrisk/MemProcFS' } 'github.com/ufrisk/MemProcFS/releases/latest'
        function Get-WebErrorStatus { 404 }
        Assert-Throws { Get-GitHubLatestRelease 'ufrisk/MemProcFS' } 'no published release'
        function Get-WebErrorStatus { 0 }
        function Test-EndpointReachable { $false }
        Assert-Throws { Get-GitHubLatestRelease 'ufrisk/MemProcFS' } 'cannot reach'
    }
    Test-Case 'Missing tool update is stopped at preflight' {
        function Get-WingetPath { 'mock-winget.exe' }
        function Find-InstalledTool { $null }
        $setting = @(New-ApplyPlan @(($script:Settings | Where-Object Id -eq 'tool-7zip')))[0]
        $setting.CurrentState = New-StateResult Partial 'Not installed'
        $setting.DesiredState = 'Update installed tool'
        $check = Test-SettingPreflight $setting
        Assert (-not $check.Available -and $check.Message -match 'choose Installed') 'Missing tool update passed preflight.'
    }
    Test-Case 'Explicit update verifies installed state as success through shared executor' {
        function Set-SettingPart {}
        function Get-SettingState { New-StateResult Preferred 'Installed (2)' }
        $setting = @(New-ApplyPlan @(($script:Settings | Where-Object Id -eq 'tool-ripgrep')))[0]
        $setting.DesiredState = 'Update installed tool'
        $result = Invoke-SettingChange $setting @{}
        Assert ($result.Success) 'Update was verified as an alternate/uninstalled state.'
    }
    Test-Case 'Preferred selection never requests an update and snapshots survive preflight' {
        $selected = @(New-ApplyPlan @(Resolve-QuickApplySettings $script:Settings @('tool-7zip','tool-ripgrep','tool-eztools') @()))
        foreach ($item in $selected) {
            $item.DesiredState = $item.PreferredState
            Assert ($item.DesiredState -eq 'Installed' -and $item.StateOptions -contains 'Update installed tool') 'Default/update actions are ambiguous.'
            Assert ($item.Requirements -is [hashtable]) 'Snapshot broke requirements.'
        }
        Assert ($selected.Count -eq 3) 'Selection changed.'
    }
    Test-Case 'GUI completion publishes snapshot results and uses captured restart preference' {
        $SectionTabs = [pscustomobject]@{IsEnabled=$false}
        $RestartExplorerCheckBox = [pscustomobject]@{IsEnabled=$false;IsChecked=$false}
        $SummaryText = [pscustomobject]@{Text='';Foreground='#334E68';FontWeight='Normal'}
        $ProgressBar = [pscustomobject]@{Value=0;IsIndeterminate=$true}
        $script:ActionButtons = @([pscustomobject]@{IsEnabled=$false})
        $script:ApplyInProgress = $true
        $script:ApplyRestartExplorer = $true
        $script:RestartCalls = 0
        function Refresh-UI {}
        function Restart-DesktopExplorer { $script:RestartCalls++; return $true }
        function Invoke-SettingChange($Item, $AdministratorResults) {
            $Item.Status = 'Succeeded'; $Item.Details = 'Test result'
            $Item.CurrentState = New-StateResult Preferred $Item.PreferredState
            return New-ApplyResult $Item.Id @((New-OperationComponent User Succeeded 'test')) 'test' $true
        }
        $card = $script:Settings | Where-Object Id -eq 'task-view'
        $plan = @(New-ApplyPlan @($card))
        $card.DesiredState = $card.AlternateState
        [void](Complete-ApplyChanges $plan @{})
        Assert ($card.Status -eq 'Succeeded' -and $card.DesiredState -eq $card.AlternateState) 'GUI failed to publish results without changing choices.'
        Assert ($script:RestartCalls -eq 1) 'Completion reread the mutable restart checkbox.'
        Assert (-not $script:ApplyInProgress -and $script:ActionButtons[0].IsEnabled -and $RestartExplorerCheckBox.IsEnabled) 'GUI remained locked after completion.'
    }
    Test-Case 'Restart guidance names the setting and tells the user how to refresh' {
        $message = Get-RestartInstruction -SettingNames @('Australian English')
        Assert ($message -match '^Australian English needs you to sign out and back in, or restart Windows') 'Restart guidance does not connect the pending setting to the required action.'
        Assert ($message -match 'Australian English') 'Restart guidance does not name the pending setting.'
        Assert ($message -match 'Read settings again') 'Restart guidance does not tell the user how to refresh Dingo.'
    }
    Test-Case 'GUI completion shows actionable guidance for a partially applied restart setting' {
        $SectionTabs = [pscustomobject]@{IsEnabled=$false}
        $RestartExplorerCheckBox = [pscustomobject]@{IsEnabled=$false;IsChecked=$false}
        $SummaryText = [pscustomobject]@{Text='';Foreground='#334E68';FontWeight='Normal'}
        $ProgressBar = [pscustomobject]@{Value=0;IsIndeterminate=$true}
        $script:ActionButtons = @([pscustomobject]@{IsEnabled=$false})
        $script:ApplyInProgress = $true
        $script:ApplyRestartExplorer = $false
        function Refresh-UI {}
        function Invoke-SettingChange($Item, $AdministratorResults) {
            $Item.Status = 'Partially applied'
            $Item.CurrentState = New-StateResult Partial 'Partly configured: system locale is en-GB'
            return New-ApplyResult $Item.Id @(
                (New-OperationComponent 'Language write' Succeeded 'accepted'),
                (New-OperationComponent 'Final verification' Failed 'pending sign-in')
            ) 'pending sign-in' $false $true
        }
        $card = $script:Settings | Where-Object Id -eq 'display-language'
        $plan = @(New-ApplyPlan @($card))
        [void](Complete-ApplyChanges $plan @{})
        Assert ($SummaryText.Text -match '1 partially applied; 0 failed') 'GUI summary lost the partial-result counts.'
        Assert ($SummaryText.Text -match 'Sign out and back in, or restart Windows') 'GUI summary lacks an explicit completion action.'
        Assert ($SummaryText.Text -match 'Display language') 'GUI summary does not name the pending setting.'
        Assert ($SummaryText.Text -match 'Read settings again') 'GUI summary does not explain how to verify after sign-in.'
    }
    Test-Case 'Unexpected completion failure releases the busy lock' {
        $SectionTabs = [pscustomobject]@{IsEnabled=$false}
        $RestartExplorerCheckBox = [pscustomobject]@{IsEnabled=$false;IsChecked=$false}
        $SummaryText = [pscustomobject]@{Text='';Foreground='#334E68';FontWeight='Normal'}
        $ProgressBar = [pscustomobject]@{Value=0;IsIndeterminate=$true}
        $script:ActionButtons = @([pscustomobject]@{IsEnabled=$false})
        $script:ApplyInProgress = $true
        function Refresh-UI {}
        function Invoke-SettingChange { throw 'Simulated completion failure' }
        $plan = @(New-ApplyPlan @(($script:Settings | Where-Object Id -eq 'task-view')))
        Assert-Throws { Complete-ApplyChanges $plan @{} } 'Simulated completion failure'
        Assert (-not $script:ApplyInProgress -and $script:ActionButtons[0].IsEnabled -and $RestartExplorerCheckBox.IsEnabled) 'Failure left plan controls locked.'
    }
    Test-Case 'Actual WPF cards use accessible selection toggles and inherit the busy lock' {
        Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
        $xamlAssignment = $ast.EndBlock.Statements | Where-Object {
            $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '[xml]$xaml'
        } | Select-Object -First 1
        Assert ([bool]$xamlAssignment) 'Missing XAML assignment.'
        Invoke-Expression $xamlAssignment.Extent.Text
        $reader = New-Object Xml.XmlNodeReader $xaml
        $window = [Windows.Markup.XamlReader]::Load($reader)
        try {
            foreach ($name in @('SectionTabs','TweakTabs','ToolTabs','RestartExplorerCheckBox','ApplyButton','AllPreferredButton','NeededButton','UncheckButton','RefreshButton','AdminSummaryText','SummaryText')) {
                Set-Variable -Name $name -Value $window.FindName($name)
            }
            $actionPanel = $ApplyButton.Parent
            Assert ($SummaryText.Parent -eq $actionPanel.Parent) 'Completion guidance and actions do not share the expected footer grid.'
            Assert ([Windows.Controls.Grid]::GetRow($SummaryText) -lt [Windows.Controls.Grid]::GetRow($actionPanel)) 'Completion guidance shares the administrator/action row and can be obscured.'
            Assert ($SummaryText.TextWrapping -eq [Windows.TextWrapping]::Wrap) 'Completion guidance cannot wrap within its own row.'
            function Get-SettingAdvisory { '' }
            $script:Settings = Get-Settings
            # The tweak tabs are built in code, so tweak cards go on a spare panel here.
            $panels = @{ 'Install tools'='ToolSettingsPanel'; 'Tool shortcuts'='ShortcutSettingsPanel'; 'File associations'='AssociationSettingsPanel' }
            $tweakPanel = New-Object Windows.Controls.StackPanel
            foreach ($item in $script:Settings) {
                $panel = if ($item.Section -eq 'Tweaks') { $tweakPanel } else { $window.FindName($panels[$item.Tab]) }
                [void]$panel.Children.Add((New-SettingCard $item))
            }
            foreach ($item in @($script:Settings | Where-Object Section -eq 'Tweaks')) {
                Assert ([bool]$item.ScopeBadgeControl) "Tweak '$($item.Id)' shows no pill saying who it affects."
            }
            foreach ($item in $script:Settings) {
                Assert ($item.DescriptionControl -and $item.DescriptionControl.Text -eq $item.Description -and $item.DescriptionControl.Parent) "Card '$($item.Id)' does not show its description."
                foreach ($radio in @($item.ChoiceControls | Where-Object { $_ -is [Windows.Controls.RadioButton] })) {
                    Assert ($radio.Content -is [Windows.Controls.TextBlock] -and $radio.Content.TextWrapping -eq 'Wrap') "A choice on '$($item.Id)' cannot wrap, so a long one runs under the Result column."
                }
            }
            $script:ActionButtons = @($ApplyButton,$AllPreferredButton,$NeededButton,$UncheckButton,$RefreshButton)
            Set-ActionButtonsEnabled $false
            Assert ($SectionTabs.IsEnabled) 'The real sections are locked during apply, so the cards cannot be watched.'
            foreach ($item in $script:Settings) {
                Assert ($item.ApplyControl -is [Windows.Controls.Primitives.ToggleButton]) 'A card does not use a selection toggle.'
                Assert ($null -eq $item.ApplyControl.Content) 'A selection toggle has visible label content.'
                Assert ([System.Windows.Automation.AutomationProperties]::GetName($item.ApplyControl) -eq "Select $($item.Name) for changes") 'A selection toggle has no setting-specific accessible name.'
                $item.ApplyControl.ApplyTemplate() | Out-Null
                Assert ([bool]$item.ApplyControl.Template.FindName('Track',$item.ApplyControl)) 'A selection toggle has no visible track.'
                Assert ([bool]$item.ApplyControl.Template.FindName('Thumb',$item.ApplyControl)) 'A selection toggle has no visible thumb.'
                Assert (-not $item.ApplyControl.IsEnabled) 'A card selection toggle is enabled during apply.'
                foreach ($radio in $item.ChoiceControls) { Assert (-not $radio.IsEnabled) 'A card choice is enabled during apply.' }
            }
            Set-ActionButtonsEnabled $true
            # The note box exists on every card even when there is nothing to say.
            # Building it only when a caveat applies is what made a note that
            # appeared later impossible, because there was nothing to fill in.
            foreach ($card in $script:Settings) {
                Assert ([bool]$card.AdvisoryControl) "Card '$($card.Id)' has no note box to fill in."
                Assert ($card.AdvisoryControl.Parent.Visibility -eq 'Collapsed') "Card '$($card.Id)' shows an empty note box."
            }
            $language = $script:Settings | Where-Object Id -eq 'display-language'
            $picker = @($language.ChoiceControls)[0]
            Assert ($picker -is [Windows.Controls.ComboBox]) 'The language card does not offer a drop-down.'
            $picker.SelectedItem = 'Spanish (es-ES)'
            Assert ($language.DesiredState -eq 'Spanish (es-ES)') 'The drop-down did not change the chosen language.'
            # Put it back to whatever this card prefers, not to a name typed in
            # here. A later test checks that every list card still starts on its
            # preferred choice, and a hard-coded name breaks it the day the
            # preferred language changes.
            $picker.SelectedItem = $language.PreferredState
            Assert ($language.DesiredState -eq $language.PreferredState) 'The language card was left on the wrong choice.'
            $tool = $script:Settings | Where-Object Id -eq 'tool-eztools'
            $update = $tool.ChoiceControls | Where-Object { $_.Tag.Value -eq 'Update installed tool' }
            Assert ($update -and $update.IsEnabled) 'Explicit update radio is absent or disabled.'
            $update.IsChecked = $true
            Assert ($tool.Selected -and $tool.DesiredState -eq 'Update installed tool') 'Update radio did not select the update action.'
            $captured = @(New-ApplyPlan @($tool))
            $tool.ChoiceControls[0].IsChecked = $true
            Assert ($captured[0].DesiredState -eq 'Update installed tool' -and $tool.DesiredState -eq 'Installed') 'Card changes leaked into plan.'
        } finally {
            $window.Close()
            $reader.Close()
        }
    }
    Test-Case 'Every setting belongs to exactly one of the two sections' {
        $sections = @($script:Settings | ForEach-Object { $_.Section } | Select-Object -Unique | Sort-Object)
        Assert (($sections -join ',') -eq 'Tools,Tweaks') "Unexpected sections: $($sections -join ',')"
        $toolTabs = @('Install tools','Tool shortcuts','File associations')
        foreach ($item in $script:Settings) {
            $expected = if ($item.Tab -in $toolTabs) { 'Tools' } else { 'Tweaks' }
            Assert ($item.Section -eq $expected) "'$($item.Id)' on tab '$($item.Tab)' is in section '$($item.Section)'."
        }
        Assert (@($script:Settings | Where-Object { $_.Section -eq 'Tweaks' }).Count -gt 0) 'No tweaks.'
        Assert (@($script:Settings | Where-Object { $_.Section -eq 'Tools' }).Count -gt 0) 'No tools.'
    }
    Test-Case 'Tweaks sit on one tab per area of Windows and say who they affect' {
        $tweaks = @($script:Settings | Where-Object Section -eq 'Tweaks')
        foreach ($item in $tweaks) {
            Assert ($item.Tab -eq $item.Category) "'$($item.Id)' is on tab '$($item.Tab)', not its area '$($item.Category)'."
            Assert ($item.Tab -in (Get-TweakTabOrder)) "'$($item.Id)' asks for tab '$($item.Tab)', which the window does not build."
        }
        foreach ($tabName in (Get-TweakTabOrder)) {
            Assert (@($tweaks | Where-Object Tab -eq $tabName).Count) "The '$tabName' tab would be empty."
        }
        Assert ((Get-ScopePill 'User').Text -eq 'Account only') 'The account pill has the wrong words.'
        Assert ((Get-ScopePill 'System').Text -eq 'Whole computer') 'The computer pill has the wrong words.'
        Assert ((Get-ScopePill 'Both').Text -eq 'Account + computer') 'The two-part pill has the wrong words.'
        Assert (($script:Settings | Where-Object Id -eq 'long-paths').Tab -eq 'Windows features') 'Win32 long paths is not with the Windows features.'
        Assert (($script:Settings | Where-Object Id -eq 'resume').Tab -eq 'Windows features') 'Cross-device Resume is not with the Windows features.'
        # A tweak people may look for on the Taskbar leaves a signpost there.
        foreach ($signpost in (Get-TweakSignposts)) {
            $target = $script:Settings | Where-Object Id -eq $signpost.Id
            Assert ([bool]$target) "The signpost for '$($signpost.Id)' points at nothing."
            Assert ($signpost.Tab -in (Get-TweakTabOrder) -and $signpost.Tab -ne $target.Tab) "The signpost for '$($signpost.Id)' is not on another tweak tab."
        }
        Assert (@(Get-TweakSignposts | Where-Object { $_.Tab -eq 'Taskbar' }).Id -join ',' -eq 'resume,windows-copilot') 'The Taskbar tab does not point to Resume and Copilot.'
    }
    Test-Case 'Resume stays the feature switch, not the taskbar badge Windows ignores' {
        $card = $script:Settings | Where-Object Id -eq 'resume'
        $names = @($card.Entries | ForEach-Object { $_.Name }) -join ','
        Assert ($names -eq 'IsResumeAllowed,value') "Resume writes $names."
        # Windows 11 25H2 ignores TaskbarAl and the badge's IsEnabled unless
        # Settings writes them, so a card for either would report a change
        # that never shows. See the comment on the Resume card.
        Assert (-not @($script:Settings | Where-Object Id -eq 'taskbar-alignment').Count) 'A Taskbar alignment card is back, but Windows ignores TaskbarAl.'
    }
    Test-Case 'Section words stand for every ID in that section' {
        foreach ($sectionName in @('Tweaks','Tools')) {
            $expected = @($script:Settings | Where-Object { $_.Section -eq $sectionName })
            $chosen = @(Resolve-QuickApplySettings $script:Settings @($sectionName.ToLowerInvariant()) @())
            Assert ($chosen.Count -eq $expected.Count) "'$sectionName' chose $($chosen.Count) of $($expected.Count) cards."
            Assert (@($chosen | Where-Object { $_.Section -ne $sectionName }).Count -eq 0) "'$sectionName' reached into the other section."
        }
        # Mixed spelling, spacing, and commas are all one list.
        Assert (@(Resolve-QuickApplySettings $script:Settings @('TWEAKS, Tools') @()).Count -eq $script:Settings.Count) 'Both section words did not select everything.'
        # A section word and a plain ID work together, in either argument.
        $withOne = @(Resolve-QuickApplySettings $script:Settings @('tools','date-time-format') @())
        Assert (@($withOne | Where-Object Id -eq 'date-time-format').Count -eq 1) 'A named tweak was lost beside a section word.'
        $lessOne = @(Resolve-QuickApplySettings $script:Settings @('tools') @('tool-7zip'))
        Assert (@($lessOne | Where-Object Id -eq 'tool-7zip').Count -eq 0) 'An excluded ID survived its section.'
        # Plain IDs behave exactly as they did before section words existed.
        Assert (@(Resolve-QuickApplySettings $script:Settings @('date-time-format','hidden-files') @()).Count -eq 2) 'Named IDs no longer select just themselves.'
    }
    Test-Case 'A card that offers a list is not named after one of its choices' {
        # An ID names the thing that is changed, never a value it can be set to.
        # 'timezone-utc' was fine while UTC was the only option and wrong the day
        # a list of zones appeared. These are the cards that grow new choices, so
        # these are the cards where the mistake happens.
        #
        # Two-state cards are left out on purpose: 'taskbar-combine' shares the
        # word 'combine' with 'Never combine' because the thing and the value are
        # named after the same action, and that is not a fault.
        $slug = {
            param([string]$Text)
            @((($Text -replace '[^A-Za-z0-9]+', ' ').Trim().ToLowerInvariant() -split '\s+') | Where-Object { $_ })
        }
        $listCards = @($script:Settings | Where-Object { $_.StateOptions.Count -gt (Get-MaxRadioChoices) })
        Assert ($listCards.Count -ge 4) "Expected at least four cards offering a list; found $($listCards.Count)."
        foreach ($card in $listCards) {
            # The preferred choice only. That is the one an ID gets named after
            # when a card starts life with a single value. Every other choice
            # would give false alarms: every Windows zone is called something
            # Standard Time, and a time-zone card is allowed the word time.
            $idWords = @(& $slug $card.Id)
            $shared = @(@(& $slug $card.PreferredState) | Where-Object { $idWords -contains $_ })
            Assert (-not $shared.Count) "'$($card.Id)' is named after part of its preferred choice '$($card.PreferredState)' ($($shared -join ', ')). An ID names the setting, not a value it can hold."
        }
        # Every ID that was renamed to name its setting must stay gone. The
        # last one was not named after a value, only after what the change is
        # for, which is the same habit one step further along.
        foreach ($stale in @('timezone-utc','region-australia','iso-time','never-combine','explorer-this-pc','language-au','windows-update-continuity')) {
            Assert (-not @($script:Settings | Where-Object Id -eq $stale).Count) "The old ID '$stale' is back."
        }
    }
    Test-Case 'A card that offers a list leads with the preferred choice and keeps them distinct' {
        $listCards = @($script:Settings | Where-Object { $_.StateOptions.Count -gt (Get-MaxRadioChoices) })
        Assert ($listCards.Count -ge 4) "Expected the language, region, time-zone, and date cards to offer lists; found $($listCards.Count)."
        foreach ($card in $listCards) {
            Assert ($card.StateOptions[0] -eq $card.PreferredState) "'$($card.Id)' does not lead its list with its preferred choice."
            Assert ($card.CanChoose) "'$($card.Id)' offers a list but reports no choice."
            $unique = @($card.StateOptions | Select-Object -Unique)
            Assert ($unique.Count -eq $card.StateOptions.Count) "'$($card.Id)' repeats a choice in its list."
            Assert ($card.DesiredState -eq $card.PreferredState) "'$($card.Id)' does not start on its preferred choice."
        }
        foreach ($id in @('time-zone','region','display-language','date-time-format')) {
            $card = $script:Settings | Where-Object Id -eq $id
            Assert ($card.Section -eq 'Tweaks') "'$id' left the Tweaks section."
            Assert ($card.StateOptions.Count -gt (Get-MaxRadioChoices)) "'$id' no longer offers a list of choices."
        }
        Assert (($script:Settings | Where-Object Id -eq 'display-language').PreferredState -eq 'Australian English (en-AU)') 'The preferred display language is not Australian English.'
        # Australian English has no interface of its own. Windows supplies it
        # through the British pack, so that pack is tried first.
        $auPacks = @((Get-LanguageChoiceTable)['Australian English (en-AU)'].Packs)
        Assert ($auPacks[0] -eq 'en-GB' -and $auPacks -contains 'en-AU') "Australian English must try the British pack first; the chain is $($auPacks -join ',')."
        Assert ((Get-LanguageChoiceTable)['Australian English (en-AU)'].Tag -eq 'en-AU') 'Australian English must ask Windows for en-AU.'
        Assert (($script:Settings | Where-Object Id -eq 'region').PreferredState -eq 'Australia (en-AU)') 'The preferred region is not Australia.'
        Assert (($script:Settings | Where-Object Id -eq 'time-zone').PreferredState -eq 'UTC') 'The preferred time zone is not UTC.'
    }
    Test-Case 'Every date and time choice writes a complete distinct set of values' {
        $card = $script:Settings | Where-Object Id -eq 'date-time-format'
        Assert ($card.PreferredState -like 'ISO-style*') 'ISO-style is no longer the preferred date and time format.'
        # A choice that left a value out would blend into the previous choice.
        foreach ($state in $card.StateOptions) {
            foreach ($entry in $card.Entries) {
                Assert ($entry.States -and $entry.States.ContainsKey($state)) "'$($entry.Name)' has no value for the '$state' format."
                $wanted = Get-EntryWantedValue $entry $state $card
                Assert (-not [string]::IsNullOrWhiteSpace([string]$wanted)) "'$($entry.Name)' has an empty value for the '$state' format."
                Assert ($wanted -ne '__REMOVE_VALUE__') "'$($entry.Name)' would be removed for the '$state' format."
            }
        }
        # Two choices that wrote the same values could never be told apart.
        $fingerprints = @($card.StateOptions | ForEach-Object {
            $state = $_
            @($card.Entries | ForEach-Object { "$($_.Name)=$(Get-EntryWantedValue $_ $state $card)" }) -join '|'
        })
        Assert (@($fingerprints | Select-Object -Unique).Count -eq $fingerprints.Count) 'Two date and time choices write the same values.'
        # A card with no per-state map must still use its preferred/alternate pair.
        $pair = $script:Settings | Where-Object Id -eq 'hidden-files'
        $entry = @($pair.Entries)[0]
        Assert ((Get-EntryWantedValue $entry $pair.PreferredState $pair) -eq $entry.Preferred) 'A plain entry lost its preferred value.'
        Assert ((Get-EntryWantedValue $entry $pair.AlternateState $pair) -eq $entry.Alternate) 'A plain entry lost its alternate value.'
    }
    Test-Case 'A display language names a pack chain and reads the language that really carries it' {
        $table = Get-LanguageChoiceTable
        foreach ($label in @($table.Keys)) {
            $choice = $table[$label]
            Assert ($choice.Tag -match '^[a-z]{2}-[A-Z]{2}$') "'$label' has a malformed language tag '$($choice.Tag)'."
            Assert (@($choice.Packs).Count -ge 1) "'$label' names no display pack."
            foreach ($pack in @($choice.Packs)) { Assert ($pack -match '^[a-z]{2}-[A-Z]{2}$') "'$label' names a malformed pack '$pack'." }
            # A variant Windows serves through the British pack tries that pack
            # first. Every other language tries its own pack first.
            $firstPack = if (@($choice.Packs) -contains 'en-GB' -and $choice.Tag -ne 'en-CA') { 'en-GB' } else { $choice.Tag }
            Assert (@($choice.Packs)[0] -eq $firstPack) "'$label' tries '$(@($choice.Packs)[0])' first, not '$firstPack'."
            Assert (@($choice.Packs) -contains $choice.Tag) "'$label' never tries its own pack."
            $unique = @(@($choice.Packs) | Select-Object -Unique)
            Assert ($unique.Count -eq @($choice.Packs).Count) "'$label' repeats a pack in its chain."
        }
        # Windows returns one list object, not one object per language, and it
        # answers a request for a variant with the parent that owns the pack.
        $windowsStyleList = New-Object 'System.Collections.Generic.List[object]'
        $windowsStyleList.Add([pscustomobject]@{ LanguageId='en-NZ'; LanguagePacks='None' })
        $windowsStyleList.Add([pscustomobject]@{ LanguageId='en-GB'; LanguagePacks='LpCab, LXP' })
        function Get-InstalledLanguage { param([string]$Language) $windowsStyleList }
        Assert ((Expand-InstalledLanguageResult $windowsStyleList).Count -eq 2) 'The Windows language list was not flattened.'
        Assert ((Get-DisplayLanguagePackSource 'en-NZ') -eq 'en-GB') 'A variant served by its parent did not report the parent.'
        Assert (Test-DisplayLanguagePackInstalled 'en-NZ') 'A variant served by its parent was called uninstalled.'
        # A language with no pack at all must read as absent, not as present.
        $emptyList = New-Object 'System.Collections.Generic.List[object]'
        $emptyList.Add([pscustomobject]@{ LanguageId=''; LanguagePacks='' })
        function Get-InstalledLanguage { param([string]$Language) $emptyList }
        Assert ((Get-DisplayLanguagePackSource 'de-DE') -eq '') 'An absent display pack was reported as installed.'
        Assert (-not (Test-DisplayLanguagePackInstalled 'de-DE')) 'An absent display pack passed the installed check.'
        # A row whose pack says None is not a pack either.
        $noneList = New-Object 'System.Collections.Generic.List[object]'
        $noneList.Add([pscustomobject]@{ LanguageId='en-AU'; LanguagePacks='None' })
        function Get-InstalledLanguage { param([string]$Language) $noneList }
        Assert ((Get-DisplayLanguagePackSource 'en-AU') -eq '') "A language whose pack is 'None' was reported as installed."
    }
    Test-Case 'Dingo installs a missing display pack, skips one it has, and refuses one Windows will not supply' {
        $script:Installed = New-Object System.Collections.ArrayList
        function Install-DisplayLanguagePack { param([string]$Language,[int]$TimeoutSeconds=900) [void]$script:Installed.Add($Language) }
        function Get-AvailableDisplayLanguagePacks { @('en-GB','en-US','de-DE') }
        # Already served: nothing is downloaded and the real source is returned.
        function Get-DisplayLanguagePackSource { param([string]$Language) if ($Language -in @('en-NZ','en-GB')) { 'en-GB' } else { '' } }
        Assert ((Install-RequiredDisplayLanguagePack @('en-NZ','en-GB')) -eq 'en-GB') 'An already-served language did not report its source.'
        Assert ($script:Installed.Count -eq 0) 'Dingo downloaded a display pack it already had.'
        # Missing but offered: it is installed, then verified.
        $script:Installed.Clear()
        function Get-DisplayLanguagePackSource { param([string]$Language) if ($script:Installed -contains $Language) { $Language } else { '' } }
        Assert ((Install-RequiredDisplayLanguagePack @('de-DE')) -eq 'de-DE') 'A missing display pack was not installed.'
        Assert ($script:Installed -contains 'de-DE') 'The missing display pack was never requested.'
        # Variant not offered: Dingo falls through to the parent pack.
        $script:Installed.Clear()
        Assert ((Install-RequiredDisplayLanguagePack @('en-ZA','en-GB')) -eq 'en-GB') 'Dingo did not fall through to the parent pack.'
        Assert (@($script:Installed) -join ',' -eq 'en-GB') "Dingo tried to install a pack Windows does not offer: $(@($script:Installed) -join ',')."
        # Nothing offered and nothing installed: refuse with a clear reason.
        $script:Installed.Clear()
        Assert-Throws { Install-RequiredDisplayLanguagePack @('zz-ZZ') } 'offers no display pack'
        Assert ($script:Installed.Count -eq 0) 'Dingo tried to install an unavailable display pack.'
        # An install that reports success but leaves no pack must still fail.
        function Get-DisplayLanguagePackSource { param([string]$Language) '' }
        Assert-Throws { Install-RequiredDisplayLanguagePack @('de-DE') } 'does not list its pack'
        # A pack named for no language at all is a programming error.
        Assert-Throws { Install-RequiredDisplayLanguagePack @() } 'No display-language pack was named'
    }
    Test-Case 'A pack install Windows will not stop keeps its real reason and blocks the next pack' {
        # On a VDI image Stop-Job threw "not implemented" for the Install-Language
        # job. That replaced the timeout message, and the next pack then queued
        # behind the one still running and looked stuck.
        Set-RunScopedFlag 'PackStillRunning' $false
        function Stop-Job { throw (New-Object NotImplementedException 'The method or operation is not implemented.') }
        Stop-PackJob ([pscustomobject]@{}) 'en-GB'
        Assert (Get-RunScopedFlag 'PackStillRunning') 'A pack install that could not be stopped was not recorded.'
        $script:Installed = New-Object Collections.ArrayList
        function Get-AvailableDisplayLanguagePacks { @('en-GB','en-AU') }
        function Get-DisplayLanguagePackSource { param([string]$Language) '' }
        function Install-DisplayLanguagePack { param([string]$Language) [void]$script:Installed.Add($Language); throw "Windows did not finish installing the $Language display pack within 15 minutes." }
        Assert-Throws { Install-RequiredDisplayLanguagePack @('en-GB','en-AU') } 'still installing the en-GB display pack in the background'
        Assert (($script:Installed -join ',') -eq 'en-GB') "Dingo started $($script:Installed -join ', ') while a pack was still installing."
        Set-RunScopedFlag 'PackStillRunning' $false
    }
    Test-Case 'The Microsoft 365 Copilot card reads and removes the app for this account only' {
        $script:M365 = @([pscustomobject]@{ Name='Microsoft.MicrosoftOfficeHub'; PackageFullName='Microsoft.MicrosoftOfficeHub_1_x64__8wekyb3d8bbwe' })
        function Get-AppxPackage { param($Name, $ErrorAction) @($script:M365 | Where-Object Name -eq $Name) }
        function Remove-AppxPackage { param($Package, $ErrorAction) $script:M365 = @($script:M365 | Where-Object PackageFullName -ne $Package) }
        $card = $script:Settings | Where-Object Id -eq 'm365-copilot'
        Assert ($card.Tab -eq 'Taskbar') 'The Microsoft 365 Copilot card is not on the Taskbar tab.'
        Assert ((Get-SettingState $card).Status -eq 'Partial') 'An installed app was not reported as not yet removed.'
        Set-SettingPart $card 'Removed' User
        Assert ((Get-SettingState $card).Status -eq 'Preferred') 'The app was not reported removed.'
        # A managed app that will not go must fail, not report success.
        $script:M365 = @([pscustomobject]@{ Name='Microsoft.MicrosoftOfficeHub'; PackageFullName='kept' })
        function Remove-AppxPackage { param($Package, $ErrorAction) }
        Assert-Throws { Set-SettingPart $card 'Removed' User } 'still installed'
    }
    Test-Case 'Diagnostic data goes off only on the editions that obey it' {
        # 0 is honoured only on Enterprise, Education and Server. Every other
        # edition treats it as 1, so 1 is what the card writes there.
        $script:Edition = ''
        function Get-ItemProperty { param($LiteralPath, $Name, $ErrorAction) if (-not $script:Edition) { throw 'No such value.' } [pscustomobject]@{ EditionID = $script:Edition } }
        foreach ($edition in @('Enterprise','EnterpriseN','EnterpriseS','Education','EducationN','IoTEnterprise','ServerRdsh','ServerDatacenter')) {
            $script:Edition = $edition
            Assert ((Get-LowestDiagnosticDataLevel) -eq 0) "$edition does not turn diagnostic data off."
        }
        foreach ($edition in @('Professional','ProfessionalN','ProfessionalEducation','ProfessionalWorkstation','Core','CoreN','')) {
            $script:Edition = $edition
            Assert ((Get-LowestDiagnosticDataLevel) -eq 1) "'$edition' does not keep required diagnostic data."
        }
    }
    Test-Case 'The Privacy cards write the diagnostic data level this edition allows and say who they affect' {
        $cards = @($script:Settings | Where-Object Tab -eq 'Privacy')
        Assert ((@($cards | ForEach-Object Id) -join ',') -eq 'diagnostic-data,telemetry-service,defender-samples') "The Privacy tab holds $(@($cards | ForEach-Object Id) -join ', ')."
        $data = $cards | Where-Object Id -eq 'diagnostic-data'
        Assert ($data.DisplayScope -eq 'Both' -and $data.RequiresAdmin) 'Diagnostic data does not touch both the account and the computer.'
        $telemetry = $data.Entries | Where-Object Name -eq 'AllowTelemetry'
        $level = Get-LowestDiagnosticDataLevel
        Assert ($telemetry.Scope -eq 'Machine' -and $telemetry.Path -eq 'SOFTWARE\Policies\Microsoft\Windows\DataCollection' -and $telemetry.Preferred -eq $level) "AllowTelemetry is not $level in the policy key."
        $wording = if ($level -eq 0) { 'Turns diagnostic data off' } else { 'cannot turn diagnostic data off' }
        Assert ($data.Description -match $wording) 'The card does not say what this edition allows.'
        $optOut = $data.Entries | Where-Object Name -eq 'POWERSHELL_TELEMETRY_OPTOUT'
        Assert ($optOut.Path -eq 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -and $optOut.Type -eq 'String') 'The PowerShell 7 opt-out is not a machine environment variable.'
        Assert (-not @($data.Entries | Where-Object { $_.Scope -eq 'ElevatedUser' }).Count) 'An account value would be written by the administrator account.'
        foreach ($id in @('telemetry-service','defender-samples')) {
            $card = $cards | Where-Object Id -eq $id
            Assert ($card.DisplayScope -eq 'System' -and $card.RequiresAdmin) "'$id' does not need administrator approval for the whole computer."
        }
    }
    Test-Case 'The telemetry service card reads, disables, and restores the startup type' {
        $script:Svc = [pscustomobject]@{ Name='DiagTrack'; StartType='Automatic'; Status='Running' }
        $script:Stopped = $false
        function Get-Service { param($Name, $ErrorAction) if ($Name -eq $script:Svc.Name) { $script:Svc } elseif ($ErrorAction -eq 'Stop') { throw "No service $Name" } }
        function Set-Service { param($Name, $StartupType, $ErrorAction) $script:Svc.StartType = $StartupType }
        function Stop-Service { param($Name, [switch]$Force, $ErrorAction) $script:Stopped = $true; $script:Svc.Status = 'Stopped' }
        function Start-Service { param($Name, $ErrorAction) $script:Svc.Status = 'Running' }
        function Test-IsAdministrator { $true }
        $card = $script:Settings | Where-Object Id -eq 'telemetry-service'
        Assert ((Get-SettingState $card).Status -eq 'Alternate') 'A service that starts automatically is not read as the Windows default.'
        Set-SettingPart $card 'Disabled' Machine
        Assert ($script:Svc.StartType -eq 'Disabled' -and $script:Stopped) 'The service was not disabled and stopped.'
        Assert ((Get-SettingState $card).Status -eq 'Preferred') 'A disabled service is not read as preferred.'
        $script:Svc.StartType = 'Manual'
        Assert ((Get-SettingState $card).Status -eq 'Partial') 'A service set to Manual is not reported as neither choice.'
        Set-SettingPart $card 'Automatic' Machine
        Assert ($script:Svc.StartType -eq 'Automatic' -and $script:Svc.Status -eq 'Running') 'The service was not restored.'
        # A service Windows refuses to change must fail, not report success.
        function Set-Service { param($Name, $StartupType, $ErrorAction) }
        Assert-Throws { Set-SettingPart $card 'Disabled' Machine } 'still starts as Automatic'
        $script:Svc = [pscustomobject]@{ Name='Other'; StartType='Automatic'; Status='Running' }
        Assert ((Get-SettingState $card).Status -eq 'Unavailable') 'A missing service is not reported as unavailable.'
    }
    Test-Case 'Background services start only when needed, and a service Windows lacks is skipped' {
        # The start types a clean Windows 11 Pro 25H2 install had.
        $script:Services = @{
            MapsBroker=[pscustomobject]@{ Name='MapsBroker'; StartType='Automatic'; Status='Stopped' }
            StorSvc=[pscustomobject]@{ Name='StorSvc'; StartType='Automatic'; Status='Running' }
            InventorySvc=[pscustomobject]@{ Name='InventorySvc'; StartType='Automatic'; Status='Running' }
            WSAIFabricSvc=[pscustomobject]@{ Name='WSAIFabricSvc'; StartType='Automatic'; Status='Running' }
            whesvc=[pscustomobject]@{ Name='whesvc'; StartType='Automatic'; Status='Running' }
            wuqisvc=[pscustomobject]@{ Name='wuqisvc'; StartType='Manual'; Status='Stopped' }
        }
        $script:Stopped = New-Object Collections.ArrayList
        function Get-Service { param($Name, $ErrorAction) if ($script:Services.ContainsKey($Name)) { $script:Services[$Name] } elseif ($ErrorAction -eq 'Stop') { throw "No service $Name" } }
        function Set-Service { param($Name, $StartupType, $ErrorAction) $script:Services[$Name].StartType = $StartupType }
        function Stop-Service { param($Name, [switch]$Force, $ErrorAction) [void]$script:Stopped.Add($Name); $script:Services[$Name].Status = 'Stopped' }
        function Start-Service { param($Name, $ErrorAction) $script:Services[$Name].Status = 'Running' }
        function Test-IsAdministrator { $true }
        $card = $script:Settings | Where-Object Id -eq 'background-services'
        Assert ($card.Tab -eq 'Windows features' -and $card.DisplayScope -eq 'System') 'Background services is not a whole-computer card on the Windows features tab.'
        Assert ((Get-SettingState $card).Status -eq 'Alternate') 'A clean install is not read as the Windows default.'
        Set-SettingPart $card 'Start only when needed' Machine
        $types = ($script:Services.Keys | Sort-Object | ForEach-Object { "$($_)=$($script:Services[$_].StartType)" }) -join ','
        Assert ($types -eq 'InventorySvc=Manual,MapsBroker=Manual,StorSvc=Manual,whesvc=Manual,WSAIFabricSvc=Manual,wuqisvc=Disabled') "The services are now $types."
        # A Manual service may be in use, so only the disabled one is stopped.
        Assert (($script:Stopped -join ',') -eq '') "Dingo stopped $($script:Stopped -join ', '), which were not running or are only set to Manual."
        Assert ((Get-SettingState $card).Status -eq 'Preferred') 'The applied choice is not read as preferred.'
        Set-SettingPart $card 'Windows default' Machine
        Assert ((Get-SettingState $card).Status -eq 'Alternate') 'Switching back did not restore the clean-install start types.'
        # An older Windows without the newest services still gets the rest.
        $script:Services.Remove('whesvc'); $script:Services.Remove('WSAIFabricSvc')
        Set-SettingPart $card 'Start only when needed' Machine
        $state = Get-SettingState $card
        Assert ($state.Status -eq 'Preferred' -and $state.Details -match 'no WSAIFabricSvc, whesvc service') "A missing service was not skipped and named: $($state.Status) $($state.Details)"
        $script:Services = @{}
        Assert ((Get-SettingState $card).Status -eq 'Unavailable') 'A computer with none of the services is not reported as unavailable.'
    }
    Test-Case 'Diagnostic data reads a clean install as the Windows default and leaves setup choices alone' {
        # What a clean Windows 11 Pro 25H2 install held after setup. Advertising
        # ID and tailored experiences are setup choices; 2 is what that install had.
        $script:Values = @{
            Enabled_AdvertisingInfo=0; TailoredExperiencesWithDiagnosticDataEnabled=2
            RestrictImplicitInkCollection=0; RestrictImplicitTextCollection=0; HarvestContacts=1; AcceptedPrivacyPolicy=1
        }
        function Get-EntryValue {
            param($Entry)
            $key = if ($Entry.Name -eq 'Enabled') { "Enabled_$(Split-Path $Entry.Path -Leaf)" } else { $Entry.Name }
            if ($script:Values.ContainsKey($key)) { return [pscustomobject]@{ Status='Present'; Exists=$true; Value=$script:Values[$key]; ValueType=$Entry.Type; ErrorMessage='' } }
            [pscustomobject]@{ Status='Missing'; Exists=$false; Value=$null; ValueType=''; ErrorMessage='' }
        }
        $card = $script:Settings | Where-Object Id -eq 'diagnostic-data'
        $state = Get-RegistrySettingState $card
        Assert ($state.Status -eq 'Alternate') "A clean install reads as '$($state.DisplayText)'."
        # A switch turned on in Settings is still the Windows default.
        $script:Values['Start_TrackProgs'] = 1
        $script:Values['Enabled_TIPC'] = 1
        Assert ((Get-RegistrySettingState $card).Status -eq 'Alternate') 'A switch turned on in Settings reads as a custom setup.'
        # A value the card does not know about is still custom.
        $script:Values['HarvestContacts'] = 7
        Assert ((Get-RegistrySettingState $card).Status -eq 'Partial') 'An unknown value reads as the Windows default.'
        # Switching back never writes a setup choice.
        function New-ItemProperty { throw 'A setup choice was written.' }
        function Remove-ItemProperty { throw 'A setup choice was removed.' }
        foreach ($leaf in @('AdvertisingInfo','Privacy')) {
            $entry = @($card.Entries | Where-Object { (Split-Path $_.Path -Leaf) -eq $leaf })
            Assert ($entry.Count -eq 1) "Found $($entry.Count) setup-choice entries under $leaf."
            Set-EntryValue $entry[0] 'Windows default' $card
        }
    }
    Test-Case 'The Defender card reads back sample submission and names a policy that overrides it' {
        $script:Consent = 1
        $script:Policy = $null
        function Get-MpPreference { param($ErrorAction) [pscustomobject]@{ SubmitSamplesConsent = [byte]$script:Consent } }
        function Set-MpPreference { param($SubmitSamplesConsent, $ErrorAction) $script:Consent = $SubmitSamplesConsent }
        function Get-DefenderSamplePolicyValue { $script:Policy }
        function Test-IsAdministrator { $true }
        $card = $script:Settings | Where-Object Id -eq 'defender-samples'
        $state = Get-SettingState $card
        Assert ($state.Status -eq 'Alternate' -and $state.DisplayText -eq 'Send safe samples') "Windows' default read as '$($state.DisplayText)'."
        Set-SettingPart $card 'Never send' Machine
        Assert ($script:Consent -eq 2) "Never send wrote $script:Consent, not 2."
        Assert ((Get-SettingState $card).Status -eq 'Preferred') 'Never send is not read as preferred.'
        $script:Consent = 3
        Assert ((Get-SettingState $card).DisplayText -eq 'Send all samples') 'A value the card does not offer is not named.'
        $script:Policy = 1
        Assert ((Get-SettingState $card).Details -match 'policy sets this to Send safe samples') 'A policy value is not named on the card.'
        # Microsoft says a blocked change can look as if it worked.
        function Set-MpPreference { param($SubmitSamplesConsent, $ErrorAction) }
        Assert-Throws { Set-SettingPart $card 'Never send' Machine } 'Tamper Protection may have blocked'
        function Get-MpPreference { param($ErrorAction) throw 'The service is not running.' }
        Assert ((Get-SettingState $card).Status -eq 'Unavailable') 'A Defender that does not answer is not reported as unavailable.'
    }
    Test-Case 'The window reports what the administrator step is doing, card by card' {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ('dingo-progress-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force $dir | Out-Null
        try {
            $savedSettings = $script:Settings
            $script:WorkerProgressPath = Join-Path $dir 'progress.json'
            $resultPath = Join-Path $dir 'result.json'
            $SummaryText = [pscustomobject]@{Text='';Foreground='#334E68';FontWeight='Normal'}
            $ProgressBar = [pscustomobject]@{Value=0;IsIndeterminate=$true}
            $script:Settings = @(
                [pscustomobject]@{Id='a';Details='';DetailsControl=[pscustomobject]@{Text=''}}
                [pscustomobject]@{Id='b';Details='';DetailsControl=[pscustomobject]@{Text=''}}
            )
            $pending = [pscustomobject]@{
                Started=(Get-Date).AddSeconds(-450); ProgressPath=$script:WorkerProgressPath; ResultPath=$resultPath
                Selected=@([pscustomobject]@{Id='a';RequiresAdmin=$true},[pscustomobject]@{Id='b';RequiresAdmin=$true})
            }
            # Nothing published yet: the approval prompt is still unanswered.
            Update-AdministratorProgress $pending
            Assert ($SummaryText.Text -match 'Waiting for administrator approval') 'An unanswered approval prompt is not named.'
            # These two clocks read the real wall clock, so a slow machine can push
            # the count on to the next second between the offset above and the
            # check here. Accept that one second. The point of the check is the
            # m:ss shape and the right starting point, not the exact tick.
            Assert ($SummaryText.Text -match '7:3[01]') 'The waiting message carries no elapsed time.'
            Assert ($ProgressBar.IsIndeterminate) 'The progress bar claims progress before the worker started.'
            # First step running, nothing finished.
            Set-Content -LiteralPath $resultPath -Value '[]'
            Set-WorkerProgressStep 1 2 'a' 'First card' 'Working' 'Writing the computer-wide policy'
            Update-AdministratorProgress $pending
            Assert ($SummaryText.Text -match 'step 1 of 2: First card') 'The running step is not named.'
            Assert ($SummaryText.Text -match 'Writing the computer-wide policy') 'The running step does not say what it is doing.'
            Assert ($SummaryText.Text -match '0 of 2 finished') 'The finished count is missing.'
            Assert (-not $ProgressBar.IsIndeterminate -and $ProgressBar.Value -eq 0) 'The progress bar did not switch to a real count.'
            Assert (($script:Settings | Where-Object Id -eq 'a').DetailsControl.Text -eq 'Writing the computer-wide policy') 'The running card does not show its own step.'
            Assert (($script:Settings | Where-Object Id -eq 'b').DetailsControl.Text -match 'Waiting') 'A card not yet reached does not say so.'
            # A long download says so, and names the time it is allowed.
            Set-Content -LiteralPath $resultPath -Value '[{"Id":"a"}]'
            Set-WorkerProgressStep 2 2 'b' 'Display language' 'Working' 'Reading'
            $script:WorkerStep.StepStarted = (Get-Date).AddSeconds(-134).ToString('o')
            Write-WorkerProgress 'Downloading' 'Downloading the en-GB language pack. Windows allows 12m 0s more.'
            Update-AdministratorProgress $pending
            Assert ($SummaryText.Text -match 'Windows Update, so this step is the slow one') 'A download does not explain why it is slow.'
            Assert ($SummaryText.Text -match '2:1[45] on this step') 'The per-step clock is missing.'
            Assert ($SummaryText.Text -match '1 of 2 finished') 'The finished count did not advance.'
            Assert ($ProgressBar.Value -eq 50) "The progress bar reads $($ProgressBar.Value) instead of 50."
            Assert (($script:Settings | Where-Object Id -eq 'a').DetailsControl.Text -match 'finished') 'A finished card still says it is waiting.'
            Assert ($SummaryText.Text -notmatch '\.\.') 'The summary sentence doubles its full stop.'
            # A read that lands mid-write keeps the last good reading.
            $lastGood = $SummaryText.Text
            Set-Content -LiteralPath $script:WorkerProgressPath -Value '{"Index":2,"Tot'
            Update-AdministratorProgress $pending
            Assert ($SummaryText.Text -match 'step 2 of 2: Display language') 'A torn read lost the running step.'
            Assert ($SummaryText.Text -notmatch 'Waiting for administrator approval') 'A torn read made a running worker look unstarted.'
            # Progress publishing is a no-op wherever there is nowhere to publish.
            $script:WorkerProgressPath = ''
            $script:WorkerStep = $null
            Write-WorkerProgress 'Working' 'no target'
            Assert ($true) 'Publishing progress without a target must not throw.'
        } finally {
            $script:Settings = $savedSettings
            $script:WorkerProgressPath = ''
            $script:WorkerStep = $null
            Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
        }
    }
    Test-Case 'A system locale counts as set once Windows has written it down for the next restart' {
        # Set-WinSystemLocale never changes the running locale, so demanding the
        # running one would fail every first-time change on a real computer.
        function Get-WinSystemLocale { [pscustomobject]@{ Name='en-US' } }
        function Get-PendingSystemLocaleId { '0C09' }
        Assert (Test-SystemLocaleAccepted 'en-AU') 'A written but not yet restarted system locale was refused.'
        Assert (-not (Test-SystemLocaleAccepted 'de-DE')) 'A different pending locale was accepted.'
        # Lower case and stray spaces are the same written value.
        function Get-PendingSystemLocaleId { ' 0c09 ' }
        Assert (Test-SystemLocaleAccepted 'en-AU') 'A pending locale in lower case was refused.'
        # Nothing written and nothing running means not set.
        function Get-PendingSystemLocaleId { '' }
        Assert (-not (Test-SystemLocaleAccepted 'en-AU')) 'An unwritten system locale was accepted.'
        # Already running it needs no registry reading at all.
        function Get-WinSystemLocale { [pscustomobject]@{ Name='en-AU' } }
        Assert (Test-SystemLocaleAccepted 'en-AU') 'The running system locale was refused.'
        # A tag Windows does not know is never accepted.
        function Get-WinSystemLocale { [pscustomobject]@{ Name='en-US' } }
        function Get-PendingSystemLocaleId { '0C09' }
        Assert (-not (Test-SystemLocaleAccepted 'zz-ZZ')) 'An unknown language tag was accepted as a system locale.'
    }
    Test-Case 'Only a language that must be downloaded counts as a slow step, and the answer is cached' {
        $card = ($script:Settings | Where-Object Id -eq 'display-language').PSObject.Copy()
        $other = ($script:Settings | Where-Object Id -eq 'hidden-files').PSObject.Copy()
        try {
            function Get-DisplayLanguagePackSource { param([string]$Language) '' }
            Clear-DisplayPackCache
            Assert (Test-SettingNeedsLanguageDownload $card) 'A language with no pack anywhere was not treated as a download.'
            # A pack that is already here means no download.
            function Get-DisplayLanguagePackSource { param([string]$Language) if ($Language -eq 'en-GB') { 'en-GB' } else { '' } }
            Clear-DisplayPackCache
            $card.DesiredState = 'British English (en-GB)'
            Assert (-not (Test-SettingNeedsLanguageDownload $card)) 'An installed pack was still treated as a download.'
            # A variant served by its parent pack is not a download either.
            $card.DesiredState = 'Australian English (en-AU)'
            Assert (-not (Test-SettingNeedsLanguageDownload $card)) 'A variant served by its parent pack was treated as a download.'
            # A language with nothing to ride on is.
            $card.DesiredState = 'Japanese (ja-JP)'
            Assert (Test-SettingNeedsLanguageDownload $card) 'A language with no pack at all was not treated as a download.'
            Assert ((Get-SettingAdvisory $card) -match 'hold up the whole run') 'The note does not warn that the run is held up.'
            # No other kind of card is ever a language download.
            Assert (-not (Test-SettingNeedsLanguageDownload $other)) 'A registry card was treated as a language download.'
            # Windows is asked once per language, not once per redraw: the card asks
            # this every time the window refreshes, and asking Windows costs seconds.
            $script:Asked = 0
            function Get-DisplayLanguagePackSource { param([string]$Language) $script:Asked++; '' }
            Clear-DisplayPackCache
            1..20 | ForEach-Object { [void](Test-SettingNeedsLanguageDownload $card) }
            Assert ($script:Asked -le 1) "Windows was asked $script:Asked times for 20 redraws; the answer is not cached."
            # Reading settings again must ask afresh, or an installed pack would
            # keep showing the warning for the rest of the session.
            Clear-DisplayPackCache
            [void](Test-SettingNeedsLanguageDownload $card)
            Assert ($script:Asked -gt 1) 'Reading settings again did not clear the cached answer.'
        } finally {
            Clear-DisplayPackCache
        }
    }
    Test-Case 'A display language with no pack on this computer warns before anyone waits' {
        $card = ($script:Settings | Where-Object Id -eq 'display-language').PSObject.Copy()
        function Get-DisplayLanguagePackSource { param([string]$Language) '' }
        # The answer is cached per language, so a changed stub needs a fresh start.
        Clear-DisplayPackCache
        $advisory = Get-SettingAdvisory $card
        Assert ($advisory -match 'must download') 'A missing display pack does not warn that Windows must download one.'
        Assert ($advisory -match 'ten minutes') 'The warning does not say how long the download can take.'
        Assert ($advisory -match 'fifteen') 'The warning does not say when Dingo gives up.'
        Assert ($advisory -match 'Every other selected change still runs') 'The warning does not say the rest of the plan is unaffected.'
        Assert ($advisory -match 'hold up the whole run') 'The warning does not say the run is held up.'
        # A pack that is already present is not worth a warning.
        function Get-DisplayLanguagePackSource { param([string]$Language) 'en-GB' }
        Clear-DisplayPackCache
        Assert (-not (Get-SettingAdvisory $card)) 'An installed display pack still warns about a download.'
        # A card of any other kind is never given this warning.
        function Get-DisplayLanguagePackSource { param([string]$Language) '' }
        Clear-DisplayPackCache
        Assert (-not (Get-SettingAdvisory ($script:Settings | Where-Object Id -eq 'hidden-files'))) 'A registry card was given the language download warning.'
    }
    Test-Case 'A language download is watched for real activity and gives up early when it stalls' {
        $script:Shown = New-Object System.Collections.ArrayList
        function Write-WorkerProgress { param($Phase,$Detail) [void]$script:Shown.Add([string]$Detail) }
        try {
            # Windows writes progress records into the job when a command reports
            # any, so the newest record is what it is doing right now.
            $fake = [pscustomobject]@{ ChildJobs=@([pscustomobject]@{ Progress=@(
                [pscustomobject]@{ PercentComplete=10; StatusDescription='Downloading' }
                [pscustomobject]@{ PercentComplete=64; StatusDescription='Installing' }
            ) }) }
            $report = Get-JobProgressReport $fake
            Assert ($report.Percent -eq 64) "The newest progress record was not read; got $($report.Percent)."
            Assert ($report.Status -eq 'Installing') 'The newest status line was not read.'
            Assert ((Get-JobProgressReport $fake).Signal -eq $report.Signal) 'The same progress reads as a change.'
            $empty = Get-JobProgressReport ([pscustomobject]@{ ChildJobs=@() })
            Assert ($empty.Percent -eq -1 -and $empty.Count -eq 0) 'A job with no progress stream did not read as no news.'
            # The real signal for a language pack: Install-Language reports no
            # percentage at all, so Dingo watches what Windows servicing touches.
            $real = Get-ServicingActivity
            Assert ($real -is [string]) 'The servicing activity signal is not a plain string.'
            Assert ((Get-ServicingActivity) -eq $real -or $true) 'Reading servicing activity must not throw.'
            # Servicing frozen and no percentage: give up early and say so.
            function Get-ServicingActivity { 'frozen' }
            function Install-Language { param($Language,[switch]$ExcludeFeatures,[switch]$AsJob) Start-Job -ScriptBlock { Start-Sleep -Seconds 90 } }
            $watch = [Diagnostics.Stopwatch]::StartNew()
            Assert-Throws { Install-DisplayLanguagePack 'en-GB' 90 10 } 'Neither Windows Update nor the servicing logs changed'
            Assert ($watch.Elapsed.TotalSeconds -lt 60) "A stall waited $([int]$watch.Elapsed.TotalSeconds)s instead of giving up early."
            Assert (@($script:Shown | Where-Object { $_ -match 'Nothing has moved for' }).Count -gt 0) 'A stalling download never said it had stopped moving.'
            Assert (@($script:Shown | Where-Object { $_ -match 'gives no percentage' }).Count -gt 0) 'Dingo did not say plainly that Windows gives no percentage.'
            # Servicing busy: no false stall, even with no percentage at all.
            $script:Shown.Clear()
            $script:Beat = 0
            function Get-ServicingActivity { $script:Beat++; "moving-$script:Beat" }
            $watch = [Diagnostics.Stopwatch]::StartNew()
            Assert-Throws { Install-DisplayLanguagePack 'en-GB' 14 6 } 'did not finish installing'
            Assert ($watch.Elapsed.TotalSeconds -ge 12) 'A busy download was cut short by a false stall.'
            Assert (@($script:Shown | Where-Object { $_ -match 'Last sign of activity' }).Count -gt 0) 'A busy download never reported its last sign of activity.'
            # A percentage, when a command does report one, is preferred and named.
            $script:Shown.Clear()
            function Get-ServicingActivity { 'frozen' }
            function Install-Language { param($Language,[switch]$ExcludeFeatures,[switch]$AsJob)
                Start-Job -ScriptBlock { Write-Progress -Activity 'l' -Status 'Downloading' -PercentComplete 41; Start-Sleep -Seconds 90 } }
            Assert-Throws { Install-DisplayLanguagePack 'en-GB' 90 10 } 'It sat at 41%'
            Assert (@($script:Shown | Where-Object { $_ -match '41% done' }).Count -gt 0) 'The real percentage was never shown.'
            # Keeps moving and finishes: no stall, no throw.
            $script:Shown.Clear()
            function Install-Language { param($Language,[switch]$ExcludeFeatures,[switch]$AsJob)
                Start-Job -ScriptBlock { foreach ($i in 20,60,100) { Write-Progress -Activity 'l' -Status 'Downloading' -PercentComplete $i; Start-Sleep -Seconds 3 } } }
            Install-DisplayLanguagePack 'en-GB' 90 5
            Assert (@($script:Shown | Where-Object { $_ -match '100% done' }).Count -gt 0) 'A download that kept moving never reported completion.'
        } finally {
            Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue
        }
    }
    Test-Case 'Switching display language replaces the account language list rather than adding to it' {
        # Windows shows Store apps in the FIRST supported language of this list, so
        # leaving an old entry above the chosen one quietly defeats the change.
        $card = $script:Settings | Where-Object Id -eq 'display-language'
        $script:Applied = $null
        $script:Forced = $false
        function Get-DisplayLanguagePackSource { param([string]$Language) 'en-GB' }
        function Test-DisplayLanguagePackInstalled { param([string]$Language) $true }
        function New-WinUserLanguageList { param([string]$Language) @([pscustomobject]@{ LanguageTag=$Language }) }
        function Set-WinUserLanguageList { param($LanguageList,[switch]$Force) $script:Applied = @($LanguageList); $script:Forced = [bool]$Force }
        function Set-WinUILanguageOverride { param([string]$Language) }
        function Get-WinUserLanguageList { $script:Applied }
        function Get-WinUILanguageOverride { [pscustomobject]@{ Name='en-AU' } }
        function Get-ConfiguredDateTimeFormatState { '' }
        Set-LanguageKindPart $card 'Australian English (en-AU)' 'User'
        Assert (@($script:Applied).Count -eq 1) "The account language list kept $(@($script:Applied).Count) entries instead of one."
        Assert (@($script:Applied)[0].LanguageTag -eq 'en-AU') 'The chosen language is not the only entry.'
        Assert ($script:Forced) 'The language list was not replaced with -Force.'
        # With no pack installed the account is never pointed at the language.
        $script:Applied = $null
        function Test-DisplayLanguagePackInstalled { param([string]$Language) $false }
        Assert-Throws { Set-LanguageKindPart $card 'Australian English (en-AU)' 'User' } 'cannot be switched to it yet'
        Assert ($null -eq $script:Applied) 'The account language list changed even though no display pack was installed.'
    }
    Test-Case 'No script variable shares a name with a command-line parameter' {
        # A script parameter lives in the script scope, so a top-level
        # $script:Name = '' of the same name silently wipes the value the script
        # was started with. That is invisible until something far away misbehaves.
        $parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        Assert ($parameterNames.Count -gt 5) 'The parameter block could not be read.'
        # An assignment that reads the parameter on its own right-hand side is
        # extending it on purpose, which is safe. One that does not is a wipe.
        $wipes = New-Object System.Collections.ArrayList
        $checked = 0
        foreach ($statement in $ast.EndBlock.Statements) {
            if ($statement -isnot [Management.Automation.Language.AssignmentStatementAst]) { continue }
            $left = $statement.Left
            if ($left -isnot [Management.Automation.Language.VariableExpressionAst]) { continue }
            $path = $left.VariablePath.UserPath
            if ($path -notlike 'script:*') { continue }
            $checked++
            $name = $path.Substring(7)
            if ($parameterNames -notcontains $name) { continue }
            $reads = @($statement.Right.FindAll({ param($node)
                $node -is [Management.Automation.Language.VariableExpressionAst] -and
                $node.VariablePath.UserPath -eq $name }, $true))
            if (-not $reads.Count) { [void]$wipes.Add($name) }
        }
        Assert ($checked -gt 3) 'No top-level script variables were found to check.'
        $clashes = @($wipes | Select-Object -Unique)
        Assert ($clashes.Count -eq 0) "These script variables wipe the parameter of the same name: $($clashes -join ', ')."
    }
    Test-Case 'The administrator step can be stopped, and keeps what it already finished' {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ('dingo-cancel-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force $dir | Out-Null
        $flag = Join-Path $dir 'cancel.flag'
        $savedSettings = $script:Settings
        try {
            # With nowhere to look, nothing is ever treated as a stop request.
            $script:WorkerCancelPath = ''
            Assert (-not (Test-WorkerCancelled)) 'A worker with no cancel path thought it was stopped.'
            $script:WorkerCancelPath = $flag
            Assert (-not (Test-WorkerCancelled)) 'A missing stop file was read as a stop request.'
            Set-Content -LiteralPath $flag -Value 'stop'
            Assert (Test-WorkerCancelled) 'A stop file was not noticed.'
            # A long download lets go promptly and says why.
            function Write-WorkerProgress { param($Phase,$Detail) }
            function Get-ServicingActivity { [Guid]::NewGuid().ToString() }
            function Install-Language { param($Language,[switch]$ExcludeFeatures,[switch]$AsJob) Start-Job -ScriptBlock { Start-Sleep -Seconds 120 } }
            $watch = [Diagnostics.Stopwatch]::StartNew()
            Assert-Throws { Install-DisplayLanguagePack 'en-GB' 120 60 } 'Stopped at your request'
            Assert ($watch.Elapsed.TotalSeconds -lt 30) "A stop took $([int]$watch.Elapsed.TotalSeconds)s to take effect."
            # The plan loop stops between settings, never halfway through one, and
            # every setting it did finish is still reported.
            Remove-Item -LiteralPath $flag -Force
            # Keyed to the setting, not to a call count, so how many scopes each
            # setting happens to have cannot change what this test proves.
            function Invoke-SettingPartResults { param($Setting,$State,$Scope)
                if ($Setting.Id -eq 'b') { Set-Content -LiteralPath $flag -Value 'stop' }
                @((New-OperationComponent 'Machine' 'Succeeded' 'ok')) }
            $plan = @('a','b','c','d') | ForEach-Object { [pscustomobject]@{ Id=$_; DesiredState='x' } }
            # Real enough for the real scope check: one computer-wide entry each.
            $all = @('a','b','c','d') | ForEach-Object { [pscustomobject]@{ Id=$_; Name="card $_"; DesiredState='x'; Kind='Registry'; Entries=@([pscustomobject]@{ Scope='Machine' }) } }
            # Assigned, not piped: the function returns its list with a leading comma,
            # so a pipeline sees one list object rather than one result per setting.
            $results = Invoke-AdministratorPlan $plan $all
            $ids = @(foreach ($result in $results) { [string]$result.Id })
            Assert ($ids.Count -eq 2) "A stopped plan reported $($ids.Count) settings instead of the 2 it finished."
            Assert (($ids -join ',') -eq 'a,b') "A stopped plan lost or reordered what it finished: $($ids -join ',')."
            $failed = @(foreach ($result in $results) { if (-not $result.Success) { $result } })
            Assert ($failed.Count -eq 0) 'A stopped plan marked a finished setting as failed.'
        } finally {
            $script:Settings = $savedSettings
            $script:WorkerCancelPath = ''
            Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue
            Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
        }
    }
    Test-Case 'A slow language download runs last and alongside the quick settings' {
        $savedSettings = $script:Settings
        try {
            $entry = @([pscustomobject]@{ Scope='Machine' })
            $all = @(
                [pscustomobject]@{ Id='time-zone'; Name='Time zone'; DesiredState='UTC'; Kind='Registry'; Entries=$entry }
                [pscustomobject]@{ Id='display-language'; Name='Display language'; DesiredState='British English (en-GB)'; Kind='Language'; Entries=$entry }
                [pscustomobject]@{ Id='onedrive'; Name='OneDrive'; DesiredState='Disabled'; Kind='Registry'; Entries=$entry }
                [pscustomobject]@{ Id='edge-copilot'; Name='Copilot in Edge'; DesiredState='Disabled'; Kind='Registry'; Entries=$entry }
            )
            $plan = @($all | ForEach-Object { [pscustomobject]@{ Id=$_.Id; DesiredState=$_.DesiredState } })
            function Get-AvailableDisplayLanguagePacks { @('en-GB') }
            # No pack here, so the language step is the slow one and goes last.
            function Get-DisplayLanguagePackSource { param([string]$Language) '' }
            Clear-DisplayPackCache
            $split = Split-SlowPlanRequests $plan $all
            Assert ((@($split.Quick) | ForEach-Object { $_.Id }) -join ',' -eq 'time-zone,onedrive,edge-copilot') 'The quick settings were reordered or lost.'
            Assert ((@($split.Slow) | ForEach-Object { $_.Id }) -join ',' -eq 'display-language') 'The slow language step was not separated out.'
            # A pack that is already here is not slow, so nothing is moved.
            function Get-DisplayLanguagePackSource { param([string]$Language) 'en-GB' }
            Clear-DisplayPackCache
            $split = Split-SlowPlanRequests $plan $all
            Assert (@($split.Slow).Count -eq 0) 'A language whose pack is installed was treated as slow.'
            Assert (@($split.Quick).Count -eq 4) 'Settings went missing when nothing was slow.'
            # The download is started up front and taken over later, so the quick
            # settings run while Windows fetches it rather than queueing behind it.
            function Get-DisplayLanguagePackSource { param([string]$Language) '' }
            Clear-DisplayPackCache
            $script:Notes = New-Object System.Collections.ArrayList
            function Write-Log { param($Level,$Message) [void]$script:Notes.Add([string]$Message) }
            function Write-WorkerProgress { param($Phase,$Detail) }
            function Install-Language { param($Language,[switch]$ExcludeFeatures,[switch]$AsJob) Start-Job -ScriptBlock { Start-Sleep -Seconds 6 } }
            function Invoke-SettingPartResults { param($Setting,$State,$Scope)
                if ($Setting.Kind -eq 'Language') { [void](Install-DisplayLanguagePack 'en-GB' 60 30) } else { Start-Sleep -Milliseconds 700 }
                @((New-OperationComponent 'Machine' 'Succeeded' 'ok')) }
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $results = Invoke-AdministratorPlan $plan $all
            $elapsed = $watch.Elapsed.TotalSeconds
            $ids = @(foreach ($result in $results) { [string]$result.Id })
            Assert (($ids -join ',') -eq 'time-zone,onedrive,edge-copilot,display-language') "The plan ran in the order $($ids -join ',')."
            # Three quick settings of 0.7s plus a 6s download is 8.1s one after the
            # other. Overlapped it is about 6s, so anything under 7.5s proves it.
            Assert ($elapsed -lt 7.5) "The download did not overlap the quick settings: the plan took $([math]::Round($elapsed,1))s."
            Assert ($elapsed -ge 5.5) "The download did not actually run: the plan took $([math]::Round($elapsed,1))s."
            Assert (@($script:Notes | Where-Object { $_ -match 'in the background' }).Count -gt 0) 'The early download was never started.'
            Assert (@($script:Notes | Where-Object { $_ -match 'Taking over' }).Count -gt 0) 'The early download was started but not used.'
            # Starting it twice would download it twice.
            Clear-DisplayPackCache
            $script:Notes.Clear()
            Assert ((Start-DisplayLanguagePackPrefetch @('en-GB')) -eq 'en-GB') 'The first request did not start a download.'
            Assert ((Start-DisplayLanguagePackPrefetch @('en-GB')) -eq '') 'The same pack was queued for download twice.'
            Stop-PrestartedPackJobs
            # A pack already present is never downloaded again.
            function Get-DisplayLanguagePackSource { param([string]$Language) 'en-GB' }
            Clear-DisplayPackCache
            Assert ((Start-DisplayLanguagePackPrefetch @('en-GB')) -eq '') 'An installed pack was queued for download.'
            # A download nobody took over is dropped rather than left running.
            function Get-DisplayLanguagePackSource { param([string]$Language) '' }
            Clear-DisplayPackCache
            [void](Start-DisplayLanguagePackPrefetch @('en-GB'))
            Stop-PrestartedPackJobs
            Assert ($null -eq (Get-PrestartedPackJob 'en-GB')) 'A dropped download was still on offer.'
        } finally {
            $script:Settings = $savedSettings
            Clear-DisplayPackCache
            Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue
        }
    }
    Test-Case 'A card note appears and disappears as the choice changes' {
        # The caveat depends on the chosen language, so it has to be recomputed
        # rather than frozen at the moment the card was first drawn.
        $box = [pscustomobject]@{ Visibility='Collapsed' }
        $card = ($script:Settings | Where-Object Id -eq 'display-language').PSObject.Copy()
        $card | Add-Member -NotePropertyName AdvisoryControl -NotePropertyValue ([pscustomobject]@{ Text=''; Parent=$box }) -Force
        try {
            # A pack that is here: nothing to warn about.
            function Get-DisplayLanguagePackSource { param([string]$Language) 'en-GB' }
            Clear-DisplayPackCache
            $card.DesiredState = 'British English (en-GB)'
            Update-CardAdvisory $card
            Assert ($box.Visibility -eq 'Collapsed') 'A language whose pack is installed still shows a note.'
            Assert ($card.AdvisoryControl.Text -eq '') 'An empty note box still holds text.'
            # Switch to one with no pack: the note must appear.
            function Get-DisplayLanguagePackSource { param([string]$Language) if ($Language -eq 'en-GB') { 'en-GB' } else { '' } }
            Clear-DisplayPackCache
            $card.DesiredState = 'Spanish (es-ES)'
            Update-CardAdvisory $card
            Assert ($box.Visibility -eq 'Visible') 'Choosing a language that needs a download did not raise the note.'
            Assert ($card.AdvisoryControl.Text -match 'Spanish \(es-ES\)') "The note does not name the chosen language: '$($card.AdvisoryControl.Text)'."
            Assert ($card.AdvisoryControl.Text -match 'hold up the whole run') 'The note does not warn that the run is held up.'
            Assert ($card.AdvisoryControl.Text -match '^Note: ') 'The note is not labelled as one.'
            # And back again.
            $card.DesiredState = 'British English (en-GB)'
            Update-CardAdvisory $card
            Assert ($box.Visibility -eq 'Collapsed') 'Switching back to an installed language left the note showing.'
            # A card with no note box at all must be left alone, not throw.
            $bare = ($script:Settings | Where-Object Id -eq 'hidden-files').PSObject.Copy()
            Update-CardAdvisory $bare
            Assert ($true) 'Updating a card with no note box must not throw.'
        } finally {
            Clear-DisplayPackCache
        }
    }
    Test-Case 'A setting that is not finished says so loudly, not only in small print' {
        # The sentence at the foot of the window was missed. The same words now
        # also come up as a box, and the sentence itself is coloured.
        $SummaryText = [pscustomobject]@{Text='';Foreground='#334E68';FontWeight='Normal'}
        $ProgressBar = [pscustomobject]@{Value=0;IsIndeterminate=$true}
        $RestartExplorerCheckBox = [pscustomobject]@{IsEnabled=$false;IsChecked=$false}
        $script:ActionButtons = @([pscustomobject]@{IsEnabled=$false})
        $script:ApplyInProgress = $true
        $script:ApplyRestartExplorer = $false
        $script:Notices = New-Object System.Collections.ArrayList
        function Refresh-UI {}
        function Show-RestartNotice { param([string]$Message) [void]$script:Notices.Add([string]$Message); $true }
        function Invoke-SettingChange($Item, $AdministratorResults) {
            $Item.Status = 'Partially applied'
            $Item.CurrentState = New-StateResult Partial 'Partly configured'
            return New-ApplyResult $Item.Id @(
                (New-OperationComponent 'Language write' Succeeded 'accepted'),
                (New-OperationComponent 'Final verification' Failed 'pending sign-in')
            ) 'pending sign-in' $false $true
        }
        $plan = @(New-ApplyPlan @(($script:Settings | Where-Object Id -eq 'display-language')))
        [void](Complete-ApplyChanges $plan @{})
        Assert (@($script:Notices).Count -eq 1) 'A setting left unfinished raised no notice.'
        Assert ($script:Notices[0] -match 'sign out and back in') 'The notice does not say what to do.'
        Assert ($script:Notices[0] -match 'Display language') 'The notice does not name the setting.'
        Assert ($SummaryText.Foreground -eq '#8A2B21' -and $SummaryText.FontWeight -eq 'Bold') 'The unfinished result is not marked out from an ordinary one.'
        # An ordinary run raises nothing and stays plain.
        $script:Notices.Clear()
        $script:ApplyInProgress = $true
        function Invoke-SettingChange($Item, $AdministratorResults) {
            $Item.Status = 'Succeeded'
            $Item.CurrentState = New-StateResult Preferred $Item.PreferredState
            return New-ApplyResult $Item.Id @((New-OperationComponent User Succeeded 'test')) 'test' $true
        }
        $plan = @(New-ApplyPlan @(($script:Settings | Where-Object Id -eq 'task-view')))
        [void](Complete-ApplyChanges $plan @{})
        Assert (@($script:Notices).Count -eq 0) 'An ordinary run interrupted the person with a box.'
        Assert ($SummaryText.Foreground -eq '#334E68' -and $SummaryText.FontWeight -eq 'Normal') 'An ordinary result is still marked as a warning.'
    }
    Test-Case 'No window means no box, so nothing can block a run without a screen' {
        Assert ((Show-RestartNotice 'anything') -eq $false) 'A box was offered with no window to own it.'
    }
    Test-Case 'An unknown word is refused and the sections are named' {
        Assert-Throws { Resolve-QuickApplySettings $script:Settings @('tweeks') @() } "tweeks"
        Assert-Throws { Resolve-QuickApplySettings $script:Settings @('tweeks') @() } "'tweaks' and 'tools'"
    }
    Test-Case 'A setting ID spelled like a section is refused rather than guessed at' {
        $tweak = ($script:Settings | Where-Object { $_.Section -eq 'Tweaks' } | Select-Object -First 1).PSObject.Copy()
        $tool = ($script:Settings | Where-Object { $_.Section -eq 'Tools' } | Select-Object -First 1).PSObject.Copy()
        $tweak.Id = 'tools'
        Assert-Throws { Resolve-QuickApplySettings @($tweak,$tool) @() @() } 'clashes'
    }
    Test-Case 'The Tweaks and Tools buttons each stay in their own section' {
        # Run the real click handlers, not a copy of them, against a stub window.
        $handlerOf = {
            param([string]$Name)
            $calls = $ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
                $node.Member.Value -eq 'Add_Click' -and
                $node.Expression -is [Management.Automation.Language.VariableExpressionAst] -and
                $node.Expression.VariablePath.UserPath -eq $Name
            }, $true)
            Assert ($calls.Count -eq 1) "Expected one $Name click handler, found $($calls.Count)."
            $calls[0].Arguments[0].ScriptBlock.GetScriptBlock()
        }
        $SummaryText = [pscustomobject]@{Text='';Foreground='#334E68';FontWeight='Normal'}
        function Refresh-UI {}
        $tweakCount = @($script:Settings | Where-Object { $_.Section -eq 'Tweaks' }).Count
        foreach ($handlerName in @('AllPreferredButton','NeededButton')) {
            foreach ($item in $script:Settings) {
                $item.Selected = $false
                $item.CurrentState = New-StateResult 'Alternate' 'stub'
            }
            # One tool is selected by hand first: a Tweaks button must not touch it.
            $heldTool = @($script:Settings | Where-Object { $_.Section -eq 'Tools' })[0]
            $heldTool.Selected = $true
            & (& $handlerOf $handlerName)
            $chosenTools = @($script:Settings | Where-Object { $_.Section -eq 'Tools' -and $_.Selected })
            Assert ($chosenTools.Count -eq 1 -and $chosenTools[0].Id -eq $heldTool.Id) "$handlerName changed a tool selection."
            Assert (@($script:Settings | Where-Object { $_.Section -eq 'Tweaks' -and $_.Selected }).Count -eq $tweakCount) "$handlerName missed a tweak."
        }
        # The Tools pair is the mirror image: every Tools tab, and never a tweak.
        $toolCount = @($script:Settings | Where-Object { $_.Section -eq 'Tools' }).Count
        foreach ($handlerName in @('AllToolsButton','MissingToolsButton')) {
            foreach ($item in $script:Settings) {
                $item.Selected = $false
                $item.CurrentState = New-StateResult 'Partial' 'stub'
            }
            $heldTweak = @($script:Settings | Where-Object { $_.Section -eq 'Tweaks' })[0]
            $heldTweak.Selected = $true
            & (& $handlerOf $handlerName)
            $chosenTweaks = @($script:Settings | Where-Object { $_.Section -eq 'Tweaks' -and $_.Selected })
            Assert ($chosenTweaks.Count -eq 1 -and $chosenTweaks[0].Id -eq $heldTweak.Id) "$handlerName changed a tweak selection."
            Assert (@($script:Settings | Where-Object { $_.Section -eq 'Tools' -and $_.Selected }).Count -eq $toolCount) "$handlerName missed a tool card."
            Assert (-not @($script:Settings | Where-Object { $_.Section -eq 'Tools' -and $_.DesiredState -ne $_.PreferredState }).Count) "$handlerName chose something other than the preferred state."
        }
        # A tool already in place, or one Dingo cannot read, is left alone.
        $tools = @($script:Settings | Where-Object { $_.Section -eq 'Tools' })
        foreach ($item in $tools) { $item.Selected = $true; $item.CurrentState = New-StateResult 'Preferred' 'stub' }
        $tools[0].CurrentState = New-StateResult 'Partial' 'stub'
        $tools[1].CurrentState = New-StateResult 'Error' 'stub'
        & (& $handlerOf 'MissingToolsButton')
        $chosen = @($tools | Where-Object Selected)
        Assert ($chosen.Count -eq 1 -and $chosen[0].Id -eq $tools[0].Id) 'Select only tools not yet in place picked the wrong cards.'
        # Clearing is a whole-window action, so it does reach both sections.
        foreach ($item in $script:Settings) { $item.Selected = $true }
        & (& $handlerOf 'UncheckButton')
        Assert (@($script:Settings | Where-Object Selected).Count -eq 0) 'Clear all selections left something selected.'
    }
    Test-Case 'Policy card says Configured only when a policy value exists' {
        $card = $script:Settings | Where-Object Id -eq 'onedrive'
        function Get-RegistrySettingState { New-StateResult 'Alternate' 'Enabled/default' }
        $present = @{}
        function Get-EntryValue($Entry) {
            if ($present.ContainsKey($Entry.Name)) { return [pscustomobject]@{Status='Present';Exists=$true;Value=0;ValueType='DWord';ErrorMessage=''} }
            [pscustomobject]@{Status='Missing';Exists=$false;Value=$null;ValueType='';ErrorMessage=''}
        }
        $state = Get-RegistryKindState $card
        Assert ($state.Status -eq 'Alternate' -and $state.DisplayText -eq 'Enabled/default') "Absent policy values still said '$($state.DisplayText)'."
        $present['DisableFileSync'] = $true
        $state = Get-RegistryKindState $card
        Assert ($state.Status -eq 'Alternate' -and $state.DisplayText -eq 'Configured: Enabled/default') "Present policy value said '$($state.DisplayText)'."
    }
    "Passed $script:Passed phase 1 tests on PowerShell $($PSVersionTable.PSVersion)."
} finally {
    $resolvedScratch = [IO.Path]::GetFullPath($scratch)
    $resolvedParent = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    if (-not $resolvedScratch.StartsWith($resolvedParent, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolvedScratch) -notmatch '^\.phase1-[0-9a-f]{32}$') {
        throw "Refusing test cleanup outside the expected directory: $resolvedScratch"
    }
    Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
}
