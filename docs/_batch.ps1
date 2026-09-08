$ErrorActionPreference = 'Continue'
$DocsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $DocsRoot
$Watch = Join-Path $Root 'Watch\Watch-PvssLog.ps1'
$cfg = Join-Path $Root 'Watch\watch-config.txt'
$cfgBefore = [System.IO.File]::ReadAllText($cfg)
$log = Join-Path $DocsRoot 'PVSS_II_Examples\PVSS_II_C1P.log'
$tmp = Join-Path $env:TEMP 'pvss_batch'
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Path $tmp | Out-Null

$pass = 0; $fail = 0
function Check($name, $cond, $detail = '') {
    if ($cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $name) -ForegroundColor Green }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $name, $detail) -ForegroundColor Red }
}

# Child process, because the script's operator-facing messages go to the host (Write-Host)
# and would not be captured in-process.
function Run($tag, $extra) {
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Watch,
        '-Report', '-NoPause', '-LogPath', $log)
    if (-not $extra.ContainsKey('NoOutPath')) { $argv += @('-OutPath', (Join-Path $tmp $tag)) }
    foreach ($k in $extra.Keys) {
        if ($k -eq 'NoOutPath') { continue }
        if ($extra[$k] -is [bool]) { if ($extra[$k]) { $argv += "-$k" } }
        else {
            $v = [string]$extra[$k]
            if ($v -match '\s') { $v = '"' + $v + '"' }
            $argv += @("-$k", $v)
        }
    }
    $stdout = Join-Path $tmp "$tag.console"
    $p = Start-Process powershell.exe -ArgumentList $argv -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError "$stdout.err"
    $txt = ''
    foreach ($f in @($stdout, "$stdout.err")) { if (Test-Path $f) { $txt += (Get-Content $f -Raw) } }
    return @{ Out = $txt; Code = $p.ExitCode }
}

Write-Host 'Batch mode' -ForegroundColor Cyan
$r = Run 'all' @{ Format = 'Both' }
Check 'All/Both exit 0' ($r.Code -eq 0) $r.Out
Check 'All writes .txt' (Test-Path "$tmp\all.txt")
Check 'All writes .html' (Test-Path "$tmp\all.html")

$r = Run 'sev' @{ Format = 'Text'; Organize = 'Severity'; Severities = '1,2,3'; TopN = 15 }
Check 'Severity exit 0' ($r.Code -eq 0) $r.Out
Check 'Severity writes only .txt' ((Test-Path "$tmp\sev.txt") -and -not (Test-Path "$tmp\sev.html"))
$sevTxt = Get-Content "$tmp\sev.txt" -Raw
Check 'Severity: module headlines present' ($sevTxt -match '--- Module headlines ---')
Check 'Severity: BACnet module absent' ($sevTxt -notmatch '--- BACnet module ---')
Check 'Severity: -Severities honoured' ($sevTxt -match 'Severities    : FATAL, SEVERE, ERROR\b')
Check 'Severity: -TopN honoured' ($sevTxt -match 'TopN          : 15')

$r = Run 'drv' @{ Format = 'Text'; Organize = 'Driver'; Driver = 'BACnet' }
Check 'Driver exit 0' ($r.Code -eq 0) $r.Out
$drvTxt = Get-Content "$tmp\drv.txt" -Raw
Check 'Driver: deep-dive present' ($drvTxt -match '--- Driver deep-dive ---')
Check 'Driver: name matched by substring' ($drvTxt -match '=== WCCOAGmsBACnet\(1\) ===')
Check 'Driver: severity patterns suppressed' ($drvTxt -notmatch '--- Top patterns by severity ---')

Write-Host 'Time windows' -ForegroundColor Cyan
$r = Run 'win' @{ Format = 'Text'; From = '2026.09.04 14:00'; To = '2026.09.04 15:00' }
Check 'From/To exit 0' ($r.Code -eq 0) $r.Out
$winTxt = Get-Content "$tmp\win.txt" -Raw
if ($winTxt -match 'Time span : (\S+ \S+)\s+-->\s+(\S+ \S+)') {
    Check 'From/To: window respected' (($Matches[1] -ge '2026.09.04 14:00') -and ($Matches[2] -le '2026.09.04 15:00:00.999')) ("$($Matches[1]) .. $($Matches[2])")
}
else { Check 'From/To: span line found' $false $winTxt.Substring(0, 400) }
$allTxt = Get-Content "$tmp\all.txt" -Raw
$allLines = if ($allTxt -match 'Lines     : ([\d,]+)') { [int](($Matches[1]) -replace ',') } else { -1 }
$winLines = if ($winTxt -match 'Lines     : ([\d,]+)') { [int](($Matches[1]) -replace ',') } else { -1 }
Check 'From/To: fewer lines than entire' ($winLines -gt 0 -and $winLines -lt $allLines) "$winLines vs $allLines"

$r = Run 'toonly' @{ Format = 'Text'; To = '2026.09.04' }
Check 'Date-only -To widens to end of day' ($r.Code -eq 0 -and (Get-Content "$tmp\toonly.txt" -Raw) -match 'Time span : 2026\.09\.04 12:34') $r.Out

$r = Run 'hrs' @{ Format = 'Text'; LastHours = 2 }
Check 'LastHours exit 0' ($r.Code -eq 0) $r.Out
$hrsLines = if ((Get-Content "$tmp\hrs.txt" -Raw) -match 'Lines     : ([\d,]+)') { [int](($Matches[1]) -replace ',') } else { -1 }
Check 'LastHours: fewer lines than entire' ($hrsLines -gt 0 -and $hrsLines -lt $allLines) "$hrsLines vs $allLines"

$r = Run 'lastmin' @{ Format = 'Text'; LastMinutes = 30 }
Check 'LastMinutes exit 0' ($r.Code -eq 0) $r.Out
Check 'LastMinutes: window label' ((Get-Content "$tmp\lastmin.txt" -Raw) -match 'Time mode     : last 30 minutes')

Write-Host 'Bad input' -ForegroundColor Cyan
$r = Run 'bad' @{ Format = 'Text'; From = 'not-a-date' }
Check 'Garbage -From exits 1' ($r.Code -eq 1) $r.Out
Check 'Garbage -From explains itself' ($r.Out -match "Invalid -From value 'not-a-date'")
$r = Run 'empty' @{ Format = 'Text'; From = '2030.01.01' }
Check '-From past end of log exits 1' ($r.Code -eq 1) $r.Out
Check '-From past end of log says empty window' ($r.Out -match 'Empty window')
$r = Run 'inverted' @{ Format = 'Text'; From = '2026.09.04 15:00'; To = '2026.09.04 13:00' }
Check '-From after -To exits 1' ($r.Code -eq 1) $r.Out

Write-Host 'Side effects' -ForegroundColor Cyan
Check 'watch-config.txt untouched' (([System.IO.File]::ReadAllText($cfg)) -eq $cfgBefore)
$r = Run 'defout' @{ Format = 'Text'; NoOutPath = $true }
$sib = $log + '.analysis.txt'
Check 'default OutPath sits next to the log' (Test-Path $sib) $r.Out
if (Test-Path $sib) { Remove-Item $sib -Force }

Write-Host ''
Write-Host ("PASS={0}  FAIL={1}" -f $pass, $fail) -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
exit $(if ($fail) { 1 } else { 0 })
