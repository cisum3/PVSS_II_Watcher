#Requires -Version 5.1
<#
.SYNOPSIS
  Self-tests for Watch (no browser). Lives in docs\; package root is its parent.
#>
param(
    [ValidateSet('Assets', 'Rules', 'Api', 'Control', 'Modules', 'Snapshot', 'Report', 'All')]
    [string]$Phase = 'All',
    [string]$LogPath = '',
    [int]$Port = 8799
)

$ErrorActionPreference = 'Stop'
$DocsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $DocsRoot
$WatchRoot = Join-Path $Root 'Watch'
$ExamplesRoot = Join-Path $DocsRoot 'PVSS_II_Examples'
$failed = 0
function Ok($m) { Write-Host "  PASS  $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL  $m" -ForegroundColor Red; $script:failed++ }

if (-not $LogPath) {
    $cand = Join-Path $ExamplesRoot 'PVSS_II_C1P.log'
    if (Test-Path -LiteralPath $cand) { $LogPath = $cand }
}

Write-Host "=== Self-test phase $Phase ===" -ForegroundColor Cyan

if ($Phase -eq 'Assets' -or $Phase -eq 'All') {
    Write-Host "`n[Assets] UI shell assets"
    if (-not (Test-Path -LiteralPath $WatchRoot)) { Bad 'Watch\ payload folder missing' }
    foreach ($f in @(
            'ui\index.html', 'ui\app.css', 'ui\app.js', 'ui\vendor\chart.umd.min.js'
        )) {
        $p = Join-Path $WatchRoot $f
        if (Test-Path -LiteralPath $p) { Ok "Watch\$f" } else { Bad "missing Watch\$f" }
    }
    $html = Get-Content (Join-Path $WatchRoot 'ui\index.html') -Raw
    if ($html -match 'id="chrome"' -and $html -match 'data-view="overview"' -and $html -match 'chart.umd.min.js' -and $html -match 'btnSnapshot') {
        Ok 'index has chrome, nav, chart script, Snapshot'
    }
    else { Bad 'index missing expected structure' }
    $css = Get-Content (Join-Path $WatchRoot 'ui\app.css') -Raw
    if ($css -match '--siemens-petrol' -and $css -match '--bg-deep' -and $css -match '--sev-fatal') {
        Ok 'Siemens + severity CSS tokens'
    }
    else { Bad 'app.css missing theme tokens' }
    $js = Get-Content (Join-Path $WatchRoot 'ui\app.js') -Raw
    if ($js -match 'mockPulse' -and $js -match '/api/pulse' -and $js -match '/api/section' -and $js -match '/api/manager' -and $js -match '/api/snapshot') {
        Ok 'app.js pulse/section/manager/snapshot + mock'
    }
    else { Bad 'app.js incomplete' }
    if (Test-Path -LiteralPath (Join-Path $Root 'Run-Watch.cmd')) { Ok 'Run-Watch.cmd at package root' } else { Bad 'Run-Watch.cmd missing at root' }

    # The .ps1 files carry no BOM, so PS 5.1 decodes them as Windows-1252. A literal non-ASCII
    # character therefore reaches the HTML report as mojibake ('...' rendered as 'a,-|'). Keep the
    # sources ASCII-only and spell such characters as HTML entities instead.
    $nonAscii = @()
    foreach ($f in @('Watch-PvssLog.ps1', 'PvssRules.ps1')) {
        $p = Join-Path $WatchRoot $f
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $n = 0
        foreach ($line in [System.IO.File]::ReadAllLines($p, [System.Text.Encoding]::UTF8)) {
            $n++
            if ($line -match '[^\x00-\x7F]') { $nonAscii += ('{0}:{1}' -f $f, $n) }
        }
    }
    if ($nonAscii.Count -eq 0) { Ok 'PowerShell sources are ASCII-only' }
    else { Bad ('non-ASCII in PowerShell source: ' + ($nonAscii -join ', ')) }
}

if ($Phase -eq 'Assets') {
    if ($failed -gt 0) { throw "Assets self-test failed ($failed)" }
    Write-Host "`nAssets OK" -ForegroundColor Green
    exit 0
}

