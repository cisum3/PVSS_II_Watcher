#Requires -Version 5.1
<#
.SYNOPSIS
  Self-tests for Watch (no browser). Lives in docs\; package root is its parent.
#>
param(
    [ValidateSet('Assets', 'Api', 'Control', 'Modules', 'Snapshot', 'All')]
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
}

if ($Phase -eq 'Assets') {
    if ($failed -gt 0) { throw "Assets self-test failed ($failed)" }
    Write-Host "`nAssets OK" -ForegroundColor Green
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
