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
$script:DingoVersion = '0.5.0'
$automaticArguments = @(Get-Variable -Name args -ValueOnly -ErrorAction SilentlyContinue)
$script:UnexpectedArguments = @(@($UnexpectedArguments) + $automaticArguments | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) })

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
        exit 3
    }
    try {
        $hostArguments = '-NoProfile -ExecutionPolicy Bypass -STA -File "{0}" -WpfHost' -f $PSCommandPath
        $hostProcess = Start-Process -FilePath (Get-PowerShellHostPath) -ArgumentList $hostArguments -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop
        exit $hostProcess.ExitCode
    } finally {
        Exit-DingoSingleInstance
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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
        [hashtable]$Requirements = @{}
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
    $defaultState = if ([string]::IsNullOrWhiteSpace($AlternateState)) { 'Whatever the Windows image currently uses' } else { $AlternateState }
    [PSCustomObject]@{
        Selected=$false; Id=$Id; Category=$Category; Name=$Name; Description=$Description
        PreferredState=$PreferredState; AlternateState=$AlternateState; DesiredState=$PreferredState
        DefaultState=$defaultState; DisplayScope=$displayScope
        StateOptions=$options; CanChoose=($options.Count -gt 1); CurrentState=(New-StateResult 'Unknown' 'Reading...')
        Status='Ready'; Details=''; LastApplyResult=$null; Kind=$Kind; Entries=$Entries; RequiresAdmin=$needsElevation
        RestartExplorer=$RestartExplorer; RestartRequired=$RestartRequired; Requirements=$requirementCopy
    }
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
    [void]$settings.Add((New-Setting 'edge-duckduckgo' 'Microsoft Edge' 'Default search provider' 'Set DuckDuckGo or remove the managed search-provider policy.' 'DuckDuckGo' 'Browser default/unmanaged' 'Registry' @(
        (New-Entry Machine $edge 'DefaultSearchProviderEnabled' 1 $script:RemoveValue),
        (New-Entry Machine $edge 'DefaultSearchProviderName' 'DuckDuckGo' $script:RemoveValue String),
        (New-Entry Machine $edge 'DefaultSearchProviderKeyword' 'duckduckgo.com' $script:RemoveValue String),
        (New-Entry Machine $edge 'DefaultSearchProviderSearchURL' 'https://duckduckgo.com/?q={searchTerms}' $script:RemoveValue String),
        (New-Entry Machine $edge 'DefaultSearchProviderSuggestURL' 'https://duckduckgo.com/ac/?q={searchTerms}&type=list' $script:RemoveValue String)
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

function Read-TerminalJson([string]$Path) {
    $raw = Get-Content -LiteralPath $Path -Raw
    try { return ($raw | ConvertFrom-Json -ErrorAction Stop) }
    catch { Write-Log 'DEBUG' "Strict JSON parse of '$Path' failed; retrying without JSONC comments and trailing commas." }
    try { return (ConvertTo-StrictJson $raw | ConvertFrom-Json -ErrorAction Stop) }
    catch { throw "Could not safely parse '$Path'. $($_.Exception.Message)" }
}

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
        return & $readCommand $Setting
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
        $result = New-ApplyResult $Item.Id @($components) 'Applied and verified.' $Item.RestartExplorer $Item.RestartRequired
        $Item.LastApplyResult = $result
        $Item.Status = 'Succeeded'
        $Item.Details = "Now set to: $($Item.CurrentState.DisplayText)"
        Write-Log 'INFO' "SUCCESS [$($Item.Id)] => $($Item.CurrentState.DisplayText)"
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
    if ($script:Settings.Count -ne 26) { throw "Expected 26 settings, found $($script:Settings.Count)." }
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
    if ($script:SettingHandlers.Count -ne 6) { throw "Expected 6 setting handlers, found $($script:SettingHandlers.Count)." }
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
    $toggleCount = @($script:Settings | Where-Object CanChoose).Count
    if ($toggleCount -lt 20) { throw "Expected at least 20 reversible settings, found $toggleCount." }
    "Self-test passed: 26 settings; $toggleCount reversible."
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
    if (Test-IsAdministrator) {
        Write-CliErrorResponse 'Start Dingo from the signed-in desktop account, not from an elevated PowerShell window. Dingo will request administrator approval only for settings that need it.' 2 $(if ($WhatIf) { 'WhatIf' } else { 'ApplyPreferred' })
        exit 2
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
                }
            })
            $exitCode = if ($blocked) { 2 } else { 0 }
            if ($OutputFormat -eq 'Json') {
                [Console]::Out.WriteLine((ConvertTo-Json -InputObject ([PSCustomObject]@{
                    Version=$script:DingoVersion; Mode='WhatIf'; Success=(-not [bool]$blocked); ExitCode=$exitCode; Changed=$false; Plan=$plan
                }) -Depth 7))
            } else {
                Write-CliStatus "Dingo dry run: $($selected.Count) preferred setting(s) would be applied. No changes were made."
                [Console]::Out.WriteLine(($plan | Format-Table Id,Name,Kind,Scope,RequiresAdmin,Available,CurrentStatus,CurrentState,Target -AutoSize | Out-String -Width 240).TrimEnd())
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

if (Test-IsAdministrator) {
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
foreach ($name in @('ScopeTabs','UserScopeText','BothScopeText','UserSettingsPanel','SystemSettingsPanel','BothSettingsPanel','AllPreferredButton','NeededButton','UncheckButton','RefreshButton','RestartExplorerCheckBox','ProgressBar','SummaryText','AdminSummaryText','OpenLogButton','ApplyButton')) {
    Set-Variable -Name $name -Value $window.FindName($name) -Scope Script
}
$desktopIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$UserScopeText.Text = "These settings affect only $desktopIdentity. A gold 'Admin approval required' label identifies a protected per-account policy that needs elevation."
$BothScopeText.Text = "These choices affect $desktopIdentity and the whole computer. Administrator approval is used only for the computer-wide part."
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
    switch ($item.DisplayScope) {
        'User' { [void]$UserSettingsPanel.Children.Add($card) }
        'System' { [void]$SystemSettingsPanel.Children.Add($card) }
        'Both' { [void]$BothSettingsPanel.Children.Add($card) }
    }
}

if ($UiSelfTest) {
    if ($script:ActionButtons | Where-Object IsEnabled) { throw 'Action buttons must remain disabled until the initial state scan finishes.' }
    $adminSettings = @($script:Settings | Where-Object RequiresAdmin)
    if ($adminSettings | Where-Object { -not $_.AdminBadgeControl }) { throw 'Every setting that requires administrator approval must show an admin badge.' }
    if (-not $AdminSummaryText) { throw 'The selected administrator-change summary is unavailable.' }
    "UI self-test passed: $($script:Settings.Count) setting cards across 3 scope tabs."
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