if ($Phase -eq 'Rules' -or $Phase -eq 'All') {
    Write-Host "`n[Rules] Declarative rule engine (offline, no host)"

    # Load Watch's function library without the listener: everything above "# --- main ---".
    $watchSrc = Get-Content -LiteralPath (Join-Path $WatchRoot 'Watch-PvssLog.ps1') -Raw
    $cut = $watchSrc.IndexOf('# --- main ---')
    if ($cut -lt 0) { throw 'Watch-PvssLog.ps1: "# --- main ---" marker not found' }
    $libPath = Join-Path $WatchRoot ('_selftest_lib_{0}.ps1' -f [guid]::NewGuid().ToString('N'))
    Set-Content -LiteralPath $libPath -Value $watchSrc.Substring(0, $cut) -Encoding UTF8
    # The library still carries Watch's own param() block, and dot-sourcing rebinds those
    # parameters in this scope - silently resetting our identically named ones to Watch's
    # defaults. Under -Phase All that left the later phases with no log and the wrong port.
    $ownParams = @{}
    foreach ($p in $MyInvocation.MyCommand.Parameters.Keys) {
        $ownParams[$p] = (Get-Variable -Name $p -Scope Script -ErrorAction SilentlyContinue).Value
    }
    try {
        . $libPath
        foreach ($p in $ownParams.Keys) { Set-Variable -Name $p -Scope Script -Value $ownParams[$p] }

        $ids = @($script:PvssRules | ForEach-Object { $_['Id'] })
        $shapeBad = @($script:PvssRules | Where-Object { -not $_['Id'] -or -not $_['Group'] -or -not $_['Label'] -or -not ($_['Re'] -is [regex]) })
        if ($shapeBad.Count -eq 0) { Ok "rule shape valid ($($ids.Count) rules)" }
        else { Bad "$($shapeBad.Count) rule(s) missing Id/Group/Label/Re" }
        if (($ids | Sort-Object -Unique).Count -eq $ids.Count) { Ok 'rule Ids unique' } else { Bad 'duplicate rule Id' }

        function Test-Lines {
            param([string[]]$Lines)
            $d = New-EmptyState
            foreach ($l in $Lines) { Process-LogLine -Line $l -Data $d }
            return $d
        }
        $ts1 = '2026.01.01 10:00:00.000'
        $ts2 = '2026.01.01 10:05:00.000'

        # Scope gating: ApogeeDrv rules must not fire for other components.
        $d = Test-Lines @(
            "WCCOAui, $ts1, IMPL, WARNING, 1, Trend buffer overflow for trend T1 in device D1"
        )
        if ((Get-RuleCount -Data $d -Id 'apogeeDrv.trendOverflow') -eq 0) { Ok 'Scope gate blocks out-of-scope rule' }
        else { Bad 'Scope gate leaked' }

        # Counting, buckets, per-bucket TrimEnd, shared sample slot, first/last, severity mix.
        $d = Test-Lines @(
            "WCCOAApogeeDrv, $ts1, IMPL, WARNING, 1, Trend buffer overflow for trend T1 in device D1"
            "WCCOAApogeeDrv, $ts1, IMPL, ERROR, 1, Trend buffer overflow for trend T2 in device D1.."
            "WCCOAApogeeDrv, $ts2, IMPL, WARNING, 1, Last sequence number 7 is greater than saved"
            "WCCOAApogeeDrv, $ts2, IMPL, ERROR, 1, Failed to get data for object OBJ1 on device D9"
        )
        if ((Get-RuleCount -Data $d -Id 'apogeeDrv.trendOverflow') -eq 2) { Ok 'rule count' } else { Bad 'rule count' }
        $devs = Get-RuleBucketMap -Data $d -Id 'apogeeDrv.trendOverflow' -Name 'device'
        if ($devs.Count -eq 1 -and $devs['D1'] -eq 2) { Ok 'BucketBy + per-bucket TrimEnd collapses D1.. to D1' }
        else { Bad "BucketBy/TrimEnd (got $($devs.Keys -join ','))" }
        if ((Get-RuleBucketCount -Data $d -Id 'apogeeDrv.trendOverflow' -Name 'trend') -eq 2) { Ok 'second bucket dimension' }
        else { Bad 'trend bucket' }
        $samp = Get-RuleSample -Data $d -Id 'apogeeDrv.trend'
        if ($samp -match 'trend T1 in device D1') { Ok 'SampleSlot keeps first line across sharing rules' }
        else { Bad 'shared SampleSlot' }
        $t = $d.HitTime['apogeeDrv.trendOverflow']
        if ($t.First -eq $ts1 -and $t.Last -eq $ts1) { Ok 'HitTime first/last' } else { Bad 'HitTime' }
        $sev = $d.HitSevs['apogeeDrv.trendOverflow']
        if ($sev['WARNING'] -eq 1 -and $sev['ERROR'] -eq 1) { Ok 'HitSevs severity mix' } else { Bad 'HitSevs' }

        # Curated payloads still read the frozen keys off the engine.
        $script:Sync['Data'] = $d
        $ap = (Build-SectionObject -Name 'apogee' -SevFilter @() -TopN 10).apogee
        if ($ap.trendOverflow -eq 2 -and $ap.trendSeq -eq 1 -and $ap.getDataFail -eq 1 -and
            $ap.trendDevices -eq 1 -and $ap.trendNames -eq 2 -and $ap.getDataSample) {
            Ok 'curated Apogee payload keys unchanged'
        }
        else { Bad 'Apogee payload' }

        $d = Test-Lines @(
            "WCCOAui, $ts1, IMPL, WARNING, 1, TryRenewSession failed, ResolveNodes pending"
            "WCCOAui, $ts2, IMPL, WARNING, 1, ReducedFunction on ICns.get"
        )
        $script:Sync['Data'] = $d
        $cns = (Build-SectionObject -Name 'cns' -SevFilter @() -TopN 10).cns
        if ($cns.tryRenew -eq 1 -and $cns.resolveNodes -eq 1 -and $cns.reducedFunction -eq 1 -and $cns.icns -eq 1) {
            Ok 'curated CNS payload keys unchanged'
        }
        else { Bad 'CNS payload' }
        if ($cns.patterns.Count -ge 1) { Ok 'PatternGroup still feeds CNS pattern map' } else { Bad 'CNS patterns' }

        # Header-token buckets and Measure aggregation (used by rules added in 2.4).
        $script:PvssRules += @{
            Id = 'selftest.measure'; Group = 'SelfTest'; Label = 'self-test'
            Re = [regex]'Repetition \(\#=(\d+)\) of a former trace'
            BucketBy = @{ manager = '$component'; area = '$area' }
            Measure = @{ repeats = @{ Group = 1; Agg = 'Sum' }; worst = @{ Group = 1; Agg = 'Max' } }
        }
        $script:RuleSetCache = @{}
        $d = Test-Lines @(
            "WCCOAui, $ts1, IMPL, WARNING, 1, Repetition (#=5) of a former trace"
            "WCCOAui, $ts2, CTRL, WARNING, 1, Repetition (#=12) of a former trace"
        )
        $mgr = Get-RuleBucketMap -Data $d -Id 'selftest.measure' -Name 'manager'
        # Not $areas: dot-sourcing the library brings Watch's [string]$Areas parameter into
        # this scope, and the type constraint would stringify the map.
        $areaMap = Get-RuleBucketMap -Data $d -Id 'selftest.measure' -Name 'area'
        if ($mgr['WCCOAui'] -eq 2 -and $areaMap['IMPL'] -eq 1 -and $areaMap['CTRL'] -eq 1) { Ok 'BucketBy header tokens' }
        else { Bad 'header-token buckets' }
        if ((Get-RuleMeasure -Data $d -Id 'selftest.measure' -Name 'repeats') -eq 17 -and
            (Get-RuleMeasure -Data $d -Id 'selftest.measure' -Name 'worst') -eq 12) { Ok 'Measure Sum + Max' }
        else { Bad 'Measure aggregation' }

        # --- detections payload (PRD 6.2) ---
        $det = Build-DetectionsObject -Data $d -TopN 10
        $grp = @($det | Where-Object { $_.group -eq 'SelfTest' })
        if ($grp.Count -eq 1 -and $grp[0].total -eq 2) { Ok 'detections groups by rule Group' }
        else { Bad 'detections grouping' }
        $row = $grp[0].rules[0]
        if ($row.id -eq 'selftest.measure' -and $row.count -eq 2 -and
            $row.measures.repeats -eq 17 -and $row.buckets.manager.distinct -eq 1 -and
            $row.buckets.manager.top[0].value -eq 'WCCOAui') { Ok 'detections row shape' }
        else { Bad 'detections row shape' }
        if (-not $row.buckets.manager.capped) { Ok 'detections reports bucket cap state' } else { Bad 'capped flag' }

        # Curated groups render in their own card, so they must not appear twice.
        $d2 = Test-Lines @(
            "WCCOAApogeeDrv, $ts1, IMPL, WARNING, 1, Trend buffer overflow for trend T1 in device D1"
            "WCCOAui, $ts1, IMPL, WARNING, 1, TryRenewSession failed"
        )
        $det2 = Build-DetectionsObject -Data $d2 -TopN 10
        $leaked = @($det2 | Where-Object { $script:CuratedGroups -contains $_.group })
        if ($leaked.Count -eq 0) { Ok 'CuratedGroups excluded from detections' }
        else { Bad "curated group leaked: $($leaked.group -join ',')" }

        # Zero-hit rules are omitted, so an empty window produces an empty array.
        $emptyDet = Build-DetectionsObject -Data (New-EmptyState) -TopN 10
        if (@($emptyDet).Count -eq 0) { Ok 'zero-hit rules omitted' } else { Bad 'zero-hit rules present' }

        # Ordering must be stable or the 10.1 byte-identical HTML check is meaningless.
        $a1 = (Build-DetectionsObject -Data $d -TopN 10 | ConvertTo-Json -Depth 10)
        $a2 = (Build-DetectionsObject -Data $d -TopN 10 | ConvertTo-Json -Depth 10)
        if ($a1 -ceq $a2) { Ok 'detections output deterministic' } else { Bad 'detections ordering unstable' }

        # A rule with no FindingAt still renders; it just carries no threshold badge.
        if ($row.findingAt -eq 0 -and $row.over -eq 0) { Ok 'no-threshold rule reports findingAt 0' }
        else { Bad "unthresholded rule: findingAt=$($row.findingAt) over=$($row.over)" }

        # --- ranking: intensity, not volume ---
        # The lower-volume burst must outrank the higher-volume trickle. Sorting by count would
        # invert this, which is exactly the corpus failure (a 4h driver outage buried under
        # three weeks of trace chatter).
        $script:PvssRules += @{ Id = 'selftest.burst'; Group = 'SelfTestRank'; Label = 'burst'
            FindingAt = 2; Re = [regex]'SELFTEST-BURST' }
        $script:PvssRules += @{ Id = 'selftest.trickle'; Group = 'SelfTestRank'; Label = 'trickle'
            FindingAt = 250; Re = [regex]'SELFTEST-TRICKLE' }
        $script:PvssRules += @{ Id = 'selftest.quiet'; Group = 'SelfTestQuiet'; Label = 'quiet'
            FindingAt = 10; Re = [regex]'SELFTEST-QUIET' }
        $script:RuleSetCache = @{}
        $dr = Test-Lines @(
            'WCCOAui, 2026.09.04 10:00:00.000, IMPL, SEVERE, 1, SELFTEST-BURST'
            'WCCOAui, 2026.09.04 10:00:05.000, IMPL, SEVERE, 1, SELFTEST-BURST'
            'WCCOAui, 2026.09.04 10:00:10.000, IMPL, SEVERE, 1, SELFTEST-BURST'
            'WCCOAui, 2026.09.04 10:00:00.000, IMPL, SEVERE, 1, SELFTEST-TRICKLE'
            'WCCOAui, 2026.09.04 12:00:00.000, IMPL, SEVERE, 1, SELFTEST-TRICKLE'
            'WCCOAui, 2026.09.04 14:00:00.000, IMPL, SEVERE, 1, SELFTEST-TRICKLE'
            'WCCOAui, 2026.09.04 16:00:00.000, IMPL, SEVERE, 1, SELFTEST-TRICKLE'
            'WCCOAui, 2026.09.04 18:00:00.000, IMPL, SEVERE, 1, SELFTEST-TRICKLE'
            'WCCOAui, 2026.09.04 10:00:00.000, IMPL, INFO, 1, SELFTEST-QUIET'
            'WCCOAui, 2026.09.04 18:00:00.000, IMPL, INFO, 1, SELFTEST-QUIET'
        )
        $allDet = @(Build-DetectionsObject -Data $dr -TopN 10)
        $rank = @($allDet | Where-Object { $_.group -eq 'SelfTestRank' })[0]
        $burst = @($rank.rules | Where-Object { $_.id -eq 'selftest.burst' })[0]
        $trickle = @($rank.rules | Where-Object { $_.id -eq 'selftest.trickle' })[0]
        if ($burst.count -lt $trickle.count -and $rank.rules[0].id -eq 'selftest.burst') {
            Ok 'detections rank by rate, not volume'
        }
        else { Bad ('rank order: ' + (@($rank.rules | ForEach-Object { $_.id }) -join ',')) }

        # Sub-minute spans are floored so two hits a second apart cannot top the list.
        if ($burst.spanSec -eq 60 -and $trickle.spanSec -eq 28800) { Ok 'span floor + real span' }
        else { Bad "spanSec burst=$($burst.spanSec) trickle=$($trickle.spanSec)" }

        if ($burst.over -eq 1.5 -and $trickle.over -eq 0.02) { Ok 'over = count / FindingAt' }
        else { Bad "over burst=$($burst.over) trickle=$($trickle.over)" }

        # Groups follow their own worst rule, so the noisy group leads.
        $gi = @($allDet | ForEach-Object { [string]$_.group })
        $gs = @($allDet | ForEach-Object { [double]$_.score })
        $desc = $true
        for ($i = 1; $i -lt $gs.Count; $i++) { if ($gs[$i] -gt $gs[$i - 1]) { $desc = $false } }
        if ($desc -and $gi[0] -eq 'SelfTestRank') { Ok 'groups ordered by worst rule' }
        else { Bad ('group order: ' + ($gi -join ',')) }

        # FindingAt is opt-in; the migrated clusters must not have grown a duplicate headline.
        $withThreshold = @($script:PvssRules | Where-Object { $_['FindingAt'] })
        $curatedWithThreshold = @($withThreshold | Where-Object { $script:CuratedGroups -contains $_['Group'] })
        if ($withThreshold.Count -gt 0 -and $curatedWithThreshold.Count -eq 0) { Ok 'FindingAt only on non-curated rules' }
        else { Bad 'FindingAt on a curated rule would double-report' }
    }
    finally {
        Remove-Item -LiteralPath $libPath -Force -ErrorAction SilentlyContinue
    }
}

