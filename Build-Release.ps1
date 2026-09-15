<#
.SYNOPSIS
    Builds the release zip for Dingo.

.DESCRIPTION
    The package used to be a file list typed by hand at release time, which is
    how Tools.example.json was left out of 0.7.6 even though the readme tells
    people to copy it. The list lives here now, and the build refuses to run if
    any of it is missing.

    The version comes from Dingo.ps1, so the zip name can never disagree with
    what the script reports.

.EXAMPLE
    .\Build-Release.ps1

.EXAMPLE
    .\Build-Release.ps1 -Verify
    Unpacks the finished zip into a temporary folder and runs the self-tests
    from it, which is what proves the package works on its own.
#>
[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [switch]$Verify
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Everything a person needs to run Dingo, and nothing that only matters in the
# repository: no tests, no screenshots, no evidence folders.
$script:PackageFiles = @(
    'Dingo.ps1'          # The program.
    'Start-Dingo.cmd'    # The launcher to double-click.
    'README.md'          # How to use it.
    'LICENSE'            # The terms.
    'Tools.example.json' # The template for a Tools.json of your own. The readme
                         # tells people to copy this, so it has to be in the box.
)

function Get-DingoReleaseVersion {
    [CmdletBinding()]
    param([string]$ScriptPath)
    $line = @(Select-String -LiteralPath $ScriptPath -Pattern "^\s*\`$script:DingoVersion\s*=\s*'([^']+)'" -ErrorAction Stop)
    if ($line.Count -ne 1) { throw "Could not read one version from '$ScriptPath'; found $($line.Count)." }
    $version = $line[0].Matches[0].Groups[1].Value
    if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "The version '$version' is not three numbers separated by dots." }
    return $version
}

# $PSScriptRoot is not filled in for a parameter default, so the folder this
# script sits in is worked out here instead.
$source = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $source) { throw 'Could not work out which folder this script is in.' }
if (-not $OutputDirectory) { $OutputDirectory = $source }
$scriptPath = Join-Path $source 'Dingo.ps1'
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "Dingo.ps1 is not in '$source'." }

# Missing is a stop, not a warning. A package with a hole in it looks fine.
$missing = @($script:PackageFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $source $_) -PathType Leaf) })
if ($missing.Count) { throw "The package is missing $($missing -join ', '). Nothing was built." }

$version = Get-DingoReleaseVersion $scriptPath
$zipPath = Join-Path $OutputDirectory "Dingo-$version.zip"
if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force -ErrorAction Stop | Out-Null
}
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

Compress-Archive -Path @($script:PackageFiles | ForEach-Object { Join-Path $source $_ }) -DestinationPath $zipPath -CompressionLevel Optimal -ErrorAction Stop

# Read the finished zip back rather than trusting what went in.
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
$archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $packed = @($archive.Entries | ForEach-Object { [string]$_.FullName })
} finally { $archive.Dispose() }
$absent = @($script:PackageFiles | Where-Object { $packed -notcontains $_ })
if ($absent.Count) { throw "The zip was written without $($absent -join ', ')." }
$extra = @($packed | Where-Object { $script:PackageFiles -notcontains $_ })
if ($extra.Count) { throw "The zip holds files nobody asked for: $($extra -join ', ')." }

$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256 -ErrorAction Stop).Hash

if ($Verify) {
    # A package that passes only where it was built proves nothing. Unpack it
    # somewhere else and run the self-tests from there.
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ("Dingo-verify-{0}" -f [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $scratch -Force -ErrorAction Stop | Out-Null
    try {
        [IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $scratch)
        $unpacked = Join-Path $scratch 'Dingo.ps1'
        foreach ($mode in @('-Version', '-SelfTest', '-UiSelfTest')) {
            $output = & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $unpacked $mode 2>&1
            if ($LASTEXITCODE -ne 0) { throw "The packaged build failed $mode : $($output -join ' ')" }
            Write-Host "  $mode  $(@($output)[-1])"
        }
    } finally { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ""
Write-Host "Built $zipPath"
Write-Host "  version  $version"
Write-Host "  files    $($packed.Count) ($($packed -join ', '))"
Write-Host "  size     $((Get-Item -LiteralPath $zipPath).Length) bytes"
Write-Host "  sha256   $hash"
Write-Host ""
Write-Host "Release it with:"
Write-Host "  gh release create v$version `"$zipPath`" --target main --title `"Dingo $version`" --notes-file <your notes>"

[PSCustomObject]@{ Path = $zipPath; Version = $version; Sha256 = $hash; Files = $packed }
