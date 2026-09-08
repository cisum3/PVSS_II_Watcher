$ErrorActionPreference = 'Continue'
$DocsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $DocsRoot
$log = Join-Path $DocsRoot 'PVSS_II_Examples\PVSS_II_C2P.log'
$tmp = Join-Path $env:TEMP 'pvss_perf'
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Path $tmp | Out-Null

$sw = [System.Diagnostics.Stopwatch]::StartNew()
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'Watch\OfflineAnalyze\Analyze-PvssLog.ps1') `
    -NonInteractive -NoPause -LogPath $log -OutPath (Join-Path $tmp 'old.txt') -Format Text *> (Join-Path $tmp 'old.console')
$oldSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)

$sw.Restart()
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'Watch\Watch-PvssLog.ps1') `
    -Report -NoPause -Entire -LogPath $log -OutPath (Join-Path $tmp 'new') -Format Text *> (Join-Path $tmp 'new.console')
$newSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)

Write-Host ("OfflineAnalyze 1.3 : {0,7:N1} s" -f $oldSec)
Write-Host ("Watch 2.4 -Report  : {0,7:N1} s  ({1:+0.0;-0.0;0.0}%)" -f $newSec, (100.0 * ($newSec - $oldSec) / $oldSec))
foreach ($f in @((Join-Path $tmp 'old.txt'), (Join-Path $tmp 'new.txt'))) {
    if (Test-Path $f) {
        $t = [System.IO.File]::ReadAllText($f)
        $n = if ($t -match 'Lines\s+: ([\d,]+)') { $Matches[1] } else { '?' }
        Write-Host ("  {0,-9} {1,10:N0} bytes  parsed={2}" -f (Split-Path -Leaf $f), (Get-Item $f).Length, $n)
    }
}
