# Tab completion for Start-Dingo.cmd.
#
# PowerShell completes the switches of a .ps1 by itself, so this file is only
# for the .cmd launcher. Two things are in the way there:
#
#   1. PowerShell cannot read the switches of a batch file, so it has nothing
#      to offer. A native argument completer supplies them.
#   2. Windows PowerShell 5.1 never calls a native argument completer for a
#      word that starts with a hyphen. So the switch names need TabExpansion2,
#      the function PowerShell asks for every completion, to be wrapped.
#
# Load it for this window:
#     . .\Dingo.Completion.ps1
#
# Load it for every window. Add that same line to your PowerShell profile:
#     notepad $PROFILE
#
# The switch list is read from Dingo.ps1 when this file loads, so it can never
# fall behind the script it completes. Nothing here changes Dingo itself.

Set-StrictMode -Version 2.0

function Get-DingoCompletionSwitch {
    [CmdletBinding()]
    param([string]$ScriptPath)

    # Anything a person is never meant to type: the plumbing Dingo passes to its
    # own elevated worker, and the catch-all for unrecognised words.
    $internal = @(
        'MachineWorker', 'ElevationBroker', 'WpfHost', 'FinalizeInternationalSettings',
        'FinalizeFormatState', 'PlanPath', 'ResultPath', 'WorkerLogPath', 'ProgressPath',
        'CancelPath', 'TargetUserSid', 'UnexpectedArguments'
    )
    $common = @([Management.Automation.Internal.CommonParameters].GetProperties() | ForEach-Object { $_.Name })

    $errors = $null
    $tokens = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Could not read the switches from '$ScriptPath': $($errors[0].Message)" }
    if (-not $ast.ParamBlock) { throw "'$ScriptPath' has no parameter block." }

    @($ast.ParamBlock.Parameters | ForEach-Object {
        $name = $_.Name.VariablePath.UserPath
        if ($internal -contains $name) { return }
        if ($common -contains $name) { return }
        # A switch stands alone. Anything else expects a value after it.
        $isSwitch = @($_.Attributes | Where-Object {
            $_ -is [Management.Automation.Language.TypeConstraintAst] -and $_.TypeName.Name -eq 'switch'
        }).Count -gt 0
        [PSCustomObject]@{ Name = $name; TakesValue = (-not $isSwitch) }
    })
}

$global:DingoCompletionScript = Join-Path $PSScriptRoot 'Dingo.ps1'
if (-not (Test-Path -LiteralPath $global:DingoCompletionScript -PathType Leaf)) {
    throw "Dingo.ps1 is not beside this file, so the switches could not be read. Looked in '$PSScriptRoot'."
}
$global:DingoCompletionSwitches = @(Get-DingoCompletionSwitch $global:DingoCompletionScript)

# The words -Include and -Exclude take. A setting ID is not offered: reading the
# real list means starting Dingo, and a tab press has to answer at once.
$global:DingoSectionWords = @('tweaks', 'tools')
$global:DingoOutputFormats = @('Text', 'Json')

# Matches the launcher however it was typed: Start-Dingo.cmd, .\Start-Dingo.cmd,
# a full path, or the name without its extension.
$global:DingoCommandPattern = '(^|[\s''"])([^\s''"]*[\\/])?Start-Dingo(\.cmd)?$'

function Get-DingoSwitchCompletion {
    [CmdletBinding()]
    param([string]$WordToComplete)
    @($global:DingoCompletionSwitches | Where-Object { "-$($_.Name)" -like "$WordToComplete*" } | ForEach-Object {
        $text = "-$($_.Name)"
        $tip = if ($_.TakesValue) { "$text <value>" } else { $text }
        [Management.Automation.CompletionResult]::new($text, $text, 'ParameterName', $tip)
    })
}

