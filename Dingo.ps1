#requires -version 5.1
<#
.SYNOPSIS
    State-aware Windows 11 preference configurator.
.DESCRIPTION
    The GUI runs as the signed-in user so HKCU changes affect the visible desktop.
    Machine-only changes are sent to a constrained elevated worker when required.
#>
[CmdletBinding(PositionalBinding=$false)]
param(
    [switch]$SelfTest,
    [switch]$StateSelfTest,
    [switch]$UiSelfTest,
    [switch]$ApplyPreferred,
    [switch]$WhatIf,
    [switch]$ListSettings,
    [Alias('?','h')]
    [switch]$Help,
    [switch]$Version,
    [string[]]$Include,
    [string[]]$Exclude,
    [ValidateSet('Text','Json')][string]$OutputFormat = 'Text',
    [switch]$NoRestartExplorer,
    [switch]$MachineWorker,
    [switch]$ElevationBroker,
    [switch]$WpfHost,
    [switch]$FinalizeInternationalSettings,
    [string]$PlanPath,
    [string]$ResultPath,
    [string]$WorkerLogPath,
    [string]$TargetUserSid,
    [Parameter(ValueFromRemainingArguments=$true)]
    [object[]]$UnexpectedArguments
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:LogFile = $null
$script:RemoveValue = '__REMOVE_VALUE__'
$script:LanguageChangePending = $false
$script:InstanceMutex = $null
$script:PendingApply = $null
$script:SettingHandlers = @{}
$script:DingoVersion = '0.5.8'
$script:DeviceIsManaged = $null
$script:ToolCatalogWarning = ''
$script:ToolCatalogCache = $null
$script:ShimDirectory = 'C:\DFIR\Tools\bin'
# Only files carrying this marker are ever deleted, so a launcher someone wrote
# by hand in the same folder is left alone.
$script:ShimMarker = 'REM Written by Dingo. Safe to delete.'
$script:MachineEnvironmentSubKey = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
# Shortcuts go in the all-users locations, so they appear for every account on
# the VM and the elevated worker can write them in one place.
$script:StartMenuShortcutDirectory = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\DFIR Tools'
$script:DesktopShortcutDirectory = Join-Path $env:PUBLIC 'Desktop'
# Written into the shortcut comment. Only shortcuts carrying this are ever
# deleted, so one placed by hand or by an installer is left alone.
$script:ShortcutMarker = 'Created by Dingo. Safe to delete.'
$automaticArguments = @(Get-Variable -Name args -ValueOnly -ErrorAction SilentlyContinue)
$script:UnexpectedArguments = @(@($UnexpectedArguments) + $automaticArguments | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) })

function Set-DingoConsoleVisible([bool]$Visible) {
    # The GUI has nothing to say to a console, so the launcher's console window
    # is hidden once the window opens, and shown again if anything fails. A
    # hidden console must never be the only place an error message appears.
    try {
        if (-not ('Dingo.NativeConsole' -as [type])) {
            $signature = '[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();' +
                         '[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);'
            Add-Type -Namespace 'Dingo' -Name 'NativeConsole' -MemberDefinition $signature -ErrorAction Stop
        }
        $consoleWindow = [Dingo.NativeConsole]::GetConsoleWindow()
        if ($consoleWindow -eq [IntPtr]::Zero) { return }
        # 0 is SW_HIDE and 5 is SW_SHOW.
        [void][Dingo.NativeConsole]::ShowWindow($consoleWindow, $(if ($Visible) { 5 } else { 0 }))
    } catch {
        # Hiding a window is a convenience. Never let it stop Dingo starting.
    }
}

# Only Start-Dingo.cmd sets this, and only when no arguments were supplied, so a
# command line run keeps its console and its output. Done here, before the slow
# work, so the console is on screen for as short a time as possible.
if ($env:DINGO_HIDE_CONSOLE -eq '1' -and -not $PSBoundParameters.Count -and -not $script:UnexpectedArguments.Count) {
    Set-DingoConsoleVisible $false
}

function Get-PowerShellHostPath {
    $hostPath = (Get-Process -Id $PID -ErrorAction Stop).Path
    if (-not $hostPath -or -not (Test-Path -LiteralPath $hostPath -PathType Leaf)) {
        throw 'Could not locate the current PowerShell executable.'
    }
    return $hostPath
}

