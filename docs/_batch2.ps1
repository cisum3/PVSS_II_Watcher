$ErrorActionPreference = 'Continue'
$DocsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $DocsRoot
$Watch = Join-Path $Root 'Watch\Watch-PvssLog.ps1'
$cfg = Join-Path $Root 'Watch\watch-config.txt'
$cfgBefore = [System.IO.File]::ReadAllText($cfg)
$src = Join-Path $DocsRoot 'PVSS_II_Examples\PVSS_II_Test.log'
$tmp = Join-Path $env:TEMP 'pvss_batch2'
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Path $tmp | Out-Null

$pass = 0; $fail = 0
function Check($name, $cond, $detail = '') {
    if ($cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $name) -ForegroundColor Green }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $name, $detail) -ForegroundColor Red }
}

# Runs Watch (or a .cmd launcher) as a child so Write-Host output and the exit code are both
# captured, optionally feeding it canned keystrokes for the -Interactive prompts.
function Run($tag, $exe, $argv, $workDir, $stdinLines) {
    $stdout = Join-Path $tmp "$tag.console"
    $p = @{ FilePath = $exe; NoNewWindow = $true; Wait = $true; PassThru = $true
        WorkingDirectory = $workDir; RedirectStandardOutput = $stdout
        RedirectStandardError = "$stdout.err"
    }
    if ($argv) { $p.ArgumentList = $argv }
    if ($null -ne $stdinLines) {
        $inFile = Join-Path $tmp "$tag.stdin"
        [System.IO.File]::WriteAllText($inFile, (($stdinLines -join "`r`n") + "`r`n"))
        $p.RedirectStandardInput = $inFile
    }
    $proc = Start-Process @p
    $txt = ''
    foreach ($f in @($stdout, "$stdout.err")) { if (Test-Path $f) { $txt += (Get-Content $f -Raw) } }
    return @{ Out = $txt; Code = $proc.ExitCode }
}

function RunWatch($tag, $extra, $workDir, $stdinLines) {
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Watch, '-Report', '-NoPause')
    foreach ($k in $extra.Keys) {
        if ($extra[$k] -is [bool]) { if ($extra[$k]) { $argv += "-$k" } }
        else {
            $v = [string]$extra[$k]
            if ($v -match '\s') { $v = '"' + $v + '"' }
            $argv += @("-$k", $v)
        }
    }
    return (Run $tag 'powershell.exe' $argv $workDir $stdinLines)
}

# --- log auto-discovery (acceptance 12) ----------------------------------------------
# Resolve-LogPath searches Watch\, the package root, and the cwd. Only the cwd is ours to
# plant files in, and neither of the other two holds a PVSS_II* log, so a temp cwd isolates
# each tier of the fallback chain.
Write-Host 'Log auto-discovery' -ForegroundColor Cyan

$d1 = Join-Path $tmp 'disc-exact'; New-Item -ItemType Directory -Path $d1 | Out-Null
Copy-Item $src (Join-Path $d1 'PVSS_II.log')
Copy-Item $src (Join-Path $d1 'PVSS_II.log.bak')
$r = RunWatch 'disc1' @{ Format = 'Text'; OutPath = (Join-Path $tmp 'disc1.txt') } $d1 $null
Check 'discovery: exact PVSS_II.log wins' ($r.Code -eq 0 -and $r.Out -match 'disc-exact\\PVSS_II\.log' -and $r.Out -notmatch 'backup log') $r.Out

$d2 = Join-Path $tmp 'disc-bak'; New-Item -ItemType Directory -Path $d2 | Out-Null
Copy-Item $src (Join-Path $d2 'PVSS_II.log.bak')
$r = RunWatch 'disc2' @{ Format = 'Text'; OutPath = (Join-Path $tmp 'disc2.txt') } $d2 $null
Check 'discovery: falls back to .bak' ($r.Code -eq 0 -and $r.Out -match 'Using backup log') $r.Out

$d3 = Join-Path $tmp 'disc-newest'; New-Item -ItemType Directory -Path $d3 | Out-Null
Copy-Item $src (Join-Path $d3 'PVSS_II_old.log')
Copy-Item $src (Join-Path $d3 'PVSS_II_new.log')
(Get-Item (Join-Path $d3 'PVSS_II_old.log')).LastWriteTime = (Get-Date).AddDays(-3)
$r = RunWatch 'disc3' @{ Format = 'Text'; OutPath = (Join-Path $tmp 'disc3.txt') } $d3 $null
Check 'discovery: newest PVSS_II*' ($r.Code -eq 0 -and $r.Out -match 'Using newest matching log.*PVSS_II_new\.log') $r.Out

