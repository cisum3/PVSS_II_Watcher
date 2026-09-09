# Safety net for the Scope additions: for every rule, count corpus matches with the scope
# gate applied and with it ignored. Any rule where the two differ has a Scope that silently
# drops detections, which is worse than the cost it saves.
param([switch]$IncludeBak)

$ErrorActionPreference = 'Stop'
$DocsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $DocsRoot
$ExamplesRoot = Join-Path $DocsRoot 'PVSS_II_Examples'
. (Join-Path $Root 'Watch\PvssRules.ps1')

$LineRe = [regex]'^([^,]+),\s*(\d{4}\.\d{2}\.\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+),\s*([^,]+),\s*([^,\s]+)'

$files = @(Get-ChildItem $ExamplesRoot -Filter 'PVSS_II*.log' -File)
if ($IncludeBak) { $files += @(Get-ChildItem $ExamplesRoot -Filter 'PVSS_II*.log.bak' -File) }

# Scopes that narrow on purpose: the curated Apogee card counted only WCCOAApogeeDrv in 2.3,
# and 4A's parity check froze that. Their out-of-scope hits are a known coverage question,
# not a regression - flagged below rather than failed.
$intentional = @('apogeeDrv.trendOverflow', 'apogeeDrv.trendSeq', 'apogeeDrv.alertId',
    'apogeeDrv.queryTimeout', 'apogeeDrv.getDataFail')

$rules = @($script:PvssRules)
$gated = @{}; $ungated = @{}; $outComp = @{}
foreach ($r in $rules) { $gated[[string]$r['Id']] = 0; $ungated[[string]$r['Id']] = 0; $outComp[[string]$r['Id']] = @{} }

# Rules evaluated per line, before and after scoping - the actual saving.
$evalBefore = 0L; $evalAfter = 0L; $lines = 0L

foreach ($f in $files) {
    $sr = New-Object System.IO.StreamReader($f.FullName)
    while ($null -ne ($line = $sr.ReadLine())) {
        $m = $LineRe.Match($line)
        if (-not $m.Success) { continue }
        $lines++
        $comp = $m.Groups[1].Value.Trim()
        foreach ($r in $rules) {
            $sc = $r['Scope']
            $inScope = (-not $sc) -or ($comp.IndexOf($sc, [StringComparison]::OrdinalIgnoreCase) -ge 0)
            $evalBefore++
            if ($inScope) { $evalAfter++ }
            if (-not $r['Re'].IsMatch($line)) { continue }
            $id = [string]$r['Id']
            $ungated[$id]++
            if ($inScope) { $gated[$id]++ }
            else {
                $oc = $outComp[$id]
                if ($oc.ContainsKey($comp)) { $oc[$comp]++ } else { $oc[$comp] = 1 }
            }
        }
    }
    $sr.Close()
    Write-Host ("  scanned {0}" -f $f.Name) -ForegroundColor DarkGray
}

Write-Host ''
$bad = 0
foreach ($r in $rules) {
    $id = [string]$r['Id']
    $g = $gated[$id]; $u = $ungated[$id]
    $sc = if ($r['Scope']) { "Scope='$($r['Scope'])'" } else { '(unscoped)' }
    if ($g -eq $u) {
        Write-Host ("  OK    {0,-26} {1,8:N0} hits   {2}" -f $id, $u, $sc) -ForegroundColor Green
    }
    elseif ($intentional -contains $id) {
        Write-Host ("  NARROW {0,-25} {1,8:N0} of {2,8:N0} hits kept   {3}" -f $id, $g, $u, $sc) -ForegroundColor Yellow
        foreach ($kv in ($outComp[$id].GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 4)) {
            Write-Host ("           out of scope: {0,8:N0}  {1}" -f $kv.Value, $kv.Key) -ForegroundColor DarkYellow
        }
    }
    else {
        $bad++
        Write-Host ("  LOSS  {0,-26} {1,8:N0} of {2,8:N0} hits kept   {3}  <-- drops {4:N0}" -f `
                $id, $g, $u, $sc, ($u - $g)) -ForegroundColor Red
        foreach ($kv in ($outComp[$id].GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 4)) {
            Write-Host ("           out of scope: {0,8:N0}  {1}" -f $kv.Value, $kv.Key) -ForegroundColor Red
        }
    }
}

Write-Host ''
Write-Host ("Lines {0:N0}   rule evaluations {1:N0} -> {2:N0}  ({3:N1}% fewer)" -f `
        $lines, $evalBefore, $evalAfter, (100.0 * ($evalBefore - $evalAfter) / [math]::Max(1, $evalBefore))) -ForegroundColor Cyan
Write-Host ("Rules scoped: {0} of {1}" -f @($rules | Where-Object { $_['Scope'] }).Count, $rules.Count) -ForegroundColor Cyan
if ($bad) { Write-Host ("FAIL: {0} rule(s) lose hits unintentionally" -f $bad) -ForegroundColor Red; exit 1 }
Write-Host 'PASS: every scope is hit-neutral on this corpus (bar the flagged NARROW rules)' -ForegroundColor Green