function Enter-DingoSingleInstance {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -replace '[^A-Za-z0-9]','_'
    $createdNew = $false
    $mutex = New-Object System.Threading.Mutex($true,"Local\Dingo_$sid",[ref]$createdNew)
    $acquired = $createdNew
    if (-not $createdNew) {
        try { $acquired = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
    }
    if (-not $acquired) { $mutex.Dispose(); return $false }
    $script:InstanceMutex = $mutex
    return $true
}

function Exit-DingoSingleInstance {
    if (-not $script:InstanceMutex) { return }
    try { $script:InstanceMutex.ReleaseMutex() } catch {}
    $script:InstanceMutex.Dispose()
    $script:InstanceMutex = $null
}

# Keep the launcher separate from the WPF host so a failed GUI process cannot
# strand the command shell, and hold the per-user mutex for the host's lifetime.
# Avoid persistent user-wide shell workarounds; the host process only owns the UI.
if (-not ($SelfTest -or $StateSelfTest -or $UiSelfTest -or $ApplyPreferred -or $WhatIf -or $ListSettings -or $Help -or $Version -or $Include -or $Exclude -or $script:UnexpectedArguments.Count -or $MachineWorker -or $ElevationBroker -or $FinalizeInternationalSettings -or $WpfHost)) {
    if (-not (Enter-DingoSingleInstance)) {
        Add-Type -AssemblyName PresentationFramework
        [System.Windows.MessageBox]::Show('Dingo is already running for this Windows account.', 'Dingo is already running', 'OK', 'Information') | Out-Null
        # This leaves with a non-zero code, so the launcher will pause. Put the
        # console back first, or that prompt waits on a window nobody can see.
        Set-DingoConsoleVisible $true
        exit 3
    }
    try {
        $hostArguments = '-NoProfile -ExecutionPolicy Bypass -STA -File "{0}" -WpfHost' -f $PSCommandPath
        $hostProcess = Start-Process -FilePath (Get-PowerShellHostPath) -ArgumentList $hostArguments -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop
        # Bring the console back for a failure, so the launcher's pause prompt and
        # any error text are on a window the person can actually see.
        if ($hostProcess.ExitCode -ne 0) { Set-DingoConsoleVisible $true }
        exit $hostProcess.ExitCode
    } catch {
        Set-DingoConsoleVisible $true
        throw
    } finally {
        Exit-DingoSingleInstance
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-DeviceIsManaged {
    # Microsoft Edge refuses a subset of its policies unless Windows is joined to
    # an Active Directory domain, joined to Entra ID, or enrolled in a real MDM
    # service. Edge reports such a policy at edge://policy as "Error, Ignored:
    # This policy is blocked, its value will be ignored." Read the join state
    # from the registry and CIM so no external command runs during a state scan.
    if ($null -ne $script:DeviceIsManaged) { return $script:DeviceIsManaged }
    $managed = $false
    try {
        if ((Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).PartOfDomain) { $managed = $true }
    } catch {
        Write-Log 'WARN' "Could not read the domain join state: $($_.Exception.Message)"
    }
    if (-not $managed) {
        $joinInfo = 'HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo'
        if ((Test-Path -LiteralPath $joinInfo) -and @(Get-ChildItem -LiteralPath $joinInfo -ErrorAction SilentlyContinue).Count) { $managed = $true }
    }
    if (-not $managed) {
        # Windows ships around thirty placeholder enrollment keys that all report
        # EnrollmentState 1. A real enrollment also carries a discovery URL or an
        # enrolled user principal name, so require one of those.
        foreach ($key in @(Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue)) {
            $values = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if (-not $values) { continue }
            $state = if ($values.PSObject.Properties['EnrollmentState']) { [int]$values.EnrollmentState } else { 0 }
            $url = if ($values.PSObject.Properties['DiscoveryServiceFullURL']) { [string]$values.DiscoveryServiceFullURL } else { '' }
            $upn = if ($values.PSObject.Properties['UPN']) { [string]$values.UPN } else { '' }
            if ($state -eq 1 -and ($url -or $upn)) { $managed = $true; break }
        }
    }
    $script:DeviceIsManaged = $managed
    Write-Log 'DEBUG' "Device management state: $(if ($managed) { 'managed' } else { 'not managed' })."
    return $managed
}

function Get-SettingAdvisory($Setting) {
    # A caveat that Dingo cannot fix by writing the setting. Dingo still applies
    # the value, because it takes effect if the VM is later joined to a domain
    # or enrolled, but the operator is told plainly that it does nothing today.
    if ($Setting.Requirements.ContainsKey('ManagedDevice')) {
        if (-not (Test-DeviceIsManaged)) {
            return 'Edge blocks this policy because this device is not joined to a domain or Entra ID and is not enrolled in Intune. Dingo writes and verifies the value, but Edge ignores it. Set the search engine by hand at edge://settings/searchEngines, or apply this on a managed image.'
        }
    }
    # A tool can install perfectly and still not start, because something it
    # depends on is absent. Say so rather than reporting an unqualified success.
    if ($Setting.Requirements.ContainsKey('RequiredTools')) {
        $missing = New-Object System.Collections.ArrayList
        foreach ($requiredId in @($Setting.Requirements['RequiredTools'])) {
            $required = @(Get-ToolCatalog | Where-Object Id -eq $requiredId)[0]
            if (-not $required) { [void]$missing.Add($requiredId); continue }
            if (-not (Find-InstalledTool $required)) { [void]$missing.Add($required.Name) }
        }
        if ($missing.Count) {
            return "This tool needs $($missing -join ' and '), which is not installed. Tick that card as well, or the tool will not start."
        }
    }
    return ''
}

function Initialize-Log {
    $base = Join-Path $PSScriptRoot 'Logs'
    New-Item -ItemType Directory -Path $base -Force | Out-Null
    $script:LogFile = Join-Path $base ("{0}_{1}.log" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff'),$PID)
    Write-Log 'INFO' "Dingo started as $([Security.Principal.WindowsIdentity]::GetCurrent().Name); PowerShell $($PSVersionTable.PSVersion)"
    Remove-StaleWorkerFiles
    Remove-StaleLogFiles
}

function Write-Log([string]$Level, [string]$Message) {
    if (-not $script:LogFile) { return }
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
}

function Write-Utf8FileAtomically {
    param([string]$Path, [string]$Content, [string]$BackupPath = '')
    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw "Destination folder does not exist: $directory" }
    $temporaryPath = Join-Path $directory (".{0}.{1}.tmp" -f [IO.Path]::GetFileName($fullPath),[Guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($temporaryPath, $Content, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            $temporaryBackup = -not [bool]$BackupPath
            $backup = if ($BackupPath) { [IO.Path]::GetFullPath($BackupPath) } else { "$fullPath.replace-backup-$([Guid]::NewGuid().ToString('N'))" }
            [IO.File]::Replace($temporaryPath, $fullPath, $backup, $true)
            if ($temporaryBackup) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
        } else {
            [IO.File]::Move($temporaryPath, $fullPath)
        }
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Remove-StaleWorkerFiles([int]$MinimumAgeHours = 24) {
    $temporaryRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
    $cutoff = (Get-Date).AddHours(-$MinimumAgeHours)
    foreach ($file in @(Get-ChildItem -LiteralPath $temporaryRoot -File -ErrorAction SilentlyContinue)) {
        if ($file.LastWriteTime -ge $cutoff -or $file.Name -notmatch '^Dingo-(plan|result)-[0-9a-f]{32}\.json$') { continue }
        if ([IO.Path]::GetFullPath($file.DirectoryName).TrimEnd('\') -ne $temporaryRoot) { continue }
        try {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            Write-Log 'DEBUG' "Removed stale administrator protocol file '$($file.FullName)'."
        } catch {
            Write-Log 'WARN' "Could not remove stale administrator protocol file '$($file.FullName)': $($_.Exception.Message)"
        }
    }
}

function Remove-SupersededFiles {
    param([string]$Directory, [string]$Filter, [int]$Keep)
    # Keep the newest $Keep matching files and delete the rest. Dingo writes a log
    # per run and a Terminal backup per change, so both sets grow without a limit.
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return }
    $candidates = @(Get-ChildItem -LiteralPath $Directory -Filter $Filter -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    if ($candidates.Count -le $Keep) { return }
    foreach ($file in $candidates[$Keep..($candidates.Count - 1)]) {
        try {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            Write-Log 'DEBUG' "Removed superseded file '$($file.FullName)'."
        } catch {
            Write-Log 'WARN' "Could not remove superseded file '$($file.FullName)': $($_.Exception.Message)"
        }
    }
}

function Remove-StaleLogFiles([int]$Keep = 20) {
    if (-not $script:LogFile) { return }
    Remove-SupersededFiles ([IO.Path]::GetDirectoryName($script:LogFile)) '*.log' $Keep
}

function Remove-StaleTerminalBackups([string]$SettingsPath, [int]$Keep = 10) {
    $directory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($SettingsPath))
    Remove-SupersededFiles $directory ("{0}.backup-*" -f [IO.Path]::GetFileName($SettingsPath)) $Keep
}

function ConvertFrom-JsonList([string]$Json) {
    $decoded = $Json | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $decoded) { return }
    # Windows PowerShell 5.1 emits a JSON array as one nested Object[]. Sending it
    # through the pipeline deliberately expands it into individual result objects.
    $decoded | ForEach-Object { $_ }
}

function New-StateResult {
    param(
        [ValidateSet('Unknown','Preferred','Alternate','Partial','Unavailable','Error')][string]$Status,
        [string]$DisplayText,
        [string]$Details = ''
    )
    [PSCustomObject]@{
        Status = $Status
        DisplayText = $DisplayText
        Details = $Details
    }
}

function New-StateResultForSetting($Setting, [string]$DisplayText, [string]$Details = '') {
    $status = if ($DisplayText -eq $Setting.PreferredState) {
        'Preferred'
    } elseif ($Setting.CanChoose -and $DisplayText -eq $Setting.AlternateState) {
        'Alternate'
    } else {
        'Partial'
    }
    New-StateResult $status $DisplayText $Details
}

function New-OperationComponent {
    param(
        [string]$Name,
        [ValidateSet('Succeeded','Failed','Skipped')][string]$Outcome,
        [string]$Message = ''
    )
    [PSCustomObject]@{ Name=$Name; Outcome=$Outcome; Message=$Message }
}

function Get-OperationOutcome([array]$Components) {
    $attempted = @($Components | Where-Object Outcome -ne 'Skipped')
    if (-not $attempted) { return 'Skipped' }
    $succeeded = @($attempted | Where-Object Outcome -eq 'Succeeded').Count
    $failed = @($attempted | Where-Object Outcome -eq 'Failed').Count
    if ($failed -and $succeeded) { return 'PartiallyApplied' }
    if ($failed) { return 'Failed' }
    return 'Succeeded'
}

function New-ApplyResult {
    param(
        [string]$Id,
        [array]$Components,
        [string]$Message = '',
        [bool]$RestartExplorer = $false,
        [bool]$RestartRequired = $false
    )
    $items = @($Components)
    $outcome = Get-OperationOutcome $items
    [PSCustomObject]@{
        Id = $Id
        Outcome = $outcome
        Success = ($outcome -eq 'Succeeded')
        Components = $items
        Message = $Message
        RestartExplorer = $RestartExplorer
        RestartRequired = $RestartRequired
    }
}

function New-Entry {
    param(
        [ValidateSet('User','Machine','ElevatedUser')][string]$Scope,
        [string]$Path,
        [string]$Name,
        $Preferred,
        $Alternate = '__REMOVE_VALUE__',
        [ValidateSet('DWord','QWord','String')][string]$Type = 'DWord'
    )
    [PSCustomObject]@{ Scope=$Scope; Path=$Path; Name=$Name; Preferred=$Preferred; Alternate=$Alternate; Type=$Type }
}

function New-Setting {
    param(
        [string]$Id,
        [string]$Category,
        [string]$Name,
        [string]$Description,
        [string]$PreferredState,
        [AllowNull()][string]$AlternateState,
        [string]$Kind = 'Registry',
        [array]$Entries = @(),
        [bool]$RestartExplorer = $false,
        [bool]$RestartRequired = $false,
        [hashtable]$Requirements = @{},
        [string]$Tab = '',
        [string]$DefaultStateText = ''
    )
    $options = New-Object System.Collections.ArrayList
    [void]$options.Add($PreferredState)
    if (-not [string]::IsNullOrWhiteSpace($AlternateState)) { [void]$options.Add($AlternateState) }
    $handler = Get-SettingHandler $Kind
    $scopes = @(& $handler.GetScopes $Entries)
    $requirementCopy = @{}
    if ($PSBoundParameters.ContainsKey('Requirements')) {
        foreach ($key in $Requirements.Keys) { $requirementCopy[$key] = $Requirements[$key] }
    }
    $hasUser = [bool](@($scopes | Where-Object { $_ -in @('User','ElevatedUser') }).Count)
    $hasMachine = $scopes -contains 'Machine'
    $needsElevation = $hasMachine -or [bool](@($Entries | Where-Object Scope -eq 'ElevatedUser').Count)
    $displayScope = if ($hasUser -and $hasMachine) { 'Both' } elseif ($hasMachine) { 'System' } else { 'User' }
    $defaultState = if (-not [string]::IsNullOrWhiteSpace($DefaultStateText)) {
        $DefaultStateText
    } elseif ([string]::IsNullOrWhiteSpace($AlternateState)) {
        'Whatever the Windows image currently uses'
    } else {
        $AlternateState
    }
    # Cards are grouped by who a setting affects unless it declares its own tab.
    $tabName = if ([string]::IsNullOrWhiteSpace($Tab)) { $displayScope } else { $Tab }
    [PSCustomObject]@{
        Selected=$false; Id=$Id; Category=$Category; Name=$Name; Description=$Description
        PreferredState=$PreferredState; AlternateState=$AlternateState; DesiredState=$PreferredState
        DefaultState=$defaultState; DisplayScope=$displayScope; Tab=$tabName
        StateOptions=$options; CanChoose=($options.Count -gt 1); CurrentState=(New-StateResult 'Unknown' 'Reading...')
        Status='Ready'; Details=''; LastApplyResult=$null; Kind=$Kind; Entries=$Entries; RequiresAdmin=$needsElevation
        RestartExplorer=$RestartExplorer; RestartRequired=$RestartRequired; Requirements=$requirementCopy
    }
}

function Get-JsonField($Object, [string]$Name, $Default = $null) {
    # Set-StrictMode 2.0 throws on an absent property, and hand-written catalog
    # entries are allowed to omit optional fields, so read them defensively.
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if (-not $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function ConvertTo-ToolDefinition($Raw) {
    $id = [string](Get-JsonField $Raw 'id' '')
    if ($id -notmatch '^tool-[a-z0-9][a-z0-9-]*$') { throw "Tool id '$id' must look like 'tool-example'." }
    $name = [string](Get-JsonField $Raw 'name' '')
    if ([string]::IsNullOrWhiteSpace($name)) { throw "Tool '$id' has no name." }

    $install = Get-JsonField $Raw 'install' $null
    $installKind = [string](Get-JsonField $install 'kind' 'winget')
    if ($installKind -notin @('winget','script')) { throw "Tool '$id' uses install kind '$installKind', which this version of Dingo cannot run." }
    $package = [string](Get-JsonField $install 'package' '')
    $url = [string](Get-JsonField $install 'url' '')
    $dest = [string](Get-JsonField $install 'dest' '')
    if ($installKind -eq 'winget') {
        if ([string]::IsNullOrWhiteSpace($package)) { throw "Tool '$id' has no winget package id." }
    } else {
        # A downloaded installer script runs with administrator rights, so refuse
        # anything that is not fetched over TLS from a named host.
        if ($url -notmatch '^https://[^/\s]+/\S+$') { throw "Tool '$id' needs an https:// url for its install script." }
        if ([string]::IsNullOrWhiteSpace($dest)) { throw "Tool '$id' needs a dest folder for its install script." }
    }
    $scope = [string](Get-JsonField $install 'scope' 'machine')
    if ($scope -notin @('machine','user')) { throw "Tool '$id' has scope '$scope'; use 'machine' or 'user'." }
    $timeoutMinutes = [int](Get-JsonField $install 'timeoutMinutes' $(if ($installKind -eq 'script') { 45 } else { 15 }))
    if ($timeoutMinutes -lt 1 -or $timeoutMinutes -gt 240) { throw "Tool '$id' has a timeout of $timeoutMinutes minutes; use 1 to 240." }

    $rules = New-Object System.Collections.ArrayList
    foreach ($rawRule in @(Get-JsonField $Raw 'detect' @())) {
        $ruleKind = [string](Get-JsonField $rawRule 'kind' '')
        if ($ruleKind -notin @('uninstall-key','file','command')) { throw "Tool '$id' has an unknown detect rule '$ruleKind'." }
        [void]$rules.Add([PSCustomObject]@{
            Kind = $ruleKind
            Match = [string](Get-JsonField $rawRule 'match' '')
            Path = [string](Get-JsonField $rawRule 'path' '')
            Command = [string](Get-JsonField $rawRule 'command' '')
        })
    }
    if (-not $rules.Count) { throw "Tool '$id' has no detect rules, so Dingo could never tell whether it is installed." }

    # A tool may offer command-line programs. Dingo writes one launcher per
    # program into a single folder, so only that folder goes on the PATH.
    $shims = $null
    $rawShims = Get-JsonField $Raw 'shims' $null
    if ($rawShims) {
        $from = [string](Get-JsonField $rawShims 'from' '')
        if ([string]::IsNullOrWhiteSpace($from)) { throw "Tool '$id' has a shims block with no 'from' folder." }
        $shims = [PSCustomObject]@{
            From = $from
            Pattern = [string](Get-JsonField $rawShims 'pattern' '*.exe')
            Recurse = [bool](Get-JsonField $rawShims 'recurse' $true)
        }
    }

    # A tool may ask for Start menu and Desktop shortcuts. Some installers make
    # none, so the program is on disk but nobody can find it.
    $shortcuts = New-Object System.Collections.ArrayList
    foreach ($rawShortcut in @(Get-JsonField $Raw 'shortcuts' @())) {
        $shortcutName = [string](Get-JsonField $rawShortcut 'name' '')
        $shortcutTarget = [string](Get-JsonField $rawShortcut 'target' '')
        if ([string]::IsNullOrWhiteSpace($shortcutName)) { throw "Tool '$id' has a shortcut with no name." }
        if ([string]::IsNullOrWhiteSpace($shortcutTarget)) { throw "Tool '$id' has a shortcut '$shortcutName' with no target." }
        # The name becomes a file name, so refuse anything that could escape the folder.
        if ($shortcutName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
            throw "Tool '$id' has a shortcut named '$shortcutName', which is not a usable file name."
        }
        [void]$shortcuts.Add([PSCustomObject]@{
            Name = $shortcutName
            Target = $shortcutTarget
            Arguments = [string](Get-JsonField $rawShortcut 'arguments' '')
        })
    }

    [PSCustomObject]@{
        Id = $id
        Name = $name
        Category = [string](Get-JsonField $Raw 'category' 'Tools')
        Description = [string](Get-JsonField $Raw 'description' "Install $name.")
        InstallKind = $installKind
        Package = $package
        Source = [string](Get-JsonField $install 'source' 'winget')
        Scope = $scope
        Url = $url
        Dest = $dest
        Arguments = @(Get-JsonField $install 'arguments' @())
        Shims = $shims
        Shortcuts = @($shortcuts)
        Requires = @(Get-JsonField $Raw 'requires' @())
        TimeoutSeconds = ($timeoutMinutes * 60)
        Detect = @($rules)
    }
}

function Get-BuiltInToolCatalog {
    @(
        [PSCustomObject]@{
            id='tool-7zip'; name='7-Zip'; category='Archives'
            description='Opens and creates zip, 7z, tar, gz, and many other archive formats.'
            install=[PSCustomObject]@{ kind='winget'; package='7zip.7zip'; scope='machine' }
            detect=@(
                [PSCustomObject]@{ kind='uninstall-key'; match='7-Zip*' },
                [PSCustomObject]@{ kind='file'; path='%ProgramFiles%\7-Zip\7zFM.exe' }
            )
        },
        [PSCustomObject]@{
            id='tool-notepadplusplus'; name='Notepad++'; category='Text and data'
            description='Text editor for logs, scripts, and configuration files.'
            install=[PSCustomObject]@{ kind='winget'; package='Notepad++.Notepad++'; scope='machine' }
            detect=@(
                [PSCustomObject]@{ kind='uninstall-key'; match='Notepad++*' },
                [PSCustomObject]@{ kind='file'; path='%ProgramFiles%\Notepad++\notepad++.exe' }
            )
        },
        [PSCustomObject]@{
            id='tool-ripgrep'; name='ripgrep'; category='Text and data'
            description='Fast recursive search across files from the command line. winget adds it to your PATH by itself.'
            install=[PSCustomObject]@{ kind='winget'; package='BurntSushi.ripgrep.MSVC'; scope='user' }
            detect=@(
                [PSCustomObject]@{ kind='uninstall-key'; match='RipGrep*' },
                [PSCustomObject]@{ kind='command'; command='rg.exe' }
            )
        },
        [PSCustomObject]@{
            # Listed before the tools that need it, because the elevated worker
            # applies the plan in catalog order.
            id='tool-dotnet-desktop-9'; name='.NET 9 Desktop Runtime'; category='Forensics'
            description="Eric Zimmerman's tools are built on .NET 9, which a fresh Windows 11 install does not include. Without this they fail to start with 'You must install .NET to run this application'."
            install=[PSCustomObject]@{ kind='winget'; package='Microsoft.DotNet.DesktopRuntime.9'; scope='machine' }
            detect=@(
                [PSCustomObject]@{ kind='file'; path='C:/Program Files/dotnet/shared/Microsoft.WindowsDesktop.App/9.*' }
            )
        },
        [PSCustomObject]@{
            id='tool-eztools'; name="Eric Zimmerman's tools"; category='Forensics'
            description='The full DFIR tool set, including Timeline Explorer, Registry Explorer, EvtxECmd, and RECmd. Installed with the author''s own Get-ZimmermanTools script. Needs the .NET 9 Desktop Runtime, which is the card above.'
            install=[PSCustomObject]@{
                kind='script'; scope='machine'
                url='https://raw.githubusercontent.com/EricZimmerman/Get-ZimmermanTools/master/Get-ZimmermanTools.ps1'
                dest='C:\DFIR\Tools\EZTools'
                arguments=@('-NetVersion','9')
                timeoutMinutes=45
            }
            shims=[PSCustomObject]@{ from='C:/DFIR/Tools/EZTools/net9'; pattern='*.exe'; recurse=$true }
            # Get-ZimmermanTools makes no shortcuts at all, so the window tools are
            # invisible in the Start menu. A target that is not on disk is skipped.
            shortcuts=@(
                [PSCustomObject]@{ name='Timeline Explorer'; target='C:/DFIR/Tools/EZTools/net9/TimelineExplorer/TimelineExplorer.exe' },
                [PSCustomObject]@{ name='Registry Explorer'; target='C:/DFIR/Tools/EZTools/net9/RegistryExplorer/RegistryExplorer.exe' },
                [PSCustomObject]@{ name='MFT Explorer'; target='C:/DFIR/Tools/EZTools/net9/MFTExplorer/MFTExplorer.exe' },
                [PSCustomObject]@{ name='ShellBags Explorer'; target='C:/DFIR/Tools/EZTools/net9/ShellBagsExplorer/ShellBagsExplorer.exe' },
                [PSCustomObject]@{ name='Jump List Explorer'; target='C:/DFIR/Tools/EZTools/net9/JumpListExplorer/JumpListExplorer.exe' },
                [PSCustomObject]@{ name='SDB Explorer'; target='C:/DFIR/Tools/EZTools/net9/SDBExplorer/SDBExplorer.exe' },
                [PSCustomObject]@{ name='EZViewer'; target='C:/DFIR/Tools/EZTools/net9/EZViewer/EZViewer.exe' }
            )
            requires=@('tool-dotnet-desktop-9')
            # Detect on the two GUI tools, not on a command-line one. A partial
            # copy of the command-line tools is common, and it would otherwise
            # be reported as a complete install. Either GUI tool proves a full run.
            detect=@(
                [PSCustomObject]@{ kind='file'; path='C:/DFIR/Tools/EZTools/net9/TimelineExplorer/TimelineExplorer.exe' },
                [PSCustomObject]@{ kind='file'; path='C:/DFIR/Tools/EZTools/net9/RegistryExplorer/RegistryExplorer.exe' }
            )
        },
        [PSCustomObject]@{
            id='tool-sqlitebrowser'; name='DB Browser for SQLite'; category='Text and data'
            description='Reads and queries SQLite databases, such as browser and application history.'
            install=[PSCustomObject]@{ kind='winget'; package='DBBrowserForSQLite.DBBrowserForSQLite'; scope='machine' }
            detect=@(
                [PSCustomObject]@{ kind='uninstall-key'; match='DB Browser for SQLite*' },
                [PSCustomObject]@{ kind='file'; path='%ProgramFiles%\DB Browser for SQLite\DB Browser for SQLite.exe' }
            )
        }
    )
}

function Get-ToolCatalogPath { Join-Path $PSScriptRoot 'Tools.json' }

function Get-ToolCatalog {
    if ($null -ne $script:ToolCatalogCache) { return $script:ToolCatalogCache }
    $problems = New-Object System.Collections.ArrayList
    $map = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($raw in (Get-BuiltInToolCatalog)) {
        $tool = ConvertTo-ToolDefinition $raw
        $map[$tool.Id] = $tool
    }
    # Tools.json is optional. It adds tools by new id and replaces built-in ones
    # by matching id, so the catalog can grow without editing this script.
    $overridePath = Get-ToolCatalogPath
    if (Test-Path -LiteralPath $overridePath -PathType Leaf) {
        try {
            $decoded = Read-JsonFileTolerantly $overridePath
            $entries = @(Get-JsonField $decoded 'tools' $decoded)
            foreach ($raw in $entries) {
                try {
                    $tool = ConvertTo-ToolDefinition $raw
                    $map[$tool.Id] = $tool
                    Write-Log 'INFO' "Tools.json supplied tool '$($tool.Id)'."
                } catch {
                    [void]$problems.Add($_.Exception.Message)
                }
            }
        } catch {
            [void]$problems.Add("Tools.json could not be read: $($_.Exception.Message)")
        }
    }
    foreach ($problem in $problems) { Write-Log 'WARN' "Tool catalog: $problem" }
    $script:ToolCatalogWarning = if ($problems.Count) { "Dingo ignored part of Tools.json. $($problems -join ' ')" } else { '' }
    $script:ToolCatalogCache = @($map.Values)
    return $script:ToolCatalogCache
}

function Get-WingetPath {
    $command = Get-Command 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    # The winget alias lives in the signed-in user's WindowsApps folder, so an
    # elevated worker may not see it. Fall back to the installed package.
    $pattern = Join-Path ${env:ProgramFiles} 'WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe'
    $candidate = @(Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1)
    if ($candidate.Count) { return $candidate[0].FullName }
    return ''
}

function Get-UninstallEntry([string]$Match) {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $values = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            $displayName = [string](Get-JsonField $values 'DisplayName' '')
            if ($displayName -and $displayName -like $Match) {
                return [PSCustomObject]@{
                    Name = $displayName
                    Version = [string](Get-JsonField $values 'DisplayVersion' '')
                    Location = [string](Get-JsonField $values 'InstallLocation' '')
                }
            }
        }
    }
    return $null
}

function Get-DisplayVersion([string]$Version) {
    # A .NET build stamps its git commit onto the product version, so Timeline
    # Explorer reports 2026.5.0+74bece05a5... Everything after the plus is build
    # metadata and means nothing to the person reading the card.
    if ([string]::IsNullOrWhiteSpace($Version)) { return '' }
    $trimmed = $Version.Trim()
    $plus = $trimmed.IndexOf('+')
    if ($plus -gt 0) { $trimmed = $trimmed.Substring(0, $plus) }
    return $trimmed
}

function Find-InstalledTool($Tool) {
    foreach ($rule in @($Tool.Detect)) {
        if ($rule.Kind -eq 'uninstall-key') {
            $entry = Get-UninstallEntry $rule.Match
            if ($entry) { return [PSCustomObject]@{ Version=(Get-DisplayVersion $entry.Version); Evidence="Windows lists it as '$($entry.Name)'." } }
        } elseif ($rule.Kind -eq 'file') {
            $path = [Environment]::ExpandEnvironmentVariables($rule.Path)
            if ($path.Contains('*') -or $path.Contains('?')) {
                # A wildcard lets a rule match a versioned folder, such as the
                # .NET runtime, whose exact patch number is not known in advance.
                $matches = @(Get-Item -Path $path -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
                if ($matches.Count) {
                    $item = $matches[0]
                    $version = if ($item.PSIsContainer) { $item.Name } else {
                        try { Get-DisplayVersion ([string]$item.VersionInfo.ProductVersion) } catch { '' }
                    }
                    return [PSCustomObject]@{ Version=$version; Evidence="Found $($item.FullName)." }
                }
            } elseif (Test-Path -LiteralPath $path -PathType Leaf) {
                $version = ''
                try { $version = Get-DisplayVersion ([string](Get-Item -LiteralPath $path -ErrorAction Stop).VersionInfo.ProductVersion) } catch { $version = '' }
                return [PSCustomObject]@{ Version=$version; Evidence="Found $path." }
            }
        } elseif ($rule.Kind -eq 'command') {
            $command = Get-Command $rule.Command -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($command) { return [PSCustomObject]@{ Version=''; Evidence="Found $($command.Source) on the PATH." } }
        }
    }
    return $null
}

function Install-WingetPackage($Tool) {
    $TimeoutSeconds = $Tool.TimeoutSeconds
    $winget = Get-WingetPath
    if (-not $winget) { throw 'winget is not available on this computer, so Dingo cannot install anything.' }
    $arguments = @(
        'install','--id',$Tool.Package,'--exact','--source',$Tool.Source,'--scope',$Tool.Scope,
        '--accept-package-agreements','--accept-source-agreements','--disable-interactivity','--silent'
    )
    Write-Log 'INFO' "Installing $($Tool.Name): winget $($arguments -join ' ')"
    $run = Invoke-ChildProcess $winget $arguments $TimeoutSeconds "The winget install of $($Tool.Package)"
    Write-Log 'DEBUG' "winget exit code $($run.ExitCode) for $($Tool.Package): $($run.Output)"
    # The package is already present and there is nothing newer. Dingo asked for
    # the tool to be installed, and it is, so that is a success.
    if ($run.ExitCode -eq -1978335189) {
        Write-Log 'INFO' "$($Tool.Name) was already installed and is up to date."
        return
    }
    if ($run.ExitCode -ne 0) {
        throw "winget exited with code $($run.ExitCode) for $($Tool.Package). $(Get-OutputTail $run.Output)"
    }
}

function Invoke-ChildProcess([string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds, [string]$Label) {
    # Start-Process -PassThru does not keep the process handle, so its ExitCode
    # stays empty and a success would look like a failure. Own the handle here.
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = (@($Arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = $null
    try {
        $process = [Diagnostics.Process]::Start($startInfo)
        # Read both pipes while the process runs, or a full pipe buffer deadlocks it.
        $standardOutput = $process.StandardOutput.ReadToEndAsync()
        $standardError = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { Write-Log 'WARN' "Could not stop the $Label process." }
            throw "$Label did not finish within $([math]::Round($TimeoutSeconds / 60)) minutes."
        }
        $output = (([string]$standardOutput.Result + ' ' + [string]$standardError.Result) -replace '\s+',' ').Trim()
        return [PSCustomObject]@{ ExitCode = $process.ExitCode; Output = $output }
    } finally {
        if ($process) { $process.Dispose() }
    }
}

function Get-OutputTail([string]$Text, [int]$Length = 300) {
    if ($Text.Length -gt $Length) { return $Text.Substring($Text.Length - $Length) }
    return $Text
}

function Install-ScriptPackage($Tool) {
    if ($Tool.Url -notmatch '^https://') { throw "The install script for $($Tool.Name) must be fetched over https." }
    $scriptPath = Join-Path $env:TEMP ("Dingo-installer-{0}.ps1" -f [Guid]::NewGuid().ToString('N'))
    try {
        # Windows PowerShell 5.1 can still default to an older protocol.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Write-Log 'INFO' "Downloading the $($Tool.Name) install script from $($Tool.Url)."
        Invoke-WebRequest -Uri $Tool.Url -OutFile $scriptPath -UseBasicParsing -ErrorAction Stop
        # Record what was actually executed, so a run can be audited afterwards.
        $hash = (Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256 -ErrorAction Stop).Hash
        Write-Log 'INFO' "Install script SHA256 $hash for $($Tool.Name)."

        if (-not (Test-Path -LiteralPath $Tool.Dest -PathType Container)) {
            New-Item -ItemType Directory -Path $Tool.Dest -Force -ErrorAction Stop | Out-Null
            Write-Log 'INFO' "Created $($Tool.Dest)."
        }
        $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-NonInteractive','-File',$scriptPath,'-Dest',$Tool.Dest) + @($Tool.Arguments)
        Write-Log 'INFO' "Running the $($Tool.Name) install script into $($Tool.Dest)."
        $run = Invoke-ChildProcess (Get-PowerShellHostPath) $arguments $Tool.TimeoutSeconds "The $($Tool.Name) install script"
        Write-Log 'DEBUG' "Install script exit code $($run.ExitCode) for $($Tool.Name): $(Get-OutputTail $run.Output 2000)"
        if ($run.ExitCode -ne 0) {
            throw "The $($Tool.Name) install script exited with code $($run.ExitCode). $(Get-OutputTail $run.Output)"
        }
    } finally {
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    }
}

function Send-EnvironmentChange {
    if (-not ('Dingo.NativeMethods' -as [type])) { Send-InternationalSettingChange | Out-Null }
    $result = [IntPtr]::Zero
    # WM_SETTINGCHANGE with 'Environment' tells running programs to reread PATH.
    # Already-open windows keep the old value until they are restarted.
    [void][Dingo.NativeMethods]::SendMessageTimeout([IntPtr]0xffff,0x001A,[IntPtr]::Zero,'Environment',2,5000,[ref]$result)
}

function Get-MachinePathValue {
    $key = Get-Item -LiteralPath "HKLM:\$script:MachineEnvironmentSubKey" -ErrorAction Stop
    # Read the raw value. Expanding it would bake entries such as
    # %USERPROFILE%\go\bin into one account's literal path when written back.
    return [string]$key.GetValue('Path','',[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
}

function Set-MachinePathValue([string]$Value) {
    if (-not (Test-IsAdministrator)) { throw 'Changing the computer PATH requires elevation.' }
    if ([string]::IsNullOrWhiteSpace($Value)) { throw 'Refusing to write an empty computer PATH.' }
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($script:MachineEnvironmentSubKey, $true)
    if (-not $key) { throw 'Could not open the computer environment key for writing.' }
    try { $key.SetValue('Path', $Value, [Microsoft.Win32.RegistryValueKind]::ExpandString) }
    finally { $key.Close() }
}

function Split-PathValue([string]$PathValue) {
    return @(($PathValue -split ';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
}

function Test-PathContainsFolder([string]$PathValue, [string]$Folder) {
    $target = $Folder.TrimEnd('\')
    foreach ($part in (Split-PathValue $PathValue)) {
        if ($part.TrimEnd('\') -eq $target) { return $true }
    }
    return $false
}

# The two functions below do the string work only. Keeping them free of registry
# access is what lets the self-test prove PATH is never damaged.
function Add-FolderToPathValue([string]$PathValue, [string]$Folder) {
    if (Test-PathContainsFolder $PathValue $Folder) { return $PathValue }
    # Append rather than prepend, so a tool can never shadow a Windows command.
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $Folder }
    return ($PathValue.TrimEnd(';') + ';' + $Folder)
}

function Remove-FolderFromPathValue([string]$PathValue, [string]$Folder) {
    $target = $Folder.TrimEnd('\')
    return (@(Split-PathValue $PathValue | Where-Object { $_.TrimEnd('\') -ne $target }) -join ';')
}

function Add-FolderToMachinePath([string]$Folder) {
    $current = Get-MachinePathValue
    $updated = Add-FolderToPathValue $current $Folder
    if ($updated -eq $current) { return $false }
    Set-MachinePathValue $updated
    Write-Log 'INFO' "Added '$Folder' to the computer PATH."
    return $true
}

function Remove-FolderFromMachinePath([string]$Folder) {
    $current = Get-MachinePathValue
    if (-not (Test-PathContainsFolder $current $Folder)) { return $false }
    Set-MachinePathValue (Remove-FolderFromPathValue $current $Folder)
    Write-Log 'INFO' "Removed '$Folder' from the computer PATH."
    return $true
}

function Get-ExpectedShims {
    $shims = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($tool in (Get-ToolCatalog)) {
        if (-not $tool.Shims) { continue }
        $from = [Environment]::ExpandEnvironmentVariables($tool.Shims.From)
        if (-not (Test-Path -LiteralPath $from -PathType Container)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $from -Filter $tool.Shims.Pattern -File -Recurse:$tool.Shims.Recurse -ErrorAction SilentlyContinue)) {
            $name = [IO.Path]::GetFileNameWithoutExtension($file.Name)
            if ($shims.Contains($name)) {
                Write-Log 'WARN' "Two tools both provide '$name'; keeping $($shims[$name])."
                continue
            }
            $shims[$name] = $file.FullName
        }
    }
    return $shims
}

function Get-DingoShimFiles {
    if (-not (Test-Path -LiteralPath $script:ShimDirectory -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $script:ShimDirectory -Filter '*.cmd' -File -ErrorAction SilentlyContinue | Where-Object {
        $content = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue
        $content -and $content.Contains($script:ShimMarker)
    })
}

function Test-ShimIsCurrent([string]$ShimPath, [string]$TargetPath) {
    $content = Get-Content -LiteralPath $ShimPath -Raw -ErrorAction SilentlyContinue
    if (-not $content -or -not $content.Contains($script:ShimMarker)) { return $false }
    return $content.Contains('"' + $TargetPath + '"')
}

function Write-ToolShim([string]$Name, [string]$TargetPath) {
    $shimPath = Join-Path $script:ShimDirectory "$Name.cmd"
    $lines = @(
        '@echo off',
        $script:ShimMarker,
        ('"{0}" %*' -f $TargetPath)
    )
    # cmd.exe reads .cmd files as ANSI, so do not write a UTF-8 byte order mark.
    [IO.File]::WriteAllText($shimPath, (($lines -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($false)))
    if (-not (Test-ShimIsCurrent $shimPath $TargetPath)) { throw "Verification failed for the launcher '$Name.cmd'." }
}

function Get-ToolPathKindState($Setting) {
    $expected = Get-ExpectedShims
    $onPath = Test-PathContainsFolder (Get-MachinePathValue) $script:ShimDirectory
    $total = $expected.Count
    $current = 0
    foreach ($name in @($expected.Keys)) {
        $shimPath = Join-Path $script:ShimDirectory "$name.cmd"
        if ((Test-Path -LiteralPath $shimPath -PathType Leaf) -and (Test-ShimIsCurrent $shimPath $expected[$name])) { $current++ }
    }
    $stale = @(Get-DingoShimFiles).Count
    if ($onPath -and $current -eq $total) {
        $detail = if ($total) { "$total launchers in $script:ShimDirectory, and that folder is on the computer PATH." }
                  else { "$script:ShimDirectory is on the computer PATH. No installed tool offers command-line programs yet." }
        return (New-StateResult 'Preferred' $Setting.PreferredState $detail)
    }
    if (-not $onPath -and $stale -eq 0) {
        return (New-StateResult 'Alternate' $Setting.AlternateState "$script:ShimDirectory is not on the computer PATH.")
    }
    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add($(if ($onPath) { 'the folder is on the computer PATH' } else { 'the folder is not on the computer PATH' }))
    [void]$parts.Add("$current of $total launchers are present and current")
    return (New-StateResult 'Partial' 'Partly set up' (($parts -join ', ') + '.'))
}

function Set-ToolPathKindPart($Setting, [string]$DesiredState, [string]$Scope) {
    if ($DesiredState -eq $Setting.PreferredState) {
        if (-not (Test-Path -LiteralPath $script:ShimDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $script:ShimDirectory -Force -ErrorAction Stop | Out-Null
            Write-Log 'INFO' "Created $script:ShimDirectory."
        }
        $expected = Get-ExpectedShims
        foreach ($name in @($expected.Keys)) { Write-ToolShim $name $expected[$name] }
        # Drop launchers Dingo wrote for programs that are no longer installed.
        foreach ($file in (Get-DingoShimFiles)) {
            $name = [IO.Path]::GetFileNameWithoutExtension($file.Name)
            if (-not $expected.Contains($name)) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
                Write-Log 'INFO' "Removed the stale launcher '$($file.Name)'."
            }
        }
        [void](Add-FolderToMachinePath $script:ShimDirectory)
        if (-not (Test-PathContainsFolder (Get-MachinePathValue) $script:ShimDirectory)) {
            throw "Verification failed: '$script:ShimDirectory' is not on the computer PATH."
        }
        Write-Log 'INFO' "Wrote $($expected.Count) launcher(s) into $script:ShimDirectory."
    } else {
        [void](Remove-FolderFromMachinePath $script:ShimDirectory)
        if (Test-PathContainsFolder (Get-MachinePathValue) $script:ShimDirectory) {
            throw "Verification failed: '$script:ShimDirectory' is still on the computer PATH."
        }
        foreach ($file in (Get-DingoShimFiles)) { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue }
        # Leave the folder if anything Dingo did not write is still in it.
        if ((Test-Path -LiteralPath $script:ShimDirectory -PathType Container) -and
            -not @(Get-ChildItem -LiteralPath $script:ShimDirectory -Force -ErrorAction SilentlyContinue).Count) {
            Remove-Item -LiteralPath $script:ShimDirectory -Force -ErrorAction SilentlyContinue
        }
    }
    Send-EnvironmentChange
}

function Get-ExpectedShortcuts {
    $wanted = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($tool in (Get-ToolCatalog)) {
        foreach ($shortcut in @($tool.Shortcuts)) {
            $target = [Environment]::ExpandEnvironmentVariables($shortcut.Target)
            # The tool may not be installed, or this program may not be part of it.
            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { continue }
            if ($wanted.Contains($shortcut.Name)) {
                Write-Log 'WARN' "Two tools both ask for a '$($shortcut.Name)' shortcut; keeping $($wanted[$shortcut.Name].Target)."
                continue
            }
            $wanted[$shortcut.Name] = [PSCustomObject]@{
                # Normalise here, because a shortcut always reports its target
                # with backslashes and the two must compare equal.
                Target = (Get-Item -LiteralPath $target).FullName
                Arguments = [string]$shortcut.Arguments
            }
        }
    }
    return $wanted
}

function Read-ShortcutFile([string]$Path) {
    $shell = New-Object -ComObject WScript.Shell
    try {
        $link = $shell.CreateShortcut($Path)
        return [PSCustomObject]@{
            Target = [string]$link.TargetPath
            Arguments = [string]$link.Arguments
            Description = [string]$link.Description
        }
    } finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

function Get-DingoShortcutFiles([string]$Folder) {
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $Folder -Filter '*.lnk' -File -ErrorAction SilentlyContinue | Where-Object {
        try { (Read-ShortcutFile $_.FullName).Description -eq $script:ShortcutMarker } catch { $false }
    })
}

function Test-ShortcutIsCurrent([string]$Path, $Spec) {
    try { $link = Read-ShortcutFile $Path } catch { return $false }
    if ($link.Description -ne $script:ShortcutMarker) { return $false }
    if ($link.Target -ne $Spec.Target) { return $false }
    return ($link.Arguments -eq $Spec.Arguments)
}

function Write-ToolShortcut([string]$Folder, [string]$Name, $Spec) {
    $shortcutPath = Join-Path $Folder ($Name + '.lnk')
    $shell = New-Object -ComObject WScript.Shell
    try {
        $link = $shell.CreateShortcut($shortcutPath)
        $link.TargetPath = $Spec.Target
        $link.Arguments = $Spec.Arguments
        # Several of these tools look for their own files beside themselves.
        $link.WorkingDirectory = [IO.Path]::GetDirectoryName($Spec.Target)
        $link.Description = $script:ShortcutMarker
        $link.Save()
    } finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
    if (-not (Test-ShortcutIsCurrent $shortcutPath $Spec)) { throw "Verification failed for the '$Name' shortcut." }
}

function Get-ShortcutSettingFolder($Setting) {
    $entry = @($Setting.Entries)[0]
    if (-not $entry) { throw "Setting '$($Setting.Id)' has no shortcut folder." }
    return [Environment]::ExpandEnvironmentVariables([string]$entry.Folder)
}

function Get-ShortcutKindState($Setting) {
    $folder = Get-ShortcutSettingFolder $Setting
    $expected = Get-ExpectedShortcuts
    $total = $expected.Count
    $current = 0
    foreach ($name in @($expected.Keys)) {
        $shortcutPath = Join-Path $folder ($name + '.lnk')
        if ((Test-Path -LiteralPath $shortcutPath -PathType Leaf) -and (Test-ShortcutIsCurrent $shortcutPath $expected[$name])) { $current++ }
    }
    $owned = @(Get-DingoShortcutFiles $folder).Count
    if ($total -gt 0 -and $current -eq $total -and $owned -eq $total) {
        return (New-StateResult 'Preferred' $Setting.PreferredState "$total shortcut(s) in $folder.")
    }
    if ($current -eq 0 -and $owned -eq 0) {
        $detail = if ($total) { "None of the $total available shortcuts are in $folder." }
                  else { 'No installed tool asks for a shortcut yet.' }
        return (New-StateResult 'Alternate' $Setting.AlternateState $detail)
    }
    return (New-StateResult 'Partial' 'Partly set up' "$current of $total shortcuts are present and current in $folder.")
}

function Set-ShortcutKindPart($Setting, [string]$DesiredState, [string]$Scope) {
    $folder = Get-ShortcutSettingFolder $Setting
    $expected = Get-ExpectedShortcuts
    if ($DesiredState -eq $Setting.PreferredState) {
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
            New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null
            Write-Log 'INFO' "Created $folder."
        }
        foreach ($name in @($expected.Keys)) { Write-ToolShortcut $folder $name $expected[$name] }
        # Drop shortcuts Dingo wrote for programs that are no longer installed.
        foreach ($file in (Get-DingoShortcutFiles $folder)) {
            $name = [IO.Path]::GetFileNameWithoutExtension($file.Name)
            if (-not $expected.Contains($name)) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
                Write-Log 'INFO' "Removed the stale shortcut '$($file.Name)'."
            }
        }
        Write-Log 'INFO' "Wrote $($expected.Count) shortcut(s) into $folder."
    } else {
        foreach ($file in (Get-DingoShortcutFiles $folder)) { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue }
        if (@(Get-DingoShortcutFiles $folder).Count) { throw "Verification failed: Dingo shortcuts are still in $folder." }
        # Only ever remove the folder Dingo made, and only when it is empty. The
        # shared Desktop folder belongs to Windows and is never touched.
        if ($folder -eq $script:StartMenuShortcutDirectory -and
            (Test-Path -LiteralPath $folder -PathType Container) -and
            -not @(Get-ChildItem -LiteralPath $folder -Force -ErrorAction SilentlyContinue).Count) {
            Remove-Item -LiteralPath $folder -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-PackageKindState($Setting) {
    $tool = @($Setting.Entries)[0]
    $found = Find-InstalledTool $tool
    if (-not $found) {
        return (New-StateResult 'Partial' 'Not installed' "Dingo checked the Windows uninstall list and the usual folders for $($tool.Name).")
    }
    $text = if ($found.Version) { "Installed ($($found.Version))" } else { 'Installed' }
    return (New-StateResult 'Preferred' $text $found.Evidence)
}

function Set-PackageKindPart($Setting, [string]$DesiredState, [string]$Scope) {
    $tool = @($Setting.Entries)[0]
    if ($DesiredState -ne $Setting.PreferredState) { throw "Dingo installs $($tool.Name) but never removes it." }
    if ($tool.InstallKind -eq 'winget') { Install-WingetPackage $tool }
    elseif ($tool.InstallKind -eq 'script') { Install-ScriptPackage $tool }
    else { throw "Install kind '$($tool.InstallKind)' is not supported in this version of Dingo." }
}

function Get-Settings {
    $advanced = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $edge = 'SOFTWARE\Policies\Microsoft\Edge'
    $windowsUpdate = 'SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $windowsUpdateAU = "$windowsUpdate\AU"
    $settings = New-Object System.Collections.ArrayList

    [void]$settings.Add((New-Setting 'timezone-utc' 'Region & language' 'Time zone' 'Preferred time zone is UTC.' 'UTC' $null 'TimeZone' @() $false $false))
    [void]$settings.Add((New-Setting 'region-australia' 'Region & language' 'Region and formats' 'Preferred region and culture are Australia / en-AU.' 'Australia (en-AU)' $null 'Region'))
    [void]$settings.Add((New-Setting 'language-au' 'Region & language' 'Australian English' 'Selects English (Australia) for the Windows interface, input, spelling, and system locale. Windows supplies its interface through the underlying en-GB display resources.' 'Australian UI + locale (en-AU)' $null 'Language' @() $false $true))
    [void]$settings.Add((New-Setting 'iso-time' 'Region & language' 'Date and time format' 'Preferred formats are yyyy-MM-dd, HH:mm, and HH:mm:ss.' 'ISO-style / 24-hour' $null 'Registry' @(
        (New-Entry User 'Control Panel\International' 'sShortDate' 'yyyy-MM-dd' $script:RemoveValue String),
        (New-Entry User 'Control Panel\International' 'sShortTime' 'HH:mm' $script:RemoveValue String),
        (New-Entry User 'Control Panel\International' 'sTimeFormat' 'HH:mm:ss' $script:RemoveValue String),
        (New-Entry User 'Control Panel\International' 'sDate' '-' $script:RemoveValue String),
        (New-Entry User 'Control Panel\International' 'iDate' '2' $script:RemoveValue String),
        (New-Entry User 'Control Panel\International' 'iTime' '1' $script:RemoveValue String),
        (New-Entry User 'Control Panel\International' 'iTLZero' '1' $script:RemoveValue String)
    )))

    [void]$settings.Add((New-Setting 'taskbar-search' 'Taskbar' 'Search box' 'Hide or show the taskbar Search box.' 'Hidden' 'Shown' 'Registry' @(
        (New-Entry User 'Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' 0 2)
    ) $true))
    [void]$settings.Add((New-Setting 'task-view' 'Taskbar' 'Task View button' 'Hide or show Task View on the taskbar.' 'Hidden' 'Shown' 'Registry' @(
        (New-Entry User $advanced 'ShowTaskViewButton' 0 $script:RemoveValue)
    ) $true))
    [void]$settings.Add((New-Setting 'widgets' 'Taskbar' 'Windows Widgets' 'Remove the Windows Widgets packages from this Windows account. Other user profiles are left unchanged.' 'Removed' $null 'WidgetsPackage' @() $true $true))
    [void]$settings.Add((New-Setting 'resume' 'Taskbar' 'Cross-device Resume' 'Disable or enable activity hand-off from linked devices.' 'Disabled' 'Enabled' 'Registry' @(
        (New-Entry User 'Software\Microsoft\Windows\CurrentVersion\CrossDeviceResume\Configuration' 'IsResumeAllowed' 0 1),
        (New-Entry Machine 'SOFTWARE\Microsoft\PolicyManager\default\Connectivity\DisableCrossDeviceResume' 'value' 1 0)
    )))
    [void]$settings.Add((New-Setting 'never-combine' 'Taskbar' 'Combine taskbar buttons' 'Choose whether taskbar buttons are combined.' 'Never combine' 'Always combine' 'Registry' @(
        (New-Entry User $advanced 'TaskbarGlomLevel' 2 $script:RemoveValue),
        (New-Entry User $advanced 'MMTaskbarGlomLevel' 2 $script:RemoveValue)
    ) $true))
    [void]$settings.Add((New-Setting 'end-task' 'Taskbar' 'End task on right-click' 'Enable or disable End task in app taskbar menus.' 'Enabled' 'Disabled' 'Registry' @(
        (New-Entry User "$advanced\TaskbarDeveloperSettings" 'TaskbarEndTask' 1 $script:RemoveValue)
    ) $true))

    [void]$settings.Add((New-Setting 'explorer-this-pc' 'File Explorer' 'Default landing page' 'Choose This PC or Home for new Explorer windows.' 'This PC' 'Home' 'Registry' @(
        (New-Entry User $advanced 'LaunchTo' 1 $script:RemoveValue)
    ) $true))
    [void]$settings.Add((New-Setting 'hidden-files' 'File Explorer' 'Hidden files and folders' 'Show or hide items carrying the hidden attribute.' 'Shown' 'Hidden' 'Registry' @(
        (New-Entry User $advanced 'Hidden' 1 2)
    ) $true))
    [void]$settings.Add((New-Setting 'file-extensions' 'File Explorer' 'File-name extensions' 'Show or hide extensions such as .exe and .txt.' 'Shown' 'Hidden' 'Registry' @(
        (New-Entry User $advanced 'HideFileExt' 0 1)
    ) $true))
    [void]$settings.Add((New-Setting 'protected-files' 'File Explorer' 'Protected operating-system files' 'CAUTION: showing these exposes sensitive system files.' 'Shown' 'Hidden' 'Registry' @(
        (New-Entry User $advanced 'ShowSuperHidden' 1 0)
    ) $true))
    [void]$settings.Add((New-Setting 'expand-nav' 'File Explorer' 'Expand navigation pane' 'Expand the navigation tree to the current folder.' 'Enabled' 'Disabled' 'Registry' @(
        (New-Entry User $advanced 'NavPaneExpandToCurrentFolder' 1 $script:RemoveValue)
    ) $true))
    [void]$settings.Add((New-Setting 'long-paths' 'File Explorer' 'Win32 long paths' 'Allow long-path-aware applications to exceed MAX_PATH.' 'Enabled' 'Disabled/default' 'Registry' @(
        (New-Entry Machine 'SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled' 1 0)
    ) $false $true))

    [void]$settings.Add((New-Setting 'onedrive' 'Windows features' 'OneDrive file sync' 'Disable by policy without uninstalling OneDrive or deleting files.' 'Disabled' 'Enabled/default' 'Registry' @(
        (New-Entry Machine 'SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 1 $script:RemoveValue),
        (New-Entry Machine 'SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSync' 1 $script:RemoveValue)
    ) $false $true))
    [void]$settings.Add((New-Setting 'windows-copilot' 'Windows features' 'Windows Copilot and taskbar icon' 'Disables legacy Windows Copilot integration and removes detectable Copilot taskbar shortcuts. It does not uninstall standalone apps; a packaged-app pin may need to be unpinned manually.' 'Disabled' 'Enabled/default' 'Registry' @(
        (New-Entry Machine 'SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1 $script:RemoveValue),
        (New-Entry ElevatedUser 'Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1 $script:RemoveValue),
        (New-Entry User $advanced 'ShowCopilotButton' 0 1),
        (New-Entry User 'SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsCopilot' 'AllowCopilotRuntime' 0 1)
    ) $true $true))

    [void]$settings.Add((New-Setting 'windows-update-continuity' 'Windows Update' 'Forensic continuity: manual updates and restarts' 'CAUTION: for Windows 11 Pro/Enterprise/Education forensic workstations. Prevents automatic Windows Update downloads/installations, disables update deadlines, blocks update restarts while a user is signed in, and suppresses all update notifications. Check, install, and restart manually during a controlled maintenance window. It cannot cancel a restart that is already pending or override policies continually enforced by your organisation.' 'Protected; manual maintenance' 'Windows-managed/default' 'Registry' @(
        (New-Entry Machine $windowsUpdateAU 'NoAutoUpdate' 1 $script:RemoveValue),
        (New-Entry Machine $windowsUpdateAU 'NoAutoRebootWithLoggedOnUsers' 1 $script:RemoveValue),
        (New-Entry Machine $windowsUpdate 'SetComplianceDeadlineForQU' 0 $script:RemoveValue),
        (New-Entry Machine $windowsUpdate 'SetComplianceDeadlineForFU' 0 $script:RemoveValue),
        (New-Entry Machine $windowsUpdate 'SetUpdateNotificationLevel' 1 $script:RemoveValue),
        (New-Entry Machine $windowsUpdate 'UpdateNotificationLevel' 2 $script:RemoveValue),
        (New-Entry Machine $windowsUpdate 'NoUpdateNotificationsDuringActiveHours' 0 $script:RemoveValue)
    ) -Requirements @{ Editions=@('Professional','ProfessionalN','ProfessionalEducation','ProfessionalWorkstation','Enterprise','EnterpriseN','EnterpriseS','Education','EducationN','IoTEnterprise') }))

    [void]$settings.Add((New-Setting 'edge-first-run' 'Microsoft Edge' 'First-run and import extras' 'Suppress or restore default Edge first-run, import, and recommendation policies.' 'Suppressed' 'Allowed/default' 'Registry' @(
        (New-Entry Machine $edge 'HideFirstRunExperience' 1 $script:RemoveValue),
        (New-Entry Machine $edge 'AutoImportAtFirstRun' 4 $script:RemoveValue),
        (New-Entry Machine $edge 'ImportOnEachLaunch' 0 $script:RemoveValue),
        (New-Entry Machine $edge 'ImportBrowserSettings' 0 $script:RemoveValue),
        (New-Entry Machine $edge 'ShowRecommendationsEnabled' 0 $script:RemoveValue),
        (New-Entry Machine $edge 'PersonalizationReportingEnabled' 0 $script:RemoveValue)
    )))
    [void]$settings.Add((New-Setting 'edge-passwords' 'Microsoft Edge' 'Edge password manager' 'Disable or restore default password saving, generation, monitoring, and passkeys.' 'Disabled' 'Enabled/default' 'Registry' @(
        (New-Entry Machine $edge 'PasswordManagerEnabled' 0 $script:RemoveValue),
        (New-Entry Machine $edge 'PasswordGeneratorEnabled' 0 $script:RemoveValue),
        (New-Entry Machine $edge 'PasswordMonitorAllowed' 0 $script:RemoveValue),
        (New-Entry Machine $edge 'PasswordManagerPasskeysEnabled' 0 $script:RemoveValue)
    )))
    [void]$settings.Add((New-Setting 'edge-copilot' 'Microsoft Edge' 'Copilot in Edge' 'Disable or restore default Copilot-related Edge surfaces and page access.' 'Disabled' 'Enabled/default' 'Registry' @(
        (New-Entry Machine $edge 'HubsSidebarEnabled' 0 $script:RemoveValue),
        (New-Entry Machine $edge 'Microsoft365CopilotChatIconEnabled' 0 $script:RemoveValue),
        (New-Entry Machine $edge 'CopilotPageContext' 0 $script:RemoveValue),
        (New-Entry Machine $edge 'AllowBrowsingWithCopilot' 0 $script:RemoveValue),
        (New-Entry Machine $edge 'M365LinksAutoOpenCopilotEnabled' 0 $script:RemoveValue)
    )))
    # Edge treats DefaultSearchProvider* as a protected policy and blocks it on a
    # device that is not domain joined, Entra joined, or Intune enrolled, which is
    # every standalone analysis VM. ManagedSearchEngines is not protected and does
    # apply. It replaces the whole engine list, so Bing is never created rather
    # than removed. Written to the Recommended key so an analyst can still change
    # engines afterwards. Only the default entry may carry is_default: adding
    # "is_default": false to another entry makes Edge reject the whole policy
    # silently. DefaultSearchProviderSearchURL suppresses ManagedSearchEngines, so
    # the old values must be absent for the preferred state to hold.
    $searchEngines = '[{"is_default":true,"keyword":"google.com","name":"Google","search_url":"https://www.google.com/search?q={searchTerms}"},{"keyword":"duckduckgo.com","name":"DuckDuckGo","search_url":"https://duckduckgo.com/?q={searchTerms}","suggest_url":"https://duckduckgo.com/ac/?q={searchTerms}&type=list"}]'
    [void]$settings.Add((New-Setting 'edge-search-engines' 'Microsoft Edge' 'Search engines' 'Offer Google and DuckDuckGo only, with Google as the default. Bing is never added. Restart Edge to finish applying it.' 'Google and DuckDuckGo, no Bing' 'Browser default (includes Bing)' 'Registry' @(
        (New-Entry Machine "$edge\Recommended" 'ManagedSearchEngines' $searchEngines $script:RemoveValue String),
        (New-Entry Machine $edge 'DefaultSearchProviderEnabled' $script:RemoveValue $script:RemoveValue),
        (New-Entry Machine $edge 'DefaultSearchProviderName' $script:RemoveValue $script:RemoveValue String),
        (New-Entry Machine $edge 'DefaultSearchProviderKeyword' $script:RemoveValue $script:RemoveValue String),
        (New-Entry Machine $edge 'DefaultSearchProviderSearchURL' $script:RemoveValue $script:RemoveValue String),
        (New-Entry Machine $edge 'DefaultSearchProviderSuggestURL' $script:RemoveValue $script:RemoveValue String)
    )))

    # None of these are protected policies, so they apply on an unmanaged VM.
    # The three NewTabPage values are what actually removes the news feed,
    # weather, and background images; WinUtil's Edge debloat does not cover them.
    [void]$settings.Add((New-Setting 'edge-debloat' 'Microsoft Edge' 'Clutter, promotions, and new tab page' 'Remove the new tab page news feed, weather, background images, and quick links, plus Collections, shopping, Rewards, wallet donations, Insider and default-browser promotions, the web widget, feedback, telemetry, and the Copilot Discover Chat extension. Sends Do Not Track. Restart Edge to finish applying it.' 'Removed' 'Edge default' 'Registry' @(
        (New-Entry Machine $edge 'NewTabPageContentEnabled' 0 $script:RemoveValue),
        (New-Entry Machine $edge 'NewTabPageAllowedBackgroundTypes' 3 $script:RemoveValue),
        (New-Entry Machine $edge 'NewTabPageQuickLinksEnabled' 0 $script:RemoveValue),
        (New-Entry Machine $edge 'EdgeCollectionsEnabled' 0 $script:RemoveValue),
        (New-Entry Machine $edge 'EdgeShoppingAssistantEnabled' 0 $script:RemoveValue),
        (New-Entry Machine $edge 'ShowMicrosoftRewards' 0 $script:RemoveValue),
        (New-Entry Machine $edge 'WalletDonationEnabled' 0 $script:RemoveValue),
        (New-Entry Machine $edge 'MicrosoftEdgeInsiderPromotionEnabled' 0 $script:RemoveValue),
        (New-Entry Machine $edge 'DefaultBrowserSettingsCampaignEnabled' 0 $script:RemoveValue),
        (New-Entry Machine $edge 'WebWidgetAllowed' 0 $script:RemoveValue),
        (New-Entry Machine $edge 'UserFeedbackAllowed' 0 $script:RemoveValue),
        (New-Entry Machine $edge 'AlternateErrorPagesEnabled' 0 $script:RemoveValue),
        (New-Entry Machine $edge 'EdgeAssetDeliveryServiceEnabled' 0 $script:RemoveValue),
        (New-Entry Machine $edge 'DiagnosticData' 0 $script:RemoveValue),
        (New-Entry Machine $edge 'ConfigureDoNotTrack' 1 $script:RemoveValue),
        (New-Entry Machine 'SOFTWARE\Policies\Microsoft\EdgeUpdate' 'CreateDesktopShortcutDefault' 0 $script:RemoveValue),
        # Copilot's "Discover Chat" extension.
        (New-Entry Machine "$edge\ExtensionInstallBlocklist" '1' 'ofefcgjbeghpigppfmkologfjadafddi' $script:RemoveValue String)
    )))

    [void]$settings.Add((New-Setting 'terminal-cwd' 'Windows Terminal' 'Windows PowerShell starting directory' 'Use the parent process directory or the user profile.' 'Parent process directory' 'User profile directory' 'Terminal'))
    [void]$settings.Add((New-Setting 'start-bing' 'Start menu' 'Bing/web search' 'Disable or restore default web suggestions in Start/Search.' 'Disabled' 'Enabled/default' 'Registry' @(
        (New-Entry ElevatedUser 'Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1 $script:RemoveValue),
        (New-Entry User 'Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0 $script:RemoveValue)
    ) $true))
    [void]$settings.Add((New-Setting 'start-recommendations' 'Start menu' 'Recommendations' 'Disable or restore default recent and recommended content.' 'Disabled' 'Enabled/default' 'Registry' @(
        (New-Entry User $advanced 'Start_TrackDocs' 0 1),
        (New-Entry User 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 0 $script:RemoveValue),
        (New-Entry User 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 0 $script:RemoveValue),
        (New-Entry Machine 'SOFTWARE\Policies\Microsoft\Windows\Explorer' 'HideRecommendedSection' 1 $script:RemoveValue)
    ) $true))

    # Tools come from a catalog rather than from literals here, so Tools.json can
    # add more of them later without a code change.
    foreach ($tool in (Get-ToolCatalog)) {
        [void]$settings.Add((New-Setting $tool.Id $tool.Category $tool.Name $tool.Description 'Installed' $null 'Package' @($tool) $false $false `
            @{ WingetRequired = ($tool.InstallKind -eq 'winget'); RequiredTools = @($tool.Requires) } 'Install tools' 'Not installed'))
    }
    # Shortcuts come after the tool cards, because a shortcut is only written for
    # a program that is already on disk.
    [void]$settings.Add((New-Setting 'tools-start-menu' 'Tools' 'Start menu shortcuts' `
        "Puts a shortcut for each installed window tool into a DFIR Tools folder in the Start menu, for every account on this computer. Some installers make no shortcut at all, so the program is on disk but nobody can find it. Turning this off removes only the shortcuts Dingo made." `
        'Created' 'Not created' 'Shortcut' @([PSCustomObject]@{ Scope='Machine'; Folder=$script:StartMenuShortcutDirectory }) $false $false @{} 'Tool shortcuts'))
    [void]$settings.Add((New-Setting 'tools-desktop' 'Tools' 'Desktop shortcuts' `
        "Puts the same shortcuts on the shared Desktop, for every account on this computer. Turning this off removes only the shortcuts Dingo made." `
        'Created' 'Not created' 'Shortcut' @([PSCustomObject]@{ Scope='Machine'; Folder=$script:DesktopShortcutDirectory }) $false $false @{} 'Tool shortcuts'))
    # Added last on purpose. The elevated worker runs the plan in this order, so
    # the launchers are written after the tools they point at are installed.
    [void]$settings.Add((New-Setting 'tools-on-path' 'Tools' 'Run tools from anywhere' `
        "Puts one small launcher for each installed command-line tool into $script:ShimDirectory, then adds that single folder to the computer PATH. You can then type EvtxECmd from any folder. The folder is added at the end of the PATH, so a tool can never shadow a Windows command." `
        'On the PATH' 'Not on the PATH' 'ToolPath' @() $false $false @{} 'Tool shortcuts'))
    return ,$settings
}

function Test-SettingHasScope($Setting, [ValidateSet('User','Machine','ElevatedUser')][string]$Scope) {
    $handler = Get-SettingHandler $Setting.Kind
    return @(& $handler.GetScopes $Setting.Entries) -contains $Scope
}

function Get-EntryPath($Entry) {
    if ($Entry.Scope -eq 'User') { return "HKCU:\$($Entry.Path)" }
    if ($Entry.Scope -eq 'ElevatedUser') {
        if ($MachineWorker) {
            if ($TargetUserSid -notmatch '^S-\d(?:-\d+)+$') { throw 'The desktop user SID supplied to the administrator step is invalid.' }
            return "Registry::HKEY_USERS\$TargetUserSid\$($Entry.Path)"
        }
        return "HKCU:\$($Entry.Path)"
    }
    return "HKLM:\$($Entry.Path)"
}

function Get-EntryValue($Entry) {
    $path = Get-EntryPath $Entry
    try {
        if (-not (Test-Path -LiteralPath $path -ErrorAction Stop)) {
            return [PSCustomObject]@{ Status='Missing'; Exists=$false; Value=$null; ErrorMessage='' }
        }
        $properties = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
        $property = $properties.PSObject.Properties[$Entry.Name]
        if (-not $property) {
            return [PSCustomObject]@{ Status='Missing'; Exists=$false; Value=$null; ErrorMessage='' }
        }
        return [PSCustomObject]@{ Status='Present'; Exists=$true; Value=$property.Value; ErrorMessage='' }
    } catch {
        return [PSCustomObject]@{ Status='Error'; Exists=$false; Value=$null; ErrorMessage=$_.Exception.Message }
    }
}

function Test-EntryValue($Entry, $Expected) {
    $actual = Get-EntryValue $Entry
    if ($actual.Status -eq 'Error') {
        throw "Could not read $(Get-EntryPath $Entry)\$($Entry.Name): $($actual.ErrorMessage)"
    }
    if ($Expected -eq $script:RemoveValue) { return -not $actual.Exists }
    return $actual.Exists -and ([string]$actual.Value -eq [string]$Expected)
}

function Set-EntryValue($Entry, $DesiredState, $Setting) {
    if ($Entry.Scope -in @('Machine','ElevatedUser') -and -not (Test-IsAdministrator)) { throw 'This registry setting requires elevation.' }
    $wanted = if ($DesiredState -eq $Setting.PreferredState) { $Entry.Preferred } else { $Entry.Alternate }
    $path = Get-EntryPath $Entry
    if ($wanted -eq $script:RemoveValue) {
        $current = Get-EntryValue $Entry
        if ($current.Status -eq 'Error') { throw "Could not read $path\$($Entry.Name) before removing it: $($current.ErrorMessage)" }
        if ($current.Exists) { Remove-ItemProperty -LiteralPath $path -Name $Entry.Name -ErrorAction Stop }
    } else {
        if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
        New-ItemProperty -LiteralPath $path -Name $Entry.Name -Value $wanted -PropertyType $Entry.Type -Force | Out-Null
    }
    if (-not (Test-EntryValue $Entry $wanted)) { throw "Verification failed for $path\$($Entry.Name)." }
    Write-Log 'DEBUG' "Verified $path\$($Entry.Name) => $wanted"
}

function Get-TerminalFiles {
    @(
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
    ) | Where-Object { Test-Path -LiteralPath $_ }
}

function Get-PowerShellProfiles($SettingsObject) {
    if (-not $SettingsObject.profiles -or -not $SettingsObject.profiles.list) { return @() }
    @($SettingsObject.profiles.list | Where-Object {
        $profileName = if ($_.PSObject.Properties['name']) { [string]$_.name } else { '' }
        $commandLine = if ($_.PSObject.Properties['commandline']) { [string]$_.commandline } else { '' }
        $profileName -eq 'Windows PowerShell' -or $commandLine -match '(^|[\\/])powershell(\.exe)?(\s|$)'
    })
}

function ConvertTo-StrictJson([string]$Text) {
    # Windows Terminal writes JSONC: // and /* */ comments plus trailing commas.
    # Windows PowerShell 5.1 ConvertFrom-Json rejects all three, so remove them
    # before parsing. Scan character by character and skip anything inside a
    # string literal, otherwise the // in a URL such as https://aka.ms would be
    # mistaken for the start of a comment.
    $builder = New-Object Text.StringBuilder
    $length = $Text.Length
    $inString = $false
    $index = 0
    while ($index -lt $length) {
        $character = $Text[$index]
        if ($inString) {
            [void]$builder.Append($character)
            if ($character -eq '\') {
                if ($index + 1 -lt $length) { [void]$builder.Append($Text[$index + 1]) }
                $index += 2
                continue
            }
            if ($character -eq '"') { $inString = $false }
            $index++
            continue
        }
        if ($character -eq '"') {
            $inString = $true
            [void]$builder.Append($character)
            $index++
            continue
        }
        if ($character -eq '/' -and $index + 1 -lt $length) {
            $next = $Text[$index + 1]
            if ($next -eq '/') {
                while ($index -lt $length -and $Text[$index] -notin @("`r","`n")) { $index++ }
                continue
            }
            if ($next -eq '*') {
                $index += 2
                while ($index + 1 -lt $length -and -not ($Text[$index] -eq '*' -and $Text[$index + 1] -eq '/')) { $index++ }
                $index += 2
                # Keep the JSON tokens either side of the comment apart.
                [void]$builder.Append(' ')
                continue
            }
        }
        [void]$builder.Append($character)
        $index++
    }
    # A comma before a closing brace or bracket is legal in JSONC but not in JSON.
    return ([regex]::Replace($builder.ToString(), ',(?=\s*[}\]])', ''))
}

function Read-JsonFileTolerantly([string]$Path) {
    $raw = Get-Content -LiteralPath $Path -Raw
    try { return ($raw | ConvertFrom-Json -ErrorAction Stop) }
    catch { Write-Log 'DEBUG' "Strict JSON parse of '$Path' failed; retrying without JSONC comments and trailing commas." }
    try { return (ConvertTo-StrictJson $raw | ConvertFrom-Json -ErrorAction Stop) }
    catch { throw "Could not safely parse '$Path'. $($_.Exception.Message)" }
}

function Read-TerminalJson([string]$Path) { Read-JsonFileTolerantly $Path }

function Get-TerminalState {
    $files = @(Get-TerminalFiles)
    if (-not $files) { return 'Unavailable (launch Terminal once)' }
    $states = @()
    foreach ($path in $files) {
        $settingsObject = Read-TerminalJson $path
        $profiles = @(Get-PowerShellProfiles $settingsObject)
        if (-not $profiles) { $states += 'Missing profile'; continue }
        foreach ($profile in $profiles) {
            if ($profile.PSObject.Properties['startingDirectory'] -and $null -eq $profile.startingDirectory) { $states += 'Parent process directory' }
            elseif (-not $profile.PSObject.Properties['startingDirectory'] -or [string]$profile.startingDirectory -eq '%USERPROFILE%') { $states += 'User profile directory' }
            else { $states += "Custom: $($profile.startingDirectory)" }
        }
    }
    $unique = @($states | Select-Object -Unique)
    if ($unique.Count -eq 1) { return $unique[0] }
    return 'Mixed/custom'
}

function Set-TerminalState([string]$DesiredState) {
    $files = @(Get-TerminalFiles)
    if (-not $files) { throw 'Windows Terminal settings.json was not found. Launch Windows Terminal once, then retry.' }
    foreach ($path in $files) {
        $settingsObject = Read-TerminalJson $path
        $profiles = @(Get-PowerShellProfiles $settingsObject)
        if (-not $profiles) { throw "Windows PowerShell profile not found in '$path'." }
        # Rewriting the file serializes plain JSON. Any comment the operator added
        # survives only in the backup, so record that before the file is replaced.
        if ((Get-Content -LiteralPath $path -Raw) -match '(?m)^\s*(//|/\*)') {
            Write-Log 'WARN' "'$path' contains comments. They are preserved in the backup but not in the rewritten file."
        }
        $wanted = if ($DesiredState -eq 'Parent process directory') { $null } else { '%USERPROFILE%' }
        foreach ($profile in $profiles) {
            if ($profile.PSObject.Properties['startingDirectory']) { $profile.startingDirectory = $wanted }
            else { $profile | Add-Member -NotePropertyName startingDirectory -NotePropertyValue $wanted }
        }
        $json = $settingsObject | ConvertTo-Json -Depth 100
        $null = $json | ConvertFrom-Json -ErrorAction Stop
        $backup = "$path.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
        Write-Utf8FileAtomically $path $json $backup
        Write-Log 'DEBUG' "Updated '$path'; backup '$backup'"
        Remove-StaleTerminalBackups $path
    }
    if ((Get-TerminalState) -ne $DesiredState) { throw 'Windows Terminal verification failed.' }
}

function Get-CurrentUserWidgetsPackages {
    $packageNames = @('Microsoft.WidgetsPlatformRuntime','MicrosoftWindows.Client.WebExperience')
    $packages = New-Object System.Collections.ArrayList
    foreach ($packageName in $packageNames) {
        try {
            $found = @(Get-AppxPackage -Name $packageName -ErrorAction Stop)
            foreach ($package in $found) {
                if (-not ($packages | Where-Object PackageFullName -eq $package.PackageFullName)) { [void]$packages.Add($package) }
            }
        } catch {
            throw "Could not inspect the $packageName package for the current Windows account. $($_.Exception.Message)"
        }
    }
    return @($packages)
}

function Get-WidgetsPackageState {
    $packages = @(Get-CurrentUserWidgetsPackages)
    if (-not $packages) { return 'Removed' }
    $names = @($packages | Select-Object -ExpandProperty Name -Unique)
    return "Installed for this account: $($names -join ', ')"
}

function Remove-WidgetsPackages {
    # Stop only Microsoft's own Widgets host processes. A wildcard such as
    # '*Widget*' would also match unrelated third-party tools on an analyst VM.
    Get-Process -Name 'Widgets','WidgetService','WidgetBoard' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    foreach ($package in @(Get-CurrentUserWidgetsPackages)) {
        Write-Log 'DEBUG' "Removing Widgets package $($package.PackageFullName)"
        Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop
    }
    $remaining = @(Get-CurrentUserWidgetsPackages)
    if ($remaining) {
        throw "Widgets package removal did not finish for this account. Still installed: $(@($remaining.Name | Select-Object -Unique) -join ', ')."
    }
    Write-Log 'DEBUG' 'Verified that Windows Widgets packages are removed for the current account.'
}

function Test-CopilotTaskbarPinned {
    $pinFolder = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
    if (-not (Test-Path -LiteralPath $pinFolder -PathType Container)) { return $false }
    return [bool](Get-ChildItem -LiteralPath $pinFolder -Filter '*.lnk' -ErrorAction Stop | Where-Object Name -match 'Copilot' | Select-Object -First 1)
}

function Unpin-CopilotFromTaskbar {
    $pinFolder = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
    if (Test-Path -LiteralPath $pinFolder) {
        Get-ChildItem -LiteralPath $pinFolder -Filter '*.lnk' -ErrorAction SilentlyContinue |
            Where-Object Name -match 'Copilot' |
            Remove-Item -Force -ErrorAction Stop
    }
    if (Test-CopilotTaskbarPinned) { throw 'Windows still reports that a Copilot app is pinned to the taskbar.' }
    Write-Log 'DEBUG' 'Verified that no Copilot shortcut remains in the standard taskbar pin folder.'
}

function Get-RegistrySettingState($Setting) {
    $preferred = @($Setting.Entries | Where-Object { -not (Test-EntryValue $_ $_.Preferred) }).Count -eq 0
    if ($preferred) { return New-StateResult 'Preferred' $Setting.PreferredState }
    if ($Setting.CanChoose) {
        $alternate = @($Setting.Entries | Where-Object { -not (Test-EntryValue $_ $_.Alternate) }).Count -eq 0
        if ($alternate) { return New-StateResult 'Alternate' $Setting.AlternateState }
    }
    if ($Setting.Id -eq 'iso-time') {
        $shortDate = (Get-EntryValue ($Setting.Entries | Where-Object Name -eq 'sShortDate')).Value
        $shortTime = (Get-EntryValue ($Setting.Entries | Where-Object Name -eq 'sShortTime')).Value
        return New-StateResult 'Partial' "Custom: $shortDate, $shortTime"
    }
    return New-StateResult 'Partial' 'Custom or partly configured'
}

function Get-IsoTimeSetting {
    return $script:Settings | Where-Object Id -eq 'iso-time' | Select-Object -First 1
}

function Test-IsoTimeFormat {
    $setting = Get-IsoTimeSetting
    return $setting -and (@($setting.Entries | Where-Object { -not (Test-EntryValue $_ $_.Preferred) }).Count -eq 0)
}

function Register-InternationalSettingsFinalizer {
    $runOncePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    if (-not (Test-Path -LiteralPath $runOncePath)) { New-Item -Path $runOncePath -Force | Out-Null }
    $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -FinalizeInternationalSettings -WorkerLogPath "{1}"' -f $PSCommandPath,$script:LogFile
    $command = '"{0}" {1}' -f (Join-Path $PSHOME 'powershell.exe'),$arguments
    New-ItemProperty -LiteralPath $runOncePath -Name 'DingoFinalizeInternationalSettings' -Value $command -PropertyType String -Force | Out-Null
    Write-Log 'INFO' 'Registered a one-time sign-in finalizer so Windows language initialization cannot replace the ISO date/time formats.'
}

function Send-InternationalSettingChange {
    if (-not ('Dingo.NativeMethods' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
namespace Dingo {
    public static class NativeMethods {
        [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, string lParam, uint flags, uint timeout, out IntPtr result);
    }
}
'@
    }
    $result = [IntPtr]::Zero
    [void][Dingo.NativeMethods]::SendMessageTimeout([IntPtr]0xffff,0x001A,[IntPtr]::Zero,'intl',2,5000,[ref]$result)
}

function Test-DisplayLanguagePackInstalled([string]$Language) {
    $installed = @(Get-InstalledLanguage -Language $Language -ErrorAction Stop)
    return [bool]($installed | Where-Object { $_.LanguagePacks -and [string]$_.LanguagePacks -ne 'None' })
}

function Install-DisplayLanguagePack([string]$Language, [int]$TimeoutSeconds = 900) {
    Write-Log 'INFO' "Installing the supported $Language Windows display-language pack. Timeout is $TimeoutSeconds seconds."
    # Dingo needs only the UI resources. Avoid hot-adding handwriting, OCR,
    # speech, and other text services while this WPF process is running.
    $job = Install-Language -Language $Language -ExcludeFeatures -AsJob -ErrorAction Stop
    try {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $nextHeartbeat = 30
        $completed = $null
        while (-not $completed -and $timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            $completed = Wait-Job -Job $job -Timeout 5
            if (-not $completed -and $timer.Elapsed.TotalSeconds -ge $nextHeartbeat) {
                Write-Log 'INFO' "Still installing $Language display-language pack ($([math]::Floor($timer.Elapsed.TotalMinutes))m $($timer.Elapsed.Seconds)s elapsed; job state $($job.State))."
                $nextHeartbeat += 30
            }
        }
        if (-not $completed) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            throw "Windows did not finish installing the $Language display pack within $([math]::Round($TimeoutSeconds / 60)) minutes. Check Windows Update connectivity and try again."
        }
        Receive-Job -Job $job -ErrorAction Stop | Out-Null
        if ($job.State -ne 'Completed') {
            $reason = if ($job.ChildJobs[0].JobStateInfo.Reason) { $job.ChildJobs[0].JobStateInfo.Reason.Message } else { "job state $($job.State)" }
            throw "Windows failed to install the $Language display pack: $reason"
        }
    } finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

function Get-RegistryKindState($Setting) {
    $state = Get-RegistrySettingState $Setting
    if ($Setting.Id -eq 'windows-copilot' -and $state.Status -eq 'Preferred' -and (Test-CopilotTaskbarPinned)) {
        return New-StateResult 'Partial' "$($state.DisplayText); Copilot app pinned to taskbar"
    }
    return $state
}

function Get-TimeZoneKindState($Setting) { New-StateResultForSetting $Setting (Get-TimeZone).Id }

function Get-RegionKindState($Setting) {
    $locale = try { (Get-ItemProperty -LiteralPath 'HKCU:\Control Panel\International' -Name LocaleName).LocaleName } catch { (Get-Culture).Name }
    $geo = try { [int](Get-WinHomeLocation).GeoId } catch { -1 }
    $display = if ($locale -eq 'en-AU' -and $geo -eq 12) { 'Australia (en-AU)' } else { "$locale (GeoId $geo)" }
    New-StateResultForSetting $Setting $display
}

function Get-LanguageKindState($Setting) {
    $tags = @((Get-WinUserLanguageList).LanguageTag)
    $systemPreferred = try { [string](Get-SystemPreferredUILanguage -ErrorAction Stop) } catch { '' }
    $systemLocale = try { (Get-WinSystemLocale).Name } catch { '' }
    $override = try { (Get-WinUILanguageOverride).Name } catch { '' }
    $uiLanguage = try { (Get-UICulture).Name } catch { '' }
    $displayPack = $uiLanguage -in @('en-AU','en-GB')
    if (-not $displayPack) {
        try { $displayPack = Test-DisplayLanguagePackInstalled 'en-GB' }
        catch { Write-Log 'WARN' "Could not query the en-GB display pack while reading language state: $($_.Exception.Message)"; $displayPack = $false }
    }
    $userReady = $tags.Count -gt 0 -and $tags[0] -eq 'en-AU'
    $committedAustralianUi = -not $override -and $systemPreferred -in @('en-AU','en-GB') -and $uiLanguage -in @('en-AU','en-GB')
    $displayReady = $displayPack -and (($override -eq 'en-AU') -or ($uiLanguage -eq 'en-AU') -or $committedAustralianUi)
    if ($systemLocale -eq 'en-AU' -and $userReady -and $displayReady) { return New-StateResult 'Preferred' 'Australian UI + locale (en-AU)' }
    $parts = New-Object System.Collections.ArrayList
    if (-not $displayPack) { [void]$parts.Add('en-GB display pack not installed') }
    if ($systemPreferred -notin @('en-AU','en-GB') -and $override -ne 'en-AU') { [void]$parts.Add("system UI is $systemPreferred") }
    if ($systemLocale -ne 'en-AU') { [void]$parts.Add("system locale is $systemLocale") }
    if (-not $userReady) { [void]$parts.Add("user languages: $(if ($tags) { $tags -join ', ' } else { 'none' })") }
    if ($displayPack -and $override -ne 'en-AU' -and $uiLanguage -ne 'en-AU') { [void]$parts.Add("user UI is $uiLanguage") }
    New-StateResult 'Partial' ('Partly configured: ' + ($parts -join '; '))
}

function Get-TerminalKindState($Setting) {
    $display = Get-TerminalState
    if ($display -like 'Unavailable*') { return New-StateResult 'Unavailable' $display 'Launch Windows Terminal once, then read settings again.' }
    New-StateResultForSetting $Setting $display
}

function Get-WidgetsKindState($Setting) { New-StateResultForSetting $Setting (Get-WidgetsPackageState) }

function Set-RegistryKindPart($Setting, [string]$DesiredState, [string]$Scope) {
    foreach ($entry in @($Setting.Entries | Where-Object Scope -eq $Scope)) { Set-EntryValue $entry $DesiredState $Setting }
    if ($Scope -eq 'User' -and $Setting.Id -eq 'iso-time') {
        Send-InternationalSettingChange
        $override = try { (Get-WinUILanguageOverride).Name } catch { '' }
        $uiLanguage = try { (Get-UICulture).Name } catch { '' }
        if ($script:LanguageChangePending -or ($override -and $override -ne $uiLanguage)) { Register-InternationalSettingsFinalizer }
    }
    if ($Scope -eq 'User' -and $Setting.Id -eq 'windows-copilot' -and $DesiredState -eq $Setting.PreferredState) { Unpin-CopilotFromTaskbar }
}

function Set-TimeZoneKindPart($Setting, [string]$DesiredState, [string]$Scope) {
    Set-TimeZone -Id 'UTC'
    if ((Get-TimeZone).Id -ne 'UTC') { throw 'Time-zone verification failed.' }
}

function Set-RegionKindPart($Setting, [string]$DesiredState, [string]$Scope) {
    Set-Culture -CultureInfo 'en-AU'
    Set-WinHomeLocation -GeoId 12
    $locale = (Get-ItemProperty -LiteralPath 'HKCU:\Control Panel\International' -Name LocaleName).LocaleName
    if ($locale -ne 'en-AU' -or [int](Get-WinHomeLocation).GeoId -ne 12) { throw 'Region verification failed.' }
}

function Set-LanguageKindPart($Setting, [string]$DesiredState, [string]$Scope) {
    if ($Scope -eq 'User') {
        $list = New-WinUserLanguageList -Language 'en-AU'
        Set-WinUserLanguageList -LanguageList $list -Force
        Set-WinUILanguageOverride -Language 'en-AU'
        $tags = @((Get-WinUserLanguageList).LanguageTag)
        $override = (Get-WinUILanguageOverride).Name
        if ($tags.Count -eq 0 -or $tags[0] -ne 'en-AU' -or $override -ne 'en-AU') { throw 'Australian display-language verification failed.' }
        $script:LanguageChangePending = $true
        if (Test-IsoTimeFormat) { Register-InternationalSettingsFinalizer }
    } else {
        if (-not (Test-DisplayLanguagePackInstalled 'en-GB')) { Install-DisplayLanguagePack 'en-GB' }
        if (-not (Test-DisplayLanguagePackInstalled 'en-GB')) { throw 'The en-GB Windows display pack was not installed.' }
        Set-SystemPreferredUILanguage -Language 'en-AU' -PassThru | Out-Null
        Set-WinSystemLocale -SystemLocale 'en-AU'
        if ((Get-WinSystemLocale).Name -ne 'en-AU') { throw 'Computer-wide Australian locale verification failed.' }
        Write-Log 'INFO' 'The en-AU system UI request was accepted using the installed en-GB base resources; Windows applies and reports it after sign-out or restart.'
    }
}

function Set-TerminalKindPart($Setting, [string]$DesiredState, [string]$Scope) { Set-TerminalState $DesiredState }
function Set-WidgetsKindPart($Setting, [string]$DesiredState, [string]$Scope) { Remove-WidgetsPackages }

function Get-SettingState($Setting) {
    try {
        $handler = Get-SettingHandler $Setting.Kind
        $readCommand = [string]$handler.Read
        $state = & $readCommand $Setting
        # A setting can be written and verified and still do nothing, so carry the
        # caveat with the state rather than reporting an unqualified success.
        $advisory = Get-SettingAdvisory $Setting
        if ($advisory) {
            $state.Details = if ($state.Details) { "$($state.Details) $advisory" } else { $advisory }
        }
        return $state
    }
    catch {
        Write-Log 'WARN' "State read failed [$($Setting.Id)]: $($_.Exception.Message)"
        return New-StateResult 'Error' 'Could not read this setting' $_.Exception.Message
    }
}

function Set-SettingPart($Setting, [string]$DesiredState, [ValidateSet('User','Machine','ElevatedUser')][string]$Scope) {
    if ($DesiredState -notin $Setting.StateOptions) { throw "Invalid desired state '$DesiredState'." }
    if (-not (Test-SettingHasScope $Setting $Scope)) { throw "Setting '$($Setting.Id)' does not support scope '$Scope'." }
    $handler = Get-SettingHandler $Setting.Kind
    $applyCommand = [string]$handler.Apply
    & $applyCommand $Setting $DesiredState $Scope
}

function Write-WorkerResults([System.Collections.IEnumerable]$Results, [string]$Path) {
    $items = @($Results)
    $json = if ($items.Count) { ConvertTo-Json -InputObject $items -Depth 8 } else { '[]' }
    Write-Utf8FileAtomically $Path $json
}

function Invoke-AdministratorPlan([array]$Plan, [array]$AllSettings, [string]$CheckpointPath = '') {
    $results = New-Object System.Collections.ArrayList
    foreach ($request in $Plan) {
        $setting = $AllSettings | Where-Object Id -eq $request.Id | Select-Object -First 1
        if (-not $setting) {
            $unknown = New-ApplyResult ([string]$request.Id) @((New-OperationComponent 'Administrator plan' 'Failed' 'Unknown setting ID.')) 'Unknown setting ID.'
            [void]$results.Add($unknown)
            if ($CheckpointPath) { Write-WorkerResults $results $CheckpointPath }
            continue
        }
        $components = New-Object System.Collections.ArrayList
        Write-Log 'INFO' "ADMINISTRATOR BEGIN [$($setting.Id)] => $($request.DesiredState)"
        foreach ($scope in @('Machine','ElevatedUser')) {
            if (-not (Test-SettingHasScope $setting $scope)) { continue }
            $componentName = if ($scope -eq 'Machine') { 'Whole computer' } else { 'Protected account policy' }
            try {
                Set-SettingPart $setting ([string]$request.DesiredState) $scope
                [void]$components.Add((New-OperationComponent $componentName 'Succeeded' 'Applied and verified.'))
            } catch {
                [void]$components.Add((New-OperationComponent $componentName 'Failed' $_.Exception.Message))
                Write-Log 'ERROR' "ADMINISTRATOR COMPONENT FAILED [$($setting.Id)/$scope] $($_.Exception.ToString())"
            }
        }
        $failedMessages = @($components | Where-Object Outcome -eq 'Failed' | ForEach-Object { "$($_.Name): $($_.Message)" })
        $message = if ($failedMessages) { $failedMessages -join '; ' } else { 'Administrator-required components applied and verified.' }
        $result = New-ApplyResult $setting.Id @($components) $message
        [void]$results.Add($result)
        Write-Log $(if ($result.Success) { 'INFO' } else { 'ERROR' }) "ADMINISTRATOR $($result.Outcome.ToUpperInvariant()) [$($setting.Id)] $message"
        if ($CheckpointPath) { Write-WorkerResults $results $CheckpointPath }
    }
    return ,$results
}

function Start-AdministratorChanges([array]$Selected) {
    $requests = @($Selected | Where-Object RequiresAdmin | ForEach-Object {
        [PSCustomObject]@{ Id=$_.Id; DesiredState=$_.DesiredState }
    })
    if (-not $requests) { return $null }
    $token = [Guid]::NewGuid().ToString('N')
    $planPath = Join-Path $env:TEMP "Dingo-plan-$token.json"
    $resultPath = Join-Path $env:TEMP "Dingo-result-$token.json"
    try {
        Write-Utf8FileAtomically $planPath (ConvertTo-Json -InputObject $requests -Depth 6)
        Write-Utf8FileAtomically $resultPath '[]'
        $desktopSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $argumentText = '-NoProfile -ExecutionPolicy Bypass -STA -File "{0}" -ElevationBroker -PlanPath "{1}" -ResultPath "{2}" -WorkerLogPath "{3}" -TargetUserSid "{4}"' -f $PSCommandPath,$planPath,$resultPath,$script:LogFile,$desktopSid
        $process = Start-Process -FilePath (Get-PowerShellHostPath) -ArgumentList $argumentText -WindowStyle Hidden -PassThru -ErrorAction Stop
        if (-not $process) { throw 'Windows returned no process handle for the elevation broker.' }
        return [PSCustomObject]@{ Process=$process; PlanPath=$planPath; ResultPath=$resultPath; Selected=$Selected; Started=Get-Date; StartError=$null }
    } catch {
        Remove-Item -LiteralPath $planPath,$resultPath -Force -ErrorAction SilentlyContinue
        return [PSCustomObject]@{ Process=$null; PlanPath=$null; ResultPath=$null; Selected=$Selected; Started=Get-Date; StartError="The elevation broker could not start: $($_.Exception.Message)" }
    }
}

function Complete-AdministratorChanges($Operation) {
    $map = @{}
    if (-not $Operation.Process) {
        $map['*'] = New-ApplyResult '*' @((New-OperationComponent 'Administrator broker' 'Failed' $Operation.StartError)) $Operation.StartError
        return $map
    }
    try {
        $Operation.Process.WaitForExit()
        $resultJson = Get-Content -LiteralPath $Operation.ResultPath -Raw
        Write-Log 'DEBUG' "Administrator worker exit code $($Operation.Process.ExitCode); result: $resultJson"
        $results = @(ConvertFrom-JsonList $resultJson)
        foreach ($result in $results) { $map[[string]$result.Id] = $result }
        if (-not $results) {
            $message = "Administrator step returned no results (exit code $($Operation.Process.ExitCode)). See the log for worker diagnostics."
            $map['*'] = New-ApplyResult '*' @((New-OperationComponent 'Administrator worker' 'Failed' $message)) $message
        } elseif ($Operation.Process.ExitCode -ne 0 -and -not $map.ContainsKey('*')) {
            $message = "Administrator step exited with code $($Operation.Process.ExitCode)."
            $map['*'] = New-ApplyResult '*' @((New-OperationComponent 'Administrator worker' 'Failed' $message)) $message
        }
    } catch {
        $message = "Could not read the administrator result: $($_.Exception.Message)"
        $map['*'] = New-ApplyResult '*' @((New-OperationComponent 'Administrator result' 'Failed' $message)) $message
    } finally {
        Remove-Item -LiteralPath $Operation.PlanPath,$Operation.ResultPath -Force -ErrorAction SilentlyContinue
    }
    return $map
}

function Invoke-SettingChange($Item, [hashtable]$AdministratorResults) {
    $components = New-Object System.Collections.ArrayList
    try {
        if ($Item.RequiresAdmin) {
            $administratorResult = if ($AdministratorResults.ContainsKey($Item.Id)) { $AdministratorResults[$Item.Id] } else { $AdministratorResults['*'] }
            if (-not $administratorResult -or -not [bool]$administratorResult.Success) {
                $reason = if ($administratorResult) { $administratorResult.Message } else { 'The administrator step returned no answer.' }
                if ($administratorResult -and $administratorResult.Components) {
                    foreach ($component in @($administratorResult.Components)) { [void]$components.Add($component) }
                } else {
                    [void]$components.Add((New-OperationComponent 'Administrator-required part' 'Failed' $reason))
                }
                throw "Administrator-required part failed: $reason"
            }
            foreach ($component in @($administratorResult.Components)) { [void]$components.Add($component) }
        }
        if (Test-SettingHasScope $Item User) {
            try {
                Set-SettingPart $Item $Item.DesiredState User
                [void]$components.Add((New-OperationComponent 'Signed-in account' 'Succeeded' 'Applied.'))
            } catch {
                [void]$components.Add((New-OperationComponent 'Signed-in account' 'Failed' $_.Exception.Message))
                throw
            }
        }
        $Item.CurrentState = Get-SettingState $Item
        $expectedStatus = if ($Item.DesiredState -eq $Item.PreferredState) { 'Preferred' } else { 'Alternate' }
        if ($Item.CurrentState.Status -ne $expectedStatus) {
            $reason = if ($Item.CurrentState.Status -eq 'Error') { "$($Item.CurrentState.DisplayText): $($Item.CurrentState.Details)" } else { $Item.CurrentState.DisplayText }
            [void]$components.Add((New-OperationComponent 'Final verification' 'Failed' "Windows reports '$reason'."))
            throw "Windows still reports '$reason' instead of '$($Item.DesiredState)'."
        }
        [void]$components.Add((New-OperationComponent 'Final verification' 'Succeeded' "Windows reports '$($Item.CurrentState.DisplayText)'."))
        # The write succeeded, so the outcome and the exit code stay successful.
        # Only the operator-facing wording changes when a caveat applies.
        $advisory = Get-SettingAdvisory $Item
        $message = if ($advisory) { "Applied and verified. $advisory" } else { 'Applied and verified.' }
        $result = New-ApplyResult $Item.Id @($components) $message $Item.RestartExplorer $Item.RestartRequired
        $Item.LastApplyResult = $result
        $Item.Status = if ($advisory) { 'Applied with caveat' } else { 'Succeeded' }
        $Item.Details = if ($advisory) { "Written, but Edge ignores it here. $advisory" } else { "Now set to: $($Item.CurrentState.DisplayText)" }
        Write-Log $(if ($advisory) { 'WARN' } else { 'INFO' }) "SUCCESS [$($Item.Id)] => $($Item.CurrentState.DisplayText)$(if ($advisory) { " (caveat: $advisory)" })"
        return $result
    } catch {
        $message = $_.Exception.Message
        if (-not ($components | Where-Object Outcome -eq 'Failed')) {
            [void]$components.Add((New-OperationComponent 'Application' 'Failed' $message))
        }
        $Item.CurrentState = Get-SettingState $Item
        $result = New-ApplyResult $Item.Id @($components) $message $Item.RestartExplorer $Item.RestartRequired
        $Item.LastApplyResult = $result
        $Item.Status = if ($result.Outcome -eq 'PartiallyApplied') { 'Partially applied' } else { 'Failed' }
        $Item.Details = $message
        if ($result.Outcome -eq 'PartiallyApplied') {
            Write-Log 'WARN' "PARTIALLY APPLIED [$($Item.Id)] $message"
        } else {
            Write-Log 'ERROR' "FAILED [$($Item.Id)] $message"
        }
        return $result
    }
}

function Resolve-QuickApplySettings {
    param([array]$AllSettings, [string[]]$IncludeIds, [string[]]$ExcludeIds)
    $known = @{}
    foreach ($setting in $AllSettings) { $known[([string]$setting.Id).ToLowerInvariant()] = $setting }
    $normalise = {
        param([string[]]$Values)
        @($Values | ForEach-Object { @([string]$_ -split ',') } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
    }
    $includeKeys = @(& $normalise $IncludeIds)
    $excludeKeys = @(& $normalise $ExcludeIds)
    $unknown = @($includeKeys + $excludeKeys | Where-Object { -not $known.ContainsKey($_) } | Select-Object -Unique)
    if ($unknown) { throw "Unknown setting ID$(if ($unknown.Count -eq 1) { '' } else { 's' }): $($unknown -join ', ')." }
    $selected = if ($includeKeys) {
        @($AllSettings | Where-Object { ([string]$_.Id).ToLowerInvariant() -in $includeKeys })
    } else {
        @($AllSettings)
    }
    if ($excludeKeys) { $selected = @($selected | Where-Object { ([string]$_.Id).ToLowerInvariant() -notin $excludeKeys }) }
    return $selected
}

function Restart-DesktopExplorer {
    try {
        Stop-Process -Name explorer -Force -ErrorAction Stop
        Start-Sleep -Milliseconds 700
        if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
        Write-Log 'INFO' 'File Explorer restarted for the desktop user.'
        return $true
    } catch {
        Write-Log 'WARN' "File Explorer restart failed: $($_.Exception.Message)"
        return $false
    }
}

function Write-CliStatus([string]$Message) {
    if ($OutputFormat -eq 'Text') { [Console]::Out.WriteLine($Message) }
}

function Get-DingoHelpText {
@'
Dingo - Windows 11 preferences

GUI:
  Start-Dingo.cmd

Quick apply:
  Start-Dingo.cmd -WhatIf [-Include id1,id2] [-Exclude id3] [-OutputFormat Text|Json]
  Start-Dingo.cmd -ApplyPreferred [-Include id1,id2] [-Exclude id3] [-NoRestartExplorer] [-OutputFormat Text|Json]

Discovery:
  Start-Dingo.cmd -ListSettings [-OutputFormat Text|Json]
  Start-Dingo.cmd -Version
  Start-Dingo.cmd -Help

Tools:
  Analyst tools appear on the Tools tab and use IDs that start with 'tool-'.
  Dingo installs them with winget and never uninstalls them.
  Add your own by placing a Tools.json file next to Dingo.ps1. See the README.

Exit codes: 0 success, 1 partial/failed application, 2 invalid command/environment, 3 already running.
'@
}

function Write-CliErrorResponse([string]$Message, [int]$ExitCode, [string]$Mode = 'Command') {
    if ($OutputFormat -eq 'Json') {
        [Console]::Out.WriteLine((ConvertTo-Json -InputObject ([PSCustomObject]@{
            Version=$script:DingoVersion; Mode=$Mode; Success=$false; ExitCode=$ExitCode; Error=$Message
        }) -Depth 5))
    } else {
        [Console]::Error.WriteLine($Message)
    }
}

function Register-SettingHandler {
    param(
        [string]$Kind,
        [scriptblock]$GetScopes,
        [string]$ReadCommand,
        [string]$ApplyCommand,
        [hashtable]$RequiredCommands = @{}
    )
    if ([string]::IsNullOrWhiteSpace($Kind) -or -not $GetScopes -or -not $ReadCommand -or -not $ApplyCommand) { throw 'A setting handler is incomplete.' }
    if ($script:SettingHandlers.ContainsKey($Kind)) { throw "A setting handler named '$Kind' is already registered." }
    foreach ($command in @($ReadCommand,$ApplyCommand)) {
        if (-not (Get-Command $command -CommandType Function -ErrorAction SilentlyContinue)) { throw "Setting handler '$Kind' references unavailable function '$command'." }
    }
    $script:SettingHandlers[$Kind] = [PSCustomObject]@{
        Kind=$Kind; GetScopes=$GetScopes; Read=$ReadCommand; Apply=$ApplyCommand; RequiredCommands=$RequiredCommands
    }
}

function Get-SettingHandler([string]$Kind) {
    if (-not $script:SettingHandlers.ContainsKey($Kind)) { throw "No setting handler is registered for kind '$Kind'." }
    return $script:SettingHandlers[$Kind]
}

function Initialize-SettingHandlers {
    Register-SettingHandler 'Registry' { param($entries) @($entries | Select-Object -ExpandProperty Scope -Unique) } 'Get-RegistryKindState' 'Set-RegistryKindPart'
    Register-SettingHandler 'TimeZone' { param($entries) @('Machine') } 'Get-TimeZoneKindState' 'Set-TimeZoneKindPart' @{ Machine=@('Get-TimeZone','Set-TimeZone') }
    Register-SettingHandler 'Region' { param($entries) @('User') } 'Get-RegionKindState' 'Set-RegionKindPart' @{ User=@('Get-Culture','Set-Culture','Get-WinHomeLocation','Set-WinHomeLocation') }
    Register-SettingHandler 'Language' { param($entries) @('User','Machine') } 'Get-LanguageKindState' 'Set-LanguageKindPart' @{
        User=@('Get-WinUserLanguageList','New-WinUserLanguageList','Set-WinUserLanguageList','Get-WinUILanguageOverride','Set-WinUILanguageOverride')
        Machine=@('Get-WinSystemLocale','Set-WinSystemLocale','Get-SystemPreferredUILanguage','Set-SystemPreferredUILanguage','Get-InstalledLanguage','Install-Language')
    }
    # A machine-scope package needs the elevated worker; a per-user package must
    # stay in the signed-in account so it lands in the right profile.
    Register-SettingHandler 'Package' {
        param($entries)
        $tool = @($entries)[0]
        @(if ($tool -and $tool.Scope -eq 'user') { 'User' } else { 'Machine' })
    } 'Get-PackageKindState' 'Set-PackageKindPart'
    Register-SettingHandler 'ToolPath' { param($entries) @('Machine') } 'Get-ToolPathKindState' 'Set-ToolPathKindPart'
    Register-SettingHandler 'Shortcut' { param($entries) @('Machine') } 'Get-ShortcutKindState' 'Set-ShortcutKindPart'
    Register-SettingHandler 'Terminal' { param($entries) @('User') } 'Get-TerminalKindState' 'Set-TerminalKindPart'
    Register-SettingHandler 'WidgetsPackage' { param($entries) @('User') } 'Get-WidgetsKindState' 'Set-WidgetsKindPart' @{ User=@('Get-AppxPackage','Remove-AppxPackage') }
}

function Test-SettingPreflight($Setting) {
    $problems = New-Object System.Collections.ArrayList
    try {
        $handler = Get-SettingHandler $Setting.Kind
        foreach ($scope in @(& $handler.GetScopes $Setting.Entries)) {
            foreach ($command in @($handler.RequiredCommands[$scope])) {
                if ($command -and -not (Get-Command $command -ErrorAction SilentlyContinue)) { [void]$problems.Add("$scope requires unavailable command '$command'") }
            }
        }
        if ($Setting.Requirements.ContainsKey('RequiredCommands')) {
            foreach ($command in @($Setting.Requirements['RequiredCommands'])) {
                if ($command -and -not (Get-Command $command -ErrorAction SilentlyContinue)) { [void]$problems.Add("requires unavailable command '$command'") }
            }
        }
        if ($Setting.Requirements.ContainsKey('WingetRequired') -and [bool]$Setting.Requirements['WingetRequired']) {
            if ($Setting.CurrentState.Status -ne 'Preferred' -and -not (Get-WingetPath)) {
                [void]$problems.Add('winget is not available, so this tool cannot be installed')
            }
        }
        if ($Setting.Requirements.ContainsKey('Editions')) {
            $supportedEditions = @($Setting.Requirements['Editions'])
            try { $edition = [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name EditionID -ErrorAction Stop).EditionID }
            catch { [void]$problems.Add("could not determine the Windows edition: $($_.Exception.Message)"); $edition = '' }
            if ($edition -and $edition -notin $supportedEditions) { [void]$problems.Add("Windows edition '$edition' is not supported") }
        }
        if ($Setting.Requirements.ContainsKey('MinimumBuild')) {
            $minimumBuild = [int]$Setting.Requirements['MinimumBuild']
            $build = [Environment]::OSVersion.Version.Build
            if ($build -lt $minimumBuild) { [void]$problems.Add("requires Windows build $minimumBuild or later (current build $build)") }
        }
        if ($Setting.CurrentState.Status -in @('Unknown','Error','Unavailable')) {
            $Setting.CurrentState = Get-SettingState $Setting
        }
        if ($Setting.CurrentState.Status -in @('Error','Unavailable')) {
            $detail = if ($Setting.CurrentState.Details) { $Setting.CurrentState.Details } else { $Setting.CurrentState.DisplayText }
            [void]$problems.Add("current state is not safely actionable: $detail")
        }
    } catch {
        [void]$problems.Add($_.Exception.Message)
    }
    [PSCustomObject]@{ Id=$Setting.Id; Available=($problems.Count -eq 0); Message=($problems -join '; ') }
}

function Test-PlanPreflight([array]$Selected) {
    return @($Selected | ForEach-Object { Test-SettingPreflight $_ })
}

Initialize-SettingHandlers
$script:Settings = Get-Settings
# The GUI shows this on the Tools tab. Command-line runs have no tab, so say it here.
if ($script:ToolCatalogWarning -and -not $WpfHost) { [Console]::Error.WriteLine($script:ToolCatalogWarning) }

$unexpectedValues = @($script:UnexpectedArguments)
if ($unexpectedValues.Count) {
    $unexpectedText = @($unexpectedValues | ForEach-Object { "'$_'" }) -join ', '
    $message = "Unrecognised command-line option or argument: $unexpectedText"
    if ($OutputFormat -eq 'Json') {
        [Console]::Out.WriteLine((ConvertTo-Json -InputObject ([PSCustomObject]@{
            Version=$script:DingoVersion; Mode='Command'; Success=$false; ExitCode=2; Error=$message; Help=(Get-DingoHelpText)
        }) -Depth 5))
    } else {
        [Console]::Out.WriteLine($message)
        [Console]::Out.WriteLine('')
        [Console]::Out.WriteLine((Get-DingoHelpText))
    }
    exit 2
}

if ($Help) {
    [Console]::Out.WriteLine((Get-DingoHelpText))
    exit 0
}

if ($Version) { [Console]::Out.WriteLine("Dingo $script:DingoVersion"); exit 0 }

if ($ListSettings) {
    $catalog = @($script:Settings | ForEach-Object {
        [PSCustomObject]@{ Id=$_.Id; Name=$_.Name; Category=$_.Category; Kind=$_.Kind; Scope=$_.DisplayScope; RequiresAdmin=$_.RequiresAdmin; PreferredState=$_.PreferredState; Requirements=$_.Requirements }
    })
    if ($OutputFormat -eq 'Json') { [Console]::Out.WriteLine((ConvertTo-Json -InputObject $catalog -Depth 5)) }
    else { [Console]::Out.WriteLine(($catalog | Format-Table -AutoSize | Out-String -Width 220).TrimEnd()) }
    exit 0
}

if ($ElevationBroker) {
    try {
        $workerArguments = '-NoProfile -ExecutionPolicy Bypass -STA -File "{0}" -MachineWorker -PlanPath "{1}" -ResultPath "{2}" -WorkerLogPath "{3}" -TargetUserSid "{4}"' -f $PSCommandPath,$PlanPath,$ResultPath,$WorkerLogPath,$TargetUserSid
        $workerProcess = Start-Process -FilePath (Get-PowerShellHostPath) -ArgumentList $workerArguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop
        if (-not $workerProcess) { throw 'Windows returned no process handle after administrator approval.' }
        exit $workerProcess.ExitCode
    } catch {
        $message = "Administrator approval was cancelled or failed: $($_.Exception.Message)"
        Write-WorkerResults @((New-ApplyResult '*' @((New-OperationComponent 'Administrator approval' 'Failed' $message)) $message)) $ResultPath
        exit 1
    }
}

if ($FinalizeInternationalSettings) {
    $script:LogFile = $WorkerLogPath
    try {
        # A pending display-language change is committed while the user profile is
        # initialising. Apply custom formats afterwards so that commit cannot reset them.
        Start-Sleep -Seconds 3
        $isoSetting = Get-IsoTimeSetting
        foreach ($entry in $isoSetting.Entries) { Set-EntryValue $entry $isoSetting.PreferredState $isoSetting }
        Send-InternationalSettingChange
        Write-Log 'INFO' 'One-time sign-in finalizer reapplied and verified the ISO date/time formats.'
        exit 0
    } catch {
        Write-Log 'ERROR' "One-time sign-in finalizer failed: $($_.Exception.ToString())"
        exit 1
    }
}

if ($SelfTest) {
    # Tools.json may add tools, so the total is the fixed settings plus the catalog.
    $expectedSettingCount = 30 + @(Get-ToolCatalog).Count
    if ($script:Settings.Count -ne $expectedSettingCount) { throw "Expected $expectedSettingCount settings, found $($script:Settings.Count)." }
    foreach ($workerHelper in @('Test-DisplayLanguagePackInstalled','Install-DisplayLanguagePack','Write-Utf8FileAtomically','New-ApplyResult','New-OperationComponent')) {
        if (-not (Get-Command $workerHelper -CommandType Function -ErrorAction SilentlyContinue)) { throw "Elevated-worker helper is unavailable: $workerHelper" }
    }
    $selfTestTokens = $null; $selfTestErrors = $null
    $selfTestAst = [Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$selfTestTokens,[ref]$selfTestErrors)
    if ($selfTestAst.Extent.Text -notmatch 'CmdletBinding\s*\(\s*PositionalBinding\s*=\s*\$false\s*\)' -or $selfTestAst.Extent.Text -notmatch 'ValueFromRemainingArguments\s*=\s*\$true') {
        throw 'Command-line parsing must reject stray positional and unknown arguments through the Dingo help path.'
    }
    if ((Get-DingoHelpText) -notmatch '-ApplyPreferred' -or (Get-DingoHelpText) -notmatch '-ListSettings') { throw 'The command-line help text is incomplete.' }
    $launcherAst = $selfTestAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-AdministratorChanges' },$true)
    $launcherStart = if ($launcherAst) { $launcherAst.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Start-Process' },$true) } else { $null }
    if (-not $launcherStart) { throw 'The asynchronous elevated-worker launcher does not start a process.' }
    if ($launcherAst.Extent.Text -notmatch '-ElevationBroker' -or $launcherAst.Extent.Text -match '-Verb\s+RunAs') { throw 'The WPF launcher must delegate UAC to the non-WPF elevation broker.' }
    $duplicates = $script:Settings | Group-Object Id | Where-Object Count -gt 1
    if ($duplicates) { throw "Duplicate IDs: $($duplicates.Name -join ', ')" }
    if ($script:SettingHandlers.Count -ne 9) { throw "Expected 9 setting handlers, found $($script:SettingHandlers.Count)." }
    foreach ($setting in $script:Settings) { [void](Get-SettingHandler $setting.Kind) }
    foreach ($dispatcherName in @('Get-SettingState','Set-SettingPart')) {
        $dispatcherAst = $selfTestAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $dispatcherName },$true)
        if (-not $dispatcherAst -or $dispatcherAst.Extent.Text -match '\bswitch\s*\(') { throw "The $dispatcherName dispatcher is not using the handler registry." }
    }
    if ($script:Settings | Where-Object { $_.DesiredState -notin $_.StateOptions }) { throw 'A desired state is absent from its options.' }
    if ($script:Settings | Where-Object { $_.CurrentState.Status -ne 'Unknown' -or -not $_.CurrentState.DisplayText }) { throw 'A setting has an invalid initial structured state.' }
    $stateContract = New-StateResult 'Error' 'Could not read this setting' 'test error'
    if ($stateContract.Status -ne 'Error' -or $stateContract.Details -ne 'test error') { throw 'The structured state contract is invalid.' }
    $partialContract = New-ApplyResult 'contract-test' @(
        (New-OperationComponent 'first' 'Succeeded' 'ok'),
        (New-OperationComponent 'second' 'Failed' 'test failure')
    ) 'test'
    if ($partialContract.Outcome -ne 'PartiallyApplied' -or $partialContract.Success -or $partialContract.Components.Count -ne 2) { throw 'The structured apply-result contract is invalid.' }
    $bingSetting = $script:Settings | Where-Object Id -eq 'start-bing'
    if ($bingSetting.DisplayScope -ne 'User' -or -not $bingSetting.RequiresAdmin) { throw 'Bing search must remain an account setting while requesting elevation for its protected policy value.' }
    $widgetsSetting = $script:Settings | Where-Object Id -eq 'widgets'
    if ($widgetsSetting.DisplayScope -ne 'User' -or $widgetsSetting.RequiresAdmin -or -not (Test-SettingHasScope $widgetsSetting 'User')) {
        throw 'Widgets must remain a current-account setting that does not request administrator approval.'
    }
    $preflightMock = $widgetsSetting.PSObject.Copy()
    $preflightMock.Requirements = @{ RequiredCommands=@('Dingo-Definitely-Missing-Command') }
    $preflightResult = Test-SettingPreflight $preflightMock
    if ($preflightResult.Available -or $preflightResult.Message -notmatch 'Dingo-Definitely-Missing-Command') { throw 'Preflight did not reject an unavailable required command.' }
    $quickSelection = @(Resolve-QuickApplySettings $script:Settings @('WIDGETS,timezone-utc') @('timezone-utc'))
    if ($quickSelection.Count -ne 1 -or $quickSelection[0].Id -ne 'widgets') { throw 'Quick-apply include/exclude filtering is invalid.' }
    $unknownRejected = $false
    try { [void](Resolve-QuickApplySettings $script:Settings @('not-a-setting') @()) } catch { $unknownRejected = $true }
    if (-not $unknownRejected) { throw 'Quick apply did not reject an unknown setting ID.' }
    $guiApplyAst = $selfTestAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Complete-ApplyChanges' },$true)
    $sharedApplyCall = if ($guiApplyAst) { $guiApplyAst.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-SettingChange' },$true) } else { $null }
    if (-not $sharedApplyCall) { throw 'The GUI is not using the shared setting-application core.' }
    # Every self-test must stay runnable where all processes are elevated, such as
    # Windows Sandbox. Only the real GUI is refused there.
    # Match on the condition, not the body. Searching the body would find this
    # self-test block itself, because the message text appears here too.
    $allConditions = @($selfTestAst.FindAll({ param($node) $node -is [Management.Automation.Language.IfStatementAst] },$true) |
        ForEach-Object { $_.Clauses[0].Item1.Extent.Text })
    $guardCondition = @($allConditions | Where-Object { $_ -match 'Test-IsAdministrator' -and $_ -match 'UiSelfTest' })
    if ($guardCondition.Count -ne 1 -or $guardCondition[0] -notmatch '-not\s+\$UiSelfTest') {
        throw 'The elevated-start guard must let the UI self-test through.'
    }
    # A dry run makes no changes, so it must stay usable where every process is
    # elevated. Only real changes are refused there.
    $dryRunGuard = @($allConditions | Where-Object { $_ -match 'Test-IsAdministrator' -and $_ -match 'WhatIf' })
    if ($dryRunGuard.Count -ne 1 -or $dryRunGuard[0] -notmatch '-not\s+\$WhatIf') {
        throw 'The elevated-start guard must let a dry run through.'
    }
    $launcherPath = Join-Path $PSScriptRoot 'Start-Dingo.cmd'
    if (-not (Test-Path -LiteralPath $launcherPath) -or (Get-Content -LiteralPath $launcherPath -Raw) -notmatch '%\*') { throw 'Start-Dingo.cmd does not forward command-line arguments.' }
    $updateSetting = $script:Settings | Where-Object Id -eq 'windows-update-continuity'
    $requiredUpdatePolicies = @{
        NoAutoUpdate=1; NoAutoRebootWithLoggedOnUsers=1
        SetComplianceDeadlineForQU=0; SetComplianceDeadlineForFU=0
        SetUpdateNotificationLevel=1; UpdateNotificationLevel=2
        NoUpdateNotificationsDuringActiveHours=0
    }
    if (-not $updateSetting -or $updateSetting.DisplayScope -ne 'System' -or -not $updateSetting.RequiresAdmin) { throw 'The forensic-continuity setting must be a computer-wide policy that requests elevation.' }
    if (-not @($updateSetting.Requirements.Editions).Count) { throw 'The forensic-continuity setting must declare its supported Windows editions.' }
    foreach ($policyName in $requiredUpdatePolicies.Keys) {
        $entry = $updateSetting.Entries | Where-Object Name -eq $policyName | Select-Object -First 1
        if (-not $entry -or $entry.Scope -ne 'Machine' -or [int]$entry.Preferred -ne [int]$requiredUpdatePolicies[$policyName] -or $entry.Alternate -ne $script:RemoveValue) {
            throw "The forensic-continuity policy '$policyName' is absent, weakened, or not reversible."
        }
    }
    $protocolPath = Join-Path $env:TEMP ("Dingo-protocol-test-{0}.json" -f [Guid]::NewGuid().ToString('N'))
    $atomicPath = Join-Path $env:TEMP ("Dingo-atomic-test-{0}.txt" -f [Guid]::NewGuid().ToString('N'))
    $atomicBackup = "$atomicPath.backup"
    try {
        Write-Utf8FileAtomically $atomicPath 'before'
        Write-Utf8FileAtomically $atomicPath 'after' $atomicBackup
        if ((Get-Content -LiteralPath $atomicPath -Raw) -ne 'after' -or (Get-Content -LiteralPath $atomicBackup -Raw) -ne 'before') { throw 'Atomic replacement or backup verification failed.' }
        [IO.File]::WriteAllText($protocolPath, 'stale', (New-Object Text.UTF8Encoding($false)))
        Write-WorkerResults @(
            (New-ApplyResult 'one' @((New-OperationComponent 'Whole computer' 'Succeeded' 'ok')) 'ok'),
            $partialContract
        ) $protocolPath
        $protocolResults = @(ConvertFrom-JsonList (Get-Content -LiteralPath $protocolPath -Raw))
        if ($protocolResults.Count -ne 2) { throw "The multi-setting administrator result protocol returned $($protocolResults.Count) result(s): $(Get-Content -LiteralPath $protocolPath -Raw)" }
        if ($protocolResults[1].Outcome -ne 'PartiallyApplied' -or @($protocolResults[1].Components).Count -ne 2) { throw 'The administrator protocol did not preserve structured component results.' }
    } finally {
        Remove-Item -LiteralPath $protocolPath,$atomicPath,$atomicBackup -Force -ErrorAction SilentlyContinue
    }
    # Windows Terminal ships JSONC. Windows PowerShell 5.1 rejects comments and
    # trailing commas, so prove the tolerant reader handles them without damaging
    # the // inside a URL or an escaped quote inside a string.
    $jsonCases = @(
        @{ Name='line comment'; Text=("{`n // note`n `"a`": 1 }"); Check={ param($o) $o.a -eq 1 } },
        @{ Name='block comment'; Text='{ /* note */ "a": 1 }'; Check={ param($o) $o.a -eq 1 } },
        @{ Name='trailing comma in object'; Text='{ "a": 1, }'; Check={ param($o) $o.a -eq 1 } },
        @{ Name='trailing comma in array'; Text='{ "a": [1,2,] }'; Check={ param($o) $o.a.Count -eq 2 } },
        @{ Name='url is not a comment'; Text='{ "a": "https://aka.ms/x" }'; Check={ param($o) $o.a -eq 'https://aka.ms/x' } },
        @{ Name='escaped quote is not a delimiter'; Text='{ "a": "say \"//\" here", "b": 2 }'; Check={ param($o) $o.b -eq 2 -and $o.a -eq 'say "//" here' } },
        @{ Name='comment marker inside a string survives'; Text='{ "a": "/* keep */" }'; Check={ param($o) $o.a -eq '/* keep */' } }
    )
    foreach ($jsonCase in $jsonCases) {
        $decoded = try { ConvertTo-StrictJson $jsonCase.Text | ConvertFrom-Json -ErrorAction Stop } catch { throw "JSONC case '$($jsonCase.Name)' did not parse: $($_.Exception.Message)" }
        if (-not (& $jsonCase.Check $decoded)) { throw "JSONC case '$($jsonCase.Name)' parsed to the wrong value." }
    }
    $keepTestDirectory = Join-Path $env:TEMP ("Dingo-keep-test-{0}" -f [Guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $keepTestDirectory -Force | Out-Null
        foreach ($ordinal in 1..5) {
            $keepTestFile = Join-Path $keepTestDirectory "sample$ordinal.log"
            [IO.File]::WriteAllText($keepTestFile, 'x', (New-Object Text.UTF8Encoding($false)))
            [IO.File]::SetLastWriteTime($keepTestFile, (Get-Date).AddMinutes(-$ordinal))
        }
        Remove-SupersededFiles $keepTestDirectory '*.log' 2
        $kept = @(Get-ChildItem -LiteralPath $keepTestDirectory -Filter '*.log' -File | Select-Object -ExpandProperty Name | Sort-Object)
        if ($kept.Count -ne 2 -or $kept[0] -ne 'sample1.log' -or $kept[1] -ne 'sample2.log') {
            throw "File retention kept the wrong set: $($kept -join ', ')"
        }
    } finally {
        Remove-Item -LiteralPath $keepTestDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ((Get-Command Remove-WidgetsPackages).Definition -match "Get-Process[^`n]*\*Widget\*") { throw 'Widgets process termination must not use a wildcard name match.' }
    # The Edge search setting must use ManagedSearchEngines, which is not a
    # protected policy, and must clear the protected DefaultSearchProvider*
    # values because they suppress it.
    $searchSetting = $script:Settings | Where-Object Id -eq 'edge-search-engines' | Select-Object -First 1
    if (-not $searchSetting) { throw 'The Edge search-engines setting is missing.' }
    $managedEntry = $searchSetting.Entries | Where-Object Name -eq 'ManagedSearchEngines' | Select-Object -First 1
    if (-not $managedEntry -or $managedEntry.Path -notmatch '\\Recommended$') {
        throw 'ManagedSearchEngines must be written to the Recommended key so an analyst can still change engines.'
    }
    $engineList = $managedEntry.Preferred | ConvertFrom-Json -ErrorAction Stop
    $engineNames = @($engineList | ForEach-Object { [string]$_.name })
    if ($engineNames -notcontains 'Google' -or $engineNames -notcontains 'DuckDuckGo') { throw 'The engine list must offer Google and DuckDuckGo.' }
    if ($engineNames -contains 'Bing') { throw 'Bing must not appear in the engine list.' }
    # Edge rejects the whole policy if a non-default entry carries is_default.
    $defaultEntries = @($engineList | Where-Object { $_.PSObject.Properties['is_default'] })
    if ($defaultEntries.Count -ne 1 -or -not $defaultEntries[0].is_default -or $defaultEntries[0].name -ne 'Google') {
        throw 'Exactly one engine may carry is_default, it must be true, and it must be Google.'
    }
    foreach ($suppressor in @('DefaultSearchProviderEnabled','DefaultSearchProviderSearchURL')) {
        $entry = $searchSetting.Entries | Where-Object Name -eq $suppressor | Select-Object -First 1
        if (-not $entry -or $entry.Preferred -ne $script:RemoveValue) {
            throw "'$suppressor' must be removed by the preferred state; it suppresses ManagedSearchEngines."
        }
    }
    # The Edge debloat setting must be fully reversible and must include the
    # three NewTabPage values, which are the ones that remove the news feed,
    # weather, and background images.
    $debloatSetting = $script:Settings | Where-Object Id -eq 'edge-debloat' | Select-Object -First 1
    if (-not $debloatSetting) { throw 'The Edge debloat setting is missing.' }
    $requiredDebloat = @{
        NewTabPageContentEnabled=0; NewTabPageAllowedBackgroundTypes=3; NewTabPageQuickLinksEnabled=0
        EdgeCollectionsEnabled=0; EdgeShoppingAssistantEnabled=0; ShowMicrosoftRewards=0
        WalletDonationEnabled=0; MicrosoftEdgeInsiderPromotionEnabled=0; DefaultBrowserSettingsCampaignEnabled=0
        WebWidgetAllowed=0; UserFeedbackAllowed=0; AlternateErrorPagesEnabled=0
        EdgeAssetDeliveryServiceEnabled=0; DiagnosticData=0; ConfigureDoNotTrack=1
        CreateDesktopShortcutDefault=0
    }
    foreach ($valueName in $requiredDebloat.Keys) {
        $entry = $debloatSetting.Entries | Where-Object Name -eq $valueName | Select-Object -First 1
        if (-not $entry) { throw "The Edge debloat setting is missing '$valueName'." }
        if ([int]$entry.Preferred -ne [int]$requiredDebloat[$valueName]) { throw "'$valueName' has the wrong preferred value." }
    }
    if (-not ($debloatSetting.Entries | Where-Object { $_.Path -match 'ExtensionInstallBlocklist$' })) {
        throw 'The Edge debloat setting must block the Copilot Discover Chat extension.'
    }
    # Every entry must be removable, or the setting could not be undone.
    foreach ($entry in $debloatSetting.Entries) {
        if ($entry.Alternate -ne $script:RemoveValue) { throw "Debloat entry '$($entry.Name)' is not reversible." }
        if ($entry.Scope -ne 'Machine') { throw "Debloat entry '$($entry.Name)' must be a computer-wide policy." }
    }
    if (-not $debloatSetting.CanChoose) { throw 'The Edge debloat setting must be reversible from the card.' }

    # The advisory machinery stays available for future settings even though no
    # shipped setting needs it now, so prove it still works with a stand-in.
    $savedManagedState = $script:DeviceIsManaged
    try {
        $advisoryMock = $searchSetting.PSObject.Copy()
        $advisoryMock.Requirements = @{ ManagedDevice=$true }
        $script:DeviceIsManaged = $false
        if ((Get-SettingAdvisory $advisoryMock) -notmatch 'ignores it') { throw 'An unmanaged device must produce a caveat.' }
        if (-not (Test-SettingPreflight $advisoryMock).Available) { throw 'A caveat must never fail preflight.' }
        $script:DeviceIsManaged = $true
        if (Get-SettingAdvisory $advisoryMock) { throw 'A managed device must produce no caveat.' }
        $script:DeviceIsManaged = $false
        # A tool caveat depends on what this machine has installed, so those are
        # checked separately below rather than asserted to be absent.
        foreach ($shipped in @($script:Settings | Where-Object { -not $_.Requirements.ContainsKey('RequiredTools') -or -not @($_.Requirements['RequiredTools']).Count })) {
            if (Get-SettingAdvisory $shipped) { throw "Setting '$($shipped.Id)' carries an unexpected caveat." }
        }
        # A tool that needs another tool must say so when that one is absent, and
        # must stay silent when it is present. Neither may fail preflight.
        $dependentMock = ($script:Settings | Where-Object Id -eq 'tool-eztools' | Select-Object -First 1).PSObject.Copy()
        $dependentMock.Requirements = @{ RequiredTools = @('tool-definitely-not-in-the-catalog') }
        if ((Get-SettingAdvisory $dependentMock) -notmatch 'will not start') { throw 'A tool with a missing dependency must produce a caveat.' }
        if (-not (Test-SettingPreflight $dependentMock).Available) { throw 'A dependency caveat must never fail preflight.' }
        $dependentMock.Requirements = @{ RequiredTools = @() }
        if (Get-SettingAdvisory $dependentMock) { throw 'A tool with no dependencies must produce no caveat.' }
        $ezRequires = @(($script:Settings | Where-Object Id -eq 'tool-eztools' | Select-Object -First 1).Requirements['RequiredTools'])
        if ($ezRequires -notcontains 'tool-dotnet-desktop-9') { throw "Eric Zimmerman's tools must declare the .NET runtime they need." }
    } finally {
        $script:DeviceIsManaged = $savedManagedState
    }
    # Tool cards are one-way on purpose: Dingo installs, and never uninstalls.
    $builtInTools = @(Get-BuiltInToolCatalog | ForEach-Object { ConvertTo-ToolDefinition $_ })
    foreach ($expectedId in @('tool-7zip','tool-notepadplusplus','tool-ripgrep','tool-sqlitebrowser','tool-eztools','tool-dotnet-desktop-9')) {
        if (@($builtInTools | Where-Object Id -eq $expectedId).Count -ne 1) { throw "The built-in tool catalog is missing '$expectedId'." }
    }
    $toolSettings = @($script:Settings | Where-Object Kind -eq 'Package')
    if ($toolSettings.Count -ne @(Get-ToolCatalog).Count) { throw "Every catalog tool must become a setting; found $($toolSettings.Count)." }
    foreach ($toolSetting in $toolSettings) {
        if ($toolSetting.Tab -ne 'Install tools') { throw "Tool '$($toolSetting.Id)' must sit on the Install tools tab." }
        if ($toolSetting.CanChoose) { throw "Tool '$($toolSetting.Id)' must not offer an uninstall option." }
        if ($toolSetting.DefaultState -ne 'Not installed') { throw "Tool '$($toolSetting.Id)' must report 'Not installed' as the untouched state." }
        if (@($toolSetting.Entries).Count -ne 1) { throw "Tool '$($toolSetting.Id)' must carry exactly one tool definition." }
    }
    # Scope decides elevation, so prove both directions with stand-in settings.
    $scopeProbe = @{
        user = (New-Setting 'tool-scope-user' 'Tools' 'User scope' 'probe' 'Installed' $null 'Package' @(($builtInTools | Where-Object Scope -eq 'user' | Select-Object -First 1)) $false $false @{} 'Tools' 'Not installed')
        machine = (New-Setting 'tool-scope-machine' 'Tools' 'Machine scope' 'probe' 'Installed' $null 'Package' @(($builtInTools | Where-Object Scope -eq 'machine' | Select-Object -First 1)) $false $false @{} 'Tools' 'Not installed')
    }
    if ($scopeProbe.user.RequiresAdmin -or -not (Test-SettingHasScope $scopeProbe.user 'User')) {
        throw 'A per-user package must stay in the signed-in account and must not request administrator approval.'
    }
    if (-not $scopeProbe.machine.RequiresAdmin -or -not (Test-SettingHasScope $scopeProbe.machine 'Machine')) {
        throw 'A machine-wide package must request administrator approval.'
    }
    # Dingo must refuse to run a tool definition it cannot understand.
    foreach ($badTool in @(
        [PSCustomObject]@{ id='7zip'; name='x'; install=[PSCustomObject]@{ package='a' }; detect=@([PSCustomObject]@{ kind='file'; path='x' }) },
        [PSCustomObject]@{ id='tool-x'; name=''; install=[PSCustomObject]@{ package='a' }; detect=@([PSCustomObject]@{ kind='file'; path='x' }) },
        [PSCustomObject]@{ id='tool-x'; name='x'; install=[PSCustomObject]@{ package='' }; detect=@([PSCustomObject]@{ kind='file'; path='x' }) },
        [PSCustomObject]@{ id='tool-x'; name='x'; install=[PSCustomObject]@{ package='a'; kind='chocolatey' }; detect=@([PSCustomObject]@{ kind='file'; path='x' }) },
        [PSCustomObject]@{ id='tool-x'; name='x'; install=[PSCustomObject]@{ package='a'; scope='everyone' }; detect=@([PSCustomObject]@{ kind='file'; path='x' }) },
        [PSCustomObject]@{ id='tool-x'; name='x'; install=[PSCustomObject]@{ package='a' }; detect=@() },
        [PSCustomObject]@{ id='tool-x'; name='x'; install=[PSCustomObject]@{ package='a' }; detect=@([PSCustomObject]@{ kind='guess' }) },
        [PSCustomObject]@{ id='tool-x'; name='x'; install=[PSCustomObject]@{ package='a'; timeoutMinutes=0 }; detect=@([PSCustomObject]@{ kind='file'; path='x' }) },
        [PSCustomObject]@{ id='tool-x'; name='x'; install=[PSCustomObject]@{ package='a'; timeoutMinutes=999 }; detect=@([PSCustomObject]@{ kind='file'; path='x' }) },
        # A downloaded installer script runs elevated, so plain http, a non-url,
        # and a missing destination must all be refused.
        [PSCustomObject]@{ id='tool-x'; name='x'; install=[PSCustomObject]@{ kind='script'; url='http://example.com/a.ps1'; dest='C:\x' }; detect=@([PSCustomObject]@{ kind='file'; path='x' }) },
        [PSCustomObject]@{ id='tool-x'; name='x'; install=[PSCustomObject]@{ kind='script'; url='file:///c:/a.ps1'; dest='C:\x' }; detect=@([PSCustomObject]@{ kind='file'; path='x' }) },
        [PSCustomObject]@{ id='tool-x'; name='x'; install=[PSCustomObject]@{ kind='script'; dest='C:\x' }; detect=@([PSCustomObject]@{ kind='file'; path='x' }) },
        [PSCustomObject]@{ id='tool-x'; name='x'; install=[PSCustomObject]@{ kind='script'; url='https://example.com/a.ps1' }; detect=@([PSCustomObject]@{ kind='file'; path='x' }) }
    )) {
        $rejected = $false
        try { [void](ConvertTo-ToolDefinition $badTool) } catch { $rejected = $true }
        if (-not $rejected) { throw "An invalid tool definition was accepted: $($badTool.id)." }
    }
    # An optional field left out must not throw under Set-StrictMode 2.0.
    $minimalTool = ConvertTo-ToolDefinition ([PSCustomObject]@{ id='tool-minimal'; name='Minimal'; install=[PSCustomObject]@{ package='a' }; detect=@([PSCustomObject]@{ kind='command'; command='cmd.exe' }) })
    if ($minimalTool.Scope -ne 'machine' -or $minimalTool.Source -ne 'winget' -or $minimalTool.Category -ne 'Tools') { throw 'Tool defaults are wrong.' }
    if (-not (Find-InstalledTool $minimalTool)) { throw 'Tool detection did not find cmd.exe on the PATH.' }
    # Eric Zimmerman's tools are fetched by the author's own script, not by winget.
    $ezTool = $builtInTools | Where-Object Id -eq 'tool-eztools' | Select-Object -First 1
    if ($ezTool.InstallKind -ne 'script') { throw 'The Eric Zimmerman tool set must use the script install kind.' }
    if ($ezTool.Url -notmatch '^https://raw\.githubusercontent\.com/EricZimmerman/') { throw 'The Get-ZimmermanTools script must come from its own repository over https.' }
    if ($ezTool.Dest -ne 'C:\DFIR\Tools\EZTools') { throw 'The Eric Zimmerman tool set must install to C:\DFIR\Tools\EZTools.' }
    if ($ezTool.Scope -ne 'machine') { throw 'Writing to C:\DFIR needs administrator approval.' }
    if ($ezTool.TimeoutSeconds -lt 1800) { throw 'The Eric Zimmerman download needs a long timeout.' }
    $ezSetting = $script:Settings | Where-Object Id -eq 'tool-eztools' | Select-Object -First 1
    if (-not $ezSetting.RequiresAdmin) { throw 'The Eric Zimmerman tool set must request administrator approval.' }
    if ([bool]$ezSetting.Requirements['WingetRequired']) { throw 'A script install must not be blocked by a missing winget.' }
    # Eric Zimmerman's tools will not start without the .NET 9 Desktop Runtime,
    # and a fresh Windows 11 install does not have it. It must be offered, and it
    # must be installed first, because the worker applies the plan in this order.
    $runtimeIndex = [array]::IndexOf(@($builtInTools | ForEach-Object { $_.Id }), 'tool-dotnet-desktop-9')
    $ezIndex = [array]::IndexOf(@($builtInTools | ForEach-Object { $_.Id }), 'tool-eztools')
    if ($runtimeIndex -lt 0 -or $ezIndex -lt 0 -or $runtimeIndex -gt $ezIndex) {
        throw 'The .NET runtime must be listed before the tools that need it.'
    }
    $missingTool = ConvertTo-ToolDefinition ([PSCustomObject]@{ id='tool-absent'; name='Absent'; install=[PSCustomObject]@{ package='a' }; detect=@([PSCustomObject]@{ kind='file'; path='%ProgramFiles%\Dingo-Definitely-Absent\x.exe' }) })
    if (Find-InstalledTool $missingTool) { throw 'Tool detection reported a missing tool as installed.' }
    # A wildcard rule must match a versioned folder and report its name as the version.
    $wildcardTool = ConvertTo-ToolDefinition ([PSCustomObject]@{ id='tool-wildcard'; name='Wildcard'; install=[PSCustomObject]@{ package='a' }; detect=@([PSCustomObject]@{ kind='file'; path='C:/Windows/Dingo-Definitely-Absent-*' }) })
    if (Find-InstalledTool $wildcardTool) { throw 'A wildcard rule matched a folder that does not exist.' }
    $wildcardHit = ConvertTo-ToolDefinition ([PSCustomObject]@{ id='tool-wildcard2'; name='Wildcard'; install=[PSCustomObject]@{ package='a' }; detect=@([PSCustomObject]@{ kind='file'; path='C:/Windows/Microsoft.NET/Frame*' }) })
    $wildcardFound = Find-InstalledTool $wildcardHit
    if (-not $wildcardFound -or -not $wildcardFound.Version) { throw 'A wildcard rule did not match a folder that does exist.' }
    # PATH damage is the worst thing this tool could do, so prove the string
    # handling on a stand-in value before it is ever written to the registry.
    $pathSetting = $script:Settings | Where-Object Id -eq 'tools-on-path' | Select-Object -First 1
    if (-not $pathSetting) { throw 'The command-line access setting is missing.' }
    if ($pathSetting.Tab -ne 'Tool shortcuts' -or -not $pathSetting.RequiresAdmin -or -not $pathSetting.CanChoose) {
        throw 'Command-line access must be a reversible Tool shortcuts card that requests administrator approval.'
    }
    if ($script:Settings[-1].Id -ne 'tools-on-path') {
        throw 'Command-line access must be applied last, after the tools its launchers point at.'
    }
    $samplePath = 'C:\Windows\system32;%USERPROFILE%\go\bin;C:\Program Files\Git\cmd'
    if (@(Split-PathValue "$samplePath;;  ;").Count -ne 3) { throw 'Empty PATH entries must be dropped.' }
    if ((Split-PathValue $samplePath)[1] -ne '%USERPROFILE%\go\bin') { throw 'PATH entries must not be expanded.' }
    foreach ($variant in @('C:\DFIR\Tools\bin','c:\dfir\tools\bin','C:\DFIR\Tools\bin\')) {
        if (-not (Test-PathContainsFolder "$samplePath;C:\DFIR\Tools\bin" $variant)) { throw "PATH matching failed for '$variant'." }
    }
    if (Test-PathContainsFolder $samplePath 'C:\DFIR\Tools\bin') { throw 'PATH matching reported a folder that is absent.' }
    $added = Add-FolderToPathValue $samplePath 'C:\DFIR\Tools\bin'
    if ($added -ne "$samplePath;C:\DFIR\Tools\bin") { throw 'Adding to PATH must append one entry to the end.' }
    if ((Add-FolderToPathValue $added 'C:\DFIR\Tools\bin') -ne $added) { throw 'Adding to PATH twice must change nothing.' }
    if ((Remove-FolderFromPathValue $added 'C:\DFIR\Tools\bin') -ne $samplePath) { throw 'Removing from PATH must restore the original value.' }
    if ((Remove-FolderFromPathValue $samplePath 'C:\DFIR\Tools\bin') -ne $samplePath) { throw 'Removing an absent folder must change nothing.' }
    $emptyRejected = $false
    try { Set-MachinePathValue '  ' } catch { $emptyRejected = $true }
    if (-not $emptyRejected) { throw 'Writing an empty computer PATH must be refused.' }
    # Launchers: written correctly, recognised again, and never deleting a file
    # somebody else put in the same folder.
    $shimTestDirectory = Join-Path $env:TEMP ("Dingo-shim-test-{0}" -f [Guid]::NewGuid().ToString('N'))
    $savedShimDirectory = $script:ShimDirectory
    try {
        $script:ShimDirectory = $shimTestDirectory
        New-Item -ItemType Directory -Path $shimTestDirectory -Force | Out-Null
        $foreignPath = Join-Path $shimTestDirectory 'mine.cmd'
        [IO.File]::WriteAllText($foreignPath, "@echo off`r`necho hand written`r`n", (New-Object Text.UTF8Encoding($false)))
        Write-ToolShim 'EvtxECmd' 'C:\DFIR\Tools\EZTools\net9\EvtxeCmd\EvtxECmd.exe'
        $shimPath = Join-Path $shimTestDirectory 'EvtxECmd.cmd'
        $shimText = Get-Content -LiteralPath $shimPath -Raw
        $expectedCall = '"C:\DFIR\Tools\EZTools\net9\EvtxeCmd\EvtxECmd.exe" %*'
        if (-not $shimText.Contains($expectedCall)) { throw 'The launcher does not call its program with the supplied arguments.' }
        if ([IO.File]::ReadAllBytes($shimPath)[0] -eq 0xEF) { throw 'A launcher must not start with a byte order mark; cmd.exe would choke on it.' }
        if (-not (Test-ShimIsCurrent $shimPath 'C:\DFIR\Tools\EZTools\net9\EvtxeCmd\EvtxECmd.exe')) { throw 'A freshly written launcher was not recognised.' }
        if (Test-ShimIsCurrent $shimPath 'C:\Somewhere\Else.exe') { throw 'A launcher pointing elsewhere was treated as current.' }
        if (Test-ShimIsCurrent $foreignPath 'C:\anything.exe') { throw 'A hand-written file must never be treated as a Dingo launcher.' }
        $owned = @(Get-DingoShimFiles | Select-Object -ExpandProperty Name)
        if ($owned.Count -ne 1 -or $owned[0] -ne 'EvtxECmd.cmd') { throw "Dingo claimed the wrong launcher files: $($owned -join ', ')" }
        if (-not (Test-Path -LiteralPath $foreignPath)) { throw 'The hand-written file disappeared.' }
    } finally {
        $script:ShimDirectory = $savedShimDirectory
        Remove-Item -LiteralPath $shimTestDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    # Hiding the console is only ever right for the GUI. Prove the launcher asks
    # for it on a bare run, and that Dingo obeys nothing else.
    $launcherPath = Join-Path $PSScriptRoot 'Start-Dingo.cmd'
    if (Test-Path -LiteralPath $launcherPath -PathType Leaf) {
        $launcherText = Get-Content -LiteralPath $launcherPath -Raw
        if ($launcherText -notmatch 'if\s+"%~1"=="" set "DINGO_HIDE_CONSOLE=1"') {
            throw 'The launcher must ask for a hidden console only when no arguments were supplied.'
        }
    }
    $hideCall = $selfTestAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -match '\$env:DINGO_HIDE_CONSOLE'
    }, $true)
    if (@($hideCall).Count -ne 1) { throw 'The console must be hidden only behind the launcher environment check.' }
    if (@($hideCall)[0].Clauses[0].Item2.Extent.Text -notmatch 'Set-DingoConsoleVisible\s+\$false') {
        throw 'The launcher environment check must hide the console, and nothing else.'
    }
    Set-DingoConsoleVisible $true

    # Shortcuts: written correctly, recognised again, and never deleting one that
    # an installer or a person put in the same folder.
    foreach ($shortcutId in @('tools-start-menu','tools-desktop')) {
        $shortcutSetting = $script:Settings | Where-Object Id -eq $shortcutId | Select-Object -First 1
        if (-not $shortcutSetting) { throw "The '$shortcutId' setting is missing." }
        if ($shortcutSetting.Tab -ne 'Tool shortcuts' -or -not $shortcutSetting.RequiresAdmin -or -not $shortcutSetting.CanChoose) {
            throw "'$shortcutId' must be a reversible Tool shortcuts card that requests administrator approval."
        }
        $shortcutIndex = [array]::IndexOf(@($script:Settings | ForEach-Object { $_.Id }), $shortcutId)
        $lastToolIndex = [array]::IndexOf(@($script:Settings | ForEach-Object { $_.Id }), @($toolSettings)[-1].Id)
        if ($shortcutIndex -lt $lastToolIndex) { throw "'$shortcutId' must be applied after the tools it points at." }
    }
    $ezShortcuts = @(($builtInTools | Where-Object Id -eq 'tool-eztools' | Select-Object -First 1).Shortcuts)
    if (@($ezShortcuts | Where-Object Name -eq 'Timeline Explorer').Count -ne 1) {
        throw "Eric Zimmerman's tools must offer a Timeline Explorer shortcut, because its installer makes none."
    }
    $badShortcutRejected = $false
    try {
        [void](ConvertTo-ToolDefinition ([PSCustomObject]@{
            id='tool-badshortcut'; name='Bad'; install=[PSCustomObject]@{ kind='winget'; package='a.b' }
            detect=@([PSCustomObject]@{ kind='command'; command='a.exe' })
            shortcuts=@([PSCustomObject]@{ name='..\..\evil'; target='C:/Windows/notepad.exe' })
        }))
    } catch { $badShortcutRejected = $true }
    if (-not $badShortcutRejected) { throw 'A shortcut name that is not a usable file name must be refused.' }
    $shortcutTestDirectory = Join-Path $env:TEMP ("Dingo-shortcut-test-{0}" -f [Guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $shortcutTestDirectory -Force | Out-Null
        $notepadPath = Join-Path $env:SystemRoot 'notepad.exe'
        $shortcutSpec = [PSCustomObject]@{ Target=$notepadPath; Arguments='' }
        # A shortcut somebody else made, in the same folder.
        $foreignShortcut = Join-Path $shortcutTestDirectory 'Theirs.lnk'
        $foreignShell = New-Object -ComObject WScript.Shell
        try {
            $foreignLink = $foreignShell.CreateShortcut($foreignShortcut)
            $foreignLink.TargetPath = $notepadPath
            $foreignLink.Description = 'Made by hand'
            $foreignLink.Save()
        } finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($foreignShell) }
        Write-ToolShortcut $shortcutTestDirectory 'Test Tool' $shortcutSpec
        $writtenShortcut = Join-Path $shortcutTestDirectory 'Test Tool.lnk'
        if (-not (Test-Path -LiteralPath $writtenShortcut -PathType Leaf)) { throw 'The shortcut file was not created.' }
        if (-not (Test-ShortcutIsCurrent $writtenShortcut $shortcutSpec)) { throw 'A freshly written shortcut was not recognised.' }
        if (Test-ShortcutIsCurrent $writtenShortcut ([PSCustomObject]@{ Target='C:\Somewhere\Else.exe'; Arguments='' })) {
            throw 'A shortcut pointing elsewhere was treated as current.'
        }
        if (Test-ShortcutIsCurrent $foreignShortcut $shortcutSpec) { throw 'A hand-made shortcut must never be treated as a Dingo shortcut.' }
        $ownedShortcuts = @(Get-DingoShortcutFiles $shortcutTestDirectory | Select-Object -ExpandProperty Name)
        if ($ownedShortcuts.Count -ne 1 -or $ownedShortcuts[0] -ne 'Test Tool.lnk') {
            throw "Dingo claimed the wrong shortcut files: $($ownedShortcuts -join ', ')"
        }
        if (-not (Test-Path -LiteralPath $foreignShortcut)) { throw 'The hand-made shortcut disappeared.' }
    } finally {
        Remove-Item -LiteralPath $shortcutTestDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    $toggleCount = @($script:Settings | Where-Object CanChoose).Count
    if ($toggleCount -lt 20) { throw "Expected at least 20 reversible settings, found $toggleCount." }
    "Self-test passed: $($script:Settings.Count) settings; $toggleCount reversible; $($toolSettings.Count) tools."
    exit 0
}

if ($StateSelfTest) {
    foreach ($setting in $script:Settings) {
        $state = Get-SettingState $setting
        [PSCustomObject]@{ Id=$setting.Id; Status=$state.Status; CurrentState=$state.DisplayText; Details=$state.Details; PreferredState=$setting.PreferredState }
    }
    exit 0
}

if ($MachineWorker) {
    $script:LogFile = $WorkerLogPath
    try {
        Write-Log 'INFO' "Administrator worker started as $([Security.Principal.WindowsIdentity]::GetCurrent().Name) for desktop SID $TargetUserSid."
        if (-not (Test-IsAdministrator)) { throw 'The machine worker was not elevated.' }
        if ($TargetUserSid -notmatch '^S-\d(?:-\d+)+$') { throw 'The desktop user SID supplied to the administrator step is invalid.' }
        $plan = @(ConvertFrom-JsonList (Get-Content -LiteralPath $PlanPath -Raw))
        Write-Log 'INFO' "Administrator worker received $($plan.Count) setting(s)."
        $results = Invoke-AdministratorPlan $plan $script:Settings $ResultPath
        Write-WorkerResults $results $ResultPath
        exit 0
    } catch {
        Write-Log 'ERROR' "Machine worker fatal error: $($_.Exception.ToString())"
        Write-WorkerResults @((New-ApplyResult '*' @((New-OperationComponent 'Administrator worker' 'Failed' $_.Exception.Message)) $_.Exception.Message)) $ResultPath
        exit 1
    }
}

if ($ApplyPreferred -or $WhatIf -or $Include -or $Exclude) {
    $exitCode = 0
    if (-not ($ApplyPreferred -or $WhatIf)) {
        Write-CliErrorResponse 'Use -ApplyPreferred to make changes, or -WhatIf to preview them.' 2
        exit 2
    }
    # A dry run changes nothing, so it stays available where every process is
    # elevated, such as Windows Sandbox. Only real changes are refused.
    if ((Test-IsAdministrator) -and -not $WhatIf) {
        Write-CliErrorResponse 'Start Dingo from the signed-in desktop account, not from an elevated PowerShell window. Dingo will request administrator approval only for settings that need it.' 2 'ApplyPreferred'
        exit 2
    }
    $elevatedDryRun = [bool]((Test-IsAdministrator) -and $WhatIf)
    if ($elevatedDryRun) {
        Write-CliStatus 'Note: this dry run is elevated, so account settings are read from the elevated account. That is the same account under UAC, but not if you elevated as somebody else.'
    }
    if (-not (Enter-DingoSingleInstance)) {
        Write-CliErrorResponse 'Dingo is already running for this Windows account.' 3 $(if ($WhatIf) { 'WhatIf' } else { 'ApplyPreferred' })
        exit 3
    }
    try {
        Initialize-Log
        $selected = @(Resolve-QuickApplySettings $script:Settings $Include $Exclude)
        if (-not $selected) { throw 'The include/exclude filters selected no settings.' }
        foreach ($item in $selected) {
            $item.DesiredState = $item.PreferredState
            $item.CurrentState = Get-SettingState $item
        }
        $preflight = @(Test-PlanPreflight $selected)
        $blocked = @($preflight | Where-Object { -not $_.Available })
        if ($WhatIf) {
            $plan = @($selected | ForEach-Object {
                $item = $_
                $check = $preflight | Where-Object Id -eq $item.Id | Select-Object -First 1
                [PSCustomObject]@{
                    Id=$item.Id; Name=$item.Name; Kind=$item.Kind; Scope=$item.DisplayScope; RequiresAdmin=$item.RequiresAdmin
                    Available=$check.Available; PreflightMessage=$check.Message
                    CurrentStatus=$item.CurrentState.Status; CurrentState=$item.CurrentState.DisplayText; Target=$item.PreferredState
                    Advisory=(Get-SettingAdvisory $item)
                }
            })
            $exitCode = if ($blocked) { 2 } else { 0 }
            if ($OutputFormat -eq 'Json') {
                [Console]::Out.WriteLine((ConvertTo-Json -InputObject ([PSCustomObject]@{
                    Version=$script:DingoVersion; Mode='WhatIf'; Success=(-not [bool]$blocked); ExitCode=$exitCode; Changed=$false; Elevated=$elevatedDryRun; Plan=$plan
                }) -Depth 7))
            } else {
                Write-CliStatus "Dingo dry run: $($selected.Count) preferred setting(s) would be applied. No changes were made."
                [Console]::Out.WriteLine(($plan | Format-Table Id,Name,Kind,Scope,RequiresAdmin,Available,CurrentStatus,CurrentState,Target -AutoSize | Out-String -Width 240).TrimEnd())
                foreach ($advised in @($plan | Where-Object Advisory)) { [Console]::Out.WriteLine("[$($advised.Id)] Caveat: $($advised.Advisory)") }
                foreach ($failure in $blocked) { [Console]::Error.WriteLine("[$($failure.Id)] Preflight failed: $($failure.Message)") }
            }
            Write-Log 'INFO' "Quick-apply dry run completed for $($selected.Count) setting(s)."
        } else {
            if ($blocked) { throw "Preflight failed: $(@($blocked | ForEach-Object { "[$($_.Id)] $($_.Message)" }) -join '; ')" }
            Write-CliStatus "Dingo quick apply: applying $($selected.Count) preferred setting(s)."
            Write-Log 'INFO' "Quick apply started for $($selected.Count) setting(s)."
            $administratorResults = @{}
            if ($selected | Where-Object RequiresAdmin) {
                Write-CliStatus 'Administrator approval is required for part of this plan.'
                $operation = Start-AdministratorChanges $selected
                $administratorResults = Complete-AdministratorChanges $operation
            }
            $results = New-Object System.Collections.ArrayList
            foreach ($item in $selected) {
                Write-CliStatus "[$($item.Id)] Applying $($item.PreferredState)..."
                $result = Invoke-SettingChange $item $administratorResults
                [void]$results.Add($result)
                Write-CliStatus "[$($item.Id)] $($result.Outcome): $($item.CurrentState.DisplayText)"
            }
            $restartExplorer = @($results | Where-Object Outcome -ne 'Failed' | ForEach-Object {
                $resultId = $_.Id
                $selected | Where-Object { $_.Id -eq $resultId -and $_.RestartExplorer }
            }).Count -gt 0
            if ($restartExplorer -and -not $NoRestartExplorer) { [void](Restart-DesktopExplorer) }
            $resultRows = @($results | ForEach-Object {
                $item = $script:Settings | Where-Object Id -eq $_.Id | Select-Object -First 1
                [PSCustomObject]@{ Id=$_.Id; Outcome=$_.Outcome; CurrentStatus=$item.CurrentState.Status; CurrentState=$item.CurrentState.DisplayText; Message=$_.Message; Components=$_.Components }
            })
            $succeeded = @($results | Where-Object Outcome -eq 'Succeeded').Count
            $partial = @($results | Where-Object Outcome -eq 'PartiallyApplied').Count
            $failed = @($results | Where-Object Outcome -eq 'Failed').Count
            if ($partial -or $failed) { $exitCode = 1 }
            if ($OutputFormat -eq 'Json') {
                [Console]::Out.WriteLine((ConvertTo-Json -InputObject ([PSCustomObject]@{
                    Version=$script:DingoVersion; Mode='ApplyPreferred'; Success=($exitCode -eq 0); ExitCode=$exitCode
                    Summary=[PSCustomObject]@{Succeeded=$succeeded;PartiallyApplied=$partial;Failed=$failed}
                    RestartRequired=[bool](@($results | Where-Object RestartRequired).Count); LogPath=$script:LogFile; Results=$resultRows
                }) -Depth 9))
            } else {
                [Console]::Out.WriteLine(($resultRows | Format-Table Id,Outcome,CurrentState,Message -AutoSize | Out-String -Width 220).TrimEnd())
                Write-CliStatus "Dingo finished: $succeeded succeeded; $partial partially applied; $failed failed. Log: $script:LogFile"
            }
            Write-Log 'INFO' "Quick apply finished: $succeeded succeeded; $partial partially applied; $failed failed."
        }
    } catch {
        Write-CliErrorResponse $_.Exception.Message 2 $(if ($WhatIf) { 'WhatIf' } else { 'ApplyPreferred' })
        Write-Log 'ERROR' "Quick apply failed: $($_.Exception.ToString())"
        $exitCode = 2
    } finally {
        Exit-DingoSingleInstance
    }
    exit $exitCode
}

# The UI self-test builds the window, checks it, and closes it without changing
# anything, so it must stay runnable where every process is elevated, such as
# Windows Sandbox. The other self-tests already run before this guard.
if ((Test-IsAdministrator) -and -not $UiSelfTest) {
    Add-Type -AssemblyName PresentationFramework
    $message = @(
        'Dingo was started as an administrator. Close this window and start it normally.',
        '',
        'Double-click Start-Dingo.cmd. Do not use "Run as administrator".',
        '',
        'Dingo must keep the main window in your signed-in account so settings such as Taskbar Widgets affect your desktop. It will ask for administrator credentials automatically when a whole-computer setting needs them.'
    ) -join [Environment]::NewLine
    [System.Windows.MessageBox]::Show($message, 'Start Dingo normally', 'OK', 'Warning') | Out-Null
    exit 2
}

Initialize-Log
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Dingo - Windows 11 Preferences" Width="1280" Height="820" MinWidth="980" MinHeight="640"
        WindowStartupLocation="CenterScreen" Background="#F4F6F8" FontFamily="Segoe UI">
  <Window.Resources>
    <Style TargetType="Button"><Setter Property="Padding" Value="13,8"/><Setter Property="Margin" Value="0,0,8,0"/></Style>
    <Style TargetType="RadioButton"><Setter Property="Margin" Value="0,4,14,2"/><Setter Property="FontSize" Value="14"/></Style>
  </Window.Resources>
  <Grid Margin="18">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <StackPanel Grid.Row="0" Margin="0,0,0,12">
      <TextBlock Text="Dingo - Windows 11 Preferences" FontSize="25" FontWeight="SemiBold" Foreground="#17212B"/>
      <TextBlock Text="Pick a tab, read what Windows uses now, choose what you want, then tick the setting and click Apply checked changes." Foreground="#52606D" FontSize="14" Margin="0,4,0,0"/>
    </StackPanel>
    <WrapPanel Grid.Row="1" Margin="0,0,0,10">
      <Button Name="AllPreferredButton" Content="Choose all my preferred settings" Background="#E5F2FF"/>
      <Button Name="NeededButton" Content="Check only settings that need changing"/>
      <Button Name="UncheckButton" Content="Uncheck everything"/>
      <Button Name="RefreshButton" Content="Read settings again"/>
      <CheckBox Name="RestartExplorerCheckBox" Content="Restart File Explorer when finished" IsChecked="True" VerticalAlignment="Center" Margin="12,0,0,0"/>
    </WrapPanel>
    <TabControl Name="ScopeTabs" Grid.Row="2" FontSize="14">
      <TabItem Header="My account">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <Border Background="#EAF4FF" Padding="12" Margin="8">
            <TextBlock Name="UserScopeText" Text="These settings affect only your signed-in Windows account. Most run directly as you; Windows may request administrator approval for a protected policy, but Dingo still targets your account." TextWrapping="Wrap"/>
          </Border>
          <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <StackPanel Name="UserSettingsPanel" Margin="8,0,8,8"/>
          </ScrollViewer>
        </Grid>
      </TabItem>
      <TabItem Header="Whole computer">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <Border Background="#FFF4DF" Padding="12" Margin="8">
            <TextBlock Text="These settings affect everyone who uses this computer. Windows will ask for an administrator account when you apply them." TextWrapping="Wrap"/>
          </Border>
          <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <StackPanel Name="SystemSettingsPanel" Margin="8,0,8,8"/>
          </ScrollViewer>
        </Grid>
      </TabItem>
      <TabItem Header="My account + whole computer">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <Border Background="#F2EBFF" Padding="12" Margin="8">
            <TextBlock Name="BothScopeText" Text="These choices have two parts: one for your account and one for the whole computer. Administrator approval is needed for the computer-wide part." TextWrapping="Wrap"/>
          </Border>
          <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <StackPanel Name="BothSettingsPanel" Margin="8,0,8,8"/>
          </ScrollViewer>
        </Grid>
      </TabItem>
      <TabItem Header="Install tools">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <Border Background="#E8F6EE" Padding="12" Margin="8">
            <TextBlock Name="ToolsScopeText" Text="Analyst tools. Dingo checks whether each one is already installed, and installs the missing ones with winget. Dingo never removes a tool." TextWrapping="Wrap"/>
          </Border>
          <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <StackPanel Name="ToolSettingsPanel" Margin="8,0,8,8"/>
          </ScrollViewer>
        </Grid>
      </TabItem>
      <TabItem Header="Tool shortcuts">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <Border Background="#E8F6EE" Padding="12" Margin="8">
            <TextBlock Name="ShortcutsScopeText" Text="Ways to reach the tools you installed: Start menu and Desktop shortcuts, and launchers that let you run the command-line tools from any folder." TextWrapping="Wrap"/>
          </Border>
          <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <StackPanel Name="ShortcutSettingsPanel" Margin="8,0,8,8"/>
          </ScrollViewer>
        </Grid>
      </TabItem>
    </TabControl>
    <ProgressBar Name="ProgressBar" Grid.Row="3" Height="8" Margin="0,10,0,8" Minimum="0" Maximum="100"/>
    <DockPanel Grid.Row="4">
      <TextBlock Name="SummaryText" Text="Reading current settings..." VerticalAlignment="Center" Foreground="#334E68" TextWrapping="Wrap" MaxWidth="850"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <TextBlock Name="AdminSummaryText" Visibility="Collapsed" VerticalAlignment="Center" Foreground="#8A4B08" FontWeight="SemiBold" TextWrapping="Wrap" MaxWidth="250" Margin="0,0,14,0"/>
        <Button Name="OpenLogButton" Content="Open log folder"/>
        <Button Name="ApplyButton" Content="Apply checked changes" Background="#0B6EBD" Foreground="White" FontWeight="SemiBold"/>
      </StackPanel>
    </DockPanel>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
foreach ($name in @('ScopeTabs','UserScopeText','BothScopeText','ToolsScopeText','ShortcutsScopeText','UserSettingsPanel','SystemSettingsPanel','BothSettingsPanel','ToolSettingsPanel','ShortcutSettingsPanel','AllPreferredButton','NeededButton','UncheckButton','RefreshButton','RestartExplorerCheckBox','ProgressBar','SummaryText','AdminSummaryText','OpenLogButton','ApplyButton')) {
    Set-Variable -Name $name -Value $window.FindName($name) -Scope Script
}
$desktopIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$UserScopeText.Text = "These settings affect only $desktopIdentity. A gold 'Admin approval required' label identifies a protected per-account policy that needs elevation."
$BothScopeText.Text = "These choices affect $desktopIdentity and the whole computer. Administrator approval is used only for the computer-wide part."
$ToolsScopeText.Text = "Analyst tools. Dingo checks whether each one is already installed, and installs the missing ones with winget. Dingo never removes a tool. Add more tools by putting a Tools.json file next to Dingo.ps1. Shortcuts and command-line access are on the next tab."
if ($script:ToolCatalogWarning) {
    $ToolsScopeText.Text = "$($script:ToolCatalogWarning) The built-in tool list is being used instead."
    $ToolsScopeText.Foreground = '#8A2B21'
}
$script:ActionButtons = @($ApplyButton,$AllPreferredButton,$NeededButton,$UncheckButton,$RefreshButton)

function Set-ActionButtonsEnabled([bool]$Enabled) {
    foreach ($control in $script:ActionButtons) { $control.IsEnabled = $Enabled }
}

# ContentRendered starts the initial state scan. Prevent actions from using the
# placeholder/partially read state before that scan has finished.
Set-ActionButtonsEnabled $false

function New-CardText {
    param([string]$Text, [double]$Size = 13, [string]$Weight = 'Normal', [string]$Colour = '#243B53')
    $control = New-Object Windows.Controls.TextBlock
    $control.Text = $Text
    $control.FontSize = $Size
    $control.FontWeight = $Weight
    $control.Foreground = $Colour
    $control.TextWrapping = 'Wrap'
    $control.Margin = '0,1,8,2'
    return $control
}

function Add-CardColumn($Grid, $Control, [int]$Column) {
    [Windows.Controls.Grid]::SetColumn($Control, $Column)
    [void]$Grid.Children.Add($Control)
}

function Update-SelectionSummary {
    $selected = @($script:Settings | Where-Object Selected)
    $selectedAdmin = @($selected | Where-Object RequiresAdmin)
    $ApplyButton.Content = if ($selected.Count) {
        "Apply $($selected.Count) checked change$(if ($selected.Count -eq 1) { '' } else { 's' })"
    } else {
        'Apply checked changes'
    }
    if ($selectedAdmin.Count) {
        $AdminSummaryText.Text = "$($selectedAdmin.Count) selected setting$(if ($selectedAdmin.Count -eq 1) { '' } else { 's' }) require$(if ($selectedAdmin.Count -eq 1) { 's' }) administrator approval"
        $AdminSummaryText.Visibility = 'Visible'
    } else {
        $AdminSummaryText.Text = ''
        $AdminSummaryText.Visibility = 'Collapsed'
    }
}

function New-SettingCard($Item) {
    $border = New-Object Windows.Controls.Border
    $border.Background = 'White'
    $border.BorderBrush = '#D6DEE6'
    $border.BorderThickness = '1'
    $border.CornerRadius = '4'
    $border.Padding = '12'
    $border.Margin = '0,0,0,8'

    $grid = New-Object Windows.Controls.Grid
    foreach ($width in @(78,315,220,300,200)) {
        $column = New-Object Windows.Controls.ColumnDefinition
        $column.Width = $width
        [void]$grid.ColumnDefinitions.Add($column)
    }

    $applyCheck = New-Object Windows.Controls.CheckBox
    $applyCheck.Content = 'Change'
    $applyCheck.IsChecked = $Item.Selected
    $applyCheck.VerticalAlignment = 'Top'
    $applyCheck.Margin = '5,7,0,0'
    $applyCheck.ToolTip = 'Tick this box if you want Dingo to change this setting.'
    $applyCheck.Tag = $Item
    $applyCheck.Add_Checked({ param($sender,$eventArgs) $sender.Tag.Selected = $true; Update-SelectionSummary })
    $applyCheck.Add_Unchecked({ param($sender,$eventArgs) $sender.Tag.Selected = $false; Update-SelectionSummary })
    Add-CardColumn $grid $applyCheck 0

    $about = New-Object Windows.Controls.StackPanel
    [void]$about.Children.Add((New-CardText $Item.Name 15 'SemiBold' '#17212B'))
    [void]$about.Children.Add((New-CardText $Item.Category 11 'SemiBold' '#627D98'))
    [void]$about.Children.Add((New-CardText $Item.Description 12 'Normal' '#52606D'))
    $adminBadge = $null
    if ($Item.RequiresAdmin) {
        $adminBadge = New-Object Windows.Controls.Border
        $adminBadge.Background = '#FFF4DF'
        $adminBadge.CornerRadius = '9'
        $adminBadge.Padding = '7,2'
        $adminBadge.Margin = '0,7,0,0'
        $adminBadge.HorizontalAlignment = 'Left'
        $adminBadge.ToolTip = if ($Item.DisplayScope -eq 'User') {
            'This setting affects only your account, but Windows protects its policy value and requires administrator approval to change it.'
        } else {
            'This setting includes a computer-wide change and requires administrator approval.'
        }
        $badgeText = New-CardText 'Admin approval required' 10 'SemiBold' '#8A4B08'
        $badgeText.Margin = '0'
        $adminBadge.Child = $badgeText
        [void]$about.Children.Add($adminBadge)
    }
    # Show a caveat that applying the setting cannot resolve, so the card never
    # implies a result Windows or the target application will not honour.
    $advisory = Get-SettingAdvisory $Item
    if ($advisory) {
        $advisoryBorder = New-Object Windows.Controls.Border
        $advisoryBorder.Background = '#FFF1F0'
        $advisoryBorder.BorderBrush = '#F3B3AE'
        $advisoryBorder.BorderThickness = '1'
        $advisoryBorder.CornerRadius = '4'
        $advisoryBorder.Padding = '8,5'
        $advisoryBorder.Margin = '0,7,8,0'
        $advisoryText = New-CardText "Has no effect on this VM. $advisory" 11 'SemiBold' '#8A2B21'
        $advisoryText.Margin = '0'
        $advisoryBorder.Child = $advisoryText
        [void]$about.Children.Add($advisoryBorder)
    }
    Add-CardColumn $grid $about 1

    $state = New-Object Windows.Controls.StackPanel
    [void]$state.Children.Add((New-CardText 'WINDOWS NORMALLY USES' 10 'Bold' '#829AB1'))
    [void]$state.Children.Add((New-CardText $Item.DefaultState 13 'Normal' '#334E68'))
    [void]$state.Children.Add((New-CardText 'CURRENT SETTING' 10 'Bold' '#829AB1'))
    $currentText = New-CardText $Item.CurrentState.DisplayText 14 'SemiBold' '#B45309'
    [void]$state.Children.Add($currentText)
    Add-CardColumn $grid $state 2

    $choices = New-Object Windows.Controls.StackPanel
    [void]$choices.Children.Add((New-CardText 'CHOOSE WHAT YOU WANT' 10 'Bold' '#829AB1'))
    $choiceControls = New-Object System.Collections.ArrayList
    foreach ($option in $Item.StateOptions) {
        $radio = New-Object Windows.Controls.RadioButton
        $radio.Content = if ($option -eq $Item.PreferredState) { "$option  (my preference)" } else { [string]$option }
        $radio.GroupName = "choice-$($Item.Id)"
        $radio.IsChecked = ($Item.DesiredState -eq $option)
        $radio.Tag = [PSCustomObject]@{ Setting=$Item; Value=[string]$option; ApplyCheck=$applyCheck }
        $radio.Add_Checked({
            param($sender,$eventArgs)
            $sender.Tag.Setting.DesiredState = $sender.Tag.Value
            $sender.Tag.Setting.Selected = $true
            $sender.Tag.ApplyCheck.IsChecked = $true
        })
        [void]$choices.Children.Add($radio)
        [void]$choiceControls.Add($radio)
    }
    if (-not $Item.CanChoose) {
        [void]$choices.Children.Add((New-CardText 'This item has one recommended target. Untick the box if you want to leave it alone.' 11 'Normal' '#627D98'))
    }
    Add-CardColumn $grid $choices 3

    $result = New-Object Windows.Controls.StackPanel
    [void]$result.Children.Add((New-CardText 'RESULT' 10 'Bold' '#829AB1'))
    $statusText = New-CardText $Item.Status 13 'SemiBold' '#334E68'
    $detailsText = New-CardText $Item.Details 11 'Normal' '#52606D'
    [void]$result.Children.Add($statusText)
    [void]$result.Children.Add($detailsText)
    Add-CardColumn $grid $result 4

    $border.Child = $grid
    $Item | Add-Member -NotePropertyName ApplyControl -NotePropertyValue $applyCheck -Force
    $Item | Add-Member -NotePropertyName CurrentControl -NotePropertyValue $currentText -Force
    $Item | Add-Member -NotePropertyName StatusControl -NotePropertyValue $statusText -Force
    $Item | Add-Member -NotePropertyName DetailsControl -NotePropertyValue $detailsText -Force
    $Item | Add-Member -NotePropertyName ChoiceControls -NotePropertyValue $choiceControls -Force
    $Item | Add-Member -NotePropertyName AdminBadgeControl -NotePropertyValue $adminBadge -Force
    return $border
}

foreach ($item in $script:Settings) {
    $card = New-SettingCard $item
    switch ($item.Tab) {
        'User' { [void]$UserSettingsPanel.Children.Add($card) }
        'System' { [void]$SystemSettingsPanel.Children.Add($card) }
        'Both' { [void]$BothSettingsPanel.Children.Add($card) }
        'Install tools' { [void]$ToolSettingsPanel.Children.Add($card) }
        'Tool shortcuts' { [void]$ShortcutSettingsPanel.Children.Add($card) }
        default { throw "Setting '$($item.Id)' asks for unknown tab '$($item.Tab)'." }
    }
}

if ($UiSelfTest) {
    if ($script:ActionButtons | Where-Object IsEnabled) { throw 'Action buttons must remain disabled until the initial state scan finishes.' }
    $adminSettings = @($script:Settings | Where-Object RequiresAdmin)
    if ($adminSettings | Where-Object { -not $_.AdminBadgeControl }) { throw 'Every setting that requires administrator approval must show an admin badge.' }
    if (-not $AdminSummaryText) { throw 'The selected administrator-change summary is unavailable.' }
    # Every tab must hold cards, so a renamed tab cannot leave an empty one.
    if ($ScopeTabs.Items.Count -ne @($script:Settings | Group-Object Tab).Count) {
        throw "Every tab must hold cards: $($ScopeTabs.Items.Count) tabs for $(@($script:Settings | Group-Object Tab).Count) groups of cards."
    }
    "UI self-test passed: $($script:Settings.Count) setting cards across $($ScopeTabs.Items.Count) tabs."
    $window.Close()
    exit 0
}

function Refresh-UI {
    foreach ($item in $script:Settings) {
        $item.ApplyControl.IsChecked = $item.Selected
        $item.CurrentControl.Text = $item.CurrentState.DisplayText
        $item.CurrentControl.ToolTip = if ($item.CurrentState.Details) { $item.CurrentState.Details } else { $null }
        $item.CurrentControl.Foreground = switch ($item.CurrentState.Status) {
            'Preferred' { '#16803C' }
            'Error' { '#B42318' }
            'Unavailable' { '#627D98' }
            default { '#B45309' }
        }
        $item.StatusControl.Text = $item.Status
        $item.StatusControl.Foreground = switch ($item.Status) {
            'Succeeded' { '#16803C' }
            'Failed' { '#B42318' }
            'Partially applied' { '#B45309' }
            'Applied with caveat' { '#B45309' }
            'Running' { '#0B6EBD' }
            default { '#334E68' }
        }
        $item.DetailsControl.Text = $item.Details
        foreach ($radio in $item.ChoiceControls) {
            $radio.IsChecked = ($radio.Tag.Value -eq $item.DesiredState)
        }
    }
    Update-SelectionSummary
    $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Background)
}

function Update-CurrentStates {
    Set-ActionButtonsEnabled $false
    try {
        $count = $script:Settings.Count
        for ($i = 0; $i -lt $count; $i++) {
            $item = $script:Settings[$i]
            $SummaryText.Text = "Reading setting $($i + 1) of $count..."
            Write-Log 'DEBUG' "STATE READ BEGIN [$($item.Id)]"
            $item.CurrentState = Get-SettingState $item
            Write-Log 'DEBUG' "STATE READ $($item.CurrentState.Status.ToUpperInvariant()) [$($item.Id)] $($item.CurrentState.DisplayText)"
            $ProgressBar.Value = [math]::Round((($i + 1) / $count) * 100)
            Refresh-UI
        }
        $preferred = @($script:Settings | Where-Object { $_.CurrentState.Status -eq 'Preferred' }).Count
        $unreadable = @($script:Settings | Where-Object { $_.CurrentState.Status -in @('Error','Unavailable') }).Count
        $SummaryText.Text = "$preferred of $count settings already use your preferred choice. Nothing changes until you click Apply checked changes."
        if ($unreadable) { $SummaryText.Text += " $unreadable setting$(if ($unreadable -eq 1) { '' } else { 's' }) could not be evaluated and will not be auto-selected." }
        Write-Log 'INFO' "State refresh complete: $preferred of $count preferred."
    } finally {
        $ProgressBar.Value = 0
        Set-ActionButtonsEnabled $true
    }
}

function Complete-ApplyChanges([array]$Selected, [hashtable]$AdministratorResults) {
    $success = 0; $partial = 0; $failed = 0; $needsExplorer = $false; $needsRestart = $false
    $applyResults = New-Object System.Collections.ArrayList
    $ProgressBar.IsIndeterminate = $false
    for ($i = 0; $i -lt $Selected.Count; $i++) {
        $item = $Selected[$i]
        $item.Status = 'Running'; $item.Details = 'Changing this setting...'
        $SummaryText.Text = "Changing $($i + 1) of $($Selected.Count): $($item.Name)"
        Refresh-UI
        $result = Invoke-SettingChange $item $AdministratorResults
        [void]$applyResults.Add($result)
        if ($result.Outcome -eq 'Succeeded') {
            $success++
            if ($item.RestartExplorer) { $needsExplorer = $true }
            if ($item.RestartRequired) { $needsRestart = $true }
        } else {
            if ($result.Outcome -eq 'PartiallyApplied') {
                $partial++
            } else {
                $failed++
            }
            if (@($result.Components | Where-Object Outcome -eq 'Succeeded').Count) {
                if ($item.RestartExplorer) { $needsExplorer = $true }
                if ($item.RestartRequired) { $needsRestart = $true }
            }
        }
        $ProgressBar.Value = [math]::Round((($i + 1) / $Selected.Count) * 100)
        Refresh-UI
    }

    if ($needsExplorer -and $RestartExplorerCheckBox.IsChecked) {
        [void](Restart-DesktopExplorer)
    }
    $suffix = if ($needsRestart) { ' Restart or sign out to finish some changes.' } else { '' }
    $SummaryText.Text = "Finished: $success worked; $partial partially applied; $failed failed.$suffix"
    $ProgressBar.Value = 100
    Set-ActionButtonsEnabled $true
    Refresh-UI
    return ,@($applyResults)
}

$AllPreferredButton.Add_Click({
    foreach ($item in $script:Settings) { $item.DesiredState = $item.PreferredState; $item.Selected = $true }
    Refresh-UI
    $SummaryText.Text = 'All settings are checked and set to the choices marked "my preference". Click Apply checked changes when ready.'
})
$NeededButton.Add_Click({
    foreach ($item in $script:Settings) {
        $item.DesiredState = $item.PreferredState
        $item.Selected = ($item.CurrentState.Status -in @('Alternate','Partial'))
    }
    Refresh-UI
    $unknown = @($script:Settings | Where-Object { $_.CurrentState.Status -in @('Error','Unavailable','Unknown') }).Count
    $SummaryText.Text = 'Only settings known not to match your preference are checked.'
    if ($unknown) { $SummaryText.Text += " $unknown unreadable or unavailable setting$(if ($unknown -eq 1) { ' was' } else { 's were' }) left unchecked." }
})
$UncheckButton.Add_Click({
    foreach ($item in $script:Settings) { $item.Selected = $false }
    Refresh-UI
    $SummaryText.Text = 'Everything is unchecked. No setting will be changed.'
})
$RefreshButton.Add_Click({ Update-CurrentStates })
$OpenLogButton.Add_Click({ Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $script:LogFile) })

$ApplyButton.Add_Click({
    $selected = @($script:Settings | Where-Object Selected)
    if (-not $selected) {
        [System.Windows.MessageBox]::Show('Nothing is checked. Tick the settings you want Dingo to change.', 'Nothing selected') | Out-Null
        return
    }
    $preflight = @(Test-PlanPreflight $selected)
    $blocked = @($preflight | Where-Object { -not $_.Available })
    if ($blocked) {
        foreach ($failure in $blocked) {
            $item = $script:Settings | Where-Object Id -eq $failure.Id | Select-Object -First 1
            $item.Status = 'Failed'
            $item.Details = "Preflight failed: $($failure.Message)"
        }
        Refresh-UI
        $message = @($blocked | ForEach-Object { "$($_.Id): $($_.Message)" }) -join [Environment]::NewLine
        [System.Windows.MessageBox]::Show("Dingo did not make any changes because the preflight check failed:`n`n$message", 'Cannot apply this plan', 'OK', 'Warning') | Out-Null
        return
    }
    Set-ActionButtonsEnabled $false
    Write-Log 'INFO' "Applying $($selected.Count) setting(s) as desktop user $([Security.Principal.WindowsIdentity]::GetCurrent().Name)."
    $adminItems = @($selected | Where-Object RequiresAdmin)
    if (-not $adminItems) {
        Complete-ApplyChanges $selected @{}
        return
    }
    foreach ($item in $adminItems) { $item.Status = 'Running'; $item.Details = 'Waiting for the administrator step...' }
    $SummaryText.Text = 'Starting the administrator step...'
    $ProgressBar.IsIndeterminate = $true
    Refresh-UI

    $operation = Start-AdministratorChanges $selected
    if (-not $operation.Process) {
        Complete-ApplyChanges $selected (Complete-AdministratorChanges $operation)
        return
    }

    $pollTimer = New-Object Windows.Threading.DispatcherTimer
    $pollTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $operation | Add-Member -NotePropertyName Timer -NotePropertyValue $pollTimer
    $script:PendingApply = $operation
    $pollTimer.Add_Tick({
        param($sender,$eventArgs)
        $pending = $script:PendingApply
        if (-not $pending) { $sender.Stop(); return }
        if (-not $pending.Process.HasExited) {
            $elapsedTime = (Get-Date) - $pending.Started
            $elapsed = '{0}:{1:00}' -f [math]::Floor($elapsedTime.TotalMinutes),$elapsedTime.Seconds
            $SummaryText.Text = "Administrator step is running ($elapsed elapsed). Windows language downloads can take several minutes."
            return
        }
        $sender.Stop()
        $administratorResults = Complete-AdministratorChanges $pending
        $selectedItems = $pending.Selected
        $script:PendingApply = $null
        Complete-ApplyChanges $selectedItems $administratorResults
    })
    $pollTimer.Start()
})

$window.Add_ContentRendered({ Update-CurrentStates })
$window.Add_Closing({
    param($sender,$eventArgs)
    if (-not $script:PendingApply) { return }
    $eventArgs.Cancel = $true
    $message = if ($script:PendingApply.Process -and -not $script:PendingApply.Process.HasExited) {
        'An administrator-required operation is still running. Keep Dingo open until it finishes so it can verify every change and clean up its temporary files.'
    } else {
        'Dingo is collecting and verifying the administrator results. Please wait for the finished summary before closing the window.'
    }
    [System.Windows.MessageBox]::Show($message, 'Dingo is still working', 'OK', 'Information') | Out-Null
})
$window.Add_Closed({ Write-Log 'INFO' 'Application closed.' })
[void]$window.ShowDialog()