# The value half. PowerShell does call a native completer for a word with no
# hyphen, so -Include and -OutputFormat values work through this alone.
$global:DingoNativeCompleter = {
    param($wordToComplete, $commandAst, $cursorPosition)

    $previous = ''
    $elements = @($commandAst.CommandElements)
    for ($i = $elements.Count - 1; $i -ge 1; $i--) {
        $text = [string]$elements[$i].Extent.Text
        if ($i -eq $elements.Count - 1 -and $text -eq $wordToComplete) { continue }
        $previous = $text
        break
    }

    $words = switch -Regex ($previous) {
        '^-(Include|Exclude)$' { @($global:DingoSectionWords | ForEach-Object { ,@($_, "Every setting in the $_ section") }) }
        '^-OutputFormat$' { @($global:DingoOutputFormats | ForEach-Object { ,@($_, "$_ output") }) }
        default { @() }
    }
    foreach ($pair in $words) {
        if ($pair[0] -notlike "$wordToComplete*") { continue }
        [Management.Automation.CompletionResult]::new($pair[0], $pair[0], 'ParameterValue', $pair[1])
    }
    # A word with a hyphen never reaches here on Windows PowerShell 5.1. The
    # TabExpansion2 wrapper below is what answers those.
    if ($wordToComplete -like '-*') { Get-DingoSwitchCompletion $wordToComplete }
}

foreach ($name in @('Start-Dingo.cmd', '.\Start-Dingo.cmd', './Start-Dingo.cmd', 'Start-Dingo')) {
    Register-ArgumentCompleter -Native -CommandName $name -ScriptBlock $global:DingoNativeCompleter
}

function global:TabExpansion2 {
    # A wrapper, not a replacement. It does exactly what the built-in does, then
    # adds Dingo's switches when the built-in had nothing to say. Any fault in
    # the extra part is swallowed, so completion never breaks for other commands.
    [CmdletBinding(DefaultParameterSetName = 'ScriptInputSet')]
    param(
        [Parameter(ParameterSetName = 'ScriptInputSet', Mandatory = $true, Position = 0)][string]$inputScript,
        [Parameter(ParameterSetName = 'ScriptInputSet', Mandatory = $true, Position = 1)][int]$cursorColumn,
        [Parameter(ParameterSetName = 'AstInputSet', Mandatory = $true, Position = 0)][System.Management.Automation.Language.Ast]$ast,
        [Parameter(ParameterSetName = 'AstInputSet', Mandatory = $true, Position = 1)][System.Management.Automation.Language.Token[]]$tokens,
        [Parameter(ParameterSetName = 'AstInputSet', Mandatory = $true, Position = 2)][System.Management.Automation.Language.IScriptPosition]$positionOfCursor,
        [Parameter(ParameterSetName = 'ScriptInputSet', Position = 2)]
        [Parameter(ParameterSetName = 'AstInputSet', Position = 3)][Hashtable]$options
    )

    if ($psCmdlet.ParameterSetName -eq 'ScriptInputSet') {
        $completion = [System.Management.Automation.CommandCompletion]::CompleteInput($inputScript, $cursorColumn, $options)
        $line = $inputScript
        $cursor = $cursorColumn
    } else {
        $completion = [System.Management.Automation.CommandCompletion]::CompleteInput($ast, $tokens, $positionOfCursor, $options)
        $line = [string]$ast.Extent.Text
        $cursor = [int]$positionOfCursor.Offset
    }

    try {
        if (@($completion.CompletionMatches).Count -gt 0) { return $completion }
        if ($cursor -lt 0 -or $cursor -gt $line.Length) { return $completion }
        $before = $line.Substring(0, $cursor)
        # The word being typed: everything back to the last space.
        $wordStart = $before.LastIndexOfAny(@(' ', "`t")) + 1
        $word = $before.Substring($wordStart)
        if ($word -notlike '-*') { return $completion }
        # The command this word belongs to has to be the Dingo launcher.
        if ($before.Substring(0, $wordStart).TrimEnd() -notmatch $global:DingoCommandPattern) {
            $firstWord = @($before.Substring(0, $wordStart).Trim() -split '\s+')[0]
            if ($firstWord -notmatch $global:DingoCommandPattern) { return $completion }
        }
        $matches = @(Get-DingoSwitchCompletion $word)
        if (-not $matches.Count) { return $completion }
        $collection = New-Object 'Collections.ObjectModel.Collection[System.Management.Automation.CompletionResult]'
        foreach ($match in $matches) { $collection.Add($match) }
        return [System.Management.Automation.CommandCompletion]::new($collection, -1, $wordStart, $word.Length)
    } catch {
        Write-Verbose "Dingo completion was skipped: $($_.Exception.Message)"
        return $completion
    }
}

Write-Verbose "Dingo tab completion is ready: $($global:DingoCompletionSwitches.Count) switch(es)."
