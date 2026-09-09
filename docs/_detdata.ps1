# Design aid for the Detections section: runs the real rule engine over the corpus and
# reports the actual payload shape - what every field holds, and how big it gets.
# Skips the rest of Process-LogLine, so this is a fast approximation of one full-file scan
# per log (the rule hits themselves are exact).
param([string[]]$Logs = @(), [int]$TopN = 20, [switch]$Json)

$ErrorActionPreference = 'Stop'
$DocsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $DocsRoot
$ExamplesRoot = Join-Path $DocsRoot 'PVSS_II_Examples'
. (Join-Path $Root 'Watch\PvssRules.ps1')

$LineRe = [regex]'^([^,]+),\s*(\d{4}\.\d{2}\.\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+),\s*([^,]+),\s*([^,\s]+)'

function New-RuleState {
    @{ Hits = @{}; HitBuckets = @{}; HitMeasures = @{}; HitSevs = @{}; HitSample = @{}; HitTime = @{} }
}

if ($Logs.Count -eq 0) { $files = @(Get-ChildItem $ExamplesRoot -Filter 'PVSS_II*.log' -File | Where-Object { $_.Length -gt 0 }) }
else { $files = @($Logs | ForEach-Object { Get-Item (Join-Path $ExamplesRoot $_) }) }

foreach ($f in $files) {
    $data = New-RuleState
    $lines = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $sr = New-Object System.IO.StreamReader($f.FullName)
    while ($null -ne ($line = $sr.ReadLine())) {
        $m = $LineRe.Match($line)
        if (-not $m.Success) { continue }
        $lines++
        $comp = $m.Groups[1].Value.Trim()
        $ts = $m.Groups[2].Value
        $area = $m.Groups[3].Value.Trim()
        $sev = $m.Groups[4].Value.Trim().ToUpperInvariant()
        if ($sev -eq 'WARN') { $sev = 'WARNING' }
        $rs = $script:RuleSetCache[$comp]
        if ($null -eq $rs) { $rs = Register-RuleSet -Comp $comp }
        foreach ($r in $rs) {
            $rm = $r['Re'].Match($line)
            if (-not $rm.Success) { continue }
            Add-RuleHit -Data $data -Rule $r -Match $rm -Line $line -Comp $comp -Area $area -Sev $sev -Timestamp $ts
        }
    }
    $sr.Close()

    $det = Build-DetectionsObject -Data $data -TopN $TopN

    Write-Host ''
    Write-Host ("=== {0}  ({1:N1} MB, {2:N0} parsed lines, {3:N0}s) ===" -f `
            $f.Name, ($f.Length / 1MB), $lines, $sw.Elapsed.TotalSeconds) -ForegroundColor Cyan

    if ($Json) {
        $det | ConvertTo-Json -Depth 8
        continue
    }

    $ruleTotal = 0
    foreach ($g in $det) { $ruleTotal += @($g.rules).Count }
    Write-Host ("groups: {0}   rules with hits: {1} of {2}" -f `
        @($det).Count, $ruleTotal, @($script:PvssRules | Where-Object { $script:CuratedGroups -notcontains $_['Group'] }).Count)

    foreach ($g in $det) {
        Write-Host ''
        Write-Host ("  GROUP {0}   total={1:N0}   rules={2}" -f $g.group, $g.total, @($g.rules).Count) -ForegroundColor Yellow
        foreach ($r in $g.rules) {
            $sevs = @(); foreach ($k in $r.severities.Keys) { $sevs += ('{0}={1:N0}' -f $k, $r.severities[$k]) }
            $meas = @(); foreach ($k in $r.measures.Keys) { $meas += ('{0}={1:N0}' -f $k, $r.measures[$k]) }
            Write-Host ("    {0,-28} count={1,-9:N0} sev[{2}]" -f $r.id, $r.count, ($sevs -join ' ')) -ForegroundColor White
            Write-Host ("      label      : {0}" -f $r.label)
            Write-Host ("      window     : {0}  ->  {1}" -f $r.first, $r.last)
            if ($meas.Count) { Write-Host ("      measures   : {0}" -f ($meas -join '  ')) -ForegroundColor Green }
            $bn = @($r.buckets.Keys)
            if ($bn.Count -eq 0) { Write-Host '      buckets    : (none)' -ForegroundColor DarkGray }
            foreach ($b in $bn) {
                $bk = $r.buckets[$b]
                $top = @($bk.top)
                $t1 = if ($top.Count) { '{0} ({1:N0})' -f $top[0].value, $top[0].count } else { '-' }
                # Share of hits carried by the single busiest value: tells you whether a
                # bucket is one offender or a genuine spread.
                $share = if ($r.count) { 100.0 * $top[0].count / $r.count } else { 0 }
                $col = if ([int]$bk.distinct -eq 1) { 'DarkGray' } else { 'Gray' }
                Write-Host ("      by {0,-10}: {1,5:N0} distinct{2}   top={3}  = {4:N0}% of hits" -f `
                        $b, $bk.distinct, $(if ($bk.capped) { ' CAPPED' } else { '' }), $t1, $share) -ForegroundColor $col
            }
            if ($r.sample) {
                $s = [string]$r.sample
                Write-Host ("      sample len : {0} chars" -f $s.Length) -ForegroundColor DarkGray
            }
        }
    }
}
