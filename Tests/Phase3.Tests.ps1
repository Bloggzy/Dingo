#requires -version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$source=Join-Path (Split-Path $PSScriptRoot -Parent) 'Dingo.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors.Message -join '; ') }
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) { Invoke-Expression $statement.Extent.Text }
}
$script:LogFile=$null
$script:Passed=0
function Assert($Condition,$Message) { if (-not $Condition) { throw $Message } }
function Test-Case($Name,[scriptblock]$Body) { & $Body; $script:Passed++; "PASS $Name" }
function Assert-Throws([scriptblock]$Body,$Pattern) {
    $message=''; try { & $Body } catch { $message=$_.Exception.Message }
    Assert ($message -match $Pattern) "Expected $Pattern; got $message"
}
$scratch=Join-Path $PSScriptRoot ('.phase3-'+[Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $scratch)
$probe=Join-Path $scratch 'argument probe.exe'
try {
    Add-Type -OutputAssembly $probe -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Diagnostics;
using System.Threading;
class Probe {
    static int Main(string[] args) {
        if (args[0] == "sleep") { Thread.Sleep(30000); return 0; }
        if (args[0] == "tree" || args[0] == "detach") {
            var start = new ProcessStartInfo(System.Reflection.Assembly.GetExecutingAssembly().Location, "sleep");
            start.UseShellExecute = false; start.CreateNoWindow = true;
            var child = Process.Start(start);
            File.WriteAllText(args[1], child.Id.ToString());
            if (args[0] == "detach") return 0;
            Thread.Sleep(30000); return 0;
        }
        if (args[0] == "noise") {
            for (int i=0; i<10000; i++) { Console.Out.WriteLine(new string('o',80)); Console.Error.WriteLine(new string('e',80)); }
            Console.Out.WriteLine("stdout-end"); Console.Error.WriteLine("stderr-end"); return 7;
        }
        for (int i=1; i<args.Length; i++) Console.WriteLine("arg:" + Convert.ToBase64String(Encoding.UTF8.GetBytes(args[i])));
        return 0;
    }
}
'@
    Test-Case 'Real native argv preserves empty values quotes Unicode and trailing slashes' {
        $values=@('', 'plain', 'two words', 'a"b', 'C:\space here\', '\\server\share\', 'before\"after', 'café', '& | > ; $()')
        $run=Invoke-ChildProcess $probe (@('echo')+$values) 10 'Argument probe'
        $actual=@($run.Output -split ' ' | Where-Object { $_ -like 'arg:*' } | ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_.Substring(4))) })
        Assert ($actual.Count -eq $values.Count) 'Argument count changed.'
        for ($i=0;$i -lt $values.Count;$i++) { Assert ($actual[$i] -ceq $values[$i]) "Argument $i changed." }
    }
    Test-Case 'Concurrent noisy pipes stay bounded and preserve exit code and tails' {
        $run=Invoke-ChildProcess $probe @('noise') 10 'Output probe'
        Assert ($run.ExitCode -eq 7 -and $run.Output.Length -le 131073) 'Exit code or output bound incorrect.'
        Assert ($run.Output.Contains('stdout-end') -and $run.Output.Contains('stderr-end')) 'Output tail missing.'
    }
    Test-Case 'Timeout terminates the test process tree and returns promptly' {
        function Write-Log($Level,$Message) { Write-Host "$Level $Message" }
        $pidFile=Join-Path $scratch 'child.pid'
        $watch=[Diagnostics.Stopwatch]::StartNew()
        Assert-Throws { Invoke-ChildProcess $probe @('tree',$pidFile) 2 'Tree probe' } 'timed out.*partial'
        Assert ($watch.Elapsed.TotalSeconds -lt 15) 'Timeout cleanup was not bounded.'
        $childId=[int][IO.File]::ReadAllText($pidFile)
        $child=Get-Process -Id $childId -ErrorAction SilentlyContinue
        if ($child) { [void]$child.WaitForExit(5000); $child.Dispose() }
        Assert (-not (Get-Process -Id $childId -ErrorAction SilentlyContinue)) 'Test descendant survived timeout.'
    }
    Test-Case 'Invalid timeout and null argument fail before execution' {
        Assert-Throws { Invoke-ChildProcess $probe @('sleep') 0 'Bad timeout' } 'timeout must'
        Assert-Throws { ConvertTo-NativeArgument ("bad"+[char]0) } 'null character'
    }
    Test-Case 'Parent exit does not hide an active descendant' {
        $pidFile=Join-Path $scratch 'detached.pid'
        Assert-Throws { Invoke-ChildProcess $probe @('detach',$pidFile) 2 'Detached probe' } 'descendants timed out'
        $child=Get-Process -Id ([int][IO.File]::ReadAllText($pidFile)) -ErrorAction SilentlyContinue
        if ($child) { Assert ($child.WaitForExit(5000)) 'Descendant survived job closure.'; $child.Dispose() }
    }
    Test-Case 'Built-in script is revision and hash pinned; malformed custom hashes fail' {
        $raw=Get-BuiltInToolCatalog | Where-Object id -eq 'tool-eztools'
        $tool=ConvertTo-ToolDefinition $raw
        Assert ($tool.Url -match '/[a-f0-9]{40}/' -and $tool.Sha256 -match '^[A-F0-9]{64}$') 'Built-in provenance is not pinned.'
        $raw.install.sha256='invalid'
        Assert-Throws { ConvertTo-ToolDefinition $raw } '64-character'
    }
    Test-Case 'Journal survives incomplete and damaged records without replay' {
        $script:LogFile=Join-Path $scratch 'recovery.log'
        Write-OperationJournal Started 'one' 'setting-one' User @{DesiredState='on'}
        Write-OperationJournal Started 'two' 'setting-two' Machine @{}
        Write-OperationJournal Completed 'two' 'setting-two' Machine @{}
        $path="$($script:LogFile).$PID.journal.jsonl"
        [IO.File]::AppendAllText($path,'{"incomplete":')
        $report=@(Get-RecoveryReport $scratch)
        Assert (@($report | Where-Object SettingId -eq 'setting-one').Count -eq 1) 'Interrupted scope lost.'
        Assert (@($report | Where-Object SettingId -eq 'setting-two').Count -eq 0) 'Completed scope flagged.'
        Assert (@($report | Where-Object Status -eq 'Unreadable record').Count -eq 1) 'Truncated line ignored.'
        $script:LogFile=$null
    }
    Test-Case 'Journal failure prevents mutation' {
        function Write-OperationJournal { throw 'Journal inaccessible' }
        function Set-SettingPart { throw 'MUTATION ATTEMPTED' }
        $setting=[pscustomobject]@{Id='probe';CurrentState=@{Status='Alternate'}}
        $result=@(Invoke-SettingPartResults $setting on User)
        Assert (-not (($result.Message -join ' ') -match 'MUTATION ATTEMPTED')) 'Write ran without a journal.'
        Assert (@($result | Where-Object Outcome -eq Failed).Count -gt 0) 'Journal failure not reported.'
    }
    Test-Case 'Script hash mismatch blocks execution and destination creation' {
        function Invoke-WebRequest { param($Uri,$OutFile,[switch]$UseBasicParsing,$TimeoutSec,$MaximumRedirection,$ErrorAction) [IO.File]::WriteAllText($OutFile,'# harmless fixture') }
        function Get-AuthenticodeSignature { [pscustomobject]@{Status='NotSigned';SignerCertificate=$null} }
        function Invoke-ChildProcess { throw 'EXECUTION ATTEMPTED' }
        $dest=Join-Path $scratch 'must-not-exist'
        $tool=[pscustomobject]@{Id='probe';Name='Probe';Scope='user';Url='https://example.test/install.ps1';Sha256=('0'*64);Dest=$dest;Arguments=@();TimeoutSeconds=5}
        Assert-Throws { Install-ScriptPackage $tool } 'SHA256 mismatch'
        Assert (-not (Test-Path -LiteralPath $dest)) 'Destination created before integrity check.'
    }
    Test-Case 'Matching hash executes and records provenance before cleanup' {
        function Invoke-WebRequest { param($Uri,$OutFile,[switch]$UseBasicParsing,$TimeoutSec,$MaximumRedirection,$ErrorAction) [IO.File]::WriteAllText($OutFile,'# harmless fixture') }
        function Get-AuthenticodeSignature { [pscustomobject]@{Status='NotSigned';SignerCertificate=$null} }
        function Get-PowerShellHostPath { 'mock.exe' }
        function Invoke-ChildProcess { [pscustomobject]@{ExitCode=0;Output='fixture'} }
        $fixture=Join-Path $scratch 'fixture.ps1'; [IO.File]::WriteAllText($fixture,'# harmless fixture')
        $script:LogFile=Join-Path $scratch 'provenance.log'
        $tool=[pscustomobject]@{Id='probe';Name='Probe';Scope='user';Url='https://example.test/install.ps1';Sha256=(Get-FileHash $fixture).Hash;Dest=$scratch;Arguments=@();TimeoutSeconds=5}
        Install-ScriptPackage $tool
        $record=Get-Content -LiteralPath "$($script:LogFile).$PID.journal.jsonl" | ConvertFrom-Json
        Assert ($record.Event -eq 'InstallerProvenance' -and $record.Data.Sha256 -eq $tool.Sha256) 'Provenance absent.'
        $script:LogFile=$null
    }
    "Passed $script:Passed phase 3 tests on PowerShell $($PSVersionTable.PSVersion)."
} finally {
    $script:LogFile=$null
    # Only processes started from the GUID test directory can be cleaned up.
    Get-Process -Name 'argument probe' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $probe } | Stop-Process -Force
    $resolved=[IO.Path]::GetFullPath($scratch)
    if ([IO.Path]::GetDirectoryName($resolved) -eq [IO.Path]::GetFullPath($PSScriptRoot) -and [IO.Path]::GetFileName($resolved) -match '^\.phase3-[a-f0-9]{32}$') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
