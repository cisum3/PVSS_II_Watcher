# Compares candidate ranking schemes for the Detections section against the real corpus.
# The question: which ordering puts the actual incident at the top?
#   count      - what 2.4 ships today
#   ratio      - count / FindingAt  (how far over its own hand-tuned bar)
#   burstRate  - count / the rule's OWN first->last span, in hits/hour
#   sevRate    - burstRate weighted by the rule's severity mix
param([string[]]$Logs = @(), [int]$MinSpanSec = 60)

$ErrorActionPreference = 'Stop'
$DocsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $DocsRoot
$ExamplesRoot = Join-Path $DocsRoot 'PVSS_II_Examples'
. (Join-Path $Root 'Watch\PvssRules.ps1')

$LineRe = [regex]'^([^,]+),\s*(\d{4}\.\d{2}\.\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+),\s*([^,]+),\s*([^,\s]+)'
$TsFmt = 'yyyy.MM.dd HH:mm:ss.fff'
# Severity weights: a SEVERE burst should outrank an INFO burst of the same size.
$SevWeight = @{ FATAL = 4.0; SEVERE = 3.0; ERROR = 3.0; WARNING = 1.0; INFO = 0.25 }

function Parse-Ts([string]$s) {
    $dt = [datetime]::MinValue
    if ([datetime]::TryParseExact($s, $TsFmt, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$dt)) { return $dt }
    return $null
}

if ($Logs.Count -eq 0) { $files = @(Get-ChildItem $ExamplesRoot -Filter 'PVSS_II*.log' -File | Where-Object { $_.Length -gt 0 }) }
else { $files = @($Logs | ForEach-Object { Get-Item (Join-Path $ExamplesRoot $_) }) }

$faById = @{}
foreach ($r in $script:PvssRules) { if ($r['FindingAt']) { $faById[[string]$r['Id']] = [int]$r['FindingAt'] } }

foreach ($f in $files) {
    $data = @{ Hits = @{}; HitBuckets = @{}; HitMeasures = @{}; HitSevs = @{}; HitSample = @{}; HitTime = @{} }
    $winFirst = $null; $winLast = $null; $lines = 0
    $sr = New-Object System.IO.StreamReader($f.FullName)
    while ($null -ne ($line = $sr.ReadLine())) {
        $m = $LineRe.Match($line)
        if (-not $m.Success) { continue }
        $lines++
        $comp = $m.Groups[1].Value.Trim(); $ts = $m.Groups[2].Value
        $area = $m.Groups[3].Value.Trim()
        $sev = $m.Groups[4].Value.Trim().ToUpperInvariant()
        if ($sev -eq 'WARN') { $sev = 'WARNING' }
        if (-not $winFirst) { $winFirst = $ts }
        $winLast = $ts
        $rs = $script:RuleSetCache[$comp]
        if ($null -eq $rs) { $rs = Register-RuleSet -Comp $comp }
        foreach ($r in $rs) {
            $rm = $r['Re'].Match($line)
            if (-not $rm.Success) { continue }
            Add-RuleHit -Data $data -Rule $r -Match $rm -Line $line -Comp $comp -Area $area -Sev $sev -Timestamp $ts
        }
    }
    $sr.Close()

    $wf = Parse-Ts $winFirst; $wl = Parse-Ts $winLast
    $winHours = if ($wf -and $wl) { [math]::Max(0.0166, ($wl - $wf).TotalHours) } else { 1 }

    $rows = @()
    foreach ($g in (Build-DetectionsObject -Data $data -TopN 3)) {
        foreach ($r in $g.rules) {
            $fa = if ($faById.ContainsKey($r.id)) { $faById[$r.id] } else { 0 }
            $a = Parse-Ts ([string]$r.first); $b = Parse-Ts ([string]$r.last)
            $spanSec = if ($a -and $b) { [math]::Max($MinSpanSec, ($b - $a).TotalSeconds) } else { $MinSpanSec }
            $burst = $r.count / $spanSec * 3600.0
            # Weighted mean severity across this rule's own hits.
            $wsum = 0.0; $n = 0
            foreach ($k in $r.severities.Keys) {
                $w = if ($SevWeight.ContainsKey($k)) { $SevWeight[$k] } else { 1.0 }
                $wsum += $w * [int]$r.severities[$k]; $n += [int]$r.severities[$k]
            }
            $sevW = if ($n) { $wsum / $n } else { 1.0 }
            $rows += [pscustomobject]@{
                Group = $g.group; Id = $r.id; Count = [int]$r.count
                FindingAt = $fa
                Ratio = if ($fa) { [math]::Round($r.count / $fa, 2) } else { 0 }
                SpanHr = [math]::Round($spanSec / 3600.0, 2)
                Burst = [math]::Round($burst, 1)
                SevW = [math]::Round($sevW, 2)
                SevRate = [math]::Round($burst * $sevW, 1)
            }
        }
    }

    Write-Host ''
    Write-Host ("=== {0}   window {1:N1} h   {2:N0} parsed lines   {3} rules hit ===" -f `
            $f.Name, $winHours, $lines, $rows.Count) -ForegroundColor Cyan

    $schemes = @(
        @{ N = 'count (today)'; K = 'Count' }
        @{ N = 'ratio  count/FindingAt'; K = 'Ratio' }
        @{ N = 'burst  hits/hr over own span'; K = 'Burst' }
        @{ N = 'sevRate  burst x severity'; K = 'SevRate' }
    )
    $cols = @()
    foreach ($s in $schemes) {
        $ordered = @($rows | Sort-Object -Property $s.K -Descending | Select-Object -First 5)
        $cols += , @($ordered | ForEach-Object { '{0} ({1:N0})' -f $_.Id, $_.($s.K) })
    }
    for ($i = 0; $i -lt 4; $i++) { Write-Host ("  {0,-30}" -f $schemes[$i].N) -NoNewline -ForegroundColor Yellow }
    Write-Host ''
    for ($r = 0; $r -lt 5; $r++) {
        for ($i = 0; $i -lt 4; $i++) {
            $v = if ($r -lt $cols[$i].Count) { $cols[$i][$r] } else { '' }
            Write-Host ("  {0,-30}" -f $v) -NoNewline
        }
        Write-Host ''
    }

    Write-Host ''
    Write-Host ('  {0,-26} {1,8} {2,6} {3,7} {4,9} {5,9} {6,6} {7,10}' -f `
            'rule', 'count', 'at', 'ratio', 'spanHr', 'hits/hr', 'sevW', 'sevRate') -ForegroundColor DarkGray
    foreach ($x in ($rows | Sort-Object SevRate -Descending)) {
        Write-Host ('  {0,-26} {1,8:N0} {2,6} {3,7:N2} {4,9:N2} {5,9:N1} {6,6:N2} {7,10:N1}' -f `
                $x.Id, $x.Count, $x.FindingAt, $x.Ratio, $x.SpanHr, $x.Burst, $x.SevW, $x.SevRate)
    }
}
