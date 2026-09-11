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
        $ScopeTabs = [pscustomobject]@{IsEnabled=$true}
        $RestartExplorerCheckBox = [pscustomobject]@{IsEnabled=$true}
        Set-ActionButtonsEnabled $false
        Assert (-not $ScopeTabs.IsEnabled -and -not $RestartExplorerCheckBox.IsEnabled -and -not $script:ActionButtons[0].IsEnabled) 'Some plan controls remain enabled.'
        Set-ActionButtonsEnabled $true
        Assert ($ScopeTabs.IsEnabled -and $RestartExplorerCheckBox.IsEnabled -and $script:ActionButtons[0].IsEnabled) 'Controls did not recover.'
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
    Test-Case 'Winget no-upgrade refusal is accepted only for ensure-installed' {
        function Get-WingetPath { 'mock-winget.exe' }
        function Invoke-ChildProcess { [pscustomobject]@{ExitCode=-1978335135;Output='already installed'} }
        $tool = ($script:Settings | Where-Object Id -eq 'tool-7zip').Entries[0]
        Install-WingetPackage $tool
        Assert-Throws { Install-WingetPackage $tool $true } 'winget exited'
    }
    Test-Case 'Explicit update preflight requires winget even when tool already exists' {
        function Get-WingetPath { '' }
        function Find-InstalledTool { [pscustomobject]@{Version='1'} }
        $setting = @(New-ApplyPlan @(($script:Settings | Where-Object Id -eq 'tool-7zip')))[0]
        $setting.CurrentState = New-StateResult Preferred Installed
        Assert ((Test-SettingPreflight $setting).Available) 'Already installed tool unnecessarily requires winget.'
        $setting.DesiredState = 'Update installed tool'
        Assert (-not (Test-SettingPreflight $setting).Available) 'Update can pass preflight without winget.'
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
        $ScopeTabs = [pscustomobject]@{IsEnabled=$false}
        $RestartExplorerCheckBox = [pscustomobject]@{IsEnabled=$false;IsChecked=$false}
        $SummaryText = [pscustomobject]@{Text=''}
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
        Assert (-not $script:ApplyInProgress -and $ScopeTabs.IsEnabled -and $RestartExplorerCheckBox.IsEnabled) 'GUI remained locked after completion.'
    }
    Test-Case 'Restart guidance names the setting and tells the user how to refresh' {
        $message = Get-RestartInstruction -SettingNames @('Australian English')
        Assert ($message -match '^Australian English needs you to sign out and back in, or restart Windows') 'Restart guidance does not connect the pending setting to the required action.'
        Assert ($message -match 'Australian English') 'Restart guidance does not name the pending setting.'
        Assert ($message -match 'Read settings again') 'Restart guidance does not tell the user how to refresh Dingo.'
    }
    Test-Case 'GUI completion shows actionable guidance for a partially applied restart setting' {
        $ScopeTabs = [pscustomobject]@{IsEnabled=$false}
        $RestartExplorerCheckBox = [pscustomobject]@{IsEnabled=$false;IsChecked=$false}
        $SummaryText = [pscustomobject]@{Text=''}
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
        $card = $script:Settings | Where-Object Id -eq 'language-au'
        $plan = @(New-ApplyPlan @($card))
        [void](Complete-ApplyChanges $plan @{})
        Assert ($SummaryText.Text -match '1 partially applied; 0 failed') 'GUI summary lost the partial-result counts.'
        Assert ($SummaryText.Text -match 'Sign out and back in, or restart Windows') 'GUI summary lacks an explicit completion action.'
        Assert ($SummaryText.Text -match 'Australian English') 'GUI summary does not name the pending setting.'
        Assert ($SummaryText.Text -match 'Read settings again') 'GUI summary does not explain how to verify after sign-in.'
    }
    Test-Case 'Unexpected completion failure releases the busy lock' {
        $ScopeTabs = [pscustomobject]@{IsEnabled=$false}
        $RestartExplorerCheckBox = [pscustomobject]@{IsEnabled=$false;IsChecked=$false}
        $SummaryText = [pscustomobject]@{Text=''}
        $ProgressBar = [pscustomobject]@{Value=0;IsIndeterminate=$true}
        $script:ActionButtons = @([pscustomobject]@{IsEnabled=$false})
        $script:ApplyInProgress = $true
        function Refresh-UI {}
        function Invoke-SettingChange { throw 'Simulated completion failure' }
        $plan = @(New-ApplyPlan @(($script:Settings | Where-Object Id -eq 'task-view')))
        Assert-Throws { Complete-ApplyChanges $plan @{} } 'Simulated completion failure'
        Assert (-not $script:ApplyInProgress -and $ScopeTabs.IsEnabled -and $RestartExplorerCheckBox.IsEnabled) 'Failure left plan controls locked.'
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
            foreach ($name in @('ScopeTabs','RestartExplorerCheckBox','ApplyButton','AllPreferredButton','NeededButton','UncheckButton','RefreshButton','AdminSummaryText','SummaryText')) {
                Set-Variable -Name $name -Value $window.FindName($name)
            }
            $actionPanel = $ApplyButton.Parent
            Assert ($SummaryText.Parent -eq $actionPanel.Parent) 'Completion guidance and actions do not share the expected footer grid.'
            Assert ([Windows.Controls.Grid]::GetRow($SummaryText) -lt [Windows.Controls.Grid]::GetRow($actionPanel)) 'Completion guidance shares the administrator/action row and can be obscured.'
            Assert ($SummaryText.TextWrapping -eq [Windows.TextWrapping]::Wrap) 'Completion guidance cannot wrap within its own row.'
            function Get-SettingAdvisory { '' }
            $script:Settings = Get-Settings
            $panels = @{ User='UserSettingsPanel'; System='SystemSettingsPanel'; Both='BothSettingsPanel'; 'Install tools'='ToolSettingsPanel'; 'Tool shortcuts'='ShortcutSettingsPanel'; 'File associations'='AssociationSettingsPanel' }
            foreach ($item in $script:Settings) {
                [void]$window.FindName($panels[$item.Tab]).Children.Add((New-SettingCard $item))
            }
            $script:ActionButtons = @($ApplyButton,$AllPreferredButton,$NeededButton,$UncheckButton,$RefreshButton)
            Set-ActionButtonsEnabled $false
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
