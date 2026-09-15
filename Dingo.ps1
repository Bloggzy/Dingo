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
    [switch]$RecoveryReport,
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
    [string]$FinalizeFormatState,
    [string]$PlanPath,
    [string]$ResultPath,
    [string]$WorkerLogPath,
    [string]$ProgressPath,
    [string]$CancelPath,
    [string]$TargetUserSid,
    [string]$ToolRoot,
    [Parameter(ValueFromRemainingArguments=$true)]
    [object[]]$UnexpectedArguments
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:LogFile = $null
# Where the elevated worker publishes what it is doing. Empty everywhere
# else, which makes every progress call below a no-op.
# Named apart from the -ProgressPath parameter on purpose: a script parameter
# lives in the script scope, so reusing the name here would wipe the value the
# elevated worker was started with.
$script:WorkerProgressPath = ''
# Named apart from the -CancelPath parameter for the same reason.
$script:WorkerCancelPath = ''
$script:WorkerStep = $null
$script:RemoveValue = '__REMOVE_VALUE__'
$script:LanguageChangePending = $false
$script:InstanceMutex = $null
$script:PendingApply = $null
$script:ApplyInProgress = $false
$script:ApplyRestartExplorer = $false
$script:SettingHandlers = @{}
$script:DingoVersion = '0.7.6'
$script:DeviceIsManaged = $null
$script:ToolCatalogWarning = ''
$script:ToolCatalogCache = $null
# Where tools that carry no installer of their own are put. Every catalog path
# is written with the token below instead of a literal folder, so one option can
# move them all. Initialize-DingoToolRoot fills the token in.
$script:DefaultToolRoot = 'C:\DFIR\Tools'
$script:ToolRootToken = '%DINGO_TOOL_ROOT%'
$script:ToolRootVariableName = 'DINGO_TOOL_ROOT'
# Named apart from the -ToolRoot parameter on purpose: a script parameter lives
# in the script scope, so reusing the name here would wipe the value an elevated
# step was started with.
$script:ActiveToolRoot = $script:DefaultToolRoot
$script:ToolRootWarning = ''
$script:ToolRootRejected = $false
$script:ToolRootRejectMessage = ''
# A folder inside the tools folder, so moving the tools folder moves this too.
$script:ShimDirectory = Join-Path $script:DefaultToolRoot 'bin'
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
# Dingo registers its own handler names so ownership is never in doubt. Only an
# extension pointing at a name starting with this is ever given back.
$script:AssociationProgIdPrefix = 'Dingo.'
# Whatever an extension pointed at before Dingo changed it is kept here, so
# turning the card off restores the old value rather than guessing.
$script:AssociationBackupSubKey = 'Software\Dingo\FileAssociations'
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
if (-not ($SelfTest -or $StateSelfTest -or $UiSelfTest -or $ApplyPreferred -or $WhatIf -or $ListSettings -or $RecoveryReport -or $Help -or $Version -or $Include -or $Exclude -or $script:UnexpectedArguments.Count -or $MachineWorker -or $ElevationBroker -or $FinalizeInternationalSettings -or $WpfHost)) {
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
        # A tools folder asked for on the command line is for this run only, so it
        # is handed to the window rather than saved. The window checks it and says
        # on the Options tab if it cannot be used.
        if ($ToolRoot) { $hostArguments += ' -ToolRoot "{0}"' -f $ToolRoot }
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

function Clear-DisplayPackCache {
    $script:DisplayPackCache = @{}
}

function Get-CachedDisplayLanguagePackSource([string]$Language) {
    # Asking Windows costs a couple of seconds, and the card asks again every
    # time it redraws. The answer only changes when a pack is installed, so it
    # is cached until the next time settings are read.
    if (-not (Get-Variable -Name DisplayPackCache -Scope Script -ErrorAction SilentlyContinue)) { Clear-DisplayPackCache }
    if (-not $script:DisplayPackCache.ContainsKey($Language)) {
        $script:DisplayPackCache[$Language] = try { Get-DisplayLanguagePackSource $Language } catch { '' }
    }
    return [string]$script:DisplayPackCache[$Language]
}

function Test-SettingNeedsLanguageDownload($Setting) {
    # True when the chosen display language has no pack on this computer, so
    # applying it means a Windows Update download rather than a registry write.
    if ($Setting.Kind -ne 'Language') { return $false }
    $choice = try { Get-LocaleChoice (Get-LanguageChoiceTable) $Setting.DesiredState } catch { $null }
    if (-not $choice) { return $false }
    foreach ($pack in @($choice.Packs)) {
        if (Get-CachedDisplayLanguagePackSource $pack) { return $false }
    }
    return $true
}

function Get-PlannedSettingIds {
    # What this run is going to apply. A caveat about a missing prerequisite is
    # wrong when that prerequisite is in the same run, so the advisory asks here
    # first. A command-line run sets the list from its plan. In the window there
    # is no plan until Apply is pressed, so the ticked cards are the answer.
    # Read with Get-Variable: the test suites load Dingo one function at a time
    # and never run a bare assignment at the top of the file.
    $planned = Get-Variable -Name PlannedSettingIds -Scope Script -ErrorAction SilentlyContinue
    if ($planned -and @($planned.Value).Count) { return @($planned.Value) }
    $all = Get-Variable -Name Settings -Scope Script -ErrorAction SilentlyContinue
    if (-not $all -or -not $all.Value) { return @() }
    return @($all.Value | Where-Object { $_.Selected } | ForEach-Object { [string]$_.Id })
}

function Get-SettingAdvisory($Setting) {
    # A language with no display pack on this computer has to be fetched from
    # Windows Update. That is minutes, not seconds, so say so before the person
    # clicks Apply rather than leaving them watching a clock.
    if (Test-SettingNeedsLanguageDownload $Setting) {
        return "This computer has no display pack for $($Setting.DesiredState), so Windows must download one from Windows Update. That one step usually takes about ten minutes, and can hold up the whole run. Dingo waits fifteen minutes at most, stops sooner if nothing is moving, and every other selected change still runs."
    }
    if ($Setting.Id -eq 'windows-update') {
        return 'Registry configuration only: automatic-restart prevention is not verified. This does not cancel pending or user-scheduled restarts, establish effective management policy, or guarantee an uninterrupted processing window. Update notifications, including restart warnings, are suppressed by this selection.'
    }
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
        $planned = @(Get-PlannedSettingIds)
        foreach ($requiredId in @($Setting.Requirements['RequiredTools'])) {
            # Already in this run. Dingo lists a runtime before the tools that
            # need it and applies the plan in that order, so it will be there by
            # the time this one installs. Telling someone to select a card they
            # have already selected reads like they got something wrong.
            if ($planned -contains $requiredId) { continue }
            $required = @(Get-ToolCatalog | Where-Object Id -eq $requiredId)[0]
            if (-not $required) { [void]$missing.Add($requiredId); continue }
            if (-not (Find-InstalledTool $required)) { [void]$missing.Add($required.Name) }
        }
        if ($missing.Count) {
            return "This tool needs $($missing -join ' and '), which is not installed. Select that card as well, or the tool will not start."
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

function Write-OperationJournal($Event, $OperationId, $SettingId, $Scope, $Data) {
    if (-not $script:LogFile) { return }
    # Each process owns its file; worker and GUI never append to the same stream.
    $path = "$($script:LogFile).$PID.journal.jsonl"
    $record = [ordered]@{ SchemaVersion=1; Utc=[DateTime]::UtcNow.ToString('o'); ProcessId=$PID; Event=$Event; OperationId=$OperationId; SettingId=$SettingId; Scope=$Scope; Data=$Data }
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes((ConvertTo-Json $record -Depth 16 -Compress) + "`n")
    $stream = [IO.File]::Open($path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}

function Get-RecoveryReport([string]$Directory) {
    if (-not (Test-Path -LiteralPath $Directory)) { return }
    foreach ($file in @(Get-ChildItem -LiteralPath $Directory -Filter '*.journal.jsonl' -File -ErrorAction Stop)) {
        $pending = @{}
        foreach ($line in [IO.File]::ReadLines($file.FullName)) {
            try {
                $record = ConvertFrom-Json $line -ErrorAction Stop
                if ($record.SchemaVersion -ne 1 -or -not $record.OperationId) { throw 'Invalid journal record.' }
                if ($record.Event -eq 'Started') { $pending[$record.OperationId] = $record }
                elseif ($record.Event -eq 'Completed') { $pending.Remove($record.OperationId) }
            } catch {
                [pscustomobject]@{ Journal=$file.FullName; SettingId=''; Scope=''; Status='Unreadable record'; Details='Journal is incomplete or invalid; inspect it manually. No replay was attempted.' }
            }
        }
        foreach ($record in $pending.Values) {
            [pscustomobject]@{ Journal=$file.FullName; SettingId=$record.SettingId; Scope=$record.Scope; Status='Completion unknown'; Details='A scope started without a durable completion record. It may still be running or may have changed the workstation; reread state and inspect installer processes before retrying.' }
        }
    }
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
    } elseif ($Setting.CanChoose -and $Setting.StateOptions -contains $DisplayText) {
        # A card that offers a list rather than a pair still reports a state it
        # offers as a real choice, not as a half-finished one.
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
    $changed = @($Components | Where-Object { $_.PSObject.Properties['ChangeStatus'] -and $_.ChangeStatus -eq 'Changed' }).Count
    if ($failed -and ($succeeded -or $changed)) { return 'PartiallyApplied' }
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

# The locale choices the region and language cards offer. The first key of each table is the
# preferred one, so the window, the command line, and the README all agree.
# They are built inside a function, because the test suites load Dingo one
# function at a time and never run a bare assignment at the top of the file.
function Get-DateTimeFormatChoices {
    # The date and time formats offered on the card. Every choice sets the same
    # seven Windows values, so a half-applied mixture can never be reported as
    # one of them. iDate is 0 for month first, 1 for day first, 2 for year
    # first. iTime is 1 for a 24-hour clock. iTLZero keeps the leading zero.
    if (-not (Get-Variable -Name DateTimeFormatChoices -Scope Script -ErrorAction SilentlyContinue)) { $script:DateTimeFormatChoices = [ordered]@{
    'ISO-style / 24-hour (yyyy-MM-dd HH:mm)' = @{ sShortDate='yyyy-MM-dd'; sShortTime='HH:mm'; sTimeFormat='HH:mm:ss'; sDate='-'; iDate='2'; iTime='1'; iTLZero='1' }
    'Day first / 24-hour (dd/MM/yyyy HH:mm)' = @{ sShortDate='dd/MM/yyyy'; sShortTime='HH:mm'; sTimeFormat='HH:mm:ss'; sDate='/'; iDate='1'; iTime='1'; iTLZero='1' }
    'Day first / 12-hour (dd/MM/yyyy h:mm tt)' = @{ sShortDate='dd/MM/yyyy'; sShortTime='h:mm tt'; sTimeFormat='h:mm:ss tt'; sDate='/'; iDate='1'; iTime='0'; iTLZero='0' }
    'Day first, dots / 24-hour (dd.MM.yyyy HH:mm)' = @{ sShortDate='dd.MM.yyyy'; sShortTime='HH:mm'; sTimeFormat='HH:mm:ss'; sDate='.'; iDate='1'; iTime='1'; iTLZero='1' }
    'Month first / 24-hour (MM/dd/yyyy HH:mm)' = @{ sShortDate='MM/dd/yyyy'; sShortTime='HH:mm'; sTimeFormat='HH:mm:ss'; sDate='/'; iDate='0'; iTime='1'; iTLZero='1' }
    'Month first / 12-hour (MM/dd/yyyy h:mm tt)' = @{ sShortDate='MM/dd/yyyy'; sShortTime='h:mm tt'; sTimeFormat='h:mm:ss tt'; sDate='/'; iDate='0'; iTime='0'; iTLZero='0' }
    } }
    return $script:DateTimeFormatChoices
}

function Get-MaxRadioChoices {
    # More choices than this on one card become a drop-down list, because a
    # column of radio buttons that long does not fit the card.
    return 3
}

function Get-LanguageChoiceTable {
    if (-not (Get-Variable -Name LanguageChoices -Scope Script -ErrorAction SilentlyContinue)) { $script:LanguageChoices = [ordered]@{
    # Tag is what Windows is asked for. Packs is the display-language download
    # the tag needs, best first. Windows localises some English variants only
    # through a parent pack, so those name the parent as a fallback and Dingo
    # installs the first pack Windows actually offers.
    'Australian English (en-AU)'   = @{ Tag='en-AU'; Packs=@('en-AU','en-GB') }
    'British English (en-GB)'      = @{ Tag='en-GB'; Packs=@('en-GB') }
    'American English (en-US)'     = @{ Tag='en-US'; Packs=@('en-US') }
    'Canadian English (en-CA)'     = @{ Tag='en-CA'; Packs=@('en-CA','en-US','en-GB') }
    'New Zealand English (en-NZ)'  = @{ Tag='en-NZ'; Packs=@('en-NZ','en-GB') }
    'Irish English (en-IE)'        = @{ Tag='en-IE'; Packs=@('en-IE','en-GB') }
    'Indian English (en-IN)'       = @{ Tag='en-IN'; Packs=@('en-IN','en-GB') }
    'South African English (en-ZA)'= @{ Tag='en-ZA'; Packs=@('en-ZA','en-GB') }
    'German (de-DE)'               = @{ Tag='de-DE'; Packs=@('de-DE') }
    'French (fr-FR)'               = @{ Tag='fr-FR'; Packs=@('fr-FR') }
    'Spanish (es-ES)'              = @{ Tag='es-ES'; Packs=@('es-ES') }
    'Italian (it-IT)'              = @{ Tag='it-IT'; Packs=@('it-IT') }
    'Dutch (nl-NL)'                = @{ Tag='nl-NL'; Packs=@('nl-NL') }
    'Japanese (ja-JP)'             = @{ Tag='ja-JP'; Packs=@('ja-JP') }
    } }
    return $script:LanguageChoices
}

function Get-RegionChoiceTable {
    if (-not (Get-Variable -Name RegionChoices -Scope Script -ErrorAction SilentlyContinue)) { $script:RegionChoices = [ordered]@{
    # GeoId is the Windows country number behind Set-WinHomeLocation.
    'Australia (en-AU)'      = @{ Culture='en-AU'; GeoId=12  }
    'United Kingdom (en-GB)' = @{ Culture='en-GB'; GeoId=242 }
    'United States (en-US)'  = @{ Culture='en-US'; GeoId=244 }
    'Canada (en-CA)'         = @{ Culture='en-CA'; GeoId=39  }
    'New Zealand (en-NZ)'    = @{ Culture='en-NZ'; GeoId=183 }
    'Ireland (en-IE)'        = @{ Culture='en-IE'; GeoId=68  }
    'Singapore (en-SG)'      = @{ Culture='en-SG'; GeoId=215 }
    'India (en-IN)'          = @{ Culture='en-IN'; GeoId=113 }
    'South Africa (en-ZA)'   = @{ Culture='en-ZA'; GeoId=209 }
    'Germany (de-DE)'        = @{ Culture='de-DE'; GeoId=94  }
    'France (fr-FR)'         = @{ Culture='fr-FR'; GeoId=84  }
    'Spain (es-ES)'          = @{ Culture='es-ES'; GeoId=217 }
    'Netherlands (nl-NL)'    = @{ Culture='nl-NL'; GeoId=176 }
    'Japan (ja-JP)'          = @{ Culture='ja-JP'; GeoId=122 }
    } }
    return $script:RegionChoices
}

function Get-LocaleChoice([System.Collections.Specialized.OrderedDictionary]$Table, [string]$Label) {
    if (-not $Table.Contains($Label)) { throw "'$Label' is not a choice Dingo offers." }
    return $Table[$Label]
}

function Get-TimeZoneChoices {
    # The real list from this copy of Windows, so a chosen id is always one
    # Set-TimeZone accepts. UTC leads because it is the preferred choice.
    $ids = New-Object System.Collections.ArrayList
    [void]$ids.Add('UTC')
    try {
        foreach ($zone in @(Get-TimeZone -ListAvailable -ErrorAction Stop | Sort-Object Id)) {
            if ($zone.Id -ne 'UTC') { [void]$ids.Add([string]$zone.Id) }
        }
    } catch {
        Write-Log 'WARN' "Could not list the Windows time zones, so only a short built-in list is offered: $($_.Exception.Message)"
        foreach ($id in @('AUS Eastern Standard Time','AUS Central Standard Time','W. Australia Standard Time','Tasmania Standard Time','New Zealand Standard Time','GMT Standard Time','W. Europe Standard Time','Eastern Standard Time','Central Standard Time','Mountain Standard Time','Pacific Standard Time','Singapore Standard Time','India Standard Time','Tokyo Standard Time')) {
            [void]$ids.Add($id)
        }
    }
    return @($ids)
}

function New-Entry {
    param(
        [ValidateSet('User','Machine','ElevatedUser')][string]$Scope,
        [string]$Path,
        [string]$Name,
        $Preferred,
        $Alternate = '__REMOVE_VALUE__',
        [ValidateSet('DWord','QWord','String')][string]$Type = 'DWord',
        [hashtable]$States = $null
    )
    # States gives one value per named choice. A card that offers only a pair
    # leaves it empty and keeps using Preferred and Alternate.
    $stateMap = $null
    if ($States) {
        $stateMap = @{}
        foreach ($key in $States.Keys) { $stateMap[[string]$key] = $States[$key] }
    }
    [PSCustomObject]@{ Scope=$Scope; Path=$Path; Name=$Name; Preferred=$Preferred; Alternate=$Alternate; Type=$Type; States=$stateMap }
}

function Get-EntryWantedValue($Entry, [string]$DesiredState, $Setting) {
    if ($Entry.States -and $Entry.States.ContainsKey($DesiredState)) { return $Entry.States[$DesiredState] }
    if ($DesiredState -eq $Setting.PreferredState) { return $Entry.Preferred }
    return $Entry.Alternate
}

function Get-SettingSection([string]$TabName) {
    # Dingo does two different jobs. Tweaks change how Windows behaves for an
    # account or the computer. Tools put analyst software on the machine and
    # wire it up. They are grouped apart so neither the GUI buttons nor a bare
    # command line ever sweeps one of them up with the other.
    if ($TabName -in @('Install tools','Tool shortcuts','File associations')) { return 'Tools' }
    return 'Tweaks'
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
        [string]$DefaultStateText = '',
        [string[]]$StateChoices = @()
    )
    $options = New-Object System.Collections.ArrayList
    [void]$options.Add($PreferredState)
    if (-not [string]::IsNullOrWhiteSpace($AlternateState)) { [void]$options.Add($AlternateState) }
    # A card can offer a long list instead of a pair. The preferred choice always
    # stays first, so the list order never changes what Dingo recommends.
    foreach ($choice in $StateChoices) {
        if (-not [string]::IsNullOrWhiteSpace($choice) -and $options -notcontains $choice) { [void]$options.Add([string]$choice) }
    }
    if ($Kind -eq 'Package') { [void]$options.Add('Update installed tool') }
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
    $sectionName = Get-SettingSection $tabName
    [PSCustomObject]@{
        Selected=$false; Id=$Id; Category=$Category; Name=$Name; Description=$Description
        PreferredState=$PreferredState; AlternateState=$AlternateState; DesiredState=$PreferredState
        DefaultState=$defaultState; DisplayScope=$displayScope; Tab=$tabName; Section=$sectionName
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

function Get-DingoConfigPath {
    # Per-user and outside the script folder, so changing an option never needs
    # administrator approval and a copied-in Dingo folder stays untouched.
    Join-Path $env:LOCALAPPDATA 'Dingo\config.json'
}

function Test-PathIsOnLocalDrive([string]$Path) {
    # True only for a full path on a drive letter of this computer, with at least
    # one folder name after the drive. A network path is deliberately excluded.
    $value = [string]$Path
    if ($value.Length -lt 4) { return $false }
    if ($value[0] -notmatch '[A-Za-z]' -or $value[1] -ne ':') { return $false }
    if ($value[2] -ne [IO.Path]::DirectorySeparatorChar -and $value[2] -ne [IO.Path]::AltDirectorySeparatorChar) { return $false }
    return $true
}

function Test-ToolRootIsUsable([string]$Value) {
    # Returns the reason the folder cannot be used, or an empty string when it
    # can. One rule set is used by the option, by the command line, and by the
    # elevated worker, so all three agree.
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'Type a folder path.' }
    $trimmed = ([string]$Value).Trim()
    if ($trimmed.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0) { return 'That path holds a character Windows does not allow in a path.' }
    if ($trimmed -match '[*?%"<>|]') { return 'Use a plain folder path, with no * ? % " < > or | in it.' }
    if (-not (Test-PathIsOnLocalDrive $trimmed)) { return 'Use a full path on a drive of this computer, such as D:\DFIR\Tools. A network path is not supported.' }
    try { $full = ([IO.Path]::GetFullPath($trimmed)).TrimEnd('\') } catch { return 'Windows could not read that as a folder path.' }
    if ($full -match '^[A-Za-z]:$') { return 'Choose a folder on the drive, not the drive itself.' }
    $driveRoot = $full.Substring(0,3)
    if (-not (Test-Path -LiteralPath $driveRoot -PathType Container)) { return "Drive $($full.Substring(0,2)) is not on this computer." }
    # A folder on the computer PATH must not be writable by a standard account,
    # or one account could drop a program there that every other account runs.
    # These trees are either owned by Windows or writable by their owner.
    $forbidden = @(
        [PSCustomObject]@{ Path=$env:SystemRoot; Reason='Windows owns that folder.' },
        [PSCustomObject]@{ Path=${env:ProgramFiles}; Reason='That folder is for programs with their own installer.' },
        [PSCustomObject]@{ Path=${env:ProgramFiles(x86)}; Reason='That folder is for programs with their own installer.' },
        [PSCustomObject]@{ Path=(Join-Path $env:SystemDrive 'Users'); Reason='A folder inside an account profile can be changed by that account, and the launcher folder goes on the computer PATH.' }
    )
    foreach ($entry in $forbidden) {
        if ([string]::IsNullOrWhiteSpace([string]$entry.Path)) { continue }
        $root = ([string]$entry.Path).TrimEnd('\')
        if ($full -ieq $root -or $full.StartsWith("$root\", [StringComparison]::OrdinalIgnoreCase)) {
            return "Choose a folder outside $root. $($entry.Reason)"
        }
    }
    return ''
}

function Resolve-ToolRootValue([string]$Value) {
    $reason = Test-ToolRootIsUsable $Value
    if ($reason) { throw $reason }
    return ([IO.Path]::GetFullPath(([string]$Value).Trim())).TrimEnd('\')
}

function Set-DingoToolRoot([string]$Value) {
    $resolved = Resolve-ToolRootValue $Value
    $script:ActiveToolRoot = $resolved
    $script:ShimDirectory = Join-Path $resolved 'bin'
    # Every catalog path carries the token, and every place that uses one asks
    # Windows to expand it, so setting the variable in this process is what gives
    # the token a meaning. A child process inherits it.
    [Environment]::SetEnvironmentVariable($script:ToolRootVariableName, $resolved, 'Process')
    return $resolved
}

function Expand-ToolRootPath([string]$Path) {
    # The token is expanded by Windows like any other environment variable. This
    # wrapper exists so a path that still holds the token after expansion is
    # caught here rather than becoming a folder with a '%' in its name.
    $expanded = [Environment]::ExpandEnvironmentVariables([string]$Path)
    if ($expanded -like "*$($script:ToolRootToken)*") { throw "The tools folder is not set, so '$Path' could not be resolved." }
    return $expanded
}

function Read-DingoToolRootPreference([string]$Path = '') {
    $path = if ($Path) { $Path } else { Get-DingoConfigPath }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    try {
        $decoded = Read-JsonFileTolerantly $path
        return ([string](Get-JsonField $decoded 'toolRoot' '')).Trim()
    } catch {
        $script:ToolRootWarning = "Dingo could not read its options file '$path', so the default tools folder is being used. $($_.Exception.Message)"
        return ''
    }
}

function Save-DingoToolRootPreference([string]$Value, [string]$Path = '') {
    $resolved = Resolve-ToolRootValue $Value
    $path = if ($Path) { $Path } else { Get-DingoConfigPath }
    $directory = [IO.Path]::GetDirectoryName($path)
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
    }
    Write-Utf8FileAtomically $path (ConvertTo-Json -InputObject ([PSCustomObject]@{ toolRoot = $resolved }) -Depth 3)
    Write-Log 'INFO' "Saved the tools folder '$resolved' to $path."
    return $resolved
}

function Initialize-DingoToolRoot {
    # Order: what an elevated step was told on its command line, then the saved
    # option, then the built-in default. The elevated step is told explicitly
    # because it can run as another account, which has another options file.
    $wanted = if ($ToolRoot) { ([string]$ToolRoot).Trim() } else { Read-DingoToolRootPreference }
    if ($wanted) {
        $reason = Test-ToolRootIsUsable $wanted
        if ($reason) {
            # An elevated step must never quietly install somewhere else than
            # the window asked for, so the flag is checked by that step and the
            # run is refused with this reason.
            $script:ToolRootRejected = $true
            $script:ToolRootRejectMessage = "The tools folder '$wanted' cannot be used. $reason"
            $script:ToolRootWarning = "The tools folder '$wanted' cannot be used, so $($script:DefaultToolRoot) is being used instead. $reason"
            $wanted = ''
        }
    }
    if (-not $wanted) { $wanted = $script:DefaultToolRoot }
    return (Set-DingoToolRoot $wanted)
}

function ConvertTo-ToolDefinition($Raw) {
    $id = [string](Get-JsonField $Raw 'id' '')
    if ($id -notmatch '^tool-[a-z0-9][a-z0-9-]*$') { throw "Tool id '$id' must look like 'tool-example'." }
    $name = [string](Get-JsonField $Raw 'name' '')
    if ([string]::IsNullOrWhiteSpace($name)) { throw "Tool '$id' has no name." }

    $install = Get-JsonField $Raw 'install' $null
    $installKind = [string](Get-JsonField $install 'kind' 'winget')
    if ($installKind -notin @('winget','script','github-release')) { throw "Tool '$id' uses install kind '$installKind', which this version of Dingo cannot run." }
    $package = [string](Get-JsonField $install 'package' '')
    $url = [string](Get-JsonField $install 'url' '')
    $dest = [string](Get-JsonField $install 'dest' '')
    $repo = [string](Get-JsonField $install 'repo' '')
    $assetPattern = [string](Get-JsonField $install 'assetPattern' '')
    $expectedHash = [string](Get-JsonField $install 'sha256' '')
    if ($expectedHash -and $expectedHash -notmatch '^[0-9a-fA-F]{64}$') { throw "Tool '$id' needs a 64-character SHA256 hash." }
    if ($installKind -eq 'winget') {
        if ([string]::IsNullOrWhiteSpace($package)) { throw "Tool '$id' has no winget package id." }
    } elseif ($installKind -eq 'github-release') {
        # Dingo builds the address itself from the repository name, so a release
        # download can never be pointed at another host by the catalog.
        if ($repo -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,98}/[A-Za-z0-9][A-Za-z0-9._-]{0,98}$') { throw "Tool '$id' needs a GitHub repository written as 'owner/name'." }
        if ([string]::IsNullOrWhiteSpace($assetPattern)) { throw "Tool '$id' needs an assetPattern naming the release file to download." }
        # A pattern may hold * and ?, because a release file carries its version.
        # Anything that could turn it into a path is refused.
        if ($assetPattern -match '[\\/:"<>|]' -or $assetPattern -match '[\x00-\x1f]') { throw "Tool '$id' has an assetPattern that is not a usable file name." }
        if ($assetPattern -notlike '*.zip') { throw "Tool '$id' must name a .zip release file, because Dingo unpacks nothing else." }
        if ([string]::IsNullOrWhiteSpace($dest)) { throw "Tool '$id' needs a dest folder for its release download." }
    } else {
        # A downloaded installer script runs with administrator rights, so refuse
        # anything that is not fetched over TLS from a named host.
        if ($url -notmatch '^https://[^/\s]+/\S+$') { throw "Tool '$id' needs an https:// url for its install script." }
        if ([string]::IsNullOrWhiteSpace($dest)) { throw "Tool '$id' needs a dest folder for its install script." }
    }
    $scope = [string](Get-JsonField $install 'scope' 'machine')
    if ($scope -notin @('machine','user')) { throw "Tool '$id' has scope '$scope'; use 'machine' or 'user'." }
    $defaultTimeout = switch ($installKind) { 'script' { 45 }; 'github-release' { 30 }; default { 15 } }
    $timeoutMinutes = [int](Get-JsonField $install 'timeoutMinutes' $defaultTimeout)
    if ($timeoutMinutes -lt 1 -or $timeoutMinutes -gt 240) { throw "Tool '$id' has a timeout of $timeoutMinutes minutes; use 1 to 240." }

    $rules = New-Object System.Collections.ArrayList
    $detectMode = [string](Get-JsonField $Raw 'detectMode' 'any')
    if ($detectMode -notin @('any','all')) { throw "Tool '$id' needs detectMode 'any' or 'all'." }
    foreach ($rawRule in @(Get-JsonField $Raw 'detect' @())) {
        $ruleKind = [string](Get-JsonField $rawRule 'kind' '')
        if ($ruleKind -notin @('uninstall-key','file','command')) { throw "Tool '$id' has an unknown detect rule '$ruleKind'." }
        $requiredField = switch ($ruleKind) { 'uninstall-key' { 'match' }; 'file' { 'path' }; 'command' { 'command' } }
        if ([string]::IsNullOrWhiteSpace([string](Get-JsonField $rawRule $requiredField ''))) {
            throw "Tool '$id' has a $ruleKind rule without '$requiredField'."
        }
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
        # A tool whose program carries its version in the file name, such as
        # hayabusa-4.1.0-win-x64.exe, needs one steady launcher name instead.
        $shimName = [string](Get-JsonField $rawShims 'name' '')
        if ($shimName -and $shimName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
            throw "Tool '$id' has a shim named '$shimName', which is not a usable file name."
        }
        $shims = [PSCustomObject]@{
            From = $from
            Pattern = [string](Get-JsonField $rawShims 'pattern' '*.exe')
            Recurse = [bool](Get-JsonField $rawShims 'recurse' $true)
            Name = $shimName
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

    # A tool may want to open some file types. Windows only allows this for an
    # extension nothing has claimed yet, which is checked when the card is read.
    $associations = New-Object System.Collections.ArrayList
    foreach ($rawAssociation in @(Get-JsonField $Raw 'associations' @())) {
        $extension = [string](Get-JsonField $rawAssociation 'extension' '')
        $associationTarget = [string](Get-JsonField $rawAssociation 'target' '')
        if ($extension -notmatch '^\.[A-Za-z0-9][A-Za-z0-9_-]{0,15}$') {
            throw "Tool '$id' has a file association for '$extension', which is not a usable extension."
        }
        if ([string]::IsNullOrWhiteSpace($associationTarget)) { throw "Tool '$id' has a file association for '$extension' with no target." }
        [void]$associations.Add([PSCustomObject]@{
            # Every entry carries a scope, because New-Setting reads it to decide
            # whether a card needs administrator approval. File types never do.
            Scope = 'User'
            Extension = $extension.ToLowerInvariant()
            Target = $associationTarget
            Description = [string](Get-JsonField $rawAssociation 'description' "$name file")
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
        Sha256 = $expectedHash
        Dest = $dest
        Repo = $repo
        AssetPattern = $assetPattern
        Arguments = @(Get-JsonField $install 'arguments' @())
        Shims = $shims
        Shortcuts = @($shortcuts)
        Associations = @($associations)
        Requires = @(Get-JsonField $Raw 'requires' @())
        TimeoutSeconds = ($timeoutMinutes * 60)
        Detect = @($rules)
        DetectMode = $detectMode
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
            # .txt and .log are deliberately absent. The Windows Notepad app owns
            # them through a protected user choice that nothing can take.
            associations=@(
                [PSCustomObject]@{ extension='.json'; target='%ProgramFiles%/Notepad++/notepad++.exe'; description='JSON file' },
                [PSCustomObject]@{ extension='.md'; target='%ProgramFiles%/Notepad++/notepad++.exe'; description='Markdown file' },
                [PSCustomObject]@{ extension='.yml'; target='%ProgramFiles%/Notepad++/notepad++.exe'; description='YAML file' },
                [PSCustomObject]@{ extension='.yaml'; target='%ProgramFiles%/Notepad++/notepad++.exe'; description='YAML file' },
                [PSCustomObject]@{ extension='.ini'; target='%ProgramFiles%/Notepad++/notepad++.exe'; description='Configuration file' },
                [PSCustomObject]@{ extension='.conf'; target='%ProgramFiles%/Notepad++/notepad++.exe'; description='Configuration file' }
            )
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
                url='https://raw.githubusercontent.com/EricZimmerman/Get-ZimmermanTools/d808d1dfe6446faf884576a8a1c11b6875197a19/Get-ZimmermanTools.ps1'
                sha256='B9122527E7049D2AB3F9A58BC972189AAC62FAD9A83FDA59EA6B70C7360D7834'
                dest='%DINGO_TOOL_ROOT%\EZTools'
                arguments=@('-NetVersion','9')
                timeoutMinutes=45
            }
            shims=[PSCustomObject]@{ from='%DINGO_TOOL_ROOT%/EZTools/net9'; pattern='*.exe'; recurse=$true }
            # Timeline Explorer is the reason most analysts open a csv at all.
            # .dat goes to Registry Explorer: on an analysis VM a .dat file is
            # almost always a registry hive, NTUSER.DAT or UsrClass.dat. Windows
            # leaves .dat unclaimed, so Dingo can take it.
            associations=@(
                [PSCustomObject]@{ extension='.csv'; target='%DINGO_TOOL_ROOT%/EZTools/net9/TimelineExplorer/TimelineExplorer.exe'; description='Comma separated values' },
                [PSCustomObject]@{ extension='.tsv'; target='%DINGO_TOOL_ROOT%/EZTools/net9/TimelineExplorer/TimelineExplorer.exe'; description='Tab separated values' },
                [PSCustomObject]@{ extension='.dat'; target='%DINGO_TOOL_ROOT%/EZTools/net9/RegistryExplorer/RegistryExplorer.exe'; description='Registry hive' }
            )
            # Get-ZimmermanTools makes no shortcuts at all, so the window tools are
            # invisible in the Start menu. A target that is not on disk is skipped.
            shortcuts=@(
                [PSCustomObject]@{ name='Timeline Explorer'; target='%DINGO_TOOL_ROOT%/EZTools/net9/TimelineExplorer/TimelineExplorer.exe' },
                [PSCustomObject]@{ name='Registry Explorer'; target='%DINGO_TOOL_ROOT%/EZTools/net9/RegistryExplorer/RegistryExplorer.exe' },
                [PSCustomObject]@{ name='MFT Explorer'; target='%DINGO_TOOL_ROOT%/EZTools/net9/MFTExplorer/MFTExplorer.exe' },
                [PSCustomObject]@{ name='ShellBags Explorer'; target='%DINGO_TOOL_ROOT%/EZTools/net9/ShellBagsExplorer/ShellBagsExplorer.exe' },
                [PSCustomObject]@{ name='Jump List Explorer'; target='%DINGO_TOOL_ROOT%/EZTools/net9/JumpListExplorer/JumpListExplorer.exe' },
                [PSCustomObject]@{ name='SDB Explorer'; target='%DINGO_TOOL_ROOT%/EZTools/net9/SDBExplorer/SDBExplorer.exe' },
                [PSCustomObject]@{ name='EZViewer'; target='%DINGO_TOOL_ROOT%/EZTools/net9/EZViewer/EZViewer.exe' }
            )
            requires=@('tool-dotnet-desktop-9')
            # A minimum inventory, not proof that every upstream tool downloaded.
            detectMode='all'
            detect=@(
                [PSCustomObject]@{ kind='file'; path='%DINGO_TOOL_ROOT%/EZTools/net9/TimelineExplorer/TimelineExplorer.exe' },
                [PSCustomObject]@{ kind='file'; path='%DINGO_TOOL_ROOT%/EZTools/net9/RegistryExplorer/RegistryExplorer.exe' },
                [PSCustomObject]@{ kind='file'; path='%DINGO_TOOL_ROOT%/EZTools/net9/EvtxECmd/EvtxECmd.exe' },
                [PSCustomObject]@{ kind='file'; path='%DINGO_TOOL_ROOT%/EZTools/net9/RECmd/RECmd.exe' }
            )
        },
        [PSCustomObject]@{
            id='tool-sqlitebrowser'; name='DB Browser for SQLite'; category='Text and data'
            description='Reads and queries SQLite databases, such as browser and application history.'
            install=[PSCustomObject]@{ kind='winget'; package='DBBrowserForSQLite.DBBrowserForSQLite'; scope='machine' }
            associations=@(
                [PSCustomObject]@{ extension='.db'; target='%ProgramFiles%/DB Browser for SQLite/DB Browser for SQLite.exe'; description='SQLite database' },
                [PSCustomObject]@{ extension='.sqlite'; target='%ProgramFiles%/DB Browser for SQLite/DB Browser for SQLite.exe'; description='SQLite database' },
                [PSCustomObject]@{ extension='.sqlite3'; target='%ProgramFiles%/DB Browser for SQLite/DB Browser for SQLite.exe'; description='SQLite database' }
            )
            detect=@(
                [PSCustomObject]@{ kind='uninstall-key'; match='DB Browser for SQLite*' },
                [PSCustomObject]@{ kind='file'; path='%ProgramFiles%\DB Browser for SQLite\DB Browser for SQLite.exe' }
            )
        },
        [PSCustomObject]@{
            id='tool-memprocfs'; name='MemProcFS'; category='Memory'
            description='Reads a memory image as a file system you can browse, and runs a forensic analysis over it. Command-line tool. Downloaded from the author''s own GitHub releases and unpacked into the tools folder.'
            install=[PSCustomObject]@{
                kind='github-release'; scope='machine'
                repo='ufrisk/MemProcFS'
                assetPattern='MemProcFS_files_and_binaries_v*-win_x64-*.zip'
                dest='%DINGO_TOOL_ROOT%\MemProcFS'
            }
            shims=[PSCustomObject]@{ from='%DINGO_TOOL_ROOT%/MemProcFS'; pattern='MemProcFS.exe'; recurse=$false }
            detect=@(
                [PSCustomObject]@{ kind='file'; path='%DINGO_TOOL_ROOT%/MemProcFS/MemProcFS.exe' }
            )
        },
        [PSCustomObject]@{
            id='tool-volatility3'; name='Volatility 3'; category='Memory'
            description='Memory image analysis framework. Dingo takes the standalone Windows programs, so no Python install is needed. Command-line tools vol and volshell.'
            install=[PSCustomObject]@{
                kind='github-release'; scope='machine'
                repo='volatilityfoundation/volatility3'
                assetPattern='volatility3-win-exes-*.zip'
                dest='%DINGO_TOOL_ROOT%\Volatility3'
            }
            shims=[PSCustomObject]@{ from='%DINGO_TOOL_ROOT%/Volatility3'; pattern='*.exe'; recurse=$false }
            detect=@(
                [PSCustomObject]@{ kind='file'; path='%DINGO_TOOL_ROOT%/Volatility3/vol.exe' }
            )
        },
        [PSCustomObject]@{
            id='tool-hayabusa'; name='Hayabusa'; category='Event logs'
            description='Scans Windows event logs with Sigma rules and writes a timeline. Command-line tool. The program file carries its version, so Dingo makes one launcher called hayabusa that points at the newest copy.'
            install=[PSCustomObject]@{
                kind='github-release'; scope='machine'
                repo='Yamato-Security/hayabusa'
                assetPattern='hayabusa-*-win-x64.zip'
                dest='%DINGO_TOOL_ROOT%\Hayabusa'
            }
            shims=[PSCustomObject]@{ from='%DINGO_TOOL_ROOT%/Hayabusa'; pattern='hayabusa-*-win-x64.exe'; recurse=$false; name='hayabusa' }
            detect=@(
                [PSCustomObject]@{ kind='file'; path='%DINGO_TOOL_ROOT%/Hayabusa/hayabusa-*-win-x64.exe' }
            )
        },
        [PSCustomObject]@{
            id='tool-duckdb'; name='DuckDB'; category='Text and data'
            description='Runs SQL over csv, json, and parquet files straight from disk, with no database to load first. Command-line tool.'
            install=[PSCustomObject]@{
                kind='github-release'; scope='machine'
                repo='duckdb/duckdb'
                assetPattern='duckdb_cli-windows-amd64.zip'
                dest='%DINGO_TOOL_ROOT%\DuckDB'
            }
            shims=[PSCustomObject]@{ from='%DINGO_TOOL_ROOT%/DuckDB'; pattern='duckdb.exe'; recurse=$false }
            detect=@(
                [PSCustomObject]@{ kind='file'; path='%DINGO_TOOL_ROOT%/DuckDB/duckdb.exe' }
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
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction Stop)) {
            $values = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
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

function Find-ToolDetectionRule($rule) {
        if ($rule.Kind -eq 'uninstall-key') {
            $entry = Get-UninstallEntry $rule.Match
            if ($entry) { return [PSCustomObject]@{ Version=(Get-DisplayVersion $entry.Version); Evidence="Windows lists it as '$($entry.Name)'." } }
        } elseif ($rule.Kind -eq 'file') {
            $path = Expand-ToolRootPath $rule.Path
            if ($path.Contains('*') -or $path.Contains('?')) {
                # A wildcard lets a rule match a versioned folder, such as the
                # .NET runtime, whose exact patch number is not known in advance.
                $matches = @(try { Get-Item -Path $path -ErrorAction Stop | Sort-Object Name -Descending }
                    catch [System.Management.Automation.ItemNotFoundException] { })
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
    return $null
}

function Get-RestartInstruction([string[]]$SettingNames, [string]$ThenDo = 'Then click Read settings again.') {
    # The last sentence differs by where it is read. A window has a button to
    # press; a command line has a command to run again.
    $names = @($SettingNames | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
    if ($names.Count -eq 1) {
        return "$($names[0]) needs you to sign out and back in, or restart Windows, before it can finish applying. $ThenDo"
    }
    if ($names.Count -gt 1) {
        return "These settings need you to sign out and back in, or restart Windows, before they can finish applying: $($names -join ', '). $ThenDo"
    }
    "Sign out and back in, or restart Windows, to finish applying the selected settings. $ThenDo"
}

function Show-RestartNotice([string]$Message) {
    # The sentence at the foot of the window is easy to miss, and a setting
    # that is not finished looks finished. So the same words are also put in
    # front of the person as a box they must dismiss. There is no window
    # during a test run, and no box is shown then.
    if (-not (Get-Variable -Name DingoWindow -Scope Script -ErrorAction SilentlyContinue)) { return $false }
    if (-not $script:DingoWindow) { return $false }
    try {
        [void][Windows.MessageBox]::Show($script:DingoWindow, $Message, 'Sign out to finish applying', 'OK', 'Exclamation')
        return $true
    } catch {
        Write-Log 'WARN' "Could not show the restart notice: $($_.Exception.Message)"
        return $false
    }
}

function Set-SummaryEmphasis($Control, [bool]$Strong) {
    # Plain grey for ordinary results, and the warning colour when something
    # is still waiting on the person.
    if (-not $Control -or -not $Control.PSObject.Properties['Foreground']) { return }
    $Control.Foreground = if ($Strong) { '#8A2B21' } else { '#334E68' }
    $Control.FontWeight = if ($Strong) { 'Bold' } else { 'Normal' }
}

function Get-ToolDetection($Tool) {
    $matched = New-Object Collections.ArrayList
    $missing = New-Object Collections.ArrayList
    $mode = [string](Get-JsonField $Tool 'DetectMode' 'any')
    foreach ($rule in @($Tool.Detect)) {
        $found = Find-ToolDetectionRule $rule
        if ($found) { [void]$matched.Add($found); if ($mode -eq 'any') { break } }
        else {
            $label = switch ($rule.Kind) { 'file' { $rule.Path }; 'command' { $rule.Command }; default { $rule.Match } }
            [void]$missing.Add([string]$label)
        }
    }
    $complete = if ($mode -eq 'all') { $matched.Count -gt 0 -and $missing.Count -eq 0 } else { $matched.Count -gt 0 }
    [PSCustomObject]@{
        Complete=$complete; MatchedCount=$matched.Count; RequiredCount=@($Tool.Detect).Count; Mode=$mode
        Version=$(if ($matched.Count) { $matched[0].Version } else { '' })
        Evidence=(@($matched | ForEach-Object { $_.Evidence }) -join ' '); Missing=@($missing)
    }
}

function Find-InstalledTool($Tool) {
    $detection = Get-ToolDetection $Tool
    if ($detection.Complete) { return $detection }
    return $null
}

function Get-MissingToolRequirements($Tool) {
    foreach ($id in @($Tool.Requires)) {
        $required = Get-ToolCatalog | Where-Object Id -eq $id | Select-Object -First 1
        if (-not $required) { [string]$id }
        elseif (-not (Find-InstalledTool $required)) { [string]$required.Name }
    }
}

function Install-WingetPackage($Tool, [bool]$AllowUpgrade = $false) {
    $TimeoutSeconds = $Tool.TimeoutSeconds
    $winget = Get-WingetPath
    if (-not $winget) { throw 'winget is not available on this computer, so Dingo cannot install anything.' }
    $arguments = @(
        'install','--id',$Tool.Package,'--exact','--source',$Tool.Source,'--scope',$Tool.Scope,
        '--accept-package-agreements','--accept-source-agreements','--disable-interactivity','--silent'
    )
    if (-not $AllowUpgrade) { $arguments += '--no-upgrade' }
    Write-Log 'INFO' "Installing $($Tool.Name): winget $($arguments -join ' ')"
    $run = Invoke-ChildProcess $winget $arguments $TimeoutSeconds "The winget install of $($Tool.Package)"
    Write-Log 'DEBUG' "winget exit code $($run.ExitCode) for $($Tool.Package): $($run.Output)"
    # UPDATE_NOT_APPLICABLE (0x8A15002B), or PACKAGE_ALREADY_INSTALLED
    # (0x8A150061) when --no-upgrade prevented an implicit upgrade. The shared
    # executor still verifies installation using the catalog's detection rules.
    if ($run.ExitCode -eq -1978335189 -or (-not $AllowUpgrade -and $run.ExitCode -eq -1978335135)) {
        Write-Log 'INFO' "$($Tool.Name) is already installed; winget made no change."
        return
    }
    if ($run.ExitCode -ne 0) {
        throw "winget exited with code $($run.ExitCode) for $($Tool.Package). $(Get-OutputTail $run.Output)"
    }
}

function ConvertTo-NativeArgument([AllowEmptyString()][string]$Value) {
    # Windows CRT argv rules: escape quotes and double trailing backslashes.
    if ($Value.IndexOf([char]0) -ge 0) { throw 'A process argument contains a null character.' }
    return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}

function Initialize-ProcessOutputReader {
    if ('Dingo.ProcessOutput' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System.IO;
using System.Text;
using System.Threading.Tasks;
using System.Runtime.InteropServices;
using System.ComponentModel;
namespace Dingo {
    public sealed class InstallerJob : System.IDisposable {
        [StructLayout(LayoutKind.Sequential)] struct BasicLimits {
            public long PerProcess, PerJob; public uint Flags; public System.UIntPtr Min, Max;
            public uint ActiveLimit; public System.UIntPtr Affinity; public uint Priority, Scheduling;
        }
        [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong A,B,C,D,E,F; }
        [StructLayout(LayoutKind.Sequential)] struct Limits {
            public BasicLimits Basic; public IoCounters Io; public System.UIntPtr ProcessMemory, JobMemory, PeakProcess, PeakJob;
        }
        [StructLayout(LayoutKind.Sequential)] struct Accounting {
            public long A,B,C,D; public uint Faults, Total, Active, Terminated;
        }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern System.IntPtr CreateJobObject(System.IntPtr security, string name);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(System.IntPtr job, int kind, ref Limits info, uint size);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(System.IntPtr job, int kind, out Accounting info, uint size, System.IntPtr length);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(System.IntPtr job, System.IntPtr process);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(System.IntPtr handle);
        System.IntPtr handle;
        public InstallerJob() {
            handle=CreateJobObject(System.IntPtr.Zero,null);
            if (handle==System.IntPtr.Zero) throw new Win32Exception();
            var limits=new Limits(); limits.Basic.Flags=0x2000;
            if (!SetInformationJobObject(handle,9,ref limits,(uint)Marshal.SizeOf(typeof(Limits)))) { var error=new Win32Exception(); Dispose(); throw error; }
        }
        public void Assign(System.Diagnostics.Process process) {
            if (!AssignProcessToJobObject(handle,process.Handle)) throw new Win32Exception();
        }
        public uint ActiveProcesses {
            get { Accounting info; if (!QueryInformationJobObject(handle,1,out info,(uint)Marshal.SizeOf(typeof(Accounting)),System.IntPtr.Zero)) throw new Win32Exception(); return info.Active; }
        }
        public void Dispose() { if (handle!=System.IntPtr.Zero) { CloseHandle(handle); handle=System.IntPtr.Zero; } }
    }
    public static class ProcessOutput {
        public static async Task<string> ReadTailAsync(StreamReader reader) {
            var tail = new StringBuilder();
            var buffer = new char[4096];
            int count;
            while ((count = await reader.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false)) > 0) {
                tail.Append(buffer, 0, count);
                if (tail.Length > 65536) tail.Remove(0, tail.Length - 65536);
            }
            return tail.ToString();
        }
    }
}
'@
}

function Stop-InstallerProcessTree($Process) {
    if ($Process.HasExited) { return }
    $stop = New-Object Diagnostics.ProcessStartInfo
    $stop.FileName = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    $stop.Arguments = "/PID $($Process.Id) /T /F"
    $stop.UseShellExecute = $false
    $stop.CreateNoWindow = $true
    $stop.RedirectStandardOutput = $true
    $stop.RedirectStandardError = $true
    $killer = $null
    try {
        $killer = [Diagnostics.Process]::Start($stop)
        $discardOutput = $killer.StandardOutput.ReadToEndAsync()
        $discardError = $killer.StandardError.ReadToEndAsync()
        if (-not $killer.WaitForExit(5000)) { $killer.Kill() }
        elseif ($killer.ExitCode -ne 0) { Write-Log 'WARN' "Process-tree termination returned $($killer.ExitCode): $($discardError.Result)" }
    } catch { Write-Log 'WARN' "Process-tree termination failed: $($_.Exception.Message)" }
    finally { if ($killer) { $killer.Dispose() } }
    if (-not $Process.HasExited) { try { $Process.Kill() } catch { Write-Log 'WARN' 'Installer process could not be stopped.' } }
    [void]$Process.WaitForExit(5000)
}

function Invoke-ChildProcess([string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds, [string]$Label) {
    # Start-Process -PassThru does not keep the process handle, so its ExitCode
    # stays empty and a success would look like a failure. Own the handle here.
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    if ($TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 14400) { throw 'Process timeout must be between 1 and 14400 seconds.' }
    Initialize-ProcessOutputReader
    $startInfo.Arguments = (@($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = $null
    $job = New-Object Dingo.InstallerJob
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $process = [Diagnostics.Process]::Start($startInfo)
        try { $job.Assign($process) } catch {
            Stop-InstallerProcessTree $process
            throw "Could not assign the installer to a process job; execution stopped: $($_.Exception.Message)"
        }
        # Read both pipes while the process runs, or a full pipe buffer deadlocks it.
        $standardOutput = [Dingo.ProcessOutput]::ReadTailAsync($process.StandardOutput)
        $standardError = [Dingo.ProcessOutput]::ReadTailAsync($process.StandardError)
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $job.Dispose()
            throw "$Label timed out after $TimeoutSeconds seconds. Process-tree termination was attempted; installation may be partial and detached installer services may still be active. Inspect the workstation before retrying."
        }
        while ($job.ActiveProcesses -gt 0) {
            if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                $job.Dispose()
                throw "$Label descendants timed out after $TimeoutSeconds seconds; installation may be partial. Inspect before retrying."
            }
            Start-Sleep -Milliseconds 50
        }
        if (-not $standardOutput.Wait(5000) -or -not $standardError.Wait(5000)) { throw "$Label exited but its output pipes stayed open. A descendant may still be running; inspect before retrying." }
        $output = (([string]$standardOutput.Result + ' ' + [string]$standardError.Result) -replace '\s+',' ').Trim()
        return [PSCustomObject]@{ ExitCode = $process.ExitCode; Output = $output }
    } finally {
        $job.Dispose()
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
        Invoke-WebRequest -Uri $Tool.Url -OutFile $scriptPath -UseBasicParsing -TimeoutSec 120 -MaximumRedirection 0 -ErrorAction Stop
        # Record what was actually executed, so a run can be audited afterwards.
        $hash = (Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256 -ErrorAction Stop).Hash
        Write-Log 'INFO' "Install script SHA256 $hash for $($Tool.Name)."
        $expected = [string](Get-JsonField $Tool 'Sha256' '')
        $signature = Get-AuthenticodeSignature -LiteralPath $scriptPath -ErrorAction Stop
        Write-OperationJournal 'InstallerProvenance' ([Guid]::NewGuid().ToString('N')) $Tool.Id $Tool.Scope @{
            Url=$Tool.Url; Sha256=$hash; ExpectedSha256=$expected; SignatureStatus=[string]$signature.Status
            Signer=if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { '' }
        }
        if ($expected -and $hash -ine $expected) { throw "Installer SHA256 mismatch for $($Tool.Name); the script was not executed." }
        if (-not $expected) { Write-Log 'WARN' "No expected SHA256 configured for $($Tool.Name). Recorded provenance is not a trust check." }

        # The catalog names the folder with the tools-folder token, so resolve it
        # here and check the result before a folder is made or a script runs.
        $destination = Expand-ToolRootPath $Tool.Dest
        if (-not (Test-PathIsOnLocalDrive $destination)) { throw "The install folder '$destination' for $($Tool.Name) is not a full path on a drive of this computer." }
        if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
            New-Item -ItemType Directory -Path $destination -Force -ErrorAction Stop | Out-Null
            Write-Log 'INFO' "Created $destination."
        }
        $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-NonInteractive','-File',$scriptPath,'-Dest',$destination) + @($Tool.Arguments)
        Write-Log 'INFO' "Running the $($Tool.Name) install script into $destination."
        $run = Invoke-ChildProcess (Get-PowerShellHostPath) $arguments $Tool.TimeoutSeconds "The $($Tool.Name) install script"
        Write-Log 'DEBUG' "Install script exit code $($run.ExitCode) for $($Tool.Name): $(Get-OutputTail $run.Output 2000)"
        if ($run.ExitCode -ne 0) {
            throw "The $($Tool.Name) install script exited with code $($run.ExitCode). $(Get-OutputTail $run.Output)"
        }
    } finally {
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    }
}

function Expand-DingoZipArchive([string]$ArchivePath, [string]$Destination) {
    # Windows PowerShell 5.1 ships Expand-Archive, but it neither overwrites an
    # existing file nor refuses an entry whose name climbs out of the folder.
    # So every entry is checked first, and only then is anything written.
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $root = ([IO.Path]::GetFullPath($Destination)).TrimEnd('\')
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $planned = New-Object System.Collections.ArrayList
        foreach ($entry in $archive.Entries) {
            $relative = ([string]$entry.FullName).Replace('/', '\')
            if ([string]::IsNullOrWhiteSpace($relative)) { continue }
            if ([IO.Path]::IsPathRooted($relative) -or $relative.Contains(':')) {
                throw "The archive entry '$($entry.FullName)' carries a full path, so nothing was unpacked."
            }
            $target = [IO.Path]::GetFullPath((Join-Path $root $relative))
            if (-not $target.StartsWith("$root\", [StringComparison]::OrdinalIgnoreCase)) {
                throw "The archive entry '$($entry.FullName)' points outside $root, so nothing was unpacked."
            }
            [void]$planned.Add([PSCustomObject]@{ Entry = $entry; Target = $target; IsFolder = [string]::IsNullOrEmpty($entry.Name) })
        }
        $written = 0
        foreach ($item in $planned) {
            if ($item.IsFolder) {
                if (-not (Test-Path -LiteralPath $item.Target -PathType Container)) {
                    New-Item -ItemType Directory -Path $item.Target -Force -ErrorAction Stop | Out-Null
                }
                continue
            }
            $parent = [IO.Path]::GetDirectoryName($item.Target)
            if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
                New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
            }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($item.Entry, $item.Target, $true)
            $written++
        }
        return $written
    } finally { $archive.Dispose() }
}

function Get-GitHubLatestRelease([string]$Repo, [int]$TimeoutSeconds = 60) {
    # Windows PowerShell 5.1 can still default to an older protocol.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $uri = "https://api.github.com/repos/$Repo/releases/latest"
    $headers = @{ 'Accept' = 'application/vnd.github+json'; 'User-Agent' = "Dingo/$script:DingoVersion" }
    return Invoke-RestMethod -Uri $uri -Headers $headers -UseBasicParsing -TimeoutSec $TimeoutSeconds -ErrorAction Stop
}

function Install-GitHubReleasePackage($Tool) {
    # The catalog names a repository and a file pattern, never an address. Dingo
    # builds the address itself, so a catalog entry cannot send the download
    # somewhere else.
    Write-Log 'INFO' "Reading the latest $($Tool.Name) release from github.com/$($Tool.Repo)."
    $release = Get-GitHubLatestRelease $Tool.Repo
    $tag = [string](Get-JsonField $release 'tag_name' '')
    $assets = @(@(Get-JsonField $release 'assets' @()) | Where-Object { ([string](Get-JsonField $_ 'name' '')) -like $Tool.AssetPattern })
    if (-not $assets.Count) { throw "The latest $($Tool.Name) release ($tag) holds no file matching '$($Tool.AssetPattern)'." }
    if ($assets.Count -gt 1) {
        $names = (@($assets | ForEach-Object { [string](Get-JsonField $_ 'name' '') }) -join ', ')
        throw "'$($Tool.AssetPattern)' matches more than one file in the latest $($Tool.Name) release ($tag): $names."
    }
    $assetName = [string](Get-JsonField $assets[0] 'name' '')
    $downloadUrl = [string](Get-JsonField $assets[0] 'browser_download_url' '')
    $expectedPrefix = "https://github.com/$($Tool.Repo)/releases/download/"
    if (-not $downloadUrl.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The download address for $assetName is '$downloadUrl', which is not a release file of $($Tool.Repo)."
    }

    $archivePath = Join-Path $env:TEMP ("Dingo-release-{0}.zip" -f [Guid]::NewGuid().ToString('N'))
    $progress = $ProgressPreference
    try {
        # The progress bar makes Invoke-WebRequest many times slower on a large file.
        $ProgressPreference = 'SilentlyContinue'
        Write-Log 'INFO' "Downloading $assetName from $downloadUrl."
        Invoke-WebRequest -Uri $downloadUrl -OutFile $archivePath -UseBasicParsing -TimeoutSec ([Math]::Min($Tool.TimeoutSeconds, 3600)) -ErrorAction Stop
        # A release file is built fresh for every version, so no hash can be kept
        # in the catalog. Record what was fetched, so a run can be audited later.
        $hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256 -ErrorAction Stop).Hash
        Write-Log 'INFO' "Release file SHA256 $hash for $($Tool.Name) $tag."
        Write-OperationJournal 'InstallerProvenance' ([Guid]::NewGuid().ToString('N')) $Tool.Id $Tool.Scope @{
            Url=$downloadUrl; Sha256=$hash; ExpectedSha256=''; Repository=$Tool.Repo; Tag=$tag; Asset=$assetName
        }

        $destination = Expand-ToolRootPath $Tool.Dest
        if (-not (Test-PathIsOnLocalDrive $destination)) { throw "The install folder '$destination' for $($Tool.Name) is not a full path on a drive of this computer." }
        if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
            New-Item -ItemType Directory -Path $destination -Force -ErrorAction Stop | Out-Null
            Write-Log 'INFO' "Created $destination."
        }
        $written = Expand-DingoZipArchive $archivePath $destination
        Write-Log 'INFO' "Unpacked $written file(s) of $($Tool.Name) $tag into $destination."
    } finally {
        $ProgressPreference = $progress
        Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
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
        $from = Expand-ToolRootPath $tool.Shims.From
        if (-not (Test-Path -LiteralPath $from -PathType Container)) { continue }
        $files = @(Get-ChildItem -LiteralPath $from -Filter $tool.Shims.Pattern -File -Recurse:$tool.Shims.Recurse -ErrorAction SilentlyContinue)
        # A tool that keeps its version in the program name, such as
        # hayabusa-4.1.0-win-x64.exe, leaves the older copies behind when it is
        # updated. One launcher under a steady name points at the newest one.
        if ([string](Get-JsonField $tool.Shims 'Name' '')) { $files = @($files | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1) }
        foreach ($file in $files) {
            $name = [string](Get-JsonField $tool.Shims 'Name' '')
            if (-not $name) { $name = [IO.Path]::GetFileNameWithoutExtension($file.Name) }
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

function Assert-DingoFileOwnership([string]$Path, [ValidateSet('Shim','Shortcut')][string]$Kind) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $file = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Cannot replace '$Path': the destination is a directory or link."
    }
    $owned = if ($Kind -eq 'Shim') {
        @(Get-Content -LiteralPath $Path -ErrorAction Stop) -contains $script:ShimMarker
    } else {
        (Read-ShortcutFile $Path).Description -eq $script:ShortcutMarker
    }
    if (-not $owned) { throw "Cannot replace '$Path': this file was not created by Dingo. Rename or move it before retrying." }
}

function Write-ToolShim([string]$Name, [string]$TargetPath) {
    $shimPath = Join-Path $script:ShimDirectory "$Name.cmd"
    Assert-DingoFileOwnership $shimPath Shim
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
        $expected = Get-ExpectedShims
        foreach ($name in @($expected.Keys)) {
            Assert-DingoFileOwnership (Join-Path $script:ShimDirectory "$name.cmd") Shim
        }
        if (-not (Test-Path -LiteralPath $script:ShimDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $script:ShimDirectory -Force -ErrorAction Stop | Out-Null
            Write-Log 'INFO' "Created $script:ShimDirectory."
        }
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
            $target = Expand-ToolRootPath $shortcut.Target
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
    Assert-DingoFileOwnership $shortcutPath Shortcut
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
        foreach ($name in @($expected.Keys)) {
            Assert-DingoFileOwnership (Join-Path $folder ($name + '.lnk')) Shortcut
        }
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

function Join-WordList([string[]]$Words) {
    $items = @($Words)
    if ($items.Count -le 1) { return ($items -join '') }
    if ($items.Count -eq 2) { return ($items -join ' and ') }
    return (($items[0..($items.Count - 2)] -join ', ') + ' and ' + $items[-1])
}

function Get-AssociationProgId($Association) {
    # One handler name per program, so two tools can never collide, and so a
    # name starting with Dingo. always means Dingo put it there.
    $stem = [IO.Path]::GetFileNameWithoutExtension((Expand-ToolRootPath $Association.Target))
    return $script:AssociationProgIdPrefix + ($stem -replace '[^A-Za-z0-9]', '')
}

function Get-AssociationTarget($Association) {
    # Catalog paths use forward slashes so Tools.json remains easy to edit, but
    # Explorer's shell association launcher can reject an otherwise valid local
    # executable command written in that form. Store a native Windows path.
    return (Expand-ToolRootPath $Association.Target).Replace('/', '\')
}

function Get-ExtensionUserChoice([string]$Extension) {
    $key = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$Extension\UserChoice"
    if (-not (Test-Path -LiteralPath $key)) { return '' }
    $values = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
    if ($values -and $values.PSObject.Properties['ProgId']) { return [string]$values.ProgId }
    return ''
}

function Get-ExtensionHandlerName([string]$Extension) {
    $key = "HKCU:\Software\Classes\$Extension"
    if (-not (Test-Path -LiteralPath $key)) { return '' }
    $values = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
    if ($values -and $values.PSObject.Properties['(default)']) { return [string]$values.'(default)' }
    return ''
}

function Get-AssociationRegistration($Association) {
    $progId = Get-AssociationProgId $Association
    $commandPath = "HKCU:\Software\Classes\$progId\shell\open\command"
    $configuredOpenWithPath = "HKCU:\Software\Classes\$($Association.Extension)\OpenWithProgids"
    # Explorer may copy a used handler into FileExts as REG_NONE. That second
    # reference survives removal from Software\Classes unless it is tracked too.
    $explorerOpenWithPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$($Association.Extension)\OpenWithProgids"
    $command = if (Test-Path -LiteralPath $commandPath) {
        [string](Get-Item -LiteralPath $commandPath -ErrorAction Stop).GetValue('', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    } else { '' }
    $configuredOpenWith = (Test-Path -LiteralPath $configuredOpenWithPath) -and
        (@((Get-Item -LiteralPath $configuredOpenWithPath -ErrorAction Stop).GetValueNames()) -contains $progId)
    $explorerOpenWith = (Test-Path -LiteralPath $explorerOpenWithPath) -and
        (@((Get-Item -LiteralPath $explorerOpenWithPath -ErrorAction Stop).GetValueNames()) -contains $progId)
    [PSCustomObject]@{
        Command = $command
        OpenWithRegistered = [bool]($configuredOpenWith -or $explorerOpenWith)
        ConfiguredOpenWithRegistered = [bool]$configuredOpenWith
        ExplorerOpenWithRegistered = [bool]$explorerOpenWith
    }
}

function Get-AssociationStatus($Association) {
    $target = Get-AssociationTarget $Association
    $progId = Get-AssociationProgId $Association
    $current = Get-ExtensionHandlerName $Association.Extension
    $userChoice = Get-ExtensionUserChoice $Association.Extension
    $registration = Get-AssociationRegistration $Association
    $commandCurrent = $registration.Command -eq ('"{0}" "%1"' -f $target)
    $targetExists = Test-Path -LiteralPath $target -PathType Leaf
    $blocked = [bool]($userChoice -and $userChoice -ne $progId)
    $defaultRegistered = $userChoice -eq $progId -or (-not $userChoice -and $current -eq $progId)
    $state = if (-not $targetExists) { 'ToolMissing' }
        elseif (($defaultRegistered -or $registration.OpenWithRegistered) -and -not $commandCurrent) { 'BrokenRegistration' }
        elseif (-not $defaultRegistered -and $commandCurrent -and $registration.OpenWithRegistered) { 'OpenWithOnly' }
        elseif ($blocked) { 'Blocked' }
        elseif ($defaultRegistered -and $commandCurrent) { 'DefaultRegistered' }
        else { 'Available' }
    return [PSCustomObject]@{
        Extension = $Association.Extension
        ProgId = $progId
        Target = $target
        Current = $current
        UserChoice = $userChoice
        State = $state
        Status = 'Present'
        Command = $registration.Command
        CommandCurrent = [bool]$commandCurrent
        OpenWithRegistered = $registration.OpenWithRegistered
        ConfiguredOpenWithRegistered = $registration.ConfiguredOpenWithRegistered
        ExplorerOpenWithRegistered = $registration.ExplorerOpenWithRegistered
        PreferredSatisfied = [bool]($targetExists -and $commandCurrent -and $registration.ConfiguredOpenWithRegistered -and ($defaultRegistered -or $blocked))
        AlternateSatisfied = [bool]($current -ne $progId -and $userChoice -ne $progId -and -not $registration.OpenWithRegistered)
    }
}

function Send-AssociationChange {
    # Tells Explorer to reread file types, so an open window updates its icons
    # without a sign-out.
    try {
        if (-not ('Dingo.NativeShell' -as [type])) {
            $signature = '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int eventId, uint flags, System.IntPtr item1, System.IntPtr item2);'
            Add-Type -Namespace 'Dingo' -Name 'NativeShell' -MemberDefinition $signature -ErrorAction Stop
        }
        # SHCNE_ASSOCCHANGED with SHCNF_IDLIST.
        [Dingo.NativeShell]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
    } catch {
        Write-Log 'DEBUG' "Could not notify Explorer of the file type change: $($_.Exception.Message)"
    }
}

function Register-AssociationProgId($Association) {
    $progId = Get-AssociationProgId $Association
    $target = Get-AssociationTarget $Association
    $key = "HKCU:\Software\Classes\$progId"
    New-Item -Path "$key\shell\open\command" -Force -ErrorAction Stop | Out-Null
    New-Item -Path "$key\DefaultIcon" -Force -ErrorAction Stop | Out-Null
    Set-ItemProperty -Path $key -Name '(default)' -Value $Association.Description -ErrorAction Stop
    Set-ItemProperty -Path "$key\DefaultIcon" -Name '(default)' -Value ('"{0}",0' -f $target) -ErrorAction Stop
    Set-ItemProperty -Path "$key\shell\open\command" -Name '(default)' -Value ('"{0}" "%1"' -f $target) -ErrorAction Stop
}

function Save-AssociationBackup([string]$Extension, [string]$PreviousHandler) {
    $key = "HKCU:\$script:AssociationBackupSubKey"
    if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
    $existing = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
    # Keep the first value seen. A second apply must not record Dingo's own
    # handler name as the thing to restore.
    if ($existing -and $existing.PSObject.Properties[$Extension]) { return }
    New-ItemProperty -Path $key -Name $Extension -Value $PreviousHandler -PropertyType String -Force | Out-Null
}

function Get-AssociationBackup([string]$Extension) {
    $key = "HKCU:\$script:AssociationBackupSubKey"
    if (-not (Test-Path -LiteralPath $key)) { return '' }
    $values = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
    if ($values -and $values.PSObject.Properties[$Extension]) { return [string]$values.$Extension }
    return ''
}

function Remove-AssociationBackup([string]$Extension) {
    $key = "HKCU:\$script:AssociationBackupSubKey"
    if (-not (Test-Path -LiteralPath $key)) { return }
    Remove-ItemProperty -LiteralPath $key -Name $Extension -Force -ErrorAction SilentlyContinue
}

function Add-AssociationOpenWithEntry($Association) {
    # Works even where the default cannot be changed, so a blocked extension
    # still gains a one-click way to open the tool.
    $key = "HKCU:\Software\Classes\$($Association.Extension)\OpenWithProgids"
    New-Item -Path $key -Force -ErrorAction Stop | Out-Null
    New-ItemProperty -Path $key -Name (Get-AssociationProgId $Association) -Value ([byte[]]@()) -PropertyType Binary -Force -ErrorAction Stop | Out-Null
}

function Remove-AssociationOpenWithEntry($Association) {
    $progId = Get-AssociationProgId $Association
    $keys = @(
        "HKCU:\Software\Classes\$($Association.Extension)\OpenWithProgids",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$($Association.Extension)\OpenWithProgids"
    )
    foreach ($key in $keys) {
        if (-not (Test-Path -LiteralPath $key)) { continue }
        Remove-ItemProperty -LiteralPath $key -Name $progId -Force -ErrorAction SilentlyContinue
        if (-not @((Get-Item -LiteralPath $key).GetValueNames() | Where-Object { $_ }).Count) {
            Remove-Item -LiteralPath $key -Force -ErrorAction SilentlyContinue
        }
    }
}

function Remove-ExtensionHandlerName([string]$Extension) {
    # The registry provider will not delete an unnamed default value by name, so
    # open the key for writing and delete it through the registry API instead.
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Software\Classes\$Extension", $true)
    if (-not $key) { return }
    try { $key.DeleteValue('', $false) } finally { $key.Close() }
}

function Remove-EmptyExtensionKey([string]$Extension) {
    $key = "HKCU:\Software\Classes\$Extension"
    if (-not (Test-Path -LiteralPath $key)) { return }
    $item = Get-Item -LiteralPath $key
    # Leave anything somebody else put under this extension alone. The handler
    # name lives in the unnamed default value, which GetValueNames reports as an
    # empty string, so it has to be read directly or a restored value is lost.
    if ($null -ne $item.GetValue('', $null)) { return }
    if (@($item.GetValueNames() | Where-Object { $_ }).Count -or $item.SubKeyCount) { return }
    Remove-Item -LiteralPath $key -Force -ErrorAction SilentlyContinue
}

function Get-AssociationKindState($Setting) {
    $items = @($Setting.Entries | ForEach-Object { Get-AssociationStatus $_ })
    $preferred = @($items | Where-Object PreferredSatisfied).Count
    $alternate = @($items | Where-Object AlternateSatisfied).Count
    $fallback = @($items | Where-Object State -eq 'OpenWithOnly').Count
    $status = if ($items.Count -and $preferred -eq $items.Count) { 'Preferred' }
        elseif ($items.Count -and $alternate -eq $items.Count) { 'Alternate' } else { 'Partial' }
    $text = if ($status -eq 'Preferred') {
        if ($fallback) { "Configured; Open with fallback for $fallback type(s)" } else { 'Default registrations configured' }
    } elseif ($status -eq 'Alternate') { $Setting.AlternateState } else { 'Associations partly configured' }
    $notes = @($items | ForEach-Object {
        "$($_.Extension): $($_.State); open command valid=$($_.CommandCurrent); configured Open with=$($_.ConfiguredOpenWithRegistered); Explorer Open with=$($_.ExplorerOpenWithRegistered); user choice='$($_.UserChoice)'"
    }) -join '; '
    $result = New-StateResult $status $text "$notes. Checks cover registry configuration and target presence; applications are not launched."
    $result | Add-Member NoteProperty Associations $items
    return $result
}

function Set-AssociationKindPart($Setting, [string]$DesiredState, [string]$Scope, $EntryResults = $null) {
    $failures = New-Object Collections.ArrayList
    foreach ($association in @($Setting.Entries)) {
        $before = [PSCustomObject]@{ Status='Error'; Message='Before-state unavailable.' }
        $outcome = 'Succeeded'; $message = ''
        try {
            $before = Get-AssociationStatus $association
            $progId = $before.ProgId
            if ($DesiredState -eq $Setting.PreferredState) {
                if ($before.State -eq 'ToolMissing') { throw "Target program is missing: $($before.Target)" }
                Register-AssociationProgId $association
                # Preserve any protected user choice. A verified Open With entry
                # is a successful fallback, not a claim that the default changed.
                $choice = Get-ExtensionUserChoice $association.Extension
                if ($choice -and $choice -ne $progId) {
                    $message = "Open with registered; protected default '$choice' retained."
                } else {
                    if ($before.Current -ne $progId) { Save-AssociationBackup $association.Extension $before.Current }
                    $extensionPath = "HKCU:\Software\Classes\$($association.Extension)"
                    if (-not (Test-Path -LiteralPath $extensionPath)) { New-Item -Path $extensionPath -ErrorAction Stop | Out-Null }
                    Set-ItemProperty -Path $extensionPath -Name '(default)' -Value $progId -ErrorAction Stop
                    $message = 'Default and Open with registrations configured; open command verified.'
                }
                # Write this after the extension default. Windows PowerShell 5.1's
                # registry provider can recreate a key passed to New-Item -Force,
                # which removes an OpenWithProgids child written beforehand.
                Add-AssociationOpenWithEntry $association
                if (-not (Get-AssociationStatus $association).PreferredSatisfied) { throw 'Association registration verification failed.' }
            } else {
                if ($before.UserChoice -eq $progId) {
                    throw 'Windows still selects this handler through UserChoice. Choose another default in Windows Settings before removing this association; registration retained.'
                }
                if ($before.Current -eq $progId) {
                    $previous = Get-AssociationBackup $association.Extension
                    if ($previous) { Set-ItemProperty -Path "HKCU:\Software\Classes\$($association.Extension)" -Name '(default)' -Value $previous -ErrorAction Stop }
                    else { Remove-ExtensionHandlerName $association.Extension }
                }
                Remove-AssociationOpenWithEntry $association
                Remove-EmptyExtensionKey $association.Extension
                if (-not (Get-AssociationStatus $association).AlternateSatisfied) { throw 'Dingo association references remain after removal.' }
                Remove-AssociationBackup $association.Extension
                # Keep the ProgID: other extensions or protected choices outside
                # this card may reference it. Do not invalidate their commands.
                $message = 'Extension default restored and Open with entry removed; shared program registration retained.'
            }
        } catch {
            $outcome = 'Failed'; $message = $_.Exception.Message
            [void]$failures.Add("$($association.Extension): $message")
        }
        $after = try { Get-AssociationStatus $association } catch { [PSCustomObject]@{ Status='Error'; Message=$_.Exception.Message } }
        $component = New-ChangeComponent $association.Extension $Scope $outcome $message $before $after $DesiredState
        if ($null -ne $EntryResults) { [void]$EntryResults.Add($component) }
        Write-Log 'INFO' ("ENTRY " + (ConvertTo-Json -InputObject $component -Depth 8 -Compress))
    }
    Send-AssociationChange
    if ($failures.Count) { throw ($failures -join '; ') }
}

function Get-PackageKindState($Setting) {
    $tool = @($Setting.Entries)[0]
    $found = Get-ToolDetection $tool
    $missingRuntime = @(Get-MissingToolRequirements $tool)
    $detail = "Detection: $($found.MatchedCount)/$($found.RequiredCount) rules matched ($($found.Mode)). $($found.Evidence)"
    if (-not $found.Complete) { $detail += " Missing detection targets: $($found.Missing -join '; ')." }
    if ($missingRuntime.Count) { $detail += " Missing prerequisites: $($missingRuntime -join ', ')." }
    $status = if ($found.Complete -and -not $missingRuntime.Count) { 'Preferred' } else { 'Partial' }
    $text = if (-not $found.Complete) {
        if ($found.MatchedCount) { 'Incomplete installation' } else { 'Not installed' }
    } elseif ($missingRuntime.Count) { 'Detected; prerequisites missing' }
    elseif ($found.Mode -eq 'all') { 'Minimum inventory detected' }
    elseif ($found.Version) { "Installed ($($found.Version))" } else { 'Installed' }
    $state = New-StateResult $status $text "$detail Detection does not prove tool execution or every upstream download."
    $state | Add-Member NoteProperty Detection $found
    $state | Add-Member NoteProperty MissingPrerequisites $missingRuntime
    return $state
}

function Set-PackageKindPart($Setting, [string]$DesiredState, [string]$Scope) {
    $tool = @($Setting.Entries)[0]
    $update = $DesiredState -eq 'Update installed tool'
    if ($DesiredState -ne $Setting.PreferredState -and -not $update) { throw "Dingo installs or updates $($tool.Name) but never removes it." }
    # Recheck in the executing account immediately before invoking an installer.
    $installed = Find-InstalledTool $tool
    if ($installed -and -not $update) {
        Write-Log 'INFO' "$($tool.Name) is already installed ($($installed.Version)); leaving it unchanged."
        return
    }
    if ($update -and -not $installed) { throw "$($tool.Name) is not installed. Choose Installed to install it first." }
    if ($tool.InstallKind -eq 'winget') { Install-WingetPackage $tool $update }
    elseif ($tool.InstallKind -eq 'script') { Install-ScriptPackage $tool }
    elseif ($tool.InstallKind -eq 'github-release') { Install-GitHubReleasePackage $tool }
    else { throw "Install kind '$($tool.InstallKind)' is not supported in this version of Dingo." }
}

function Get-Settings {
    $advanced = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $edge = 'SOFTWARE\Policies\Microsoft\Edge'
    $windowsUpdate = 'SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $windowsUpdateAU = "$windowsUpdate\AU"
    $settings = New-Object System.Collections.ArrayList

    [void]$settings.Add((New-Setting 'time-zone' 'Region & language' 'Time zone' 'The clock this computer runs on. UTC is preferred, because a timeline read in UTC needs no conversion.' 'UTC' $null 'TimeZone' @() $false $false -StateChoices (Get-TimeZoneChoices)))
    [void]$settings.Add((New-Setting 'region' 'Region & language' 'Region and formats' 'The country and number, currency, and date formats Windows uses for this account. Australia is preferred.' 'Australia (en-AU)' $null 'Region' @() $false $false -StateChoices (@((Get-RegionChoiceTable).Keys))))
    [void]$settings.Add((New-Setting 'display-language' 'Region & language' 'Display language' 'The language of the Windows interface, keyboard, and spelling, and the system locale. Australian English is preferred, to match the region card above. Windows ships no separate Australian interface, so it supplies this one through the British pack and sets the language to en-AU on top of it.' 'Australian English (en-AU)' $null 'Language' @() $false $true -StateChoices (@((Get-LanguageChoiceTable).Keys))))
    # Every date and time choice sets the same seven values, so each entry
    # carries one value per choice instead of a single preferred value.
    $dateTimeFormats = Get-DateTimeFormatChoices
    $dateTimeEntries = @(foreach ($valueName in @('sShortDate','sShortTime','sTimeFormat','sDate','iDate','iTime','iTLZero')) {
        $states = @{}
        foreach ($label in @($dateTimeFormats.Keys)) { $states[$label] = [string]$dateTimeFormats[$label][$valueName] }
        New-Entry User 'Control Panel\International' $valueName $states[@($dateTimeFormats.Keys)[0]] $script:RemoveValue String -States $states
    })
    [void]$settings.Add((New-Setting 'date-time-format' 'Region & language' 'Date and time format' 'How this account writes dates and times. ISO-style is preferred, because yyyy-MM-dd sorts correctly and is never read the wrong way round.' 'ISO-style / 24-hour (yyyy-MM-dd HH:mm)' $null 'Registry' $dateTimeEntries -StateChoices (@($dateTimeFormats.Keys))))

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
    [void]$settings.Add((New-Setting 'taskbar-combine' 'Taskbar' 'Combine taskbar buttons' 'Choose whether taskbar buttons are combined.' 'Never combine' 'Always combine' 'Registry' @(
        (New-Entry User $advanced 'TaskbarGlomLevel' 2 $script:RemoveValue),
        (New-Entry User $advanced 'MMTaskbarGlomLevel' 2 $script:RemoveValue)
    ) $true))
    [void]$settings.Add((New-Setting 'end-task' 'Taskbar' 'End task on right-click' 'Enable or disable End task in app taskbar menus.' 'Enabled' 'Disabled' 'Registry' @(
        (New-Entry User "$advanced\TaskbarDeveloperSettings" 'TaskbarEndTask' 1 $script:RemoveValue)
    ) $true))

    [void]$settings.Add((New-Setting 'explorer-landing' 'File Explorer' 'Default landing page' 'Choose This PC or Home for new Explorer windows.' 'This PC' 'Home' 'Registry' @(
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

    [void]$settings.Add((New-Setting 'windows-update' 'Windows Update' 'Forensic continuity: manual update configuration' 'CAUTION: configures registry policies for manual update maintenance and suppresses update notifications, including restart warnings. Dingo verifies the stored values, not effective restart prevention. Pending restarts, Windows policy prerequisites, and organisation management can affect behavior. Schedule maintenance and independently check restart conditions before processing evidence.' 'Configured; manual maintenance' 'Windows-managed/default' 'Registry' @(
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
    [void]$settings.Add((New-Setting 'edge-debloat' 'Microsoft Edge' 'Clutter, promotions, and new tab page' 'Remove the new tab page news feed, weather, background images, and quick links, plus Collections, shopping, Rewards, Insider and default-browser promotions, feedback, telemetry, and the Copilot Discover Chat extension. Sends Do Not Track. Restart Edge to finish applying it.' 'Removed' 'Edge default' 'Registry' @(
        (New-Entry Machine $edge 'NewTabPageContentEnabled' 0 $script:RemoveValue),
        (New-Entry Machine $edge 'NewTabPageAllowedBackgroundTypes' 3 $script:RemoveValue),
        (New-Entry Machine $edge 'NewTabPageQuickLinksEnabled' 0 $script:RemoveValue),
        (New-Entry Machine $edge 'EdgeCollectionsEnabled' 0 $script:RemoveValue),
        (New-Entry Machine $edge 'EdgeShoppingAssistantEnabled' 0 $script:RemoveValue),
        (New-Entry Machine $edge 'ShowMicrosoftRewards' 0 $script:RemoveValue),
        # These retired policies were written by earlier Dingo versions. Remove
        # them for either card choice so an upgrade cleans up existing machines.
        (New-Entry Machine $edge 'WalletDonationEnabled' $script:RemoveValue $script:RemoveValue),
        (New-Entry Machine $edge 'MicrosoftEdgeInsiderPromotionEnabled' 0 $script:RemoveValue),
        (New-Entry Machine $edge 'DefaultBrowserSettingsCampaignEnabled' 0 $script:RemoveValue),
        (New-Entry Machine $edge 'WebWidgetAllowed' $script:RemoveValue $script:RemoveValue),
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
        "Puts one small launcher for each installed command-line tool into a bin folder inside your tools folder, then adds that single folder to the computer PATH. You can then type EvtxECmd from any folder. The folder is added at the end of the PATH, so a tool can never shadow a Windows command. The card says which folder once it is read." `
        'On the PATH' 'Not on the PATH' 'ToolPath' @() $false $false @{} 'Tool shortcuts'))
    # File types come last. They point at a program, so the program has to be
    # installed first, and the worker applies the plan in this order.
    foreach ($tool in (Get-ToolCatalog)) {
        if (-not @($tool.Associations).Count) { continue }
        $extensions = @($tool.Associations | ForEach-Object { $_.Extension })
        $settingId = 'assoc-' + ($tool.Id -replace '^tool-', '')
        [void]$settings.Add((New-Setting $settingId $tool.Category "$($tool.Name) file types" `
            ("Open $($extensions -join ', ') with $($tool.Name). This is a choice for your account only, so no administrator approval is needed. Windows refuses to hand over a file type another app already owns; Dingo says which ones on the card and adds an Open with entry for those instead.") `
            'Configure defaults / Open with' 'Dingo extension choices removed' 'Association' @($tool.Associations) $false $false @{} 'File associations'))
    }
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
            return [PSCustomObject]@{ Status='Missing'; Exists=$false; Value=$null; ValueType=''; ErrorMessage='' }
        }
        $properties = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
        $property = $properties.PSObject.Properties[$Entry.Name]
        if (-not $property) {
            return [PSCustomObject]@{ Status='Missing'; Exists=$false; Value=$null; ValueType=''; ErrorMessage='' }
        }
        $valueType = [string](Get-Item -LiteralPath $path -ErrorAction Stop).GetValueKind($Entry.Name)
        return [PSCustomObject]@{ Status='Present'; Exists=$true; Value=$property.Value; ValueType=$valueType; ErrorMessage='' }
    } catch {
        return [PSCustomObject]@{ Status='Error'; Exists=$false; Value=$null; ValueType=''; ErrorMessage=$_.Exception.Message }
    }
}

function Test-EntryValue($Entry, $Expected) {
    $actual = Get-EntryValue $Entry
    if ($actual.Status -eq 'Error') {
        throw "Could not read $(Get-EntryPath $Entry)\$($Entry.Name): $($actual.ErrorMessage)"
    }
    if ($Expected -eq $script:RemoveValue) { return -not $actual.Exists }
    return $actual.Exists -and $actual.ValueType -eq $Entry.Type -and ([string]$actual.Value -ceq [string]$Expected)
}

function Set-EntryValue($Entry, $DesiredState, $Setting) {
    if ($Entry.Scope -in @('Machine','ElevatedUser') -and -not (Test-IsAdministrator)) { throw 'This registry setting requires elevation.' }
    $wanted = Get-EntryWantedValue $Entry $DesiredState $Setting
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
                if ($index + 1 -ge $length) { throw 'Unterminated JSONC block comment.' }
                $index += 2
                # Keep the JSON tokens either side of the comment apart.
                [void]$builder.Append(' ')
                continue
            }
        }
        [void]$builder.Append($character)
        $index++
    }
    # Remove trailing commas only outside strings, after comments have become
    # whitespace. A regex here would also change text such as "keep,}".
    $clean = $builder.ToString()
    [void]$builder.Clear()
    $inString = $false
    for ($index = 0; $index -lt $clean.Length; $index++) {
        $character = $clean[$index]
        if ($inString) {
            [void]$builder.Append($character)
            if ($character -eq '\' -and $index + 1 -lt $clean.Length) {
                $index++
                [void]$builder.Append($clean[$index])
            } elseif ($character -eq '"') { $inString = $false }
            continue
        }
        if ($character -eq '"') { $inString = $true }
        if ($character -eq ',') {
            $nextIndex = $index + 1
            while ($nextIndex -lt $clean.Length -and [char]::IsWhiteSpace($clean[$nextIndex])) { $nextIndex++ }
            if ($nextIndex -lt $clean.Length -and $clean[$nextIndex] -in @('}',']')) { continue }
        }
        [void]$builder.Append($character)
    }
    return $builder.ToString()
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
    # Each offered choice is tried in turn, so a card with a list of choices
    # reports the one that is actually in place rather than only a pair.
    foreach ($state in @($Setting.StateOptions)) {
        $mismatched = @($Setting.Entries | Where-Object { -not (Test-EntryValue $_ (Get-EntryWantedValue $_ $state $Setting)) }).Count
        if ($mismatched -eq 0) { return New-StateResultForSetting $Setting $state }
    }
    if ($Setting.Id -eq 'date-time-format') {
        $shortDate = (Get-EntryValue ($Setting.Entries | Where-Object Name -eq 'sShortDate')).Value
        $shortTime = (Get-EntryValue ($Setting.Entries | Where-Object Name -eq 'sShortTime')).Value
        return New-StateResult 'Partial' "Custom: $shortDate, $shortTime"
    }
    return New-StateResult 'Partial' 'Custom or partly configured'
}

function Get-IsoTimeSetting {
    return $script:Settings | Where-Object Id -eq 'date-time-format' | Select-Object -First 1
}

function Get-ConfiguredDateTimeFormatState {
    # The date/time choice that is in place right now, or an empty string when
    # the formats are something Dingo does not offer.
    $setting = Get-IsoTimeSetting
    if (-not $setting) { return '' }
    foreach ($state in @($setting.StateOptions)) {
        if (@($setting.Entries | Where-Object { -not (Test-EntryValue $_ (Get-EntryWantedValue $_ $state $setting)) }).Count -eq 0) { return [string]$state }
    }
    return ''
}

function Register-InternationalSettingsFinalizer([string]$FormatState = '') {
    $setting = Get-IsoTimeSetting
    # The finalizer runs in a new process after sign-in, so the chosen format is
    # carried on its command line rather than assumed to be the preferred one.
    $state = if ($FormatState) { $FormatState } elseif ($setting) { [string]$setting.PreferredState } else { '' }
    if ($setting -and $state -notin @($setting.StateOptions)) { throw "'$state' is not a date and time format Dingo offers." }
    $runOncePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    if (-not (Test-Path -LiteralPath $runOncePath)) { New-Item -Path $runOncePath -Force | Out-Null }
    $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -FinalizeInternationalSettings -FinalizeFormatState "{1}" -WorkerLogPath "{2}"' -f $PSCommandPath,$state,$script:LogFile
    $command = '"{0}" {1}' -f (Join-Path $PSHOME 'powershell.exe'),$arguments
    New-ItemProperty -LiteralPath $runOncePath -Name 'DingoFinalizeInternationalSettings' -Value $command -PropertyType String -Force | Out-Null
    Write-Log 'INFO' "Registered a one-time sign-in finalizer so Windows language initialization cannot replace the '$state' date and time formats."
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

function Expand-InstalledLanguageResult($Result) {
    # Get-InstalledLanguage hands back one list object rather than one object
    # per language, and the pipeline does not unroll it. Flatten it here, or a
    # later property read silently answers for every language at once.
    # foreach walks the list directly: @() around a generic list throws
    # 'Argument types do not match' on Windows PowerShell 5.1.
    $entries = New-Object System.Collections.ArrayList
    if ($null -eq $Result) { return $entries.ToArray() }
    foreach ($item in $Result) {
        if ($null -eq $item) { continue }
        if ($item -isnot [string] -and $item -is [System.Collections.IEnumerable]) {
            foreach ($inner in $item) { if ($null -ne $inner) { [void]$entries.Add($inner) } }
        } else {
            [void]$entries.Add($item)
        }
    }
    return $entries.ToArray()
}

function Get-PendingSystemLocaleId {
    # Set-WinSystemLocale records the request here and Windows adopts it only
    # at the next restart, so this is what a just-written system locale looks
    # like while the running one is still the old one.
    try {
        return ([string](Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language' -Name Default -ErrorAction Stop).Default).Trim()
    } catch {
        Write-Log 'WARN' "Could not read the pending system locale: $($_.Exception.Message)"
        return ''
    }
}

function Test-SystemLocaleAccepted([string]$Tag) {
    # Accepted means either Windows is already running it, or Windows has
    # written it down for the next restart. Demanding the running locale would
    # fail every first-time change, because none of them apply before a restart.
    if ((Get-WinSystemLocale).Name -eq $Tag) { return $true }
    $wanted = try { '{0:X4}' -f ([System.Globalization.CultureInfo]::GetCultureInfo($Tag).LCID) } catch { '' }
    if (-not $wanted) { return $false }
    $pending = ([string](Get-PendingSystemLocaleId)).Trim()
    return [bool]($pending -and $pending.ToUpperInvariant() -eq $wanted)
}

function Get-DisplayLanguagePackSource([string]$Language) {
    # Asked for a variant it does not localise, Windows answers with the parent
    # language that actually carries the resources: a request for en-NZ comes
    # back with en-GB beside it. So the answer is the language id that owns a
    # real pack, not the one that was asked for. An entry with no id, no pack,
    # or a pack of 'None' is no answer, and an empty string means not installed.
    $entries = @(Expand-InstalledLanguageResult (Get-InstalledLanguage -Language $Language -ErrorAction Stop))
    foreach ($entry in $entries) {
        $id = [string](Get-JsonField $entry 'LanguageId' '')
        $packs = [string](Get-JsonField $entry 'LanguagePacks' '')
        if ($id -and $packs -and $packs -ne 'None') { return $id }
    }
    return ''
}

function Test-DisplayLanguagePackInstalled([string]$Language) {
    return [bool](Get-DisplayLanguagePackSource $Language)
}

function Test-WorkerCancelled {
    # The elevated worker cannot be killed by the window that started it, so
    # stopping is cooperative: the window drops a file and the worker notices
    # it between steps and while waiting on a long download.
    $target = Get-Variable -Name WorkerCancelPath -Scope Script -ErrorAction SilentlyContinue
    if (-not $target -or -not $target.Value) { return $false }
    try { return [bool](Test-Path -LiteralPath $target.Value -PathType Leaf) } catch { return $false }
}

function Get-ServicingActivity {
    # Install-Language reports no progress of its own, so liveness is read from
    # what Windows servicing touches while it works: its two logs, the Windows
    # Update download folder, and the servicing processes. Any change in this
    # fingerprint means something is still happening. An empty string means
    # nothing could be read, and the caller must not call that a stall.
    $parts = New-Object System.Collections.ArrayList
    $root = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }
    foreach ($name in @('Logs\DISM\dism.log','Logs\CBS\CBS.log')) {
        try {
            $item = Get-Item -LiteralPath (Join-Path $root $name) -Force -ErrorAction Stop
            [void]$parts.Add("$name=$($item.Length)@$($item.LastWriteTimeUtc.Ticks)")
        } catch { }
    }
    try {
        # Only the immediate children, which is a few dozen entries and a few
        # milliseconds. A recursive scan here would cost more than it is worth.
        $children = @(Get-ChildItem -LiteralPath (Join-Path $root 'SoftwareDistribution\Download') -Force -ErrorAction Stop)
        $newest = @($children | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
        $stamp = if ($newest.Count) { $newest[0].LastWriteTimeUtc.Ticks } else { 0 }
        [void]$parts.Add("download=$($children.Count)@$stamp")
    } catch { }
    foreach ($name in @('TiWorker','TrustedInstaller')) {
        try {
            foreach ($process in @(Get-Process -Name $name -ErrorAction Stop)) {
                $cpu = try { [math]::Round([double]$process.CPU, 1) } catch { 0 }
                [void]$parts.Add("$name=$($process.Id)@$cpu")
            }
        } catch { }
    }
    return ($parts -join ';')
}

function Get-JobProgressReport($Job) {
    # A background job keeps every progress record the command wrote, so the
    # newest one is what the installer is doing right now. Signal changes
    # whenever anything at all moves, which is how a stall is detected.
    $percent = -1
    $status = ''
    $count = 0
    try {
        $records = @($Job.ChildJobs[0].Progress)
        $count = $records.Count
        if ($count) {
            $last = $records[$count - 1]
            $percent = [int]$last.PercentComplete
            $status = [string]$last.StatusDescription
        }
    } catch {
        # A job that has not started yet has no progress stream to read.
    }
    [PSCustomObject]@{ Percent=$percent; Status=$status; Count=$count; Signal="$count|$percent|$status" }
}

function Install-DisplayLanguagePack([string]$Language, [int]$TimeoutSeconds = 900, [int]$StallSeconds = 300) {
    Write-Log 'INFO' "Installing the supported $Language Windows display-language pack. Timeout is $TimeoutSeconds seconds; a stall of $StallSeconds seconds ends it sooner."
    Write-WorkerProgress 'Downloading' "Asking Windows Update for the $Language language pack"
    # Dingo needs only the UI resources. Avoid hot-adding handwriting, OCR,
    # speech, and other text services while this WPF process is running.
    $job = Get-PrestartedPackJob $Language
    if ($job) {
        Write-Log 'INFO' "Taking over the $Language display-language download that was already running in the background."
    } else {
        $job = Install-Language -Language $Language -ExcludeFeatures -AsJob -ErrorAction Stop
    }
    try {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $nextHeartbeat = 30
        $completed = $null
        $lastSignal = ''
        $lastChange = [TimeSpan]::Zero
        $seenProgress = $false
        $report = $null
        while (-not $completed -and $timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            $completed = Wait-Job -Job $job -Timeout 5
            if (-not $completed -and (Test-WorkerCancelled)) {
                Stop-Job -Job $job -ErrorAction SilentlyContinue
                throw "Stopped at your request while Windows was installing the $Language display pack. Windows may finish the download on its own in the background."
            }
            $report = Get-JobProgressReport $job
            $activity = Get-ServicingActivity
            # Either signal moving counts as work. The cmdlet publishes no
            # progress records of its own, so most of the time it is the second.
            $signal = "$($report.Signal)|$activity"
            if ($signal -ne $lastSignal) {
                $lastSignal = $signal
                $lastChange = $timer.Elapsed
            }
            if ($report.Count -or $activity) { $seenProgress = $true }
            $stalled = $timer.Elapsed - $lastChange
            if (-not $completed -and $timer.Elapsed.TotalSeconds -ge $nextHeartbeat) {
                $where = if ($report.Count) { "$($report.Percent)% - $($report.Status)" } elseif ($activity) { "no percentage reported; Windows servicing last moved $([int]$stalled.TotalSeconds)s ago" } else { 'nothing readable about what Windows is doing' }
                Write-Log 'INFO' "Still installing $Language display-language pack ($([math]::Floor($timer.Elapsed.TotalMinutes))m $($timer.Elapsed.Seconds)s elapsed; $where; job state $($job.State))."
                $nextHeartbeat += 30
            }
            # Published every tick, not only on the heartbeat, so the window shows
            # a figure that is visibly still moving.
            $remaining = [math]::Max(0, [int]($TimeoutSeconds - $timer.Elapsed.TotalSeconds))
            $detail = if ($report.Count) {
                "Windows reports $($report.Percent)% done on the $Language language pack$(if ($report.Status) { " - $($report.Status)" })"
            } elseif ($activity) {
                # Windows gives no percentage for this, so say plainly that it is
                # working rather than invent a figure.
                "Windows is downloading and installing the $Language language pack. It gives no percentage for this, so Dingo watches Windows Update instead"
            } else {
                "Waiting for Windows Update to start on the $Language language pack"
            }
            # Say it has stopped moving well before giving up, so the person sees
            # it coming rather than being surprised by a sudden failure.
            $quietWarning = if ($StallSeconds -gt 0) { [math]::Min(60, [math]::Max(3, $StallSeconds / 3)) } else { 60 }
            if ($stalled.TotalSeconds -ge $quietWarning) {
                $detail += ". Nothing has moved for $([math]::Floor($stalled.TotalMinutes))m $($stalled.Seconds)s"
            } elseif (-not $report.Count -and $activity) {
                $detail += ". Last sign of activity $([int]$stalled.TotalSeconds)s ago"
            }
            Write-WorkerProgress 'Downloading' "$detail. Dingo waits $([math]::Floor($remaining / 60))m $($remaining % 60)s more at most"
            # Sitting out a full timeout while nothing moves helps nobody, so a
            # stall ends the step early and the rest of the plan carries on.
            if (-not $completed -and $seenProgress -and $StallSeconds -gt 0 -and $stalled.TotalSeconds -ge $StallSeconds) {
                Stop-Job -Job $job -ErrorAction SilentlyContinue
                $stuckAt = if ($report.Count) { "It sat at $($report.Percent)%" } else { 'Neither Windows Update nor the servicing logs changed' }
                throw "Windows Update stopped making progress on the $Language display pack. $stuckAt for $([math]::Floor($stalled.TotalMinutes))m $($stalled.Seconds)s, so Dingo gave up rather than wait out the full $([math]::Round($TimeoutSeconds / 60))-minute limit. Check Windows Update connectivity and try again."
            }
        }
        if (-not $completed) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            $where = if ($report -and $report.Count) { " It reached $($report.Percent)%." } else { ' Windows reports no percentage for a language pack, so Dingo cannot say how far it got.' }
            throw "Windows did not finish installing the $Language display pack within $([math]::Round($TimeoutSeconds / 60)) minutes.$where Check Windows Update connectivity and try again."
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

function Get-AvailableDisplayLanguagePacks {
    # Windows names every display pack Language.UI.Client~~~<tag>~<version>.
    # Reading the list needs elevation, so a read that fails returns nothing
    # and the caller falls back to simply trying each pack in turn.
    try {
        return @(Get-WindowsCapability -Online -Name 'Language.UI.Client*' -ErrorAction Stop |
            ForEach-Object { [regex]::Match([string]$_.Name,'^Language\.UI\.Client~~~([^~]+)~').Groups[1].Value } |
            Where-Object { $_ } | Select-Object -Unique)
    } catch {
        Write-Log 'WARN' "Could not list the Windows display-language packs, so each candidate pack is tried in turn: $($_.Exception.Message)"
        return @()
    }
}

function Select-DisplayLanguagePackToInstall([string[]]$Candidates) {
    # The pack Windows would actually be asked for, or an empty string when
    # nothing needs downloading or nothing can be downloaded.
    foreach ($candidate in $Candidates) {
        if (Get-DisplayLanguagePackSource $candidate) { return '' }
    }
    $available = @(Get-AvailableDisplayLanguagePacks)
    $tryList = @(if ($available.Count) { $Candidates | Where-Object { $available -contains $_ } } else { $Candidates })
    if (-not $tryList.Count) { return '' }
    return [string]$tryList[0]
}

function Start-DisplayLanguagePackPrefetch([string[]]$Candidates) {
    # A language pack is minutes of downloading while every other setting is
    # milliseconds of registry work. Starting it here lets the rest of the plan
    # run while Windows fetches it, instead of queueing behind it.
    if (-not (Get-Variable -Name PackJobs -Scope Script -ErrorAction SilentlyContinue)) { $script:PackJobs = @{} }
    $pack = try { Select-DisplayLanguagePackToInstall $Candidates } catch { '' }
    if (-not $pack -or $script:PackJobs.ContainsKey($pack)) { return '' }
    try {
        $script:PackJobs[$pack] = Install-Language -Language $pack -ExcludeFeatures -AsJob -ErrorAction Stop
        Write-Log 'INFO' "Started the $pack display-language download in the background so the rest of the plan need not wait for it."
        return $pack
    } catch {
        Write-Log 'WARN' "Could not start the $pack display-language download early: $($_.Exception.Message)"
        return ''
    }
}

function Get-PrestartedPackJob([string]$Language) {
    # Handed over once: whoever takes it owns waiting on it and cleaning it up.
    if (-not (Get-Variable -Name PackJobs -Scope Script -ErrorAction SilentlyContinue)) { return $null }
    if (-not $script:PackJobs.ContainsKey($Language)) { return $null }
    $job = $script:PackJobs[$Language]
    [void]$script:PackJobs.Remove($Language)
    return $job
}

function Stop-PrestartedPackJobs {
    if (-not (Get-Variable -Name PackJobs -Scope Script -ErrorAction SilentlyContinue)) { return }
    foreach ($key in @($script:PackJobs.Keys)) {
        try {
            Stop-Job -Job $script:PackJobs[$key] -ErrorAction SilentlyContinue
            Remove-Job -Job $script:PackJobs[$key] -Force -ErrorAction SilentlyContinue
            Write-Log 'WARN' "Dropped the unused $key display-language download."
        } catch { }
    }
    $script:PackJobs = @{}
}

function Install-RequiredDisplayLanguagePack([string[]]$Candidates) {
    # Returns the language whose display pack ends up carrying the interface. A
    # choice may name more than one candidate, because Windows localises some
    # English variants only through a parent pack. Nothing already present is
    # downloaded again.
    if (-not @($Candidates).Count) { throw 'No display-language pack was named for this choice.' }
    Write-WorkerProgress 'Working' 'Checking which Windows language packs are already installed'
    foreach ($candidate in $Candidates) {
        $source = Get-DisplayLanguagePackSource $candidate
        if ($source) {
            $how = if ($source -eq $candidate) { "The $candidate Windows display pack is already installed" } else { "Windows already serves $candidate from the installed $source display pack" }
            Write-Log 'INFO' "$how; nothing to download."
            return $source
        }
    }
    Write-WorkerProgress 'Working' 'Asking Windows which language packs it can supply'
    $available = @(Get-AvailableDisplayLanguagePacks)
    # The array subexpression wraps the whole choice: an empty result inside an
    # if branch is an empty pipeline, and the if would otherwise yield $null.
    $tryList = @(if ($available.Count) { $Candidates | Where-Object { $available -contains $_ } } else { $Candidates })
    if (-not $tryList.Count) {
        throw "Windows offers no display pack for $($Candidates -join ' or '). Check Windows Update connectivity, or choose another display language."
    }
    $failures = New-Object System.Collections.ArrayList
    foreach ($candidate in $tryList) {
        try {
            Install-DisplayLanguagePack $candidate
            $source = Get-DisplayLanguagePackSource $candidate
            if ($source) {
                Write-Log 'INFO' "Installed the $candidate Windows display pack and verified that $source now carries it."
                return $source
            }
            [void]$failures.Add("$candidate reported success but Windows does not list its pack")
        } catch {
            [void]$failures.Add("$candidate : $($_.Exception.Message)")
        }
        Write-Log 'WARN' "The $candidate Windows display pack did not install; trying the next pack for this language."
    }
    throw "No Windows display pack could be installed for this language: $($failures -join '; ')."
}

function Get-RegistryKindState($Setting) {
    $state = Get-RegistrySettingState $Setting
    if ($Setting.Id -eq 'windows-copilot' -and $state.Status -eq 'Preferred' -and (Test-CopilotTaskbarPinned)) {
        return New-StateResult 'Partial' "$($state.DisplayText); Copilot app pinned to taskbar"
    }
    if (@($Setting.Entries | Where-Object { $_.Path -match '(^SOFTWARE\\Policies\\|PolicyManager\\)' }).Count -and $state.Status -in @('Preferred','Alternate') -and $state.DisplayText -notlike 'Configured*') {
        $state.DisplayText = "Configured: $($state.DisplayText)"
    }
    return $state
}

function Get-TimeZoneKindState($Setting) { New-StateResultForSetting $Setting (Get-TimeZone).Id }

function Get-RegionKindState($Setting) {
    $locale = try { (Get-ItemProperty -LiteralPath 'HKCU:\Control Panel\International' -Name LocaleName).LocaleName } catch { (Get-Culture).Name }
    $geo = try { [int](Get-WinHomeLocation).GeoId } catch { -1 }
    $display = "$locale (GeoId $geo)"
    $table = Get-RegionChoiceTable
    foreach ($label in @($table.Keys)) {
        $choice = $table[$label]
        if ($locale -eq $choice.Culture -and $geo -eq [int]$choice.GeoId) { $display = $label; break }
    }
    New-StateResultForSetting $Setting $display
}

function Test-LanguageChoiceInPlace($Choice, $Tags, [string]$SystemPreferred, [string]$SystemLocale, [string]$Override, [string]$UiLanguage) {
    # A choice is in place only when the pack is present, the user list leads
    # with it, the system locale matches, and the interface already shows it or
    # is committed to show it after the next sign-in.
    $accepted = @(@(@($Choice.Tag) + @($Choice.Packs)) | Select-Object -Unique)
    $displayPack = $UiLanguage -in $accepted
    if (-not $displayPack) {
        foreach ($pack in @($Choice.Packs)) {
            try { if (Test-DisplayLanguagePackInstalled $pack) { $displayPack = $true; break } }
            catch { Write-Log 'WARN' "Could not query the $pack display pack while reading language state: $($_.Exception.Message)" }
        }
    }
    $userReady = @($Tags).Count -gt 0 -and @($Tags)[0] -eq $Choice.Tag
    $committedUi = -not $Override -and $SystemPreferred -in $accepted -and $UiLanguage -in $accepted
    $displayReady = $displayPack -and (($Override -eq $Choice.Tag) -or ($UiLanguage -eq $Choice.Tag) -or $committedUi)
    [PSCustomObject]@{
        DisplayPack=$displayPack; UserReady=$userReady; DisplayReady=$displayReady
        InPlace=($SystemLocale -eq $Choice.Tag -and $userReady -and $displayReady)
    }
}

function Get-LanguageKindState($Setting) {
    $tags = @((Get-WinUserLanguageList).LanguageTag)
    $systemPreferred = try { [string](Get-SystemPreferredUILanguage -ErrorAction Stop) } catch { '' }
    $systemLocale = try { (Get-WinSystemLocale).Name } catch { '' }
    $override = try { (Get-WinUILanguageOverride).Name } catch { '' }
    $uiLanguage = try { (Get-UICulture).Name } catch { '' }
    $table = Get-LanguageChoiceTable
    foreach ($label in @($table.Keys)) {
        $check = Test-LanguageChoiceInPlace $table[$label] $tags $systemPreferred $systemLocale $override $uiLanguage
        if ($check.InPlace) { return New-StateResultForSetting $Setting $label }
    }
    # Nothing on offer is fully in place, so say what is missing against the
    # choice that is selected on the card.
    $wantedLabel = if ($table.Contains($Setting.DesiredState)) { $Setting.DesiredState } else { $Setting.PreferredState }
    $wanted = $table[$wantedLabel]
    $accepted = @(@(@($wanted.Tag) + @($wanted.Packs)) | Select-Object -Unique)
    $check = Test-LanguageChoiceInPlace $wanted $tags $systemPreferred $systemLocale $override $uiLanguage
    $parts = New-Object System.Collections.ArrayList
    if (-not $check.DisplayPack) { [void]$parts.Add("no display pack installed for $(@($wanted.Packs) -join ' or ')") }
    if ($systemPreferred -notin $accepted -and $override -ne $wanted.Tag) { [void]$parts.Add("system UI is $systemPreferred") }
    if ($systemLocale -ne $wanted.Tag) { [void]$parts.Add("system locale is $systemLocale") }
    if (-not $check.UserReady) { [void]$parts.Add("user languages: $(if ($tags) { $tags -join ', ' } else { 'none' })") }
    if ($check.DisplayPack -and $override -ne $wanted.Tag -and $uiLanguage -ne $wanted.Tag) { [void]$parts.Add("user UI is $uiLanguage") }
    New-StateResult 'Partial' ('Partly configured: ' + ($parts -join '; '))
}

function Get-TerminalKindState($Setting) {
    $display = Get-TerminalState
    if ($display -like 'Unavailable*') { return New-StateResult 'Unavailable' $display 'Launch Windows Terminal once, then read settings again.' }
    New-StateResultForSetting $Setting $display
}

function Get-WidgetsKindState($Setting) { New-StateResultForSetting $Setting (Get-WidgetsPackageState) }

function Set-RegistryKindPart($Setting, [string]$DesiredState, [string]$Scope, $EntryResults = $null) {
    $failure = ''
    foreach ($entry in @($Setting.Entries | Where-Object Scope -eq $Scope)) {
        $target = "$(Get-EntryPath $entry)\$($entry.Name)"
        $wanted = Get-EntryWantedValue $entry $DesiredState $Setting
        $before = Get-EntryValue $entry
        $outcome = 'Skipped'; $message = 'Not attempted after an earlier entry failed.'
        if (-not $failure) {
            try {
                if ($before.Status -eq 'Error') { throw "Cannot read before-state: $($before.ErrorMessage)" }
                Set-EntryValue $entry $DesiredState $Setting
                $outcome = 'Succeeded'; $message = 'Registry value and type read back successfully.'
            } catch {
                $outcome = 'Failed'; $message = $_.Exception.Message; $failure = "$target : $message"
            }
        }
        $after = Get-EntryValue $entry
        $component = New-ChangeComponent $target $Scope $outcome $message $before $after ([PSCustomObject]@{
            Exists=($wanted -ne $script:RemoveValue); Value=$(if ($wanted -ne $script:RemoveValue) { $wanted } else { $null }); ValueType=$entry.Type
        })
        if ($null -ne $EntryResults) { [void]$EntryResults.Add($component) }
        Write-Log 'INFO' ("ENTRY " + (ConvertTo-Json -InputObject $component -Depth 8 -Compress))
    }
    if ($failure) { throw $failure }
    if ($Scope -eq 'User' -and $Setting.Id -eq 'date-time-format') {
        Send-InternationalSettingChange
        $override = try { (Get-WinUILanguageOverride).Name } catch { '' }
        $uiLanguage = try { (Get-UICulture).Name } catch { '' }
        if ($script:LanguageChangePending -or ($override -and $override -ne $uiLanguage)) { Register-InternationalSettingsFinalizer $DesiredState }
    }
    if ($Scope -eq 'User' -and $Setting.Id -eq 'windows-copilot' -and $DesiredState -eq $Setting.PreferredState) { Unpin-CopilotFromTaskbar }
}

function Set-TimeZoneKindPart($Setting, [string]$DesiredState, [string]$Scope) {
    Set-TimeZone -Id $DesiredState
    if ((Get-TimeZone).Id -ne $DesiredState) { throw 'Time-zone verification failed.' }
}

function Set-RegionKindPart($Setting, [string]$DesiredState, [string]$Scope) {
    $choice = Get-LocaleChoice (Get-RegionChoiceTable) $DesiredState
    Set-Culture -CultureInfo $choice.Culture
    Set-WinHomeLocation -GeoId ([int]$choice.GeoId)
    $locale = (Get-ItemProperty -LiteralPath 'HKCU:\Control Panel\International' -Name LocaleName).LocaleName
    if ($locale -ne $choice.Culture -or [int](Get-WinHomeLocation).GeoId -ne [int]$choice.GeoId) { throw 'Region verification failed.' }
}

function Set-LanguageKindPart($Setting, [string]$DesiredState, [string]$Scope) {
    $choice = Get-LocaleChoice (Get-LanguageChoiceTable) $DesiredState
    if ($Scope -eq 'User') {
        # The computer-wide part runs first and installs the pack. Check it here
        # too, so this part can never point the account at a language Windows
        # has no interface for.
        $installed = @(@($choice.Packs) | Where-Object { Test-DisplayLanguagePackInstalled $_ })
        if (-not $installed.Count) {
            throw "No Windows display pack for $DesiredState is installed, so this account cannot be switched to it yet."
        }
        $list = New-WinUserLanguageList -Language $choice.Tag
        Set-WinUserLanguageList -LanguageList $list -Force
        Set-WinUILanguageOverride -Language $choice.Tag
        $tags = @((Get-WinUserLanguageList).LanguageTag)
        $override = (Get-WinUILanguageOverride).Name
        if ($tags.Count -eq 0 -or $tags[0] -ne $choice.Tag -or $override -ne $choice.Tag) { throw "$DesiredState display-language verification failed." }
        $script:LanguageChangePending = $true
        $formatState = Get-ConfiguredDateTimeFormatState
        if ($formatState) { Register-InternationalSettingsFinalizer $formatState }
    } else {
        # The display pack is settled before anything asks Windows to use the
        # language, so a missing pack fails here rather than half-way through.
        $pack = Install-RequiredDisplayLanguagePack @($choice.Packs)
        if (-not $pack -or -not (Test-DisplayLanguagePackInstalled $pack)) { throw "No Windows display pack for $DesiredState was installed." }
        Set-SystemPreferredUILanguage -Language $choice.Tag -PassThru | Out-Null
        Set-WinSystemLocale -SystemLocale $choice.Tag
        if (-not (Test-SystemLocaleAccepted $choice.Tag)) { throw "Computer-wide $DesiredState locale verification failed." }
        if ((Get-WinSystemLocale).Name -ne $choice.Tag) {
            Write-Log 'INFO' "Windows recorded $($choice.Tag) as the system locale and will start using it after the next restart."
        }
        if ($choice.Tag -ne $pack) {
            Write-Log 'INFO' "The $($choice.Tag) system UI request was accepted using the installed $pack base resources; Windows applies and reports it after sign-out or restart."
        }
    }
}

function Set-TerminalKindPart($Setting, [string]$DesiredState, [string]$Scope) { Set-TerminalState $DesiredState }
function Set-WidgetsKindPart($Setting, [string]$DesiredState, [string]$Scope) { Remove-WidgetsPackages }

function Get-SettingState($Setting) {
    try {
        $handler = Get-SettingHandler $Setting.Kind
        $readCommand = [string]$handler.Read
        $state = & $readCommand $Setting
        $state | Add-Member NoteProperty VerificationBasis (Get-VerificationDescription $Setting) -Force
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

function Set-SettingPart($Setting, [string]$DesiredState, [ValidateSet('User','Machine','ElevatedUser')][string]$Scope, $EntryResults = $null) {
    if ($DesiredState -notin $Setting.StateOptions) { throw "Invalid desired state '$DesiredState'." }
    if (-not (Test-SettingHasScope $Setting $Scope)) { throw "Setting '$($Setting.Id)' does not support scope '$Scope'." }
    $handler = Get-SettingHandler $Setting.Kind
    $applyCommand = [string]$handler.Apply
    if ($Setting.Kind -in @('Registry','Association')) { & $applyCommand $Setting $DesiredState $Scope $EntryResults }
    else { & $applyCommand $Setting $DesiredState $Scope }
}

function Get-VerificationDescription($Setting) {
    switch ($Setting.Kind) {
        'Registry' { 'Registry value, type, or absence checked; effective Windows/application behavior is not verified.' }
        'Association' { 'Extension choices, Open with entries, open commands, and target presence checked; applications were not launched.' }
        'Package' { 'Catalog detection rules and declared prerequisites checked; execution and every upstream download are not verified.' }
        default { 'Current state checked using the setting handler; restart/sign-in requirements still apply.' }
    }
}

function New-ChangeComponent($Target, $Scope, $Outcome, $Message, $Before, $After, $Requested) {
    $change = if ($Outcome -eq 'Skipped') { 'NotAttempted' }
        elseif ($Before.Status -eq 'Error' -or $After.Status -eq 'Error') { 'Unknown' }
        elseif ((ConvertTo-Json -InputObject $Before -Depth 8 -Compress) -ceq (ConvertTo-Json -InputObject $After -Depth 8 -Compress)) { 'Unchanged' }
        else { 'Changed' }
    $component = New-OperationComponent $Target $Outcome $Message
    $component | Add-Member NoteProperty Scope $Scope
    $component | Add-Member NoteProperty Before $Before
    $component | Add-Member NoteProperty After $After
    $component | Add-Member NoteProperty Requested $Requested
    $component | Add-Member NoteProperty ChangeStatus $change
    return $component
}

function Invoke-SettingPartResults($Setting, $DesiredState, $Scope) {
    $entries = New-Object Collections.ArrayList
    $operationId = [Guid]::NewGuid().ToString('N')
    try {
        Write-OperationJournal Started $operationId $Setting.Id $Scope @{ DesiredState=$DesiredState; BeforeState=$Setting.CurrentState }
        Set-SettingPart $Setting $DesiredState $Scope $entries
        if (-not $entries.Count) { [void]$entries.Add((New-OperationComponent $Scope Succeeded 'Handler completed; final state verification follows.')) }
    } catch {
        if (-not @($entries | Where-Object Outcome -eq 'Failed').Count) {
            [void]$entries.Add((New-OperationComponent $Scope Failed $_.Exception.Message))
        }
    }
    try { Write-OperationJournal Completed $operationId $Setting.Id $Scope @{ Components=@($entries) } }
    catch { [void]$entries.Add((New-OperationComponent 'Recovery journal' Failed "Could not persist completion: $($_.Exception.Message)")) }
    return @($entries)
}

function Write-WorkerProgress([string]$Phase, [string]$Detail = '') {
    # The elevated worker runs in its own process, so the window can only see
    # what is written down. A failed write never stops the actual work.
    # Read with Get-Variable: the test suites load Dingo one function at a time
    # and never run a bare assignment at the top of the file.
    $target = Get-Variable -Name WorkerProgressPath -Scope Script -ErrorAction SilentlyContinue
    $step = Get-Variable -Name WorkerStep -Scope Script -ErrorAction SilentlyContinue
    if (-not $target -or -not $target.Value -or -not $step -or -not $step.Value) { return }
    try {
        $script:WorkerStep.Phase = $Phase
        $script:WorkerStep.Detail = $Detail
        $script:WorkerStep.Updated = (Get-Date).ToString('o')
        Write-Utf8FileAtomically $script:WorkerProgressPath (ConvertTo-Json -InputObject $script:WorkerStep -Depth 4)
    } catch {
        Write-Log 'DEBUG' "Could not publish worker progress: $($_.Exception.Message)"
    }
}

function Set-WorkerProgressStep([int]$Index, [int]$Total, [string]$Id, [string]$Name, [string]$Phase, [string]$Detail = '') {
    $script:WorkerStep = [PSCustomObject]@{
        Index=$Index; Total=$Total; Id=$Id; Name=$Name; Phase=$Phase; Detail=$Detail
        StepStarted=(Get-Date).ToString('o'); Updated=(Get-Date).ToString('o')
    }
    Write-WorkerProgress $Phase $Detail
}

function Write-WorkerResults([System.Collections.IEnumerable]$Results, [string]$Path) {
    $items = @($Results)
    $json = if ($items.Count) { ConvertTo-Json -InputObject $items -Depth 8 } else { '[]' }
    Write-Utf8FileAtomically $Path $json
}

function New-ApplyPlan([array]$Selected) {
    # Copy only the model, never WPF controls. Deep-copy nested entries and
    # requirements so later card edits cannot alter a preflighted operation.
    foreach ($item in $Selected) {
        $model = $item | Select-Object Selected,Id,Category,Name,Description,PreferredState,AlternateState,DesiredState,
            DefaultState,DisplayScope,Tab,StateOptions,CanChoose,CurrentState,Status,Details,LastApplyResult,
            Kind,Entries,RequiresAdmin,RestartExplorer,RestartRequired,Requirements
        [Management.Automation.PSSerializer]::Deserialize([Management.Automation.PSSerializer]::Serialize($model, 100))
    }
}

function Publish-PlanState($Item) {
    $card = $script:Settings | Where-Object Id -eq $Item.Id | Select-Object -First 1
    if (-not $card) { return }
    # Results may flow back to the UI; editable choices never flow into the plan.
    foreach ($name in @('Status','Details','CurrentState','LastApplyResult')) { $card.$name = $Item.$name }
}

function Split-SlowPlanRequests([array]$Plan, [array]$AllSettings) {
    # A setting that needs a Windows Update download is minutes long. Moving it
    # behind the quick ones means everything else is finished and reported while
    # it runs, instead of waiting its turn behind it.
    $quick = New-Object System.Collections.ArrayList
    $slow = New-Object System.Collections.ArrayList
    foreach ($request in $Plan) {
        $setting = $AllSettings | Where-Object Id -eq $request.Id | Select-Object -First 1
        $isSlow = $false
        if ($setting) {
            $probe = $setting.PSObject.Copy()
            $probe.DesiredState = [string]$request.DesiredState
            $isSlow = try { Test-SettingNeedsLanguageDownload $probe } catch { $false }
        }
        if ($isSlow) { [void]$slow.Add($request) } else { [void]$quick.Add($request) }
    }
    [PSCustomObject]@{ Quick=@($quick); Slow=@($slow) }
}

function Invoke-AdministratorPlan([array]$Plan, [array]$AllSettings, [string]$CheckpointPath = '') {
    $results = New-Object System.Collections.ArrayList
    $split = Split-SlowPlanRequests $Plan $AllSettings
    $ordered = @(@($split.Quick) + @($split.Slow))
    foreach ($slowRequest in @($split.Slow)) {
        $setting = $AllSettings | Where-Object Id -eq $slowRequest.Id | Select-Object -First 1
        if (-not $setting -or $setting.Kind -ne 'Language') { continue }
        $choice = try { Get-LocaleChoice (Get-LanguageChoiceTable) ([string]$slowRequest.DesiredState) } catch { $null }
        if ($choice) { [void](Start-DisplayLanguagePackPrefetch @($choice.Packs)) }
    }
    $total = @($ordered).Count
    $index = 0
    foreach ($request in $ordered) {
        $index++
        # Checked between settings, so a stop never lands halfway through one.
        if (Test-WorkerCancelled) {
            Write-Log 'WARN' "Administrator worker stopped at the user's request before [$($request.Id)]; $($results.Count) of $total change(s) were done."
            Stop-PrestartedPackJobs
            break
        }
        $setting = $AllSettings | Where-Object Id -eq $request.Id | Select-Object -First 1
        Set-WorkerProgressStep $index $total ([string]$request.Id) $(if ($setting) { [string]$setting.Name } else { [string]$request.Id }) 'Working' 'Reading the current setting'
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
            foreach ($component in @(Invoke-SettingPartResults $setting ([string]$request.DesiredState) $scope)) { [void]$components.Add($component) }
        }
        $failedMessages = @($components | Where-Object Outcome -eq 'Failed' | ForEach-Object { "$($_.Name): $($_.Message)" })
        $message = if ($failedMessages) { $failedMessages -join '; ' } else { 'Administrator handlers completed; final state verification follows.' }
        $result = New-ApplyResult $setting.Id @($components) $message
        [void]$results.Add($result)
        Write-Log $(if ($result.Success) { 'INFO' } else { 'ERROR' }) "ADMINISTRATOR $($result.Outcome.ToUpperInvariant()) [$($setting.Id)] $message"
        if ($CheckpointPath) { Write-WorkerResults $results $CheckpointPath }
        Write-WorkerProgress 'Finished' $message
    }
    # Nothing should still be downloading once the plan is over.
    Stop-PrestartedPackJobs
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
    $progressPath = Join-Path $env:TEMP "Dingo-progress-$token.json"
    $cancelPath = Join-Path $env:TEMP "Dingo-cancel-$token.flag"
    try {
        Write-Utf8FileAtomically $planPath (ConvertTo-Json -InputObject $requests -Depth 6)
        Write-Utf8FileAtomically $resultPath '[]'
        $desktopSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        # The tools folder is handed over explicitly. The elevated step can run as
        # another account, and that account has its own options file.
        $argumentText = '-NoProfile -ExecutionPolicy Bypass -STA -File "{0}" -ElevationBroker -PlanPath "{1}" -ResultPath "{2}" -WorkerLogPath "{3}" -TargetUserSid "{4}" -ProgressPath "{5}" -CancelPath "{6}" -ToolRoot "{7}"' -f $PSCommandPath,$planPath,$resultPath,$script:LogFile,$desktopSid,$progressPath,$cancelPath,$script:ActiveToolRoot
        $process = Start-Process -FilePath (Get-PowerShellHostPath) -ArgumentList $argumentText -WindowStyle Hidden -PassThru -ErrorAction Stop
        if (-not $process) { throw 'Windows returned no process handle for the elevation broker.' }
        return [PSCustomObject]@{ Process=$process; PlanPath=$planPath; ResultPath=$resultPath; ProgressPath=$progressPath; CancelPath=$cancelPath; Selected=$Selected; Started=Get-Date; StartError=$null }
    } catch {
        Remove-Item -LiteralPath $planPath,$resultPath,$progressPath,$cancelPath -Force -ErrorAction SilentlyContinue
        return [PSCustomObject]@{ Process=$null; PlanPath=$null; ResultPath=$null; ProgressPath=$null; CancelPath=$null; Selected=$Selected; Started=Get-Date; StartError="The elevation broker could not start: $($_.Exception.Message)" }
    }
}

function Format-Duration([TimeSpan]$Span) {
    if ($Span.TotalSeconds -lt 0) { return '0:00' }
    '{0}:{1:00}' -f [math]::Floor($Span.TotalMinutes),$Span.Seconds
}

function Read-WorkerProgressFile([string]$Path) {
    # Read failures are normal: the worker replaces this file about twice a
    # second. The caller keeps showing the last good reading instead.
    if (-not $Path) { return $null }
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ConvertFrom-Json $raw
    } catch { return $null }
}

function Read-WorkerFinishedIds([string]$Path) {
    # The worker rewrites its result file after every setting, so the window can
    # tell which cards are already done long before the process exits.
    if (-not $Path) { return @() }
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        return @(@(ConvertFrom-JsonList $raw) | ForEach-Object { [string]$_.Id } | Where-Object { $_ })
    } catch { return @() }
}

function Format-WorkerStillWorkingLine($Progress, [TimeSpan]$StepElapsed, [int]$DetailLimit = 110) {
    # Said about a step that has been running a while. It carries no number: the
    # numbered lines count settings that have finished, and this one has not.
    $name = [string](Get-JsonField $Progress 'Name' '')
    $phase = [string](Get-JsonField $Progress 'Phase' '')
    $detail = [string](Get-JsonField $Progress 'Detail' '')
    $words = @($name, $phase) | Where-Object { $_ }
    $line = "  still working: $($words -join ': ')"
    if ($detail -and $detail -ne $phase) {
        # Some steps write a paragraph. A console line that wraps three times is
        # harder to read than a short one, and the log keeps the whole thing.
        if ($detail.Length -gt $DetailLimit) { $detail = $detail.Substring(0, $DetailLimit).TrimEnd() + '...' }
        $line += " - $detail"
    }
    if ($StepElapsed.TotalSeconds -lt 1) { return $line }
    return "$line [$(Format-Duration $StepElapsed) so far]"
}

function Get-RunFollowUpLines($Results, $Selected, [string]$ProcessPath = $null) {
    # What the person still has to do once the run is over. The window says this
    # in a box; a command-line run said nothing at all, so a PATH that reaches
    # new windows only looked like a PATH that had not worked.
    if ($null -eq $ProcessPath) { $ProcessPath = [string]$env:Path }
    $lines = New-Object System.Collections.ArrayList

    $pathApplied = @($Results | Where-Object { $_.Id -eq 'tools-on-path' -and $_.Outcome -ne 'Failed' }).Count -gt 0
    $pathWanted = @($Selected | Where-Object { $_.Id -eq 'tools-on-path' -and $_.DesiredState -eq 'On the PATH' }).Count -gt 0
    # Nothing to say when this very window already has the folder. The person is
    # not waiting on anything, and a needless instruction is worse than silence.
    if ($pathApplied -and $pathWanted -and -not (Test-PathContainsFolder $ProcessPath $script:ShimDirectory)) {
        [void]$lines.Add("Close this terminal and open a new one before the tool commands work. A PATH change reaches new windows only. The launchers are in $script:ShimDirectory.")
    }

    # A change that failed outright needs no sign-out; there is nothing waiting
    # to take effect. One that is only partly applied does.
    $restartNames = @($Results | Where-Object Outcome -ne 'Failed' | ForEach-Object {
        $finishedId = $_.Id
        $Selected | Where-Object { $_.Id -eq $finishedId -and $_.RestartRequired }
    } | ForEach-Object { [string]$_.Name })
    if ($restartNames.Count) { [void]$lines.Add((Get-RestartInstruction $restartNames 'Then run Dingo again to check.')) }

    return @($lines)
}

function Wait-AdministratorChangesOnConsole($Operation, [int]$PollMilliseconds = 500, [int]$HeartbeatSeconds = 60) {
    # A command-line run would otherwise print nothing at all between the Windows
    # approval prompt and the last result, and a tool download can take half an
    # hour.
    #
    # One line per setting, printed when that setting finishes. The count comes
    # from the worker's result file, which only ever grows, so no setting is
    # missed however fast it runs. The progress file says what is running right
    # now, and that is used only for the "still working" line, because a step
    # such as a language pack rewrites it every few seconds.
    if (-not $Operation -or -not $Operation.Process) { return }
    $names = @{}
    $planned = @($Operation.Selected | Where-Object RequiresAdmin)
    foreach ($item in $planned) { $names[[string]$item.Id] = [string]$item.Name }
    $total = $planned.Count
    $announced = @{}
    $done = 0
    $approvalSeen = $false
    $currentKey = ''
    $stepStarted = Get-Date
    $lastHeartbeat = Get-Date
    while ($true) {
        $running = -not $Operation.Process.HasExited
        foreach ($finishedId in @(Read-WorkerFinishedIds $Operation.ResultPath)) {
            if ($announced.ContainsKey($finishedId)) { continue }
            $announced[$finishedId] = $true
            $done++
            $label = if ($names.ContainsKey($finishedId)) { $names[$finishedId] } else { $finishedId }
            Write-CliStatus ("  {0}/{1} {2}" -f $done, $total, $label)
            $approvalSeen = $true
            $lastHeartbeat = Get-Date
        }
        $progress = Read-WorkerProgressFile $Operation.ProgressPath
        if ($progress) {
            $approvalSeen = $true
            $key = '{0}|{1}' -f [string](Get-JsonField $progress 'Id' ''), [string](Get-JsonField $progress 'Phase' '')
            if ($key -ne $currentKey) { $currentKey = $key; $stepStarted = Get-Date }
        }
        if (-not $running) { break }
        if (((Get-Date) - $lastHeartbeat).TotalSeconds -ge $HeartbeatSeconds) {
            $lastHeartbeat = Get-Date
            if (-not $approvalSeen) {
                Write-CliStatus '  Still waiting for administrator approval. Accept the Windows prompt to let Dingo continue.'
            } elseif ($progress) {
                Write-CliStatus (Format-WorkerStillWorkingLine $progress ((Get-Date) - $stepStarted))
            }
        }
        Start-Sleep -Milliseconds $PollMilliseconds
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
        Remove-Item -LiteralPath $Operation.PlanPath,$Operation.ResultPath,$Operation.ProgressPath,$Operation.CancelPath -Force -ErrorAction SilentlyContinue
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
            $userResults = @(Invoke-SettingPartResults $Item $Item.DesiredState User)
            foreach ($component in $userResults) { [void]$components.Add($component) }
            $failures = @($userResults | Where-Object Outcome -eq 'Failed')
            if ($failures.Count) { throw (($failures | ForEach-Object Message) -join '; ') }
        }
        $Item.CurrentState = Get-SettingState $Item
        $expectedStatus = if ($Item.Kind -eq 'Package' -or $Item.DesiredState -eq $Item.PreferredState) { 'Preferred' } else { 'Alternate' }
        if ($Item.CurrentState.Status -ne $expectedStatus) {
            $reason = if ($Item.CurrentState.Status -eq 'Error') { "$($Item.CurrentState.DisplayText): $($Item.CurrentState.Details)" } else { $Item.CurrentState.DisplayText }
            $followUp = if ($Item.RestartRequired -and $Item.CurrentState.Status -eq 'Partial') {
                ' ' + (Get-RestartInstruction -SettingNames @([string]$Item.Name))
            } else { '' }
            [void]$components.Add((New-OperationComponent 'Final verification' 'Failed' "Windows reports '$reason'.$followUp"))
            throw "Windows still reports '$reason' instead of '$($Item.DesiredState)'.$followUp"
        }
        $verification = Get-VerificationDescription $Item
        [void]$components.Add((New-OperationComponent 'Final verification' 'Succeeded' "$verification $($Item.CurrentState.Details)"))
        # The write succeeded, so the outcome and the exit code stay successful.
        # Only the operator-facing wording changes when a caveat applies.
        $advisory = Get-SettingAdvisory $Item
        $message = "$verification $($Item.CurrentState.Details)"
        if ($advisory -and -not $message.Contains($advisory)) { $message += " $advisory" }
        $result = New-ApplyResult $Item.Id @($components) $message $Item.RestartExplorer $Item.RestartRequired
        $Item.LastApplyResult = $result
        $Item.Status = if ($advisory) { 'Applied with caveat' } else { 'Succeeded' }
        $Item.Details = "$($Item.CurrentState.DisplayText). $message"
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
    # 'tweaks' and 'tools' stand for every ID in that section. They keep a
    # command line short as the tool list grows, and they let the default
    # apply reach for the tweaks alone without naming each one.
    $groups = @{}
    foreach ($setting in $AllSettings) {
        $groupKey = ([string]$setting.Section).ToLowerInvariant()
        if (-not $groups.ContainsKey($groupKey)) { $groups[$groupKey] = New-Object System.Collections.ArrayList }
        [void]$groups[$groupKey].Add(([string]$setting.Id).ToLowerInvariant())
    }
    # A section word that was also a setting ID would be read two ways, so the
    # catalog is refused rather than guessed at.
    foreach ($groupKey in $groups.Keys) {
        if ($known.ContainsKey($groupKey)) { throw "Setting ID '$groupKey' clashes with the section name of the same spelling. Rename it in Tools.json." }
    }
    $expand = {
        param([string[]]$Keys)
        @($Keys | ForEach-Object { if ($groups.ContainsKey($_)) { @($groups[$_]) } else { $_ } } | Select-Object -Unique)
    }
    $includeKeys = @(& $normalise $IncludeIds)
    $excludeKeys = @(& $normalise $ExcludeIds)
    $unknown = @($includeKeys + $excludeKeys | Where-Object { -not $known.ContainsKey($_) -and -not $groups.ContainsKey($_) } | Select-Object -Unique)
    if ($unknown) { throw "Unknown setting ID or section$(if ($unknown.Count -eq 1) { '' } else { 's' }): $($unknown -join ', '). Sections are 'tweaks' and 'tools'." }
    $includeKeys = @(& $expand $includeKeys)
    $excludeKeys = @(& $expand $excludeKeys)
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
  Start-Dingo.cmd -WhatIf [-Include what] [-Exclude what] [-OutputFormat Text|Json]
  Start-Dingo.cmd -ApplyPreferred [-Include what] [-Exclude what] [-NoRestartExplorer] [-OutputFormat Text|Json]

  Without -Include, only the Tweaks section is applied. Tool cards are left alone,
  and the run reports how many were skipped.

What to include or exclude:
  A section word, a setting ID, or a comma-separated list of either.
  Sections are 'tweaks' (account and computer settings) and 'tools'
  (installs, shortcuts, and file associations).

  -Include tweaks              the default: settings only, no installs
  -Include tools               installs, shortcuts, and file associations
  -Include tweaks,tools        everything
  -Include tools -Exclude tool-7zip    a section, less one card
  -Include date-time-format,hidden-files       named cards only

Discovery:
  Start-Dingo.cmd -ListSettings [-OutputFormat Text|Json]
  Start-Dingo.cmd -RecoveryReport [-OutputFormat Text|Json]
  Start-Dingo.cmd -Version
  Start-Dingo.cmd -Help

Tools:
  Analyst tools sit in the Tools section and use IDs that start with 'tool-'.
  Dingo installs them with winget and never uninstalls them.
  Add your own by placing a Tools.json file next to Dingo.ps1. See the README.

  A tool with no installer of its own goes in C:\DFIR\Tools. Change that folder on
  the Options tab of the window, or for one run only:
  -ToolRoot "D:\DFIR\Tools"        a full path on a drive of this computer

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
    # File types are a per-account choice, so this handler never needs elevation.
    Register-SettingHandler 'Association' { param($entries) @('User') } 'Get-AssociationKindState' 'Set-AssociationKindPart'
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
            if (($Setting.CurrentState.Status -ne 'Preferred' -or $Setting.DesiredState -eq 'Update installed tool') -and -not (Get-WingetPath)) {
                [void]$problems.Add('winget is not available, so this tool cannot be installed')
            }
        }
        if ($Setting.Kind -eq 'Package' -and $Setting.DesiredState -eq 'Update installed tool' -and
            -not (Find-InstalledTool @($Setting.Entries)[0])) {
            [void]$problems.Add('the tool is not installed; choose Installed to install it first')
        }
        if ($Setting.DesiredState -eq $Setting.PreferredState) {
            if ($Setting.Kind -eq 'ToolPath') {
                $expected = Get-ExpectedShims
                foreach ($name in @($expected.Keys)) {
                    Assert-DingoFileOwnership (Join-Path $script:ShimDirectory "$name.cmd") Shim
                }
            } elseif ($Setting.Kind -eq 'Shortcut') {
                $expected = Get-ExpectedShortcuts
                $folder = Get-ShortcutSettingFolder $Setting
                foreach ($name in @($expected.Keys)) {
                    Assert-DingoFileOwnership (Join-Path $folder ($name + '.lnk')) Shortcut
                }
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

# The tools folder has to be known before the cards are built, because a card's
# text and its state both name folders inside it.
[void](Initialize-DingoToolRoot)
Initialize-SettingHandlers
$script:Settings = Get-Settings
# The GUI shows this on the Tools tab. Command-line runs have no tab, so say it here.
if ($script:ToolCatalogWarning -and -not $WpfHost) { [Console]::Error.WriteLine($script:ToolCatalogWarning) }
# Same for the tools folder. The Options tab shows it in the window.
# A folder asked for on the command line is refused below instead, with one message.
if ($script:ToolRootWarning -and -not $WpfHost -and -not $ToolRoot) { [Console]::Error.WriteLine($script:ToolRootWarning) }

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

if ($RecoveryReport) {
    $report = @(Get-RecoveryReport (Join-Path $PSScriptRoot 'Logs'))
    if ($OutputFormat -eq 'Json') { [Console]::Out.WriteLine((ConvertTo-Json -InputObject $report -Depth 6)) }
    elseif ($report.Count) { [Console]::Out.WriteLine(($report | Format-List | Out-String).TrimEnd()) }
    else { [Console]::Out.WriteLine('No incomplete scope records found. This does not verify workstation state or installer completion.') }
    exit 0
}

if ($ListSettings) {
    $catalog = @($script:Settings | ForEach-Object {
        [PSCustomObject]@{ Id=$_.Id; Section=$_.Section; Name=$_.Name; Category=$_.Category; Kind=$_.Kind; Scope=$_.DisplayScope; RequiresAdmin=$_.RequiresAdmin; PreferredState=$_.PreferredState; Requirements=$_.Requirements }
    })
    if ($OutputFormat -eq 'Json') { [Console]::Out.WriteLine((ConvertTo-Json -InputObject $catalog -Depth 5)) }
    else { [Console]::Out.WriteLine(($catalog | Format-Table -AutoSize | Out-String -Width 220).TrimEnd()) }
    exit 0
}

if ($ElevationBroker) {
    try {
        # Installing somewhere other than the window asked for would be a quiet
        # surprise, so a folder that cannot be used stops the run instead.
        if ($script:ToolRootRejected) { throw $script:ToolRootRejectMessage }
        $workerArguments = '-NoProfile -ExecutionPolicy Bypass -STA -File "{0}" -MachineWorker -PlanPath "{1}" -ResultPath "{2}" -WorkerLogPath "{3}" -TargetUserSid "{4}" -ProgressPath "{5}" -CancelPath "{6}" -ToolRoot "{7}"' -f $PSCommandPath,$PlanPath,$ResultPath,$WorkerLogPath,$TargetUserSid,$ProgressPath,$CancelPath,$script:ActiveToolRoot
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
        $formatState = if ($FinalizeFormatState) { $FinalizeFormatState } else { [string]$isoSetting.PreferredState }
        if ($formatState -notin @($isoSetting.StateOptions)) { throw "'$formatState' is not a date and time format Dingo offers." }
        foreach ($entry in $isoSetting.Entries) { Set-EntryValue $entry $formatState $isoSetting }
        Send-InternationalSettingChange
        Write-Log 'INFO' "One-time sign-in finalizer reapplied and verified the '$formatState' date and time formats."
        exit 0
    } catch {
        Write-Log 'ERROR' "One-time sign-in finalizer failed: $($_.Exception.ToString())"
        exit 1
    }
}

if ($SelfTest) {
    # Tools.json may add tools, so the total is the fixed settings plus the catalog.
    $expectedSettingCount = 30 + @(Get-ToolCatalog).Count + @(Get-ToolCatalog | Where-Object { @($_.Associations).Count }).Count
    if ($script:Settings.Count -ne $expectedSettingCount) { throw "Expected $expectedSettingCount settings, found $($script:Settings.Count)." }
    foreach ($workerHelper in @('Test-DisplayLanguagePackInstalled','Install-DisplayLanguagePack','Write-Utf8FileAtomically','New-ApplyResult','New-OperationComponent')) {
        if (-not (Get-Command $workerHelper -CommandType Function -ErrorAction SilentlyContinue)) { throw "Elevated-worker helper is unavailable: $workerHelper" }
    }
    $selfTestTokens = $null; $selfTestErrors = $null
    $selfTestAst = [Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$selfTestTokens,[ref]$selfTestErrors)
    if ($selfTestAst.Extent.Text -notmatch 'CmdletBinding\s*\(\s*PositionalBinding\s*=\s*\$false\s*\)' -or $selfTestAst.Extent.Text -notmatch 'ValueFromRemainingArguments\s*=\s*\$true') {
        throw 'Command-line parsing must reject stray positional and unknown arguments through the Dingo help path.'
    }
    $helpText = Get-DingoHelpText
    foreach ($helpTopic in @('-ApplyPreferred','-ListSettings','-Include tweaks','-Include tools','-Include tweaks,tools')) {
        if ($helpText -notmatch [regex]::Escape($helpTopic)) { throw "The command-line help text does not cover '$helpTopic'." }
    }
    # The default is a trap if it is undocumented, so the help must state it.
    if ($helpText -notmatch 'Without -Include') { throw 'The command-line help text does not state what a bare apply does.' }
    $launcherAst = $selfTestAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-AdministratorChanges' },$true)
    $launcherStart = if ($launcherAst) { $launcherAst.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Start-Process' },$true) } else { $null }
    if (-not $launcherStart) { throw 'The asynchronous elevated-worker launcher does not start a process.' }
    if ($launcherAst.Extent.Text -notmatch '-ElevationBroker' -or $launcherAst.Extent.Text -match '-Verb\s+RunAs') { throw 'The WPF launcher must delegate UAC to the non-WPF elevation broker.' }
    $duplicates = $script:Settings | Group-Object Id | Where-Object Count -gt 1
    if ($duplicates) { throw "Duplicate IDs: $($duplicates.Name -join ', ')" }
    if ($script:SettingHandlers.Count -ne 10) { throw "Expected 10 setting handlers, found $($script:SettingHandlers.Count)." }
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
    $quickSelection = @(Resolve-QuickApplySettings $script:Settings @('WIDGETS,time-zone') @('time-zone'))
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
    $updateSetting = $script:Settings | Where-Object Id -eq 'windows-update'
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
        MicrosoftEdgeInsiderPromotionEnabled=0; DefaultBrowserSettingsCampaignEnabled=0
        UserFeedbackAllowed=0; AlternateErrorPagesEnabled=0
        EdgeAssetDeliveryServiceEnabled=0; DiagnosticData=0; ConfigureDoNotTrack=1
        CreateDesktopShortcutDefault=0
    }
    foreach ($valueName in $requiredDebloat.Keys) {
        $entry = $debloatSetting.Entries | Where-Object Name -eq $valueName | Select-Object -First 1
        if (-not $entry) { throw "The Edge debloat setting is missing '$valueName'." }
        if ([int]$entry.Preferred -ne [int]$requiredDebloat[$valueName]) { throw "'$valueName' has the wrong preferred value." }
    }
    foreach ($retiredPolicy in @('WalletDonationEnabled','WebWidgetAllowed')) {
        $entry = $debloatSetting.Entries | Where-Object Name -eq $retiredPolicy | Select-Object -First 1
        if (-not $entry -or $entry.Preferred -ne $script:RemoveValue -or $entry.Alternate -ne $script:RemoveValue) {
            throw "Retired Edge policy '$retiredPolicy' must be removed for either card choice."
        }
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

    # Check managed-device caveats independently of the update-policy caveat.
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
            if ($shipped.Id -eq 'windows-update') {
                if ((Get-SettingAdvisory $shipped) -notmatch 'not verified') { throw 'Update configuration must disclose its verification limit.' }
            } elseif (Get-SettingAdvisory $shipped) { throw "Setting '$($shipped.Id)' carries an unexpected caveat." }
        }
        # A tool that needs another tool must say so when that one is absent, and
        # must stay silent when it is present. Neither may fail preflight.
        $dependentMock = ($script:Settings | Where-Object Id -eq 'tool-eztools' | Select-Object -First 1).PSObject.Copy()
        $dependentMock.Requirements = @{ RequiredTools = @('tool-definitely-not-in-the-catalog') }
        if ((Get-SettingAdvisory $dependentMock) -notmatch 'will not start') { throw 'A tool with a missing dependency must produce a caveat.' }
        # The same tool, with that dependency in the same run. Dingo installs the
        # runtime first, so telling the person to select it would be wrong.
        $savedPlanned = @(Get-Variable -Name PlannedSettingIds -Scope Script -ErrorAction SilentlyContinue | ForEach-Object { $_.Value })
        try {
            $script:PlannedSettingIds = @('tool-definitely-not-in-the-catalog')
            if (Get-SettingAdvisory $dependentMock) { throw 'A dependency that is in the same run must produce no caveat.' }
            $script:PlannedSettingIds = @('something-else-entirely')
            if ((Get-SettingAdvisory $dependentMock) -notmatch 'will not start') { throw 'A dependency left out of the run must still produce a caveat.' }
        } finally { $script:PlannedSettingIds = $savedPlanned }
        if (-not (Test-SettingPreflight $dependentMock).Available) { throw 'A dependency caveat must never fail preflight.' }
        $dependentMock.Requirements = @{ RequiredTools = @() }
        if (Get-SettingAdvisory $dependentMock) { throw 'A tool with no dependencies must produce no caveat.' }
        $ezRequires = @(($script:Settings | Where-Object Id -eq 'tool-eztools' | Select-Object -First 1).Requirements['RequiredTools'])
        if ($ezRequires -notcontains 'tool-dotnet-desktop-9') { throw "Eric Zimmerman's tools must declare the .NET runtime they need." }
    } finally {
        $script:DeviceIsManaged = $savedManagedState
    }
    # Tool cards offer an explicit update action, but never uninstall.
    $builtInTools = @(Get-BuiltInToolCatalog | ForEach-Object { ConvertTo-ToolDefinition $_ })
    foreach ($expectedId in @('tool-7zip','tool-notepadplusplus','tool-ripgrep','tool-sqlitebrowser','tool-eztools','tool-dotnet-desktop-9','tool-memprocfs','tool-volatility3','tool-hayabusa','tool-duckdb')) {
        if (@($builtInTools | Where-Object Id -eq $expectedId).Count -ne 1) { throw "The built-in tool catalog is missing '$expectedId'." }
    }
    # The tools that come straight from a GitHub release. Each one must name a
    # repository rather than an address, must ask for a zip, must unpack inside
    # the tools folder, and must offer its program to the PATH card.
    foreach ($releaseId in @('tool-memprocfs','tool-volatility3','tool-hayabusa','tool-duckdb')) {
        $releaseTool = $builtInTools | Where-Object Id -eq $releaseId | Select-Object -First 1
        if ($releaseTool.InstallKind -ne 'github-release') { throw "'$releaseId' must use the github-release install kind." }
        if ($releaseTool.Url) { throw "'$releaseId' must not name a download address; Dingo builds it from the repository." }
        if ($releaseTool.Repo -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "'$releaseId' must name a GitHub repository as owner/name." }
        if ($releaseTool.AssetPattern -notlike '*.zip') { throw "'$releaseId' must ask for a zip file." }
        if ($releaseTool.Dest -notlike "$($script:ToolRootToken)\*") { throw "'$releaseId' must unpack inside the tools folder." }
        if ($releaseTool.Scope -ne 'machine') { throw "Writing to the tools folder needs administrator approval, so '$releaseId' must be machine scope." }
        if (-not $releaseTool.Shims -or $releaseTool.Shims.From -notlike "$($script:ToolRootToken)/*") { throw "'$releaseId' must offer its command-line program from the tools folder." }
        $releaseSetting = $script:Settings | Where-Object Id -eq $releaseId | Select-Object -First 1
        if (-not $releaseSetting) { throw "'$releaseId' produced no card." }
        if (-not $releaseSetting.RequiresAdmin) { throw "'$releaseId' must request administrator approval." }
        if ([bool]$releaseSetting.Requirements['WingetRequired']) { throw "A release download must not be blocked by a missing winget." }
    }
    # Hayabusa stamps its version into the program name, so its launcher is named
    # by hand. Every other tool takes the name from the file.
    $hayabusaTool = $builtInTools | Where-Object Id -eq 'tool-hayabusa' | Select-Object -First 1
    if ($hayabusaTool.Shims.Name -ne 'hayabusa') { throw 'The Hayabusa launcher must be called hayabusa.' }
    if ((($builtInTools | Where-Object Id -eq 'tool-duckdb' | Select-Object -First 1).Shims.Name)) { throw 'DuckDB names its own launcher, so no override is needed.' }
    # An archive must never write outside the folder it was told to fill.
    $zipTestRoot = Join-Path $env:TEMP ("Dingo-zip-test-{0}" -f [Guid]::NewGuid().ToString('N'))
    try {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        New-Item -ItemType Directory -Path $zipTestRoot -Force -ErrorAction Stop | Out-Null
        $goodZip = Join-Path $zipTestRoot 'good.zip'
        $escapeZip = Join-Path $zipTestRoot 'escape.zip'
        foreach ($case in @(
            [PSCustomObject]@{ Path=$goodZip; Entry='inner/tool.txt' },
            [PSCustomObject]@{ Path=$escapeZip; Entry='../escaped.txt' }
        )) {
            $archive = [IO.Compression.ZipFile]::Open($case.Path, [IO.Compression.ZipArchiveMode]::Create)
            try {
                $writer = New-Object IO.StreamWriter (($archive.CreateEntry($case.Entry)).Open())
                try { $writer.Write('dingo') } finally { $writer.Dispose() }
            } finally { $archive.Dispose() }
        }
        $unpackRoot = Join-Path $zipTestRoot 'unpack'
        New-Item -ItemType Directory -Path $unpackRoot -Force -ErrorAction Stop | Out-Null
        if ((Expand-DingoZipArchive $goodZip $unpackRoot) -ne 1) { throw 'A plain archive did not unpack one file.' }
        if (-not (Test-Path -LiteralPath (Join-Path $unpackRoot 'inner\tool.txt') -PathType Leaf)) { throw 'A plain archive did not land where it was told.' }
        # Unpacking the same archive again must overwrite rather than fail.
        if ((Expand-DingoZipArchive $goodZip $unpackRoot) -ne 1) { throw 'Unpacking the same archive twice must overwrite.' }
        $escapeRefused = $false
        try { [void](Expand-DingoZipArchive $escapeZip $unpackRoot) } catch { $escapeRefused = $true }
        if (-not $escapeRefused) { throw 'An archive entry pointing outside the folder was accepted.' }
        if (Test-Path -LiteralPath (Join-Path $zipTestRoot 'escaped.txt')) { throw 'An archive entry escaped the folder it was given.' }
    } finally {
        Remove-Item -LiteralPath $zipTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    $toolSettings = @($script:Settings | Where-Object Kind -eq 'Package')
    if ($toolSettings.Count -ne @(Get-ToolCatalog).Count) { throw "Every catalog tool must become a setting; found $($toolSettings.Count)." }
    foreach ($toolSetting in $toolSettings) {
        if ($toolSetting.Tab -ne 'Install tools') { throw "Tool '$($toolSetting.Id)' must sit on the Install tools tab." }
        if ($toolSetting.StateOptions.Count -ne 2 -or $toolSetting.StateOptions -notcontains 'Update installed tool' -or $toolSetting.AlternateState) {
            throw "Tool '$($toolSetting.Id)' must offer install and explicit update, with no uninstall option."
        }
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
        [PSCustomObject]@{ id='tool-x'; name='x'; install=[PSCustomObject]@{ kind='script'; url='https://example.com/a.ps1' }; detect=@([PSCustomObject]@{ kind='file'; path='x' }) },
        # A release download builds its own address, so the repository name must
        # be a plain owner/name, the file must be a zip, and the folder is needed.
        [PSCustomObject]@{ id='tool-x'; name='x'; install=[PSCustomObject]@{ kind='github-release'; assetPattern='a.zip'; dest='C:\x' }; detect=@([PSCustomObject]@{ kind='file'; path='x' }) },
        [PSCustomObject]@{ id='tool-x'; name='x'; install=[PSCustomObject]@{ kind='github-release'; repo='https://evil.example.com/o/r'; assetPattern='a.zip'; dest='C:\x' }; detect=@([PSCustomObject]@{ kind='file'; path='x' }) },
        [PSCustomObject]@{ id='tool-x'; name='x'; install=[PSCustomObject]@{ kind='github-release'; repo='owner/name/extra'; assetPattern='a.zip'; dest='C:\x' }; detect=@([PSCustomObject]@{ kind='file'; path='x' }) },
        [PSCustomObject]@{ id='tool-x'; name='x'; install=[PSCustomObject]@{ kind='github-release'; repo='owner/name'; dest='C:\x' }; detect=@([PSCustomObject]@{ kind='file'; path='x' }) },
        [PSCustomObject]@{ id='tool-x'; name='x'; install=[PSCustomObject]@{ kind='github-release'; repo='owner/name'; assetPattern='..\\a.zip'; dest='C:\x' }; detect=@([PSCustomObject]@{ kind='file'; path='x' }) },
        [PSCustomObject]@{ id='tool-x'; name='x'; install=[PSCustomObject]@{ kind='github-release'; repo='owner/name'; assetPattern='a.exe'; dest='C:\x' }; detect=@([PSCustomObject]@{ kind='file'; path='x' }) },
        [PSCustomObject]@{ id='tool-x'; name='x'; install=[PSCustomObject]@{ kind='github-release'; repo='owner/name'; assetPattern='a.zip' }; detect=@([PSCustomObject]@{ kind='file'; path='x' }) }
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
    # The folder is named with the token, not a literal, so the Options tab can
    # move it. A literal here would silently ignore the option.
    if ($ezTool.Dest -ne "$($script:ToolRootToken)\EZTools") { throw "The Eric Zimmerman tool set must install to $($script:ToolRootToken)\EZTools." }
    if ($ezTool.Scope -ne 'machine') { throw 'Writing to the tools folder needs administrator approval.' }
    # The tools folder: one rule set decides what may be used, and the token is
    # what makes every catalog path follow it.
    foreach ($bad in @(
        '', '   ', 'DFIR\Tools', '\DFIR\Tools', 'C:', 'C:\', '\\server\share\Tools',
        'C:\DFIR\To*ls', "$($env:SystemRoot)\Tools", "$($env:SystemRoot)",
        "$(${env:ProgramFiles})\Tools", "$($env:SystemDrive)\Users\Public\Tools"
    )) {
        if (-not (Test-ToolRootIsUsable $bad)) { throw "An unusable tools folder was accepted: '$bad'." }
        $refused = $false
        try { [void](Resolve-ToolRootValue $bad) } catch { $refused = $true }
        if (-not $refused) { throw "Resolving an unusable tools folder did not fail: '$bad'." }
    }
    foreach ($good in @('C:\DFIR\Tools', 'C:\DFIR\Tools\', 'C:\Dingo Tools\set 1')) {
        $reason = Test-ToolRootIsUsable $good
        if ($reason) { throw "A usable tools folder was refused: '$good'. $reason" }
    }
    if ((Resolve-ToolRootValue 'C:\DFIR\Tools\') -ne 'C:\DFIR\Tools') { throw 'A trailing backslash must be trimmed from the tools folder.' }
    if ($script:DefaultToolRoot -ne 'C:\DFIR\Tools') { throw 'The default tools folder changed.' }
    $savedToolRoot = $script:ActiveToolRoot
    $toolRootTestFile = Join-Path $env:TEMP ("Dingo-toolroot-test-{0}.json" -f [Guid]::NewGuid().ToString('N'))
    try {
        [void](Set-DingoToolRoot 'C:\Dingo-ToolRoot-Test')
        if ($script:ShimDirectory -ne 'C:\Dingo-ToolRoot-Test\bin') { throw 'The launcher folder must sit inside the tools folder.' }
        if ([Environment]::GetEnvironmentVariable($script:ToolRootVariableName) -ne 'C:\Dingo-ToolRoot-Test') { throw 'The tools folder was not published to the environment.' }
        if ((Expand-ToolRootPath "$($script:ToolRootToken)\EZTools") -ne 'C:\Dingo-ToolRoot-Test\EZTools') { throw 'The tools folder token did not expand.' }
        $ezPath = Expand-ToolRootPath ($builtInTools | Where-Object Id -eq 'tool-eztools').Dest
        if ($ezPath -ne 'C:\Dingo-ToolRoot-Test\EZTools') { throw "The Eric Zimmerman install folder ignored the tools folder: $ezPath" }
        $ezShortcut = Expand-ToolRootPath (($builtInTools | Where-Object Id -eq 'tool-eztools').Shortcuts[0].Target)
        if ($ezShortcut -notlike 'C:\Dingo-ToolRoot-Test/*') { throw "A tool shortcut ignored the tools folder: $ezShortcut" }
        # An unset token must be reported, never turned into a folder name.
        [Environment]::SetEnvironmentVariable($script:ToolRootVariableName, $null, 'Process')
        $tokenRefused = $false
        try { [void](Expand-ToolRootPath "$($script:ToolRootToken)\EZTools") } catch { $tokenRefused = $true }
        if (-not $tokenRefused) { throw 'An unresolved tools folder token must not be used as a path.' }
        # The saved option round trips, and rubbish in the file is ignored.
        [void](Save-DingoToolRootPreference 'C:\Dingo-ToolRoot-Test\deeper' $toolRootTestFile)
        if ((Read-DingoToolRootPreference $toolRootTestFile) -ne 'C:\Dingo-ToolRoot-Test\deeper') { throw 'The saved tools folder did not read back.' }
        [IO.File]::WriteAllText($toolRootTestFile, 'not json at all')
        $script:ToolRootWarning = ''
        if ((Read-DingoToolRootPreference $toolRootTestFile) -ne '') { throw 'An unreadable options file must not supply a tools folder.' }
        if (-not $script:ToolRootWarning) { throw 'An unreadable options file must be reported.' }
        if ((Read-DingoToolRootPreference (Join-Path $env:TEMP "Dingo-absent-$([Guid]::NewGuid().ToString('N')).json")) -ne '') { throw 'A missing options file must be silent.' }
    } finally {
        $script:ToolRootWarning = ''
        Remove-Item -LiteralPath $toolRootTestFile -Force -ErrorAction SilentlyContinue
        [void](Set-DingoToolRoot $savedToolRoot)
    }
    if ((Get-DingoConfigPath) -notlike "$($env:LOCALAPPDATA)\*") { throw 'The options file must live in the account it belongs to.' }
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
    # A command-line run reads the worker's progress file and says what it says,
    # so a long step never looks like a hang. PowerShell defines a function only
    # when execution reaches it, and a quick apply exits long before the window
    # code is read, so every reader it uses must stand above that block.
    $sourceText = Get-Content -LiteralPath $PSCommandPath -Raw -ErrorAction Stop
    $quickApplyOffset = $sourceText.LastIndexOf('Dingo quick apply: applying')
    if ($quickApplyOffset -lt 0) { throw 'The quick-apply block could not be found in the source.' }
    foreach ($needed in @('Format-Duration','Read-WorkerProgressFile','Read-WorkerFinishedIds','Format-WorkerStillWorkingLine','Wait-AdministratorChangesOnConsole')) {
        $definedAt = $sourceText.IndexOf("function $needed")
        if ($definedAt -lt 0) { throw "'$needed' is missing." }
        if ($definedAt -gt $quickApplyOffset) { throw "'$needed' is defined after the quick-apply block, so a command-line run could never call it." }
    }
    if ($sourceText.IndexOf('Wait-AdministratorChangesOnConsole $operation') -lt 0) { throw 'A command-line run must watch the administrator step.' }
    # The "still working" line names the step and how long it has run, and it
    # carries no counter: the numbered lines count settings that have finished.
    $workingLine = Format-WorkerStillWorkingLine ([PSCustomObject]@{
        Index=2; Total=5; Id='tool-eztools'; Name="Eric Zimmerman's tools"; Phase='Installing'; Detail='Downloading'
    }) ([TimeSpan]::FromSeconds(90))
    foreach ($part in @('still working', "Eric Zimmerman's tools", 'Installing', 'Downloading', '1:30 so far')) {
        if ($workingLine -notmatch [regex]::Escape($part)) { throw "A working line lost '$part': $workingLine" }
    }
    if ($workingLine -match '2/5') { throw "A working line must carry no counter: $workingLine" }
    $sparseLine = Format-WorkerStillWorkingLine ([PSCustomObject]@{ Name='Widgets'; Phase='Applying' }) ([TimeSpan]::Zero)
    if ($sparseLine -notmatch 'Widgets: Applying') { throw "A working line with no detail read badly: $sparseLine" }
    if ($sparseLine -match ' - ') { throw "An absent detail must not be printed: $sparseLine" }
    if ($sparseLine -match 'so far') { throw "A step that just started must not print a time: $sparseLine" }
    # A step that writes a paragraph must not wrap the console three times.
    $longDetail = 'Windows is downloading and installing the en-GB language pack. ' * 6
    $trimmed = Format-WorkerStillWorkingLine ([PSCustomObject]@{ Name='Display language'; Phase='Downloading'; Detail=$longDetail }) ([TimeSpan]::Zero)
    if ($trimmed.Length -gt 180) { throw "A long detail was not shortened: $($trimmed.Length) characters." }
    if ($trimmed -notmatch '\.\.\.$') { throw "A shortened detail must say it was shortened: $trimmed" }
    # Both counts must be named, so nobody has to guess what 26 and 43 mean.
    if ($sourceText -notmatch 'Step 1 of 2: \$administratorCount of the \$planCount change') { throw 'The administrator count must say what it counts.' }
    if ($sourceText -notmatch 'Step 2 of 2: applying and checking all \$planCount change') { throw 'The whole-plan count must say what it counts.' }
    # A caveat has to reach the screen before the work starts, or a ten minute
    # download is just an unexplained wait. A dry run has always printed them;
    # so must a real run, and before the administrator step is started.
    $noteOffset = $sourceText.LastIndexOf('Write-CliStatus "  Note [$($item.Id)]: $advisory"')
    $adminStartOffset = $sourceText.LastIndexOf('$operation = Start-AdministratorChanges $selected')
    if ($noteOffset -lt 0) { throw 'A quick apply must print the caveats it knows about.' }
    if ($adminStartOffset -lt 0 -or $noteOffset -gt $adminStartOffset) { throw 'Caveats must be printed before the administrator step starts.' }
    if ($noteOffset -lt $quickApplyOffset) { throw 'The caveats must belong to the quick-apply block.' }
    # The display language caveat is the one that costs real time, so prove it
    # says how long, rather than only that something is slow.
    foreach ($mustSay in @('about ten minutes', 'Windows Update', 'every other selected change still runs')) {
        if ($sourceText -notmatch [regex]::Escape($mustSay)) { throw "The display language caveat no longer says '$mustSay'." }
    }
    # A run that changes the PATH or needs a sign-out has to say so at the end.
    # The window puts it in a box; a command-line run has only this line.
    # Searched from the end: every phrase below also appears in the line that
    # searches for it, and the code being checked comes after the self-test.
    $followUpOffset = $sourceText.LastIndexOf('Write-CliStatus "Next: $line"')
    if ($followUpOffset -lt 0) { throw 'A command-line run must say what is still needed when it finishes.' }
    if ($followUpOffset -lt $sourceText.LastIndexOf('Dingo finished: $succeeded succeeded')) { throw 'The follow-up must come after the results, not before them.' }
    # The PATH line, driven rather than read out of the source. The folder is on
    # the stand-in PATH in one case and absent in the other, and nothing here
    # touches the real environment.
    $pathPlan = @([PSCustomObject]@{ Id='tools-on-path'; DesiredState='On the PATH'; Name='Run tools from anywhere'; RestartRequired=$false })
    $pathDone = @([PSCustomObject]@{ Id='tools-on-path'; Outcome='Succeeded' })
    $pathLines = @(Get-RunFollowUpLines $pathDone $pathPlan 'C:\Windows;C:\Windows\System32')
    if ($pathLines.Count -ne 1) { throw "A PATH change must produce one instruction; got $($pathLines.Count)." }
    if ($pathLines[0] -notmatch 'Close this terminal and open a new one') { throw "The PATH instruction reads wrong: $($pathLines[0])" }
    if ($pathLines[0] -notmatch [regex]::Escape($script:ShimDirectory)) { throw 'The PATH instruction must name the launcher folder.' }
    $alreadyOnPath = @(Get-RunFollowUpLines $pathDone $pathPlan "C:\Windows;$($script:ShimDirectory)")
    if ($alreadyOnPath.Count) { throw "A terminal that already has the folder needs no instruction: $($alreadyOnPath[0])" }
    $pathFailed = @(Get-RunFollowUpLines @([PSCustomObject]@{ Id='tools-on-path'; Outcome='Failed' }) $pathPlan 'C:\Windows')
    if ($pathFailed.Count) { throw 'A PATH change that failed must not claim a new terminal will help.' }
    $pathRemoved = @(Get-RunFollowUpLines $pathDone @([PSCustomObject]@{ Id='tools-on-path'; DesiredState='Not on the PATH'; Name='Run tools from anywhere'; RestartRequired=$false }) 'C:\Windows')
    if ($pathRemoved.Count) { throw 'Taking the folder off the PATH must not ask for a new terminal.' }
    # The sign-out line, and both together.
    $signOutPlan = @([PSCustomObject]@{ Id='display-language'; DesiredState='Australian English (en-AU)'; Name='Display language'; RestartRequired=$true })
    $signOutLines = @(Get-RunFollowUpLines @([PSCustomObject]@{ Id='display-language'; Outcome='PartiallyApplied' }) $signOutPlan 'C:\Windows')
    if ($signOutLines.Count -ne 1 -or $signOutLines[0] -notmatch 'sign out and back in') { throw "A change needing a sign-out must say so: $($signOutLines -join ' | ')" }
    if ($signOutLines[0] -match 'click') { throw 'A command line has no button to click.' }
    $bothLines = @(Get-RunFollowUpLines ($pathDone + @([PSCustomObject]@{ Id='display-language'; Outcome='Succeeded' })) ($pathPlan + $signOutPlan) 'C:\Windows')
    if ($bothLines.Count -ne 2) { throw "Two outstanding jobs must produce two lines; got $($bothLines.Count)." }
    # A quiet run says nothing at all.
    $quietLines = @(Get-RunFollowUpLines @([PSCustomObject]@{ Id='hidden-files'; Outcome='Succeeded' }) @([PSCustomObject]@{ Id='hidden-files'; DesiredState='Shown'; Name='Hidden files'; RestartRequired=$false }) 'C:\Windows')
    if ($quietLines.Count) { throw "A run with nothing outstanding must stay quiet: $($quietLines[0])" }
    # The closing sentence has to suit where it is read.
    $windowRestart = Get-RestartInstruction @('Display language')
    if ($windowRestart -notmatch 'Then click Read settings again\.$') { throw "The window wording changed: $windowRestart" }
    $consoleRestart = Get-RestartInstruction @('Display language') 'Then run Dingo again to check.'
    if ($consoleRestart -notmatch 'Then run Dingo again to check\.$') { throw "The command-line wording is wrong: $consoleRestart" }
    if ($consoleRestart -match 'click') { throw "A command line has no button to click: $consoleRestart" }
    if ($consoleRestart -notmatch 'Display language') { throw 'The restart line must name the setting that needs it.' }
    $manyRestart = Get-RestartInstruction @('Display language','Region and formats') 'Then run Dingo again to check.'
    if ($manyRestart -notmatch 'Display language, Region and formats') { throw "Two settings did not both get named: $manyRestart" }
    # A plan holds tools, shortcuts, file types and the PATH as well as Windows
    # settings, so no count may call the whole lot "settings".
    foreach ($countedLine in @($sourceText -split "`n" | Where-Object { $_ -match 'Write-CliStatus' -and $_ -match '\$planCount|\$\(\$selected\.Count\)' })) {
        if ($countedLine -match 'setting\(s\)') { throw "A count calls mixed changes settings: $($countedLine.Trim())" }
    }
    # A step with nothing running must return at once rather than wait for ever.
    Wait-AdministratorChangesOnConsole $null
    Wait-AdministratorChangesOnConsole ([PSCustomObject]@{ Process=$null; ProgressPath='' })
    # Closing File Explorer repaints every console on the desktop, so a command
    # line run must have finished printing before it happens. Otherwise stale
    # lines are redrawn over the results and a good run looks like a bad one.
    $finishedOffset = $sourceText.LastIndexOf('Dingo finished: $succeeded succeeded')
    $restartOffset = $sourceText.LastIndexOf('if ($restartExplorer -and -not $NoRestartExplorer)')
    if ($finishedOffset -lt 0 -or $restartOffset -lt 0) { throw 'The quick-apply ending could not be found in the source.' }
    if ($restartOffset -lt $finishedOffset) { throw 'A command-line run must print its results before File Explorer is restarted.' }
    $pathSetting = $script:Settings | Where-Object Id -eq 'tools-on-path' | Select-Object -First 1
    if (-not $pathSetting) { throw 'The command-line access setting is missing.' }
    if ($pathSetting.Tab -ne 'Tool shortcuts' -or -not $pathSetting.RequiresAdmin -or -not $pathSetting.CanChoose) {
        throw 'Command-line access must be a reversible Tool shortcuts card that requests administrator approval.'
    }
    $settingOrder = @($script:Settings | ForEach-Object { $_.Id })
    if ([array]::IndexOf($settingOrder, 'tools-on-path') -lt [array]::IndexOf($settingOrder, @($toolSettings)[-1].Id)) {
        throw 'Command-line access must be applied after the tools its launchers point at.'
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
    # File types: the cards exist, need no elevation, run after the tools they
    # point at, and never claim a type Windows will not hand over.
    $associationSettings = @($script:Settings | Where-Object Kind -eq 'Association')
    if ($associationSettings.Count -lt 3) { throw "Expected at least three file type cards, found $($associationSettings.Count)." }
    foreach ($associationSetting in $associationSettings) {
        if ($associationSetting.Tab -ne 'File associations') { throw "'$($associationSetting.Id)' must sit on the File associations tab." }
        if ($associationSetting.RequiresAdmin) { throw "'$($associationSetting.Id)' is a per-account choice and must not ask for administrator approval." }
        if (-not $associationSetting.CanChoose) { throw "'$($associationSetting.Id)' must be reversible." }
        $associationIndex = [array]::IndexOf($settingOrder, $associationSetting.Id)
        if ($associationIndex -lt [array]::IndexOf($settingOrder, @($toolSettings)[-1].Id)) {
            throw "'$($associationSetting.Id)' must be applied after the tools it points at."
        }
    }
    $notepadAssociations = @(($builtInTools | Where-Object Id -eq 'tool-notepadplusplus' | Select-Object -First 1).Associations | ForEach-Object { $_.Extension })
    foreach ($ownedExtension in @('.txt', '.log')) {
        if ($notepadAssociations -contains $ownedExtension) {
            throw "$ownedExtension is owned by the Windows Notepad app through a protected user choice; Dingo must not offer to take it."
        }
    }
    if (-not $notepadAssociations.Count -or $notepadAssociations -notcontains '.json') { throw 'Notepad++ should offer to open .json.' }
    # One card can point different file types at different programs. .dat is a
    # registry hive, so it must go to Registry Explorer, not Timeline Explorer.
    $hiveAssociation = @(($builtInTools | Where-Object Id -eq 'tool-eztools' | Select-Object -First 1).Associations |
        Where-Object Extension -eq '.dat')
    if ($hiveAssociation.Count -ne 1) { throw 'Eric Zimmerman''s tools should offer to open .dat.' }
    if ($hiveAssociation[0].Target -notlike '*RegistryExplorer.exe') { throw '.dat must open with Registry Explorer.' }
    $badExtensionRejected = $false
    try {
        [void](ConvertTo-ToolDefinition ([PSCustomObject]@{
            id='tool-badassoc'; name='Bad'; install=[PSCustomObject]@{ kind='winget'; package='a.b' }
            detect=@([PSCustomObject]@{ kind='command'; command='a.exe' })
            associations=@([PSCustomObject]@{ extension='not-an-extension'; target='C:/Windows/notepad.exe' })
        }))
    } catch { $badExtensionRejected = $true }
    if (-not $badExtensionRejected) { throw 'A file association without a leading dot must be refused.' }
    $sampleAssociation = [PSCustomObject]@{ Scope='User'; Extension='.dingotest'; Target='C:\Windows\System32\notepad.exe'; Description='Test' }
    if ((Get-AssociationProgId $sampleAssociation) -ne 'Dingo.notepad') { throw "Handler names must start with $script:AssociationProgIdPrefix and carry the program name." }
    if ((Join-WordList @('.a')) -ne '.a' -or (Join-WordList @('.a','.b')) -ne '.a and .b' -or (Join-WordList @('.a','.b','.c')) -ne '.a, .b and .c') {
        throw 'The extension list is not being written as readable English.'
    }
    # A key holding only an unnamed default value must never be treated as
    # empty. Getting this wrong deleted the handler Dingo had just put back.
    $emptyKeyTest = 'HKCU:\Software\Classes\.dingoselftest'
    try {
        New-Item -Path $emptyKeyTest -Force | Out-Null
        Set-ItemProperty -Path $emptyKeyTest -Name '(default)' -Value 'Somebody.Else'
        Remove-EmptyExtensionKey '.dingoselftest'
        if (-not (Test-Path -LiteralPath $emptyKeyTest)) { throw 'A file type still holding a handler name was deleted.' }
        Remove-ExtensionHandlerName '.dingoselftest'
        if ((Get-ExtensionHandlerName '.dingoselftest')) { throw 'The handler name was not removed.' }
        Remove-EmptyExtensionKey '.dingoselftest'
        if (Test-Path -LiteralPath $emptyKeyTest) { throw 'An empty file type key was left behind.' }
    } finally {
        Remove-Item -LiteralPath $emptyKeyTest -Recurse -Force -ErrorAction SilentlyContinue
    }
    $toggleCount = @($script:Settings | Where-Object { $_.CanChoose -and $_.Kind -ne 'Package' }).Count
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
    $script:WorkerProgressPath = $ProgressPath
    $script:WorkerCancelPath = $CancelPath
    try {
        Write-Log 'INFO' "Administrator worker started as $([Security.Principal.WindowsIdentity]::GetCurrent().Name) for desktop SID $TargetUserSid."
        if (-not (Test-IsAdministrator)) { throw 'The machine worker was not elevated.' }
        if ($script:ToolRootRejected) { throw $script:ToolRootRejectMessage }
        Write-Log 'INFO' "Administrator worker is using the tools folder $($script:ActiveToolRoot)."

        if ($TargetUserSid -notmatch '^S-\d(?:-\d+)+$') { throw 'The desktop user SID supplied to the administrator step is invalid.' }
        $plan = @(ConvertFrom-JsonList (Get-Content -LiteralPath $PlanPath -Raw))
        Write-Log 'INFO' "Administrator worker received $($plan.Count) change(s)."
        Set-WorkerProgressStep 0 @($plan).Count '' '' 'Starting' 'Administrator approval accepted'
        $results = Invoke-AdministratorPlan $plan $script:Settings $ResultPath
        Write-WorkerResults $results $ResultPath
        exit 0
    } catch {
        Write-Log 'ERROR' "Machine worker fatal error: $($_.Exception.ToString())"
        Write-WorkerResults @((New-ApplyResult '*' @((New-OperationComponent 'Administrator worker' 'Failed' $_.Exception.Message)) $_.Exception.Message)) $ResultPath
        exit 1
    }
}

if ($ToolRoot -and $script:ToolRootRejected -and -not ($MachineWorker -or $ElevationBroker -or $WpfHost)) {
    Write-CliErrorResponse $script:ToolRootRejectMessage 2
    exit 2
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
        # Dingo started life as a set of tweaks, and that is what a bare command
        # line still does. Installing software is a bigger act than changing a
        # registry value, so the tool cards are reached only when they are asked
        # for by name or by the 'tools' section word.
        $effectiveInclude = if ($Include) { $Include } else { @('tweaks') }
        $selected = @(New-ApplyPlan @(Resolve-QuickApplySettings $script:Settings $effectiveInclude $Exclude))
        if (-not $selected) { throw 'The include/exclude filters selected no settings.' }
        # A quiet behaviour change is a trap, so a run that used the default says
        # out loud which cards it left alone and how to ask for them.
        $skipped = $null
        if (-not $Include) {
            $skippedIds = @($script:Settings | Where-Object { $_.Section -eq 'Tools' } | ForEach-Object { [string]$_.Id })
            if ($skippedIds.Count) {
                $skipped = [PSCustomObject]@{
                    Section = 'Tools'
                    Count = $skippedIds.Count
                    Ids = $skippedIds
                    Reason = 'No -Include was given, so only the Tweaks section ran.'
                    Hint = 'Use -Include tools for the tool cards, or -Include tweaks,tools for both.'
                }
            }
        }
        $skippedNotice = if ($skipped) { "$($skipped.Count) tool card(s) were left alone. $($skipped.Reason) $($skipped.Hint)" } else { '' }
        # Settled before any state is read, because reading a state produces the
        # caveats, and a caveat has to know what else this run will do.
        $script:PlannedSettingIds = @($selected | ForEach-Object { [string]$_.Id })
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
                    CurrentStatus=$item.CurrentState.Status; CurrentState=$item.CurrentState.DisplayText; State=$item.CurrentState; Target=$item.PreferredState
                    VerificationBasis=(Get-VerificationDescription $item)
                    Advisory=(Get-SettingAdvisory $item)
                }
            })
            $exitCode = if ($blocked) { 2 } else { 0 }
            if ($OutputFormat -eq 'Json') {
                [Console]::Out.WriteLine((ConvertTo-Json -InputObject ([PSCustomObject]@{
                    Version=$script:DingoVersion; Mode='WhatIf'; Success=(-not [bool]$blocked); ExitCode=$exitCode; Changed=$false; Elevated=$elevatedDryRun; Skipped=$skipped; Plan=$plan
                }) -Depth 7))
            } else {
                Write-CliStatus "Dingo dry run: $($selected.Count) change(s) would be made. Nothing was changed."
                if ($skippedNotice) { Write-CliStatus $skippedNotice }
                [Console]::Out.WriteLine(($plan | Format-Table Id,Name,Kind,Scope,RequiresAdmin,Available,CurrentStatus,CurrentState,Target -AutoSize | Out-String -Width 240).TrimEnd())
                foreach ($advised in @($plan | Where-Object Advisory)) { [Console]::Out.WriteLine("[$($advised.Id)] Caveat: $($advised.Advisory)") }
                foreach ($failure in $blocked) { [Console]::Error.WriteLine("[$($failure.Id)] Preflight failed: $($failure.Message)") }
            }
            Write-Log 'INFO' "Quick-apply dry run completed for $($selected.Count) change(s)."
        } else {
            if ($blocked) { throw "Preflight failed: $(@($blocked | ForEach-Object { "[$($_.Id)] $($_.Message)" }) -join '; ')" }
            $planCount = $selected.Count
            Write-CliStatus "Dingo quick apply: applying $planCount change(s)."
            if ($skippedNotice) { Write-CliStatus $skippedNotice }
            Write-Log 'INFO' "Quick apply started for $planCount change(s)."
            if ($skippedNotice) { Write-Log 'INFO' $skippedNotice }
            # A caveat is worth far more before the work starts than in the
            # results afterwards. A dry run has always printed these. A real run
            # did not, so the display language pack, which alone can turn a two
            # minute run into ten, arrived as an unexplained wait.
            foreach ($item in $selected) {
                $advisory = Get-SettingAdvisory $item
                if (-not $advisory) { continue }
                Write-CliStatus "  Note [$($item.Id)]: $advisory"
                Write-Log 'INFO' "Caveat [$($item.Id)]: $advisory"
            }
            $administratorResults = @{}
            $administratorCount = @($selected | Where-Object RequiresAdmin).Count
            if ($administratorCount) {
                # Two counts appear in this output, so say what each one is for.
                # These are the settings Windows must approve; they are applied
                # first, by a second process, and counted out of their own total.
                Write-CliStatus "Step 1 of 2: $administratorCount of the $planCount change(s) need administrator approval."
                $operation = Start-AdministratorChanges $selected
                Wait-AdministratorChangesOnConsole $operation
                $administratorResults = Complete-AdministratorChanges $operation
            }
            # Every selected setting passes through here, approved ones included:
            # this is where each one is finished off and its final state read
            # back. So this count is the whole plan, not the administrator part.
            Write-CliStatus "Step 2 of 2: applying and checking all $planCount change(s)."
            $results = New-Object System.Collections.ArrayList
            $stepNumber = 0
            foreach ($item in $selected) {
                $stepNumber++
                Write-CliStatus "  $stepNumber/$planCount [$($item.Id)] Applying $($item.PreferredState)..."
                $result = Invoke-SettingChange $item $administratorResults
                [void]$results.Add($result)
                Write-CliStatus "  $stepNumber/$planCount [$($item.Id)] $($result.Outcome): $($item.CurrentState.DisplayText)"
            }
            $restartExplorer = @($results | Where-Object Outcome -ne 'Failed' | ForEach-Object {
                $resultId = $_.Id
                $selected | Where-Object { $_.Id -eq $resultId -and $_.RestartExplorer }
            }).Count -gt 0
            $resultRows = @($results | ForEach-Object {
                $item = $selected | Where-Object Id -eq $_.Id | Select-Object -First 1
                [PSCustomObject]@{ Id=$_.Id; Outcome=$_.Outcome; CurrentStatus=$item.CurrentState.Status; CurrentState=$item.CurrentState.DisplayText; State=$item.CurrentState; VerificationBasis=(Get-VerificationDescription $item); Message=$_.Message; Components=$_.Components }
            })
            $succeeded = @($results | Where-Object Outcome -eq 'Succeeded').Count
            $partial = @($results | Where-Object Outcome -eq 'PartiallyApplied').Count
            $failed = @($results | Where-Object Outcome -eq 'Failed').Count
            if ($partial -or $failed) { $exitCode = 1 }
            if ($OutputFormat -eq 'Json') {
                [Console]::Out.WriteLine((ConvertTo-Json -InputObject ([PSCustomObject]@{
                    Version=$script:DingoVersion; Mode='ApplyPreferred'; Success=($exitCode -eq 0); ExitCode=$exitCode; Skipped=$skipped
                    Summary=[PSCustomObject]@{Succeeded=$succeeded;PartiallyApplied=$partial;Failed=$failed}
                    RestartRequired=[bool](@($results | Where-Object RestartRequired).Count); LogPath=$script:LogFile; Results=$resultRows
                }) -Depth 9))
            } else {
                [Console]::Out.WriteLine(($resultRows | Format-Table Id,Outcome,CurrentState,Message -AutoSize | Out-String -Width 220).TrimEnd())
                Write-CliStatus "Dingo finished: $succeeded succeeded; $partial partially applied; $failed failed. Log: $script:LogFile"
            }
            foreach ($line in @(Get-RunFollowUpLines $results $selected)) {
                Write-CliStatus "Next: $line"
                Write-Log 'INFO' "Follow-up: $line"
            }
            # Last of all, because closing File Explorer repaints every console
            # on the desktop. Doing it earlier redraws stale lines over the
            # results table, and the run then looks like it went wrong.
            if ($restartExplorer -and -not $NoRestartExplorer) {
                Write-CliStatus 'Restarting File Explorer to finish. The desktop blinks once.'
                [void](Restart-DesktopExplorer)
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
    <Style x:Key="SelectionToggleStyle" TargetType="{x:Type ToggleButton}">
      <Setter Property="Width" Value="40"/>
      <Setter Property="Height" Value="22"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type ToggleButton}">
            <Grid Background="Transparent">
              <Border x:Name="FocusRing" BorderBrush="#0B6EBD" BorderThickness="2" CornerRadius="13" Margin="-3" Opacity="0"/>
              <Border x:Name="Track" Background="#A9B7C5" BorderBrush="#8FA1B2" BorderThickness="1" CornerRadius="11">
                <Ellipse x:Name="Thumb" Width="16" Height="16" Margin="2" HorizontalAlignment="Left" Fill="White"/>
              </Border>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="#0B6EBD"/>
                <Setter TargetName="Track" Property="BorderBrush" Value="#0B6EBD"/>
                <Setter TargetName="Thumb" Property="HorizontalAlignment" Value="Right"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="FocusRing" Property="Opacity" Value="1"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid Margin="18">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Grid Grid.Row="0" Margin="0,0,0,12">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <StackPanel Grid.Column="0">
        <TextBlock Text="Dingo - Windows 11 Preferences" FontSize="25" FontWeight="SemiBold" Foreground="#17212B"/>
        <TextBlock Name="IntroText" Text="Tweaks changes Windows settings. Tools installs analyst software and wires it up. Options is about Dingo itself. Nothing changes until you click Apply selected changes." Foreground="#52606D" FontSize="14" TextWrapping="Wrap" Margin="0,4,0,0"/>
      </StackPanel>
      <TextBlock Name="VersionText" Grid.Column="1" Text="" Foreground="#52606D" FontSize="13" VerticalAlignment="Top" HorizontalAlignment="Right" Margin="16,6,0,0"/>
    </Grid>
    <TabControl Name="SectionTabs" Grid.Row="2" FontSize="14">
      <TabItem Header="Tweaks">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <WrapPanel Grid.Row="0" Margin="8,10,8,0">
            <Button Name="AllPreferredButton" Content="Choose all my preferred settings" Background="#E5F2FF"/>
            <Button Name="NeededButton" Content="Select only settings that need changing"/>
            <TextBlock Text="These two buttons act on the Tweaks section only." VerticalAlignment="Center" Foreground="#52606D" Margin="12,0,0,0"/>
          </WrapPanel>
        <TabControl Name="TweakTabs" Grid.Row="1" BorderThickness="0" Margin="0,6,0,0" FontSize="14">
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
        </TabControl>
        </Grid>
      </TabItem>
      <TabItem Header="Tools">
        <TabControl Name="ToolTabs" BorderThickness="0" Margin="0,6,0,0" FontSize="14">
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
          <TabItem Header="File associations">
            <Grid>
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
              <Border Background="#E8F6EE" Padding="12" Margin="8">
                <TextBlock Name="AssociationScopeText" Text="Which program opens which file type. These are your account's choices, so no administrator approval is needed." TextWrapping="Wrap"/>
              </Border>
              <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                <StackPanel Name="AssociationSettingsPanel" Margin="8,0,8,8"/>
              </ScrollViewer>
            </Grid>
          </TabItem>
        </TabControl>
      </TabItem>
      <TabItem Header="Options">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <Border Background="#EEF1F4" Padding="12" Margin="8">
            <TextBlock Text="How Dingo behaves when it runs. These are not Windows settings, and nothing here is changed on your computer." TextWrapping="Wrap"/>
          </Border>
          <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel Margin="20,8,20,8">
            <TextBlock Text="When applying changes" FontWeight="SemiBold" Foreground="#17212B" Margin="0,8,0,6"/>
            <CheckBox Name="RestartExplorerCheckBox" Content="Restart File Explorer when finished" IsChecked="True"/>
            <TextBlock Text="Some File Explorer and taskbar changes only appear after Explorer restarts. Dingo restarts it only when a change it applied needs it." TextWrapping="Wrap" Foreground="#52606D" Margin="24,4,0,0"/>
            <TextBlock Text="Where tools are installed" FontWeight="SemiBold" Foreground="#17212B" Margin="0,20,0,6"/>
            <TextBlock Text="Some tools have no installer of their own, so Dingo puts those in this folder. A tool that carries its own installer is not affected. Changing this does not move a tool that is already installed, and does not remove the old folder." TextWrapping="Wrap" Foreground="#52606D" Margin="0,0,0,8"/>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBox Name="ToolRootTextBox" Grid.Column="0" VerticalAlignment="Center" Padding="6,5" FontFamily="Consolas"/>
              <Button Name="ToolRootBrowseButton" Grid.Column="1" Content="Browse" Margin="8,0,0,0"/>
            </Grid>
            <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
              <Button Name="ToolRootSaveButton" Content="Save tools folder"/>
              <Button Name="ToolRootDefaultButton" Content="Use the default folder"/>
            </StackPanel>
            <TextBlock Name="ToolRootStatusText" Text="" TextWrapping="Wrap" Foreground="#52606D" Margin="0,8,0,0"/>
            <TextBlock Text="Logs" FontWeight="SemiBold" Foreground="#17212B" Margin="0,20,0,6"/>
            <TextBlock Text="Dingo writes what it read and what it changed to a log file for this run." TextWrapping="Wrap" Foreground="#52606D" Margin="0,0,0,6"/>
            <TextBlock Name="LogPathText" Text="" TextWrapping="Wrap" Foreground="#52606D" FontFamily="Consolas" Margin="0,0,0,8"/>
            <Button Name="OpenLogButton" Content="Open log folder" HorizontalAlignment="Left" Margin="0"/>
          </StackPanel>
          </ScrollViewer>
        </Grid>
      </TabItem>
    </TabControl>
    <ProgressBar Name="ProgressBar" Grid.Row="3" Height="8" Margin="0,10,0,8" Minimum="0" Maximum="100"/>
    <Grid Grid.Row="4">
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
      <TextBlock Name="SummaryText" Grid.Row="0" Text="Reading current settings..." VerticalAlignment="Center" Foreground="#334E68" TextWrapping="Wrap" Margin="0,0,0,6"/>
      <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Right">
        <TextBlock Name="AdminSummaryText" Visibility="Collapsed" VerticalAlignment="Center" Foreground="#8A4B08" FontWeight="SemiBold" TextWrapping="Wrap" MaxWidth="250" Margin="0,0,14,0"/>
        <Button Name="StopButton" Content="Stop" Visibility="Collapsed" Background="#FCE9E7" Foreground="#8A2B21" FontWeight="SemiBold"/>
        <Button Name="RefreshButton" Content="Read settings again"/>
        <Button Name="UncheckButton" Content="Clear all selections"/>
        <Button Name="ApplyButton" Content="Apply selected changes" Background="#0B6EBD" Foreground="White" FontWeight="SemiBold"/>
      </StackPanel>
    </Grid>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$script:DingoWindow = $window
foreach ($name in @('IntroText','VersionText','SectionTabs','TweakTabs','ToolTabs','UserScopeText','BothScopeText','ToolsScopeText','ShortcutsScopeText','AssociationScopeText','UserSettingsPanel','SystemSettingsPanel','BothSettingsPanel','ToolSettingsPanel','ShortcutSettingsPanel','AssociationSettingsPanel','AllPreferredButton','NeededButton','UncheckButton','RefreshButton','RestartExplorerCheckBox','StopButton','ProgressBar','SummaryText','AdminSummaryText','LogPathText','OpenLogButton','ToolRootTextBox','ToolRootBrowseButton','ToolRootSaveButton','ToolRootDefaultButton','ToolRootStatusText','ApplyButton')) {
    Set-Variable -Name $name -Value $window.FindName($name) -Scope Script
}
$desktopIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$UserScopeText.Text = "These settings affect only $desktopIdentity. A gold 'Admin approval required' label identifies a protected per-account policy that needs elevation."
$BothScopeText.Text = "These choices affect $desktopIdentity and the whole computer. Administrator approval is used only for the computer-wide part."
$ToolsScopeText.Text = "Installed leaves an existing tool unchanged and installs it only if missing. Choose Update installed tool explicitly to update it. Dingo never removes a tool. Add more tools with Tools.json beside Dingo.ps1. Shortcuts and command-line access are on the next tab."
if ($script:ToolCatalogWarning) {
    $ToolsScopeText.Text = "$($script:ToolCatalogWarning) The built-in tool list is being used instead."
    $ToolsScopeText.Foreground = '#8A2B21'
}
$VersionText.Text = "Version $($script:DingoVersion)"
$LogPathText.Text = [string]$script:LogFile
$ToolRootTextBox.Text = $script:ActiveToolRoot
# The tools folder is changed here too, so it is locked while a plan runs.
$script:ActionButtons = @($ApplyButton,$AllPreferredButton,$NeededButton,$UncheckButton,$RefreshButton,
    $ToolRootTextBox,$ToolRootBrowseButton,$ToolRootSaveButton,$ToolRootDefaultButton)

function Set-ToolRootStatus([string]$Text, [bool]$IsProblem) {
    $ToolRootStatusText.Text = $Text
    $ToolRootStatusText.Foreground = if ($IsProblem) { '#8A2B21' } else { '#52606D' }
}

function Show-ToolRootInUse([string]$Prefix) {
    $text = "Tools without their own installer go in $($script:ActiveToolRoot). Command-line launchers go in $($script:ShimDirectory)."
    Set-ToolRootStatus (("$Prefix $text").Trim()) $false
}

function Save-ToolRootChoice([string]$Wanted) {
    $reason = Test-ToolRootIsUsable $Wanted
    if ($reason) { Set-ToolRootStatus $reason $true; return }
    try {
        $resolved = Save-DingoToolRootPreference $Wanted
        [void](Set-DingoToolRoot $resolved)
        $ToolRootTextBox.Text = $resolved
    } catch {
        Set-ToolRootStatus "The tools folder was not changed. $($_.Exception.Message)" $true
        return
    }
    # A tool card reports what is on disk, so the cards are read again with the
    # new folder. Nothing on disk is moved or removed.
    Show-ToolRootInUse 'Saved.'
    $saved = $ToolRootStatusText.Text
    Update-CurrentStates
    Set-ToolRootStatus $saved $false
}

# Say straight away where tools go, or why the saved folder was not used.
if ($script:ToolRootWarning) { Set-ToolRootStatus $script:ToolRootWarning $true } else { Show-ToolRootInUse '' }


function Show-StopButton([bool]$Visible) {
    $StopButton.Visibility = if ($Visible) { 'Visible' } else { 'Collapsed' }
    $StopButton.IsEnabled = $Visible
    $StopButton.Content = 'Stop'
}

function Set-ActionButtonsEnabled([bool]$Enabled) {
    # Everything that starts work or changes a choice is locked while a plan
    # runs. The sections themselves are not: disabling the tab control froze
    # scrolling and tab switching too, so a card finishing on another tab could
    # not be seen. Reading is allowed, changing is not.
    foreach ($control in $script:ActionButtons) { $control.IsEnabled = $Enabled }
    $RestartExplorerCheckBox.IsEnabled = $Enabled
    foreach ($item in $script:Settings) {
        if ($item.PSObject.Properties['ApplyControl']) { $item.ApplyControl.IsEnabled = $Enabled }
        if ($item.PSObject.Properties['ChoiceControls']) {
            foreach ($choice in $item.ChoiceControls) { $choice.IsEnabled = $Enabled }
        }
    }
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

function Request-AdministratorStop($Pending) {
    # Two ways to stop, because only one of them is available at a time. Before
    # the Windows approval prompt is answered there is no elevated process yet,
    # so the broker can simply be closed. Afterwards the worker runs elevated
    # and this window cannot kill it, so it is asked to stop instead.
    if (-not $Pending) { return $false }
    $asked = $false
    if ($Pending.CancelPath) {
        try {
            Write-Utf8FileAtomically $Pending.CancelPath 'stop'
            $asked = $true
        } catch {
            Write-Log 'WARN' "Could not write the stop request: $($_.Exception.Message)"
        }
    }
    $started = $Pending.PSObject.Properties['LastProgress'] -and $Pending.LastProgress
    if (-not $started -and $Pending.Process -and -not $Pending.Process.HasExited) {
        # Nothing has been applied yet, so closing the broker cancels the whole
        # thing cleanly, prompt and all.
        try { $Pending.Process.Kill() } catch { Write-Log 'WARN' "Could not close the elevation broker: $($_.Exception.Message)" }
        $asked = $true
    }
    Write-Log 'WARN' 'The user asked Dingo to stop the administrator step.'
    return $asked
}

function Update-AdministratorProgress($Pending) {
    $totalElapsed = Format-Duration ((Get-Date) - $Pending.Started)
    $progress = Read-WorkerProgressFile $Pending.ProgressPath
    if ($progress) {
        $Pending | Add-Member -NotePropertyName LastProgress -NotePropertyValue $progress -Force
    } elseif ($Pending.PSObject.Properties['LastProgress']) {
        # The worker replaces this file about twice a second, so a read can land
        # mid-write. Keep showing the last good reading rather than pretending
        # the worker has not started.
        $progress = $Pending.LastProgress
    }
    if (-not $progress) {
        # Nothing has ever been published, which almost always means the Windows
        # approval prompt is still on screen.
        $ProgressBar.IsIndeterminate = $true
        $SummaryText.Text = "Waiting for administrator approval ($totalElapsed). Accept the Windows prompt to let Dingo continue."
        return
    }
    $finished = @(Read-WorkerFinishedIds $Pending.ResultPath)
    $total = [int]$progress.Total
    $index = [int]$progress.Index
    $name = [string]$progress.Name
    $phase = [string]$progress.Phase
    $detail = [string]$progress.Detail
    # Each card says where it stands, so a long step never looks like a hang.
    foreach ($planned in @($Pending.Selected | Where-Object RequiresAdmin)) {
        $card = $script:Settings | Where-Object Id -eq $planned.Id | Select-Object -First 1
        if (-not $card -or -not $card.PSObject.Properties['DetailsControl']) { continue }
        $text = if ($finished -contains [string]$planned.Id) {
            'Administrator part finished; waiting to verify.'
        } elseif ([string]$progress.Id -eq [string]$planned.Id) {
            if ($detail) { $detail } else { 'Working...' }
        } else {
            'Waiting for the administrator step...'
        }
        $card.Details = $text
        $card.DetailsControl.Text = $text
    }
    if ($total -gt 0 -and $finished.Count -le $total) {
        $ProgressBar.IsIndeterminate = $false
        $ProgressBar.Value = [math]::Round(($finished.Count / $total) * 100)
    }
    $stepElapsed = ''
    try {
        if ($progress.StepStarted) { $stepElapsed = Format-Duration ((Get-Date) - [datetime]::Parse([string]$progress.StepStarted)) }
    } catch { $stepElapsed = '' }
    $heading = if ($index -ge 1 -and $total -ge 1 -and $name) {
        "Administrator step $index of ${total}: $name"
    } else {
        'Administrator step starting'
    }
    $body = if ($detail) { ' - ' + $detail.TrimEnd('.',' ') + '.' } else { '.' }
    $clock = if ($stepElapsed) { " $stepElapsed on this step, $totalElapsed in total." } else { " $totalElapsed elapsed." }
    $done = if ($total -ge 1) { " $($finished.Count) of $total finished." } else { '' }
    $hint = if ($phase -eq 'Downloading') { ' A language pack comes from Windows Update, so this step is the slow one.' } else { '' }
    $SummaryText.Text = "$heading$body$clock$done$hint"
}

function Update-SelectionSummary {
    $selected = @($script:Settings | Where-Object Selected)
    $selectedAdmin = @($selected | Where-Object RequiresAdmin)
    $ApplyButton.Content = if ($selected.Count) {
        "Apply $($selected.Count) selected change$(if ($selected.Count -eq 1) { '' } else { 's' })"
    } else {
        'Apply selected changes'
    }
    if ($selectedAdmin.Count) {
        $AdminSummaryText.Text = "$($selectedAdmin.Count) selected setting$(if ($selectedAdmin.Count -eq 1) { '' } else { 's' }) require$(if ($selectedAdmin.Count -eq 1) { 's' }) administrator approval"
        $AdminSummaryText.Visibility = 'Visible'
    } else {
        $AdminSummaryText.Text = ''
        $AdminSummaryText.Visibility = 'Collapsed'
    }
}

function Update-CardAdvisory($Item) {
    # The caveat depends on the choice, so it is recomputed rather than frozen
    # at the moment the card was drawn.
    if (-not $Item.PSObject.Properties['AdvisoryControl'] -or -not $Item.AdvisoryControl) { return }
    $note = Get-SettingAdvisory $Item
    $Item.AdvisoryControl.Text = if ($note) { "Note: $note" } else { '' }
    $Item.AdvisoryControl.Parent.Visibility = if ($note) { 'Visible' } else { 'Collapsed' }
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
    foreach ($width in @(58,315,220,300,200)) {
        $column = New-Object Windows.Controls.ColumnDefinition
        $column.Width = $width
        [void]$grid.ColumnDefinitions.Add($column)
    }

    $applyCheck = New-Object Windows.Controls.Primitives.ToggleButton
    $applyCheck.Style = $window.FindResource('SelectionToggleStyle')
    $applyCheck.IsChecked = $Item.Selected
    $applyCheck.VerticalAlignment = 'Top'
    $applyCheck.Margin = '5,7,0,0'
    $applyCheck.ToolTip = 'Include this setting in the next apply.'
    [System.Windows.Automation.AutomationProperties]::SetName($applyCheck, "Select $($Item.Name) for changes")
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
    # Built whether or not there is a caveat right now, and hidden when there is
    # none. A note that only exists when the card is first drawn could never
    # appear later, and a card with a list of choices can earn one at any time.
    $advisoryBorder = New-Object Windows.Controls.Border
    $advisoryBorder.Background = '#FFF1F0'
    $advisoryBorder.BorderBrush = '#F3B3AE'
    $advisoryBorder.BorderThickness = '1'
    $advisoryBorder.CornerRadius = '4'
    $advisoryBorder.Padding = '8,5'
    $advisoryBorder.Margin = '0,7,8,0'
    $advisoryText = New-CardText '' 11 'SemiBold' '#8A2B21'
    $advisoryText.Margin = '0'
    $advisoryBorder.Child = $advisoryText
    [void]$about.Children.Add($advisoryBorder)
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
    if ($Item.StateOptions.Count -gt (Get-MaxRadioChoices)) {
        # A long list of radio buttons would not fit the card, so offer a
        # drop-down list instead. The preferred choice still leads the list.
        $combo = New-Object Windows.Controls.ComboBox
        $combo.Margin = '0,2,8,0'
        $combo.MaxWidth = 260
        $combo.HorizontalAlignment = 'Left'
        [Windows.Automation.AutomationProperties]::SetName($combo, "Choose what you want for $($Item.Name)")
        foreach ($option in $Item.StateOptions) {
            [void]$combo.Items.Add([string]$option)
        }
        $combo.SelectedItem = [string]$Item.DesiredState
        $combo.Tag = [PSCustomObject]@{ Setting=$Item; Value=$null; ApplyCheck=$applyCheck }
        $combo.Add_SelectionChanged({
            param($sender,$eventArgs)
            if ($null -eq $sender.SelectedItem) { return }
            $sender.Tag.Setting.DesiredState = [string]$sender.SelectedItem
            $sender.Tag.Setting.Selected = $true
            $sender.Tag.ApplyCheck.IsChecked = $true
            # Shown the moment the choice is made, not only at the next refresh.
            Update-CardAdvisory $sender.Tag.Setting
        })
        [void]$choices.Children.Add($combo)
        [void]$choices.Children.Add((New-CardText "Dingo prefers $($Item.PreferredState)." 11 'Normal' '#627D98'))
        [void]$choiceControls.Add($combo)
    } else {
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
                Update-CardAdvisory $sender.Tag.Setting
            })
            [void]$choices.Children.Add($radio)
            [void]$choiceControls.Add($radio)
        }
    }
    if (-not $Item.CanChoose) {
        [void]$choices.Children.Add((New-CardText 'This item has one recommended target. Turn off its selection switch if you want to leave it alone.' 11 'Normal' '#627D98'))
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
    $Item | Add-Member -NotePropertyName AdvisoryControl -NotePropertyValue $advisoryText -Force
    Update-CardAdvisory $Item
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
        'File associations' { [void]$AssociationSettingsPanel.Children.Add($card) }
        default { throw "Setting '$($item.Id)' asks for unknown tab '$($item.Tab)'." }
    }
}

if ($UiSelfTest) {
    if ($script:ActionButtons | Where-Object IsEnabled) { throw 'Action buttons must remain disabled until the initial state scan finishes.' }
    foreach ($item in $script:Settings) {
        if ($item.ApplyControl -isnot [Windows.Controls.Primitives.ToggleButton] -or $null -ne $item.ApplyControl.Content) {
            throw "Setting '$($item.Id)' does not use the unlabelled selection switch."
        }
        if ([Windows.Automation.AutomationProperties]::GetName($item.ApplyControl) -ne "Select $($item.Name) for changes") {
            throw "Setting '$($item.Id)' selection switch has no accessible name."
        }
    }
    $adminSettings = @($script:Settings | Where-Object RequiresAdmin)
    if ($adminSettings | Where-Object { -not $_.AdminBadgeControl }) { throw 'Every setting that requires administrator approval must show an admin badge.' }
    if (-not $AdminSummaryText) { throw 'The selected administrator-change summary is unavailable.' }
    # Tweaks and Tools are separate jobs, and Options is about Dingo itself.
    if ($SectionTabs.Items.Count -ne 3) { throw "Expected the Tweaks, Tools, and Options sections, found $($SectionTabs.Items.Count) section(s)." }
    foreach ($sectionName in @('Tweaks','Tools','Options')) {
        $sectionTab = @($SectionTabs.Items | Where-Object { $_.Header -eq $sectionName })
        if ($sectionTab.Count -ne 1) { throw "The '$sectionName' section is missing from the window." }
    }
    # Every tab must hold cards, so a renamed tab cannot leave an empty one.
    $innerTabCount = $TweakTabs.Items.Count + $ToolTabs.Items.Count
    if ($innerTabCount -ne @($script:Settings | Group-Object Tab).Count) {
        throw "Every tab must hold cards: $innerTabCount tabs for $(@($script:Settings | Group-Object Tab).Count) groups of cards."
    }
    # A card that offers a list must still lead with the choice Dingo prefers.
    foreach ($listCard in @($script:Settings | Where-Object { $_.StateOptions.Count -gt (Get-MaxRadioChoices) })) {
        if ($listCard.StateOptions[0] -ne $listCard.PreferredState) { throw "Setting '$($listCard.Id)' does not lead its list with its preferred choice." }
        if ($listCard.ChoiceControls.Count -ne 1 -or $listCard.ChoiceControls[0] -isnot [Windows.Controls.ComboBox]) {
            throw "Setting '$($listCard.Id)' offers a long list but does not use a drop-down list."
        }
    }
    # A card must never land in the wrong half of the window.
    if ($TweakTabs.Items.Count -ne @($script:Settings | Where-Object { $_.Section -eq 'Tweaks' } | Group-Object Tab).Count) {
        throw 'The Tweaks section does not hold exactly the tweak tabs.'
    }
    if ($ToolTabs.Items.Count -ne @($script:Settings | Where-Object { $_.Section -eq 'Tools' } | Group-Object Tab).Count) {
        throw 'The Tools section does not hold exactly the tool tabs.'
    }
    if (-not $RestartExplorerCheckBox) { throw 'The Options section does not hold the File Explorer restart choice.' }
    if (-not $OpenLogButton) { throw 'The Options section does not hold the log folder button.' }
    if (-not $ToolRootTextBox -or -not $ToolRootSaveButton -or -not $ToolRootDefaultButton -or -not $ToolRootBrowseButton) {
        throw 'The Options section does not hold the tools folder controls.'
    }
    if ($ToolRootTextBox.Text -ne $script:ActiveToolRoot) { throw 'The Options section does not show the tools folder in use.' }
    if (-not $ToolRootStatusText.Text) { throw 'The Options section does not say where tools are installed.' }
    if (-not $LogPathText.Text) { throw 'The Options section does not name the log file.' }
    # A window showing a stale version is worse than one showing none at all.
    if ($VersionText.Text -notmatch [regex]::Escape($script:DingoVersion)) {
        throw "The window shows '$($VersionText.Text)' but Dingo reports version $($script:DingoVersion)."
    }
    foreach ($sectionName in @('Tweaks','Tools','Options')) {
        if ($IntroText.Text -notmatch $sectionName) { throw "The window's opening sentence does not mention the '$sectionName' section." }
    }
    "UI self-test passed: $($script:Settings.Count) setting cards across $innerTabCount tabs, plus an Options section."
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
        # The note follows the drop-down: pick a language whose pack is already
        # here and the download warning goes away by itself.
        Update-CardAdvisory $item
        foreach ($choice in $item.ChoiceControls) {
            if ($choice -is [Windows.Controls.ComboBox]) {
                if ([string]$choice.SelectedItem -ne $item.DesiredState) { $choice.SelectedItem = [string]$item.DesiredState }
            } else {
                $choice.IsChecked = ($choice.Tag.Value -eq $item.DesiredState)
            }
        }
    }
    Update-SelectionSummary
    $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Background)
}

function Update-CurrentStates {
    Clear-DisplayPackCache
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
        # One number across both halves hides more than it tells: a tweak that
        # matches a preference and a tool that is installed are different facts.
        $sectionParts = New-Object System.Collections.ArrayList
        foreach ($sectionName in @('Tweaks','Tools')) {
            $sectionItems = @($script:Settings | Where-Object { $_.Section -eq $sectionName })
            if (-not $sectionItems.Count) { continue }
            $sectionReady = @($sectionItems | Where-Object { $_.CurrentState.Status -eq 'Preferred' }).Count
            $wording = if ($sectionName -eq 'Tools') { 'already in place' } else { 'already match your preference' }
            [void]$sectionParts.Add("$($sectionName): $sectionReady of $($sectionItems.Count) $wording")
        }
        $SummaryText.Text = "$($sectionParts -join '. '). Nothing changes until you click Apply selected changes."
        Set-SummaryEmphasis $SummaryText $false
        if ($unreadable) { $SummaryText.Text += " $unreadable setting$(if ($unreadable -eq 1) { '' } else { 's' }) could not be evaluated and will not be auto-selected." }
        Write-Log 'INFO' "State refresh complete: $preferred of $count preferred ($($sectionParts -join '; '))."
    } finally {
        $ProgressBar.Value = 0
        Set-ActionButtonsEnabled $true
    }
}

function Complete-ApplyChanges([array]$Selected, [hashtable]$AdministratorResults) {
    try {
        $success = 0; $partial = 0; $failed = 0; $needsExplorer = $false; $needsRestart = $false
        $restartNames = New-Object System.Collections.ArrayList
        $partialRestartNames = New-Object System.Collections.ArrayList
        $applyResults = New-Object System.Collections.ArrayList
        $ProgressBar.IsIndeterminate = $false
        for ($i = 0; $i -lt $Selected.Count; $i++) {
            $item = $Selected[$i]
            $item.Status = 'Running'; $item.Details = 'Changing this setting...'
            Publish-PlanState $item
            $SummaryText.Text = "Changing $($i + 1) of $($Selected.Count): $($item.Name)"
            Refresh-UI
            $result = Invoke-SettingChange $item $AdministratorResults
            Publish-PlanState $item
            [void]$applyResults.Add($result)
            if ($result.Outcome -eq 'Succeeded') {
                $success++
                if ($item.RestartExplorer) { $needsExplorer = $true }
                if ($item.RestartRequired) {
                    $needsRestart = $true
                    if (-not $restartNames.Contains([string]$item.Name)) { [void]$restartNames.Add([string]$item.Name) }
                }
            } else {
                if ($result.Outcome -eq 'PartiallyApplied') {
                    $partial++
                    if ($item.RestartRequired -and -not $partialRestartNames.Contains([string]$item.Name)) {
                        [void]$partialRestartNames.Add([string]$item.Name)
                    }
                } else {
                    $failed++
                }
                if (@($result.Components | Where-Object Outcome -eq 'Succeeded').Count) {
                    if ($item.RestartExplorer) { $needsExplorer = $true }
                    if ($item.RestartRequired) {
                        $needsRestart = $true
                        if (-not $restartNames.Contains([string]$item.Name)) { [void]$restartNames.Add([string]$item.Name) }
                    }
                }
            }
            $ProgressBar.Value = [math]::Round((($i + 1) / $Selected.Count) * 100)
            Refresh-UI
        }

        if ($needsExplorer -and $script:ApplyRestartExplorer) {
            [void](Restart-DesktopExplorer)
        }
        $guidanceNames = if ($partialRestartNames.Count) { @($partialRestartNames) } else { @($restartNames) }
        $restartMessage = if ($needsRestart) { Get-RestartInstruction -SettingNames $guidanceNames } else { '' }
        $suffix = if ($restartMessage) { ' ' + $restartMessage } else { '' }
        $SummaryText.Text = "Finished: $success worked; $partial partially applied; $failed failed.$suffix"
        Set-SummaryEmphasis $SummaryText ([bool]$restartMessage)
        $ProgressBar.Value = 100
        Refresh-UI
        if ($restartMessage) { [void](Show-RestartNotice $restartMessage) }
        return ,@($applyResults)
    } finally {
        $script:ApplyInProgress = $false
        Set-ActionButtonsEnabled $true
    }
}

# These two buttons live in the Tweaks half of the window, so they reach only
# the tweak cards. A tool card is an install, not a preference, and it is never
# selected on the strength of a button the person clicked somewhere else. Tool
# selections already made are left exactly as they are.
function Get-TweakSettings {
    @($script:Settings | Where-Object { $_.Section -eq 'Tweaks' })
}
$AllPreferredButton.Add_Click({
    foreach ($item in (Get-TweakSettings)) { $item.DesiredState = $item.PreferredState; $item.Selected = $true }
    Refresh-UI
    $SummaryText.Text = 'Every Tweaks setting is selected and set to the choice marked "my preference". Tool selections were left as they are. Click Apply selected changes when ready.'
})
$NeededButton.Add_Click({
    $tweaks = Get-TweakSettings
    foreach ($item in $tweaks) {
        $item.DesiredState = $item.PreferredState
        $item.Selected = ($item.CurrentState.Status -in @('Alternate','Partial'))
    }
    Refresh-UI
    $unknown = @($tweaks | Where-Object { $_.CurrentState.Status -in @('Error','Unavailable','Unknown') }).Count
    $SummaryText.Text = 'Only Tweaks settings known not to match your preference are selected. Tool selections were left as they are.'
    if ($unknown) { $SummaryText.Text += " $unknown unreadable or unavailable setting$(if ($unknown -eq 1) { ' was' } else { 's were' }) left unselected." }
})
$UncheckButton.Add_Click({
    foreach ($item in $script:Settings) { $item.Selected = $false }
    Refresh-UI
    $SummaryText.Text = 'All selections are cleared. No setting will be changed.'
})
$RefreshButton.Add_Click({ Update-CurrentStates })
$OpenLogButton.Add_Click({ Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $script:LogFile) })
$ToolRootSaveButton.Add_Click({ Save-ToolRootChoice ([string]$ToolRootTextBox.Text) })
$ToolRootDefaultButton.Add_Click({ Save-ToolRootChoice $script:DefaultToolRoot })
$ToolRootBrowseButton.Add_Click({
    # The folder picker lives in Windows Forms, which the window does not need
    # otherwise, so it is loaded only when the button is used. Typing the path
    # still works if loading fails.
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Choose the folder for tools that have no installer of their own.'
        $dialog.ShowNewFolderButton = $true
        if (Test-Path -LiteralPath $ToolRootTextBox.Text -PathType Container) { $dialog.SelectedPath = $ToolRootTextBox.Text }
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $ToolRootTextBox.Text = $dialog.SelectedPath
            $reason = Test-ToolRootIsUsable $dialog.SelectedPath
            if ($reason) { Set-ToolRootStatus $reason $true }
            else { Set-ToolRootStatus 'Click Save tools folder to use this folder.' $false }
        }
        $dialog.Dispose()
    } catch {
        Set-ToolRootStatus "The folder picker could not open, so type the full path instead. $($_.Exception.Message)" $true
    }
})

$ApplyButton.Add_Click({
    if ($script:ApplyInProgress) { return }
    $selected = @(New-ApplyPlan @($script:Settings | Where-Object Selected))
    if (-not $selected) {
        [System.Windows.MessageBox]::Show('Nothing is selected. Turn on the switches for the settings you want Dingo to change.', 'Nothing selected') | Out-Null
        return
    }
    Set-ActionButtonsEnabled $false
    $script:ApplyInProgress = $true
    $script:ApplyRestartExplorer = [bool]$RestartExplorerCheckBox.IsChecked
    try {
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
            $script:ApplyInProgress = $false
            Set-ActionButtonsEnabled $true
            return
        }
        Set-ActionButtonsEnabled $false
        Write-Log 'INFO' "Applying $($selected.Count) change(s) as desktop user $([Security.Principal.WindowsIdentity]::GetCurrent().Name)."
        $adminItems = @($selected | Where-Object RequiresAdmin)
        if (-not $adminItems) {
            Complete-ApplyChanges $selected @{}
            return
        }
        foreach ($item in $adminItems) {
            $item.Status = 'Running'; $item.Details = 'Waiting for the administrator step...'
            Publish-PlanState $item
        }
        $SummaryText.Text = 'Waiting for administrator approval. Accept the Windows prompt to let Dingo continue.'
        $ProgressBar.IsIndeterminate = $true
        Show-StopButton $true
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
                Update-AdministratorProgress $pending
                return
            }
            $sender.Stop()
            Show-StopButton $false
            $administratorResults = Complete-AdministratorChanges $pending
            $selectedItems = $pending.Selected
            $script:PendingApply = $null
            Complete-ApplyChanges $selectedItems $administratorResults
        })
        $pollTimer.Start()
    } catch {
        $script:ApplyInProgress = $false
        Set-ActionButtonsEnabled $true
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Dingo could not complete the plan', 'OK', 'Error') | Out-Null
    }
})

$StopButton.Add_Click({
    $pending = $script:PendingApply
    if (-not $pending) { return }
    $answer = [System.Windows.MessageBox]::Show(
        "Stop the administrator step?" + [Environment]::NewLine + [Environment]::NewLine +
        "Changes already applied stay applied. Dingo finishes the setting it is on, skips the rest, and then shows you the results." + [Environment]::NewLine + [Environment]::NewLine +
        "A Windows language download cannot be called back, so Windows may finish it on its own.",
        'Stop Dingo', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    $StopButton.IsEnabled = $false
    $StopButton.Content = 'Stopping...'
    if (Request-AdministratorStop $pending) {
        $SummaryText.Text = 'Stopping. Dingo is finishing the setting it is on, then it will show you the results.'
    } else {
        $SummaryText.Text = 'Dingo could not pass on the stop request. It will show the results as soon as the administrator step ends.'
    }
})

$window.Add_ContentRendered({ Update-CurrentStates })
$window.Add_Closing({
    param($sender,$eventArgs)
    if (-not $script:ApplyInProgress) { return }
    $eventArgs.Cancel = $true
    $running = $script:PendingApply -and $script:PendingApply.Process -and -not $script:PendingApply.Process.HasExited
    if (-not $running) {
        [System.Windows.MessageBox]::Show(
            'Dingo is collecting and verifying the administrator results. Please wait for the finished summary before closing the window.',
            'Dingo is still working', 'OK', 'Information') | Out-Null
        return
    }
    # Closing is a request to stop, so offer the stop rather than only refusing.
    $answer = [System.Windows.MessageBox]::Show(
        "An administrator step is still running, so Dingo cannot close yet." + [Environment]::NewLine + [Environment]::NewLine +
        "Stop it now? Changes already applied stay applied. Dingo finishes the setting it is on, shows you the results, and then you can close it." + [Environment]::NewLine + [Environment]::NewLine +
        "Choose No to keep waiting.",
        'Dingo is still working', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    $StopButton.IsEnabled = $false
    $StopButton.Content = 'Stopping...'
    if (Request-AdministratorStop $script:PendingApply) {
        $SummaryText.Text = 'Stopping. Dingo is finishing the setting it is on, then it will show you the results.'
    }
})
$window.Add_Closed({ Write-Log 'INFO' 'Application closed.' })
[void]$window.ShowDialog()