if ($Phase -eq 'Rules') {
    if ($failed -gt 0) { throw "Rules self-test failed ($failed)" }
    Write-Host "`nRules OK" -ForegroundColor Green
    exit 0
}

# Start host for Api / Control / Modules / Snapshot
$watch = Join-Path $WatchRoot 'Watch-PvssLog.ps1'
if (-not (Test-Path -LiteralPath $watch)) { throw 'Watch\Watch-PvssLog.ps1 missing' }

Write-Host "`nStarting host on port $Port (NoBrowser)..."
$arg = "-NoProfile -ExecutionPolicy Bypass -File `"$watch`" -Port $Port -NoBrowser -NoPause"
$proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $arg -WorkingDirectory $WatchRoot -WindowStyle Hidden -PassThru

$ready = $false
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    if ($proc.HasExited) {
        throw "Host exited early with code $($proc.ExitCode)"
    }
    try {
        $h = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/api/health" -UseBasicParsing -TimeoutSec 2
        if ($h.StatusCode -eq 200) { $ready = $true; break }
    }
    catch { }
}
if (-not $ready) {
    try { Stop-Process -Id $proc.Id -Force } catch {}
    throw "Host did not become ready on port $Port"
}

function Invoke-Api {
    param([string]$Url, [string]$Method = 'GET', [string]$Body = $null)
    if ($Method -eq 'GET') {
        return (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 180).Content
    }
    try {
        return (Invoke-WebRequest -Uri $Url -Method $Method -Body $Body -ContentType 'application/json' -UseBasicParsing -TimeoutSec 180).Content
    }
    catch {
        $resp = $_.Exception.Response
        if ($resp) {
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $txt = $sr.ReadToEnd()
            $sr.Close()
            throw $txt
        }
        throw
    }
}

$base = "http://127.0.0.1:$Port"
$job = $null
try {
    if ($Phase -eq 'Api' -or $Phase -eq 'All') {
        Write-Host "`n[Api] Host + pulse/section"
        $health = Invoke-Api "$base/api/health" | ConvertFrom-Json
        if ($health.ok -and $health.port -eq $Port) { Ok "health port=$($health.port)" } else { Bad 'health' }

        $idx = Invoke-Api "$base/"
        if ($idx -match 'PVSS Log Watch') { Ok 'serves index.html' } else { Bad 'static ui' }

        if (-not $LogPath -or -not (Test-Path -LiteralPath $LogPath)) {
            Bad "test log missing: $LogPath"
        }
        else {
            $body = (@{ path = $LogPath; lastMinutes = 10080 } | ConvertTo-Json -Compress)
            $start = Invoke-Api "$base/api/logPath" -Method POST -Body $body | ConvertFrom-Json
            if ($start.ok) { Ok 'POST /api/logPath catch-up started' } else { Bad 'logPath' }

            # Catch-up is chunked async — poll until loading clears (progress % available while loading).
            $pulse = $null
            $sawPct = $false
            for ($w = 0; $w -lt 600; $w++) {
                Start-Sleep -Milliseconds 100
                $pulse = Invoke-Api "$base/api/pulse?lastMinutes=10080&severities=FATAL,SEVERE,ERROR,WARNING" | ConvertFrom-Json
                if ($pulse.loading -and $null -ne $pulse.loadProgressPct) { $sawPct = $true }
                if (-not $pulse.loading) { break }
            }
            if ($pulse.loading) { Bad 'catch-up still loading after wait' }
            elseif ($null -ne $pulse.generation -and $pulse.severityCounts) {
                $spanOk = $pulse.window -and $pulse.window.first -and $pulse.window.last
                Ok "pulse gen=$($pulse.generation) findings=$($pulse.findings.Count)$(if ($sawPct) { ' (saw %)' } else { '' })$(if ($spanOk) { ' span=yes' } else { '' })"
            }
            else { Bad 'pulse shape' }

            $sec = Invoke-Api "$base/api/section?name=patterns&lastMinutes=10080&severities=FATAL,SEVERE,ERROR,WARNING" | ConvertFrom-Json
            if ($sec.patternsBySeverity) { Ok 'section patterns' } else { Bad 'section patterns' }
        }
    }

    if ($Phase -eq 'Control' -or $Phase -eq 'All') {
        Write-Host "`n[Control] Control + tail resilience"
        $p1 = Invoke-Api "$base/api/control" -Method POST -Body '{"action":"pause"}' | ConvertFrom-Json
        $h1 = Invoke-Api "$base/api/health" | ConvertFrom-Json
        if ($h1.paused) { Ok 'pause' } else { Bad 'pause' }

        $p2 = Invoke-Api "$base/api/control" -Method POST -Body '{"action":"resume"}' | ConvertFrom-Json
        $h2 = Invoke-Api "$base/api/health" | ConvertFrom-Json
        if (-not $h2.paused) { Ok 'resume' } else { Bad 'resume' }

        # append a line to a temp copy to test tail — use original if writable share
        # Prefer copy beside script for append test
        $tmp = Join-Path $ExamplesRoot '_watch_tail_test.log'
        if ($LogPath -and (Test-Path $LogPath)) {
            # small file: copy first 200KB then start on copy, append
            $fs = [System.IO.File]::OpenRead($LogPath)
            $buf = New-Object byte[] ([math]::Min(400000, $fs.Length))
            [void]$fs.Read($buf, 0, $buf.Length)
            $fs.Close()
            [System.IO.File]::WriteAllBytes($tmp, $buf)
            $body = (@{ path = $tmp; lastMinutes = 10080 } | ConvertTo-Json -Compress)
            [void](Invoke-Api "$base/api/logPath" -Method POST -Body $body)
            for ($w = 0; $w -lt 600; $w++) {
                Start-Sleep -Milliseconds 100
                $pWait = Invoke-Api "$base/api/pulse?lastMinutes=10080&severities=FATAL,SEVERE,ERROR,WARNING,INFO" | ConvertFrom-Json
                if (-not $pWait.loading) { break }
            }
            $before = (Invoke-Api "$base/api/pulse?lastMinutes=10080&severities=FATAL,SEVERE,ERROR,WARNING,INFO" | ConvertFrom-Json).generation
            $line = "TailTestMgr, 2099.01.01 12:00:00.000, IMPL, SEVERE, 1, Self-test tail line unique-xyz-4242`r`n"
            [System.IO.File]::AppendAllText($tmp, $line, [System.Text.Encoding]::UTF8)
            $saw = $false
            for ($i = 0; $i -lt 40; $i++) {
                Start-Sleep -Milliseconds 100
                # poke host by requesting health (host tails between requests)
                [void](Invoke-Api "$base/api/health")
                $pulse = Invoke-Api "$base/api/pulse?lastMinutes=10080&severities=FATAL,SEVERE,ERROR,WARNING,INFO" | ConvertFrom-Json
                if ($pulse.generation -gt $before) { $saw = $true; break }
            }
            if ($saw) { Ok 'tail picks up appended line (generation bump)' } else { Bad 'tail did not advance generation' }

            # rotate simulation: truncate file
            [System.IO.File]::WriteAllText($tmp, $line, [System.Text.Encoding]::UTF8)
            $rotated = $false
            for ($i = 0; $i -lt 40; $i++) {
                Start-Sleep -Milliseconds 100
                [void](Invoke-Api "$base/api/health")
                $h = Invoke-Api "$base/api/health" | ConvertFrom-Json
                $pulse = Invoke-Api "$base/api/pulse?lastMinutes=10080&severities=FATAL,SEVERE,ERROR,WARNING" | ConvertFrom-Json
                if ($pulse.rotated -or $h.tailRunning) { $rotated = $true; break }
            }
            if ($rotated) { Ok 'rotate/reopen path exercised' } else { Bad 'rotate not observed' }
        }

        $r = Invoke-Api "$base/api/control" -Method POST -Body '{"action":"restart"}' | ConvertFrom-Json
        $h3 = Invoke-Api "$base/api/health" | ConvertFrom-Json
        if (-not $h3.tailRunning -and [string]::IsNullOrEmpty($h3.logPath)) { Ok 'restart clears session' } else { Bad 'restart' }

        # bad path
        try {
            [void](Invoke-Api "$base/api/logPath" -Method POST -Body '{"path":"C:\\no\\such\\PVSS_II.log"}')
            Bad 'expected error for missing path'
        }
        catch { Ok 'missing path returns error' }
    }

    if ($Phase -eq 'Modules' -or $Phase -eq 'All') {
        Write-Host "`n[Modules] Modules + manager drill-down + charts data"
        if (-not $LogPath) { Bad 'no log for Modules' }
        else {
            $body = (@{ path = $LogPath; window = 'entire' } | ConvertTo-Json -Compress)
            # entire on 7MB C1P is OK; if huge, still try lastMinutes
            if ((Get-Item $LogPath).Length -gt 15MB) {
                $body = (@{ path = $LogPath; lastMinutes = 120 } | ConvertTo-Json -Compress)
            }
            [void](Invoke-Api "$base/api/logPath" -Method POST -Body $body)
            $pulse = $null
            for ($w = 0; $w -lt 600; $w++) {
                Start-Sleep -Milliseconds 100
                $pulse = Invoke-Api "$base/api/pulse?lastMinutes=120&severities=FATAL,SEVERE,ERROR,WARNING" | ConvertFrom-Json
                if (-not $pulse.loading) { break }
            }
            if ($pulse.loading) { Bad 'Modules catch-up still loading' }
            elseif ($pulse.series.byMinute) {
                $g = $pulse.series.granularity
                Ok "series buckets=$($pulse.series.byMinute.Count) gran=$g"
            }
            else { Bad 'series' }

            # File-end anchor: short window on an old example log should still yield data.
            $body120 = (@{ path = $LogPath; lastMinutes = 120 } | ConvertTo-Json -Compress)
            [void](Invoke-Api "$base/api/logPath" -Method POST -Body $body120)
            $p120 = $null
            for ($w = 0; $w -lt 600; $w++) {
                Start-Sleep -Milliseconds 100
                $p120 = Invoke-Api "$base/api/pulse?lastMinutes=120&severities=FATAL,SEVERE,ERROR,WARNING" | ConvertFrom-Json
                if (-not $p120.loading) { break }
            }
            if ($p120.loading) { Bad '120m catch-up still loading' }
            elseif ($p120.window.first -and $p120.severityCounts -and (
                    [int]$p120.severityCounts.FATAL + [int]$p120.severityCounts.SEVERE +
                    [int]$p120.severityCounts.ERROR + [int]$p120.severityCounts.WARNING) -gt 0) {
                Ok "file-end 120m window has data ($($p120.window.first) → $($p120.window.last))"
            }
            else { Bad 'file-end 120m window empty (anchor broken?)' }

            foreach ($sec in @('bacnet', 'cns', 'coho', 'apogee', 'managers', 'perf')) {
                try {
                    $j = Invoke-Api "$base/api/section?name=$sec&lastMinutes=120&severities=FATAL,SEVERE,ERROR,WARNING" | ConvertFrom-Json
                    if ($null -ne $j.generation) { Ok "section $sec" } else { Bad "section $sec" }
                }
                catch {
                    Bad "section $sec ($($_.Exception.Message))"
                }
            }

            $mgrs = Invoke-Api "$base/api/section?name=managers&lastMinutes=120&severities=FATAL,SEVERE,ERROR,WARNING" | ConvertFrom-Json
            if ($mgrs.managers -and $mgrs.managers.Count -gt 0) {
                $name = $mgrs.managers[0].name
                $enc = [uri]::EscapeDataString($name)
                $md = Invoke-Api "$base/api/manager?name=$enc&lastMinutes=120&severities=FATAL,SEVERE,ERROR,WARNING" | ConvertFrom-Json
                if ($md.name -eq $name -and $md.patternsBySeverity) { Ok "manager drill-down: $name" } else { Bad 'manager drill-down' }
            }
            else { Bad 'no managers discovered' }

            # INFO off but bacnet headlines still present possible
            $p2 = Invoke-Api "$base/api/pulse?lastMinutes=120&severities=FATAL,SEVERE,ERROR,WARNING" | ConvertFrom-Json
            if ($null -ne $p2.moduleHeadlines.bacnet) { Ok 'BACnet headlines present with INFO filter off' } else { Bad 'bacnet headlines' }
        }
    }

    if ($Phase -eq 'Snapshot' -or $Phase -eq 'All') {
        Write-Host "`n[Snapshot] Snapshot download"
        if (-not $LogPath -or -not (Test-Path -LiteralPath $LogPath)) {
            Bad 'no log for Snapshot phase'
        }
        else {
            $body = (@{ path = $LogPath; lastMinutes = 120 } | ConvertTo-Json -Compress)
            if ((Get-Item $LogPath).Length -le 15MB) {
                $body = (@{ path = $LogPath; window = 'entire' } | ConvertTo-Json -Compress)
            }
            [void](Invoke-Api "$base/api/logPath" -Method POST -Body $body)
            $pulse = $null
            for ($w = 0; $w -lt 600; $w++) {
                Start-Sleep -Milliseconds 100
                $pulse = Invoke-Api "$base/api/pulse?lastMinutes=120&severities=FATAL,SEVERE,ERROR,WARNING" | ConvertFrom-Json
                if (-not $pulse.loading) { break }
            }
            if ($pulse.loading) { Bad 'Snapshot catch-up still loading' }
            else {
                $outHtml = Join-Path $ExamplesRoot '_snapshot_selftest.html'
                $outJson = Join-Path $ExamplesRoot '_snapshot_selftest.json'
                try {
                    $snapUrl = "$base/api/snapshot?format=html&lastMinutes=120&severities=FATAL,SEVERE,ERROR,WARNING"
                    $resp = Invoke-WebRequest -Uri $snapUrl -UseBasicParsing -TimeoutSec 120
                    if ($resp.StatusCode -ne 200) { Bad "snapshot html status $($resp.StatusCode)" }
                    elseif ($resp.Headers['Content-Disposition'] -notmatch 'attachment') { Bad 'snapshot missing Content-Disposition attachment' }
                    elseif ($resp.Content -notmatch 'PVSS Log Watch' -or $resp.Content -notmatch '--siemens-petrol') { Bad 'snapshot html missing brand/theme' }
                    elseif ($resp.Content -match '<th>Bucket</th>') { Bad 'snapshot still dumps raw chart bucket table' }
                    elseif ($resp.Content -notmatch 'Activity charts' -or $resp.Content -notmatch '<svg class="chart-svg"') { Bad 'snapshot missing SVG activity charts' }
                    else {
                        [System.IO.File]::WriteAllText($outHtml, $resp.Content, [System.Text.Encoding]::UTF8)
                        Ok 'snapshot HTML download (attachment + Siemens theme + SVG charts)'
                    }

                    $jUrl = "$base/api/snapshot?format=json&lastMinutes=120&severities=FATAL,SEVERE,ERROR,WARNING"
                    $jresp = Invoke-WebRequest -Uri $jUrl -UseBasicParsing -TimeoutSec 120
                    $j = $jresp.Content | ConvertFrom-Json
                    if ($j.meta -and $j.findings -and $j.patternsBySeverity) {
                        [System.IO.File]::WriteAllText($outJson, $jresp.Content, [System.Text.Encoding]::UTF8)
                        Ok 'snapshot JSON download'
                    }
                    else { Bad 'snapshot json shape' }
                }
                catch {
                    Bad "snapshot ($($_.Exception.Message))"
                }
                finally {
                    Remove-Item $outHtml, $outJson -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    if ($Phase -eq 'Report' -or $Phase -eq 'All') {
        # PRD 10.1: batch mode and the dashboard call the same Build-SnapshotObject and the
        # same renderers, so on a static log with matched filters the two files must agree
        # byte for byte apart from the wall-clock "Generated" line.
        Write-Host "`n[Report] Batch mode == dashboard snapshot"
        $reportLog = Join-Path $ExamplesRoot 'PVSS_II_C1P.log'
        if (-not (Test-Path -LiteralPath $reportLog)) { Bad "report log missing: $reportLog" }
        else {
            $filters = 'severities=FATAL,SEVERE,ERROR,WARNING&areas=SYS,IMPL,CTRL,PARAM,OTHER&entire=1'
            [void](Invoke-Api "$base/api/logPath" -Method POST -Body (@{ path = $reportLog; window = 'entire' } | ConvertTo-Json -Compress))
            $pulse = $null
            for ($w = 0; $w -lt 3000; $w++) {
                Start-Sleep -Milliseconds 200
                $pulse = Invoke-Api "$base/api/pulse?$filters" | ConvertFrom-Json
                if (-not $pulse.loading) { break }
            }
            if ($pulse.loading) { Bad 'Report catch-up still loading' }
            else {
                $stem = Join-Path $env:TEMP ('watchselftest_' + [guid]::NewGuid().ToString('N'))
                $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $WatchRoot 'Watch-PvssLog.ps1'),
                    '-Report', '-NoPause', '-Entire', '-Format', 'Both',
                    '-LogPath', $reportLog, '-OutPath', $stem,
                    '-Severities', 'FATAL,SEVERE,ERROR,WARNING',
                    '-Areas', 'SYS,IMPL,CTRL,PARAM,OTHER')
                $console = "$stem.console"
                $bp = Start-Process powershell.exe -ArgumentList $argv -NoNewWindow -Wait -PassThru `
                    -RedirectStandardOutput $console -RedirectStandardError "$console.err"
                if ($bp.ExitCode -ne 0) { Bad "batch -Report exit $($bp.ExitCode)" }
                else { Ok 'batch -Report exit 0' }

                # Only per-process state may differ: the wall-clock stamp and the session
                # generation counter, which counts catch-ups in the emitting process (a
                # dashboard that has been restarted a few times is several ahead of a fresh
                # batch run). Same category as the perf.health port/url carve-out in PRD 10.1.
                $stripGenerated = {
                    param([string]$Text)
                    $t = [regex]::Replace($Text, '<p class="meta">Generated [^<]*</p>', '<p class="meta">Generated ~</p>')
                    $t = [regex]::Replace($t, '(?m)^Generated : .*$', 'Generated : ~')
                    return [regex]::Replace($t, '&middot;  gen \d+</p>', '&middot;  gen ~</p>')
                }
                foreach ($pair in @(
                        @{ Name = 'html'; File = "$stem.html"; Url = "$base/api/snapshot?format=html&$filters" },
                        @{ Name = 'text'; File = "$stem.txt"; Url = "$base/api/snapshot?format=text&$filters" }
                    )) {
                    if (-not (Test-Path -LiteralPath $pair.File)) { Bad "batch produced no $($pair.Name) file"; continue }
                    $batch = & $stripGenerated ([System.IO.File]::ReadAllText($pair.File))
                    $live = & $stripGenerated ((Invoke-WebRequest -Uri $pair.Url -UseBasicParsing -TimeoutSec 300).Content)
                    if ($batch -ceq $live) { Ok ("batch {0} is byte-identical to the dashboard snapshot ({1:N0} chars)" -f $pair.Name, $batch.Length) }
                    else {
                        $bl = $batch -split "`r?`n"
                        $ll = $live -split "`r?`n"
                        $firstDiff = '(length only)'
                        for ($i = 0; $i -lt [math]::Max($bl.Count, $ll.Count); $i++) {
                            $a = if ($i -lt $bl.Count) { $bl[$i] } else { '<eof>' }
                            $b = if ($i -lt $ll.Count) { $ll[$i] } else { '<eof>' }
                            if ($a -cne $b) {
                                $firstDiff = ("line {0}`n      batch: {1}`n      live : {2}" -f ($i + 1),
                                    $a.Substring(0, [math]::Min(160, $a.Length)), $b.Substring(0, [math]::Min(160, $b.Length)))
                                break
                            }
                        }
                        Bad ("batch {0} differs from dashboard snapshot at {1}" -f $pair.Name, $firstDiff)
                    }
                }
                Remove-Item "$stem.html", "$stem.txt", $console, "$console.err" -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
finally {
    if ($proc -and -not $proc.HasExited) {
        try { Stop-Process -Id $proc.Id -Force } catch {}
    }
    $tmp = Join-Path $ExamplesRoot '_watch_tail_test.log'
    if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

if ($failed -gt 0) {
    Write-Host "`nSELF-TEST FAILED: $failed check(s)" -ForegroundColor Red
    exit 1
}
Write-Host "`nSELF-TEST OK ($Phase)" -ForegroundColor Green
exit 0
