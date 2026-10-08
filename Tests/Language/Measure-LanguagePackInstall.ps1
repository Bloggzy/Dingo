#Requires -RunAsAdministrator
<#
Times one display-language pack install and records where the time goes.

Run it on a clean VM snapshot, once per method, and revert the snapshot
between runs. Every 5 seconds it samples network bytes received, the
servicing processes' CPU, and the CBS log size, so the timeline shows
whether the time is spent downloading or installing.

  -Method InstallLanguage   what Dingo does now (Install-Language -ExcludeFeatures)
  -Method Full              Install-Language with all language features

It also records what Delivery Optimization (the Windows Update download
service) reports for each download: priority, size, and source. Before the
install it measures the plain line speed with a 50 MB test download (the site refuses 100 MB) from
speed.cloudflare.com, which is thrown away. -SkipSpeedTest leaves that out.

Output goes to a folder on the desktop. Send back the whole folder.
#>
param(
    [ValidateSet('InstallLanguage','Full')]
    [string]$Method = 'InstallLanguage',
    [string]$Language = 'en-GB',
    [switch]$SkipSpeedTest
)

$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$out = Join-Path ([Environment]::GetFolderPath('Desktop')) "LangTest_${Method}_$stamp"
New-Item -ItemType Directory -Path $out -Force | Out-Null
$summary = Join-Path $out 'summary.txt'

function Write-Summary([string]$Text) {
    Write-Host $Text
    Add-Content -LiteralPath $summary -Value $Text -Encoding UTF8
}

function Get-ReceivedBytes {
    $sum = 0
    foreach ($s in @(Get-NetAdapterStatistics -ErrorAction SilentlyContinue)) { $sum += [int64]$s.ReceivedBytes }
    return $sum
}

function Get-ServicingCpu {
    $cpu = 0.0
    foreach ($name in @('TiWorker','TrustedInstaller','DismHost')) {
        foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) { $cpu += [double]$p.CPU }
    }
    return [math]::Round($cpu, 1)
}

function Get-CbsSize {
    try { return (Get-Item -LiteralPath "$env:SystemRoot\Logs\CBS\CBS.log" -Force).Length } catch { return 0 }
}

function Get-LanguageCapabilities {
    @(Get-WindowsCapability -Online | Where-Object { $_.Name -like "*~~~$Language~*" -or $_.Name -like "Language.UI.Client~~~$Language~*" }) |
        ForEach-Object {
            # The list leaves the sizes out; only a lookup by name fills them in.
            $detail = Get-WindowsCapability -Online -Name $_.Name -ErrorAction SilentlyContinue
            [PSCustomObject]@{
                Name = $_.Name
                State = [string]$_.State
                DownloadMB = [math]::Round([double]$detail.DownloadSize / 1MB, 1)
                InstallMB = [math]::Round([double]$detail.InstallSize / 1MB, 1)
            }
        }
}

