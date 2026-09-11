[CmdletBinding()]
param(
    [string]$Dest
)

$pidFile = Join-Path $env:TEMP 'Dingo-P4-F04-child-pid.txt'
$hostPath = (Get-Process -Id $PID -ErrorAction Stop).Path
$child = Start-Process -FilePath $hostPath -ArgumentList @(
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    'Start-Sleep -Seconds 300'
) -PassThru -WindowStyle Hidden -ErrorAction Stop

[IO.File]::WriteAllText($pidFile, [string]$child.Id, (New-Object Text.UTF8Encoding($false)))
Write-Output "P4-F04 waiting fixture started child process $($child.Id)."
Start-Sleep -Seconds 300