$d4 = Join-Path $tmp 'disc-none'; New-Item -ItemType Directory -Path $d4 | Out-Null
$r = RunWatch 'disc4' @{ Format = 'Text' } $d4 $null
Check 'discovery: nothing found exits 1' ($r.Code -eq 1) $r.Out
Check 'discovery: error names the dirs searched' ($r.Out -match 'Log file not found' -and $r.Out -match 'Pass -LogPath explicitly') $r.Out

# --- launchers (acceptance 7) ----------------------------------------------------------
Write-Host 'Launchers' -ForegroundColor Cyan
$d5 = Join-Path $tmp 'cmd'; New-Item -ItemType Directory -Path $d5 | Out-Null
$cmdLog = Join-Path $d5 'PVSS_II.log'
Copy-Item $src $cmdLog

# %* forwarding, so -LogPath still reaches the script through the launcher.
$r = Run 'cmd1' 'cmd.exe' @('/c', (Join-Path $Root 'Run-Report.cmd'), '-LogPath', $cmdLog) $d5 $null
Check 'Run-Report.cmd exit 0' ($r.Code -eq 0) $r.Out
Check 'Run-Report.cmd writes HTML next to the log' (Test-Path "$cmdLog.analysis.html") $r.Out
Check 'Run-Report.cmd writes no .txt (-Format Html)' (-not (Test-Path "$cmdLog.analysis.txt"))
Check 'Run-Report.cmd binds no port' ($r.Out -notmatch 'http://127\.0\.0\.1') $r.Out

$r = Run 'cmd2' 'cmd.exe' @('/c', (Join-Path $Root 'Run-Report.cmd'), '-LogPath', 'C:\nope\missing.log') $d5 $null
Check 'Run-Report.cmd exits non-zero on failure' ($r.Code -ne 0) ("code=$($r.Code) " + $r.Out)

# --- interactive prompts (acceptance 8) -------------------------------------------------
# Read-Host reads redirected stdin, so the full V1.3 flow can be driven from a canned file.
Write-Host 'Interactive prompts' -ForegroundColor Cyan
$iArgs = @{ LogPath = $src; Interactive = $true }

# Enter through everything: Entire / All / Both.
$r = RunWatch 'i-def' ($iArgs + @{ OutPath = (Join-Path $tmp 'i-def') }) $tmp @('', '', '')
Check 'prompts: all defaults exit 0' ($r.Code -eq 0) $r.Out
Check 'prompts: window menu shown with span' ($r.Out -match 'Span:' -and $r.Out -match 'Time filter: \[E\] Entire') $r.Out
Check 'prompts: default = Entire + All + Both' ((Test-Path "$tmp\i-def.txt") -and (Test-Path "$tmp\i-def.html")) $r.Out
$defTxt = Get-Content "$tmp\i-def.txt" -Raw
Check 'prompts: Entire honoured' ($defTxt -match 'Time mode     : entire file') $defTxt

# H -> hours sub-prompt, rejecting a bad value first. The hour count is resolved against the
# end of the log into an absolute pair, so that is what the scan reports.
$r = RunWatch 'i-hrs' ($iArgs + @{ OutPath = (Join-Path $tmp 'i-hrs.txt') }) $tmp @('H', 'abc', '3', 'A', 'T')
Check 'prompts: [H] exit 0' ($r.Code -eq 0) $r.Out
Check 'prompts: [H] re-prompts on garbage' ($r.Out -match 'Enter a whole number of hours') $r.Out
Check 'prompts: [H] resolves to a 3h absolute window' ($r.Out -match 'last 3 hour\(s\) ending 2026\.05\.02 03:28:42' -and $r.Out -match 'mode=absolute 2026\.05\.02 00:28:42 -> 2026\.05\.02 03:28:42') $r.Out