$os = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Write-Summary "Method: $Method   Language: $Language   Started: $(Get-Date -Format s)"
Write-Summary "Windows: $($os.DisplayVersion) build $($os.CurrentBuild).$($os.UBR) $($os.EditionID)"
$mp = try { Get-MpComputerStatus -ErrorAction Stop } catch { $null }
Write-Summary "Logical processors: $([Environment]::ProcessorCount)   Defender real-time protection on: $(if ($mp) { $mp.RealTimeProtectionEnabled } else { 'unreadable' })"
$wsus = try { (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -Name WUServer -ErrorAction Stop).WUServer } catch { 'none' }
$repair = try { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Servicing' -ErrorAction Stop | Out-String).Trim() } catch { 'none' }
Write-Summary "WSUS server: $wsus"
Write-Summary "Optional component source policy: $repair"
Write-Summary "Installed languages before: $((@(Get-InstalledLanguage) | ForEach-Object { $_ } | ForEach-Object { "$($_.LanguageId)=$($_.LanguagePacks)" }) -join ', ')"
Write-Summary ''
Write-Summary 'Capabilities for this language BEFORE (sizes as Windows reports them):'
$before = @(Get-LanguageCapabilities)
Write-Summary (($before | Format-Table -AutoSize | Out-String).TrimEnd())
Write-Summary ''

$doSettings = try { (Get-DeliveryOptimizationPerfSnapThisMonth | Out-String).Trim() } catch { "unreadable: $($_.Exception.Message)" }
Write-Summary "Delivery Optimization this month before the run:"
Write-Summary $doSettings
$doPolicy = try { (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' -ErrorAction Stop | Out-String).Trim() } catch { 'none' }
Write-Summary "Delivery Optimization policy: $doPolicy"
Write-Summary ''

if (-not $SkipSpeedTest) {
    # Read into memory and dropped; nothing is written to disk.
    try {
        $client = New-Object Net.WebClient
        $speedTimer = [Diagnostics.Stopwatch]::StartNew()
        $bytes = $client.DownloadData('https://speed.cloudflare.com/__down?bytes=50000000')
        $speedTimer.Stop()
        $mbps = [math]::Round($bytes.Length / 1MB / $speedTimer.Elapsed.TotalSeconds, 2)
        Write-Summary "Line speed test: $([math]::Round($bytes.Length / 1MB, 1)) MB in $([math]::Round($speedTimer.Elapsed.TotalSeconds, 1)) s = $mbps MB/s"
        $bytes = $null
    } catch { Write-Summary "Line speed test failed: $($_.Exception.Message)" }
    Write-Summary ''
}
$doRows = New-Object System.Collections.ArrayList

$cbsStart = Get-CbsSize
$netStart = Get-ReceivedBytes
$cpuStart = Get-ServicingCpu
$timeline = New-Object System.Collections.ArrayList
$timer = [Diagnostics.Stopwatch]::StartNew()

switch ($Method) {
    'InstallLanguage' { $job = Install-Language -Language $Language -ExcludeFeatures -AsJob }
    'Full'            { $job = Install-Language -Language $Language -AsJob }

}

$lastNet = $netStart
# CPU seconds per process id at the last sample, so each sample can name the
# processes that worked hardest in the last 5 seconds. Service hosts are
# named by the services they run.
function Get-CpuByProcess {
    $map = @{}
    foreach ($proc in @(Get-Process -ErrorAction SilentlyContinue)) { try { $map[$proc.Id] = @($proc.Name, [double]$proc.CPU) } catch { } }
    return $map
}
$serviceNames = @{}
foreach ($svc in @(Get-CimInstance Win32_Service -Filter 'ProcessId > 0')) { $serviceNames[[int]$svc.ProcessId] = @($serviceNames[[int]$svc.ProcessId]) + $svc.Name | Where-Object { $_ } }
$lastCpu = Get-CpuByProcess
while ($job.State -in @('NotStarted','Running')) {
    Start-Sleep -Seconds 5
    $net = Get-ReceivedBytes
    $row = [PSCustomObject]@{
        Seconds = [int]$timer.Elapsed.TotalSeconds
        NetMBTotal = [math]::Round(($net - $netStart) / 1MB, 1)
        NetMBps = [math]::Round(($net - $lastNet) / 1MB / 5, 2)
        ServicingCpuSec = [math]::Round((Get-ServicingCpu) - $cpuStart, 1)
        CbsLogKB = [math]::Round(((Get-CbsSize) - $cbsStart) / 1KB, 0)
        TopCpu = ''
    }
    $nowCpu = Get-CpuByProcess
    $deltas = foreach ($id in $nowCpu.Keys) {
        $prior = if ($lastCpu.ContainsKey($id)) { $lastCpu[$id][1] } else { 0 }
        $label = $nowCpu[$id][0]
        if ($label -eq 'svchost') {
            if (-not $serviceNames.ContainsKey([int]$id)) { $serviceNames[[int]$id] = @(Get-CimInstance Win32_Service -Filter "ProcessId = $id" -ErrorAction SilentlyContinue | ForEach-Object Name) }
            $label = "svchost($(@($serviceNames[[int]$id]) -join '+'))"
        }
        [PSCustomObject]@{ Label = $label; Cpu = $nowCpu[$id][1] - $prior }
    }
    $row.TopCpu = (@($deltas | Where-Object { $_.Cpu -ge 0.2 } | Sort-Object Cpu -Descending | Select-Object -First 3) | ForEach-Object { '{0}={1:N1}' -f $_.Label, $_.Cpu }) -join ' '
    $lastCpu = $nowCpu
    $lastNet = $net
    [void]$timeline.Add($row)
    foreach ($d in @(Get-DeliveryOptimizationStatus -ErrorAction SilentlyContinue)) {
        [void]$doRows.Add([PSCustomObject]@{
            Seconds = $row.Seconds; FileId = $d.FileId; Status = $d.Status; Priority = $d.Priority
            FileSizeMB = [math]::Round([double]$d.FileSize / 1MB, 1); HttpMB = [math]::Round([double]$d.BytesFromHttp / 1MB, 1)
            PeersMB = [math]::Round([double]$d.BytesFromPeers / 1MB, 1); DownloadMode = $d.DownloadMode
            SourceURL = $d.SourceURL; PredefinedCallerApplication = $d.PredefinedCallerApplication
        })
    }
    Write-Host ("{0,5}s  net {1,7} MB  ({2} MB/s)  servicing CPU {3}s  CBS +{4} KB" -f $row.Seconds, $row.NetMBTotal, $row.NetMBps, $row.ServicingCpuSec, $row.CbsLogKB)
    if ($timer.Elapsed.TotalMinutes -ge 45) { Write-Summary 'Gave up after 45 minutes.'; break }
}
$timer.Stop()
$jobError = ''
try { Receive-Job -Job $job -ErrorAction Stop | Out-Null } catch { $jobError = $_.Exception.Message }
$timeline | Export-Csv -LiteralPath (Join-Path $out 'timeline.csv') -NoTypeInformation
$doRows | Export-Csv -LiteralPath (Join-Path $out 'delivery-optimization.csv') -NoTypeInformation

# The moment the network went quiet for good is where download ends and
# install-only work begins. Below 0.5 MB/s counts as quiet.
$lastBusy = @($timeline | Where-Object { $_.NetMBps -ge 0.5 } | Select-Object -Last 1)
$downloadEnds = if ($lastBusy.Count) { $lastBusy[0].Seconds } else { 0 }
$downloadSeconds = 5 * @($timeline | Where-Object { $_.NetMBps -ge 0.5 }).Count

Write-Summary "Job state: $($job.State)  Error: $(if ($jobError) { $jobError } else { 'none' })"
Write-Summary "Total time: $([int]$timer.Elapsed.TotalMinutes)m $($timer.Elapsed.Seconds)s"
Write-Summary "Network received during run: $([math]::Round(((Get-ReceivedBytes) - $netStart) / 1MB, 1)) MB"
Write-Summary "Last network activity at: ${downloadEnds}s. Seconds spent downloading (over 0.5 MB/s): about $downloadSeconds"
Write-Summary "Servicing CPU used: $([math]::Round((Get-ServicingCpu) - $cpuStart, 1)) s"
Write-Summary ''
Write-Summary 'Capabilities for this language AFTER:'
Write-Summary ((@(Get-LanguageCapabilities) | Format-Table -AutoSize | Out-String).TrimEnd())
Write-Summary ''
Write-Summary "Installed languages after: $((@(Get-InstalledLanguage) | ForEach-Object { $_ } | ForEach-Object { "$($_.LanguageId)=$($_.LanguagePacks)" }) -join ', ')"
Write-Summary "Pending restart: $(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')"

# The CBS lines written during the run name each package and its timing.
try {
    $fs = [IO.File]::Open("$env:SystemRoot\Logs\CBS\CBS.log", 'Open', 'Read', 'ReadWrite')
    [void]$fs.Seek($cbsStart, 'Begin')
    $reader = New-Object IO.StreamReader($fs)
    $reader.ReadToEnd() | Set-Content -LiteralPath (Join-Path $out 'cbs-during-run.log') -Encoding UTF8
    $reader.Close()
} catch { Write-Summary "Could not copy CBS log: $($_.Exception.Message)" }

Write-Summary ''
Write-Summary "Results folder: $out"
