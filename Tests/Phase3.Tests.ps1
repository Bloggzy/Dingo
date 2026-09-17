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
$script:DefaultToolRoot='C:\DFIR\Tools'
$script:ToolRootToken='%DINGO_TOOL_ROOT%'
$script:ToolRootVariableName='DINGO_TOOL_ROOT'
$script:ActiveToolRoot=$script:DefaultToolRoot
$script:ToolRootWarning=''
$script:ToolRootRejected=$false
# Sets the launcher folder and publishes the token, the same as a real start.
[void](Set-DingoToolRoot $script:DefaultToolRoot)
$script:Passed=0
function Assert($Condition,$Message) { if (-not $Condition) { throw $Message } }
function Test-Case($Name,[scriptblock]$Body) { & $Body; $script:Passed++; "PASS $Name" }
function Assert-Throws([scriptblock]$Body,$Pattern) {
    $message=''; try { & $Body } catch { $message=$_.Exception.Message }
    Assert ($message -match $Pattern) "Expected $Pattern; got $message"
}
function New-ProbeExecutable([string]$Path, [string]$Source) {
    $compiler = Join-Path $env:WinDir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
        $compiler = Join-Path $env:WinDir 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
    }
    if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
        throw "The .NET Framework C# compiler is not on this computer, so the probe cannot be built: $compiler"
    }
    $sourcePath = [IO.Path]::ChangeExtension($Path, '.cs')
    [IO.File]::WriteAllText($sourcePath, $Source, (New-Object Text.UTF8Encoding $true))
    $build = Invoke-ChildProcess $compiler @('/nologo','/target:exe','/platform:anycpu',"/out:$Path",$sourcePath) 120 'Probe compiler'
    if ($build.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "The probe did not compile (exit $($build.ExitCode)): $($build.Output)"
    }
}