# W -> both bounds, first one garbage so the re-prompt loop is exercised. Bounds must sit
# inside the sample log's span (2026.05.02 03:25:39 - 03:28:42) or the empty-window guard fires.
$r = RunWatch 'i-win' ($iArgs + @{ OutPath = (Join-Path $tmp 'i-win.txt') }) $tmp @('W', 'garbage', '2026.05.02 03:26', '2026.05.02 03:27', 'A', 'T')
Check 'prompts: [W] exit 0' ($r.Code -eq 0) $r.Out
Check 'prompts: [W] re-prompts on garbage bound' ($r.Out -match 'Examples: 2026\.09\.04 09:00') $r.Out
Check 'prompts: [W] bounds applied' ($r.Out -match 'mode=absolute 2026\.05\.02 03:26:00 -> 2026\.05\.02 03:27:00') $r.Out
$winTxt = if (Test-Path "$tmp\i-win.txt") { Get-Content "$tmp\i-win.txt" -Raw } else { '' }
Check 'prompts: [W] narrows the line count' (($winTxt -match 'Lines     : ([\d,]+)') -and [int](($Matches[1]) -replace ',') -lt 184) $r.Out

# An empty absolute window is refused rather than reported as a zero-line log.
$r = RunWatch 'i-win2' ($iArgs + @{ OutPath = (Join-Path $tmp 'i-win2.txt') }) $tmp @('W', '2030.01.01', '', 'A', 'T')
Check 'prompts: [W] out-of-range window exits 1' ($r.Code -eq 1 -and $r.Out -match 'Empty window') $r.Out

# Severity path: severity list then TopN.
$r = RunWatch 'i-sev' ($iArgs + @{ OutPath = (Join-Path $tmp 'i-sev.txt') }) $tmp @('', 'S', '1,2,3', '25', 'T')
Check 'prompts: [S] exit 0' ($r.Code -eq 0) $r.Out
$sevTxt = if (Test-Path "$tmp\i-sev.txt") { Get-Content "$tmp\i-sev.txt" -Raw } else { '' }
Check 'prompts: [S] severities applied' ($sevTxt -match 'Severities    : FATAL, SEVERE, ERROR\b') $r.Out
Check 'prompts: [S] TopN applied' ($sevTxt -match 'TopN          : 25') $r.Out
Check 'prompts: [S] organize applied' ($sevTxt -match 'Organize      : Severity') $r.Out

# Driver path: page forward, page back, then pick #1 from the first page.
$r = RunWatch 'i-drv' ($iArgs + @{ OutPath = (Join-Path $tmp 'i-drv.txt') }) $tmp @('', 'D', 'N', 'P', '1', 'T')
Check 'prompts: [D] exit 0' ($r.Code -eq 0) $r.Out
Check 'prompts: [D] picker paged' (([regex]::Matches($r.Out, 'Drivers/managers \(page ')).Count -ge 3) $r.Out
$drvTxt = if (Test-Path "$tmp\i-drv.txt") { Get-Content "$tmp\i-drv.txt" -Raw } else { '' }
Check 'prompts: [D] deep-dive rendered' ($drvTxt -match '--- Driver deep-dive ---') $r.Out

# Quit after the scan: exit 0, summary printed, nothing written.
$r = RunWatch 'i-quit' ($iArgs + @{ OutPath = (Join-Path $tmp 'i-quit.txt') }) $tmp @('', 'Q')
Check 'prompts: [Q] exits 0' ($r.Code -eq 0) $r.Out
Check 'prompts: [Q] writes no report' (-not (Test-Path "$tmp\i-quit.txt")) $r.Out
Check 'prompts: [Q] still prints the scan summary' ($r.Out -match 'Parsed [\d,]+ lines') $r.Out

# A supplied switch skips its prompt (PRD 7.3).
$r = RunWatch 'i-skip' ($iArgs + @{ OutPath = (Join-Path $tmp 'i-skip.txt'); Entire = $true; Organize = 'All'; Format = 'Text' }) $tmp @()
Check 'prompts: supplied switches skip their prompts' ($r.Code -eq 0 -and $r.Out -notmatch 'Time filter: \[E\]' -and $r.Out -notmatch 'Organize report:' -and $r.Out -notmatch 'Report format:') $r.Out

Write-Host 'Side effects' -ForegroundColor Cyan
Check 'watch-config.txt untouched' (([System.IO.File]::ReadAllText($cfg)) -eq $cfgBefore)
foreach ($leftover in @("$src.analysis.txt", "$src.analysis.html")) {
    if (Test-Path $leftover) { Remove-Item $leftover -Force }
}

Write-Host ''
Write-Host ("PASS={0}  FAIL={1}" -f $pass, $fail) -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
exit $(if ($fail) { 1 } else { 0 })
