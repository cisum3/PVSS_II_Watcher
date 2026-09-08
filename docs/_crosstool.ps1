param([string[]]$Logs = @('PVSS_II_C1P.log', 'PVSS_II_Test.log'))
$ErrorActionPreference = 'Continue'
$DocsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $DocsRoot
$old = Join-Path $Root 'Watch\OfflineAnalyze\Analyze-PvssLog.ps1'
$new = Join-Path $Root 'Watch\Watch-PvssLog.ps1'
$tmp = Join-Path $env:TEMP 'pvss_cross'
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Path $tmp | Out-Null

function Get-Section([string]$Text, [string]$Header) {
    $lines = $Text -split "`r?`n"
    $out = New-Object System.Collections.Generic.List[string]
    $inSec = $false
    foreach ($l in $lines) {
        if ($l -eq $Header) { $inSec = $true; [void]$out.Add($l); continue }
        if ($inSec) {
            if ($l -match '^---\s' -and $l -ne $Header) { break }
            [void]$out.Add($l)
        }
    }
    return (($out -join "`n").TrimEnd())
}

foreach ($name in $Logs) {
    $log = Join-Path $DocsRoot ('PVSS_II_Examples\' + $name)
    Write-Host ''
    Write-Host ("=== {0} ===" -f $name) -ForegroundColor Cyan

    $oldOut = Join-Path $tmp ($name + '.old.txt')
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $old -NonInteractive -NoPause `
        -LogPath $log -OutPath $oldOut -Format Text *> (Join-Path $tmp "$name.old.console")
    $newOut = Join-Path $tmp ($name + '.new')
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $new -Report -NoPause -Entire `
        -LogPath $log -OutPath $newOut -Format Text *> (Join-Path $tmp "$name.new.console")

    if (-not (Test-Path $oldOut)) { Write-Host '  old report missing' -ForegroundColor Red; continue }
    if (-not (Test-Path "$newOut.txt")) { Write-Host '  new report missing' -ForegroundColor Red; continue }
    $o = [System.IO.File]::ReadAllText($oldOut)
    $n = [System.IO.File]::ReadAllText("$newOut.txt")

    foreach ($h in @('--- CNS module (thin) ---', '--- Apogee module ---')) {
        $so = Get-Section $o $h
        $sn = Get-Section $n $h
        if ($so -ceq $sn) { Write-Host ("  PASS  {0} byte-identical" -f $h) -ForegroundColor Green }
        else {
            Write-Host ("  DIFF  {0}" -f $h) -ForegroundColor Yellow
            $ol = $so -split "`n"; $nl = $sn -split "`n"
            for ($i = 0; $i -lt [math]::Max($ol.Count, $nl.Count); $i++) {
                $a = if ($i -lt $ol.Count) { $ol[$i] } else { '<eof>' }
                $b = if ($i -lt $nl.Count) { $nl[$i] } else { '<eof>' }
                if ($a -cne $b) { Write-Host ("        1.3 : {0}`n        2.4 : {1}" -f $a, $b) -ForegroundColor DarkYellow }
            }
        }
    }

    $oSecs = @(($o -split "`r?`n") | Where-Object { $_ -match '^---\s' })
    $nSecs = @(($n -split "`r?`n") | Where-Object { $_ -match '^---\s' })
    Write-Host ('  1.3 only : ' + ((@($oSecs | Where-Object { $nSecs -notcontains $_ })) -join ' | '))
    Write-Host ('  2.4 only : ' + ((@($nSecs | Where-Object { $oSecs -notcontains $_ })) -join ' | '))
    foreach ($h in @('--- Severity counts ---', '--- Performance-related keyword categories ---')) {
        $so = Get-Section $o $h; $sn = Get-Section $n $h
        Write-Host ("  {0} {1}" -f $(if ($so -ceq $sn) { 'PASS ' } else { 'DIFF ' }), $h) `
            -ForegroundColor $(if ($so -ceq $sn) { 'Green' } else { 'Yellow' })
        if ($so -cne $sn) {
            Write-Host ('        1.3: ' + ($so -replace "`n", ' / ')) -ForegroundColor DarkYellow
            Write-Host ('        2.4: ' + ($sn -replace "`n", ' / ')) -ForegroundColor DarkYellow
        }
    }
}
Write-Host ''
Write-Host ("artifacts: {0}" -f $tmp) -ForegroundColor DarkGray