$scratch=Join-Path $PSScriptRoot ('.phase3-'+[Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $scratch)
$probe=Join-Path $scratch 'argument probe.exe'
try {
    # Add-Type -OutputAssembly built the probe on Windows PowerShell 5.1, but
    # .NET Core dropped assembly output, so on PowerShell 7 this whole suite
    # stopped at the first line. The .NET Framework compiler ships with Windows
    # and is the same on both runtimes, so the probe is built by calling it.
    # Invoke-ChildProcess carries the arguments, which is the function this
    # suite tests: a compiler command that arrives wrong fails the build loudly
    # rather than quietly passing a test.
    New-ProbeExecutable $probe @'
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
    Test-Case 'A dropped download is tried again; a refusal is not' {
        function Start-Sleep { }
        $state=@{Count=0}
        # No response object at all is a transport fault, so it is worth retrying.
        $value = Invoke-WithDownloadRetry { $state.Count++; if ($state.Count -lt 3) { throw 'The remote name could not be resolved' }; 'ok' } 'test download'
        Assert ($value -eq 'ok') 'The value from a successful retry was lost.'
        Assert ($state.Count -eq 3) "Took $($state.Count) tries instead of 3."
        $state.Count=0
        Assert-Throws { Invoke-WithDownloadRetry { $state.Count++; throw 'The remote name could not be resolved' } 'test download' } 'could not be resolved'
        Assert ($state.Count -eq 3) "Gave up after $($state.Count) tries instead of 3."
        # A refusal that will read the same in ten seconds is never repeated.
        function Get-WebErrorStatus { 404 }
        $state.Count=0
        Assert-Throws { Invoke-WithDownloadRetry { $state.Count++; throw 'not found' } 'test download' } 'not found'
        Assert ($state.Count -eq 1) "A permanent refusal was tried $($state.Count) times."
        function Get-WebErrorStatus { 503 }
        $state.Count=0
        Assert-Throws { Invoke-WithDownloadRetry { $state.Count++; throw 'busy' } 'test download' } 'busy'
        Assert ($state.Count -eq 3) "A busy server was tried $($state.Count) times instead of 3."
    }
    Test-Case 'The web session asks for TLS 1.2 and offers the account to a proxy' {
        Initialize-DingoWebSession
        Assert ((([Net.ServicePointManager]::SecurityProtocol) -band [Net.SecurityProtocolType]::Tls12) -ne 0) 'TLS 1.2 was not requested.'
        $proxy=[Net.WebRequest]::DefaultWebProxy
        Assert ((-not $proxy) -or $proxy.Credentials) 'A proxy was left with nothing to answer with.'
    }
    Test-Case 'A zip is unpacked into place and leaves no staging folder behind' {
        $src=Join-Path $scratch 'pack-src'
        New-Item -ItemType Directory -Path (Join-Path $src 'sub') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $src 'tool.exe'),'new')
        [IO.File]::WriteAllText((Join-Path $src 'sub\data.txt'),'new data')
        $zip=Join-Path $scratch 'pack.zip'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($src,$zip)
        $dest=Join-Path $scratch 'pack-dest'
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $dest 'tool.exe'),'old')
        $written=Expand-DingoZipArchive $zip $dest
        Assert ($written -eq 2) "Wrote $written file(s) instead of 2."
        Assert ((Get-Content -Raw -LiteralPath (Join-Path $dest 'tool.exe')) -eq 'new') 'The old file was not replaced.'
        Assert ((Get-Content -Raw -LiteralPath (Join-Path $dest 'sub\data.txt')) -eq 'new data') 'The nested file is wrong.'
        Assert (-not @(Get-ChildItem -Path $scratch -Filter 'pack-dest.dingo-unpack-*' -Force -ErrorAction SilentlyContinue).Count) 'A staging folder was left behind.'
    }
    Test-Case 'A tool that is open stops the unpack, and the copy in place survives' {
        $zip=Join-Path $scratch 'pack.zip'
        $dest=Join-Path $scratch 'locked-dest'
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $dest 'tool.exe'),'old')
        $held=[IO.File]::Open((Join-Path $dest 'tool.exe'),'Open','ReadWrite','None')
        try { Assert-Throws { Expand-DingoZipArchive $zip $dest } 'open right now' }
        finally { $held.Dispose() }
        Assert ((Get-Content -Raw -LiteralPath (Join-Path $dest 'tool.exe')) -eq 'old') 'The running tool was overwritten.'
        Assert (-not (Test-Path -LiteralPath (Join-Path $dest 'sub\data.txt'))) 'Other files landed although the unpack stopped.'
        Assert (-not @(Get-ChildItem -Path $scratch -Filter 'locked-dest.dingo-unpack-*' -Force -ErrorAction SilentlyContinue).Count) 'A staging folder was left behind.'
    }
    Test-Case 'An unpack that will not fit stops before the folder is touched' {
        function Get-FreeSpaceBytes { [int64]1 }
        $zip=Join-Path $scratch 'pack.zip'
        $dest=Join-Path $scratch 'full-dest'
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $dest 'tool.exe'),'old')
        Assert-Throws { Expand-DingoZipArchive $zip $dest } 'Make room'
        Assert ((Get-Content -Raw -LiteralPath (Join-Path $dest 'tool.exe')) -eq 'old') 'The folder was changed although the drive was full.'
        Assert (-not @(Get-ChildItem -Path $scratch -Filter 'full-dest.dingo-unpack-*' -Force -ErrorAction SilentlyContinue).Count) 'A staging folder was left behind.'
        # A drive that cannot be asked must never stop an install that would work.
        function Get-FreeSpaceBytes { [int64](-1) }
        Assert-EnoughFreeSpace $dest ([int64]1TB) 'A test'
    }
    "Passed $script:Passed phase 3 tests on PowerShell $($PSVersionTable.PSVersion)."
} finally {
    $script:LogFile=$null
    # Only processes started from the GUID test directory can be cleaned up.
    Get-Process -Name 'argument probe' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $probe } | Stop-Process -Force
    $resolved=[IO.Path]::GetFullPath($scratch)
    if ([IO.Path]::GetDirectoryName($resolved) -eq [IO.Path]::GetFullPath($PSScriptRoot) -and [IO.Path]::GetFileName($resolved) -match '^\.phase3-[a-f0-9]{32}$') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
