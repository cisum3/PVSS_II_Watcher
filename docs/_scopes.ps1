# Which components does each UNSCOPED rule actually fire on? A rule that only ever fires for
# one manager can take a Scope, which drops it from every other component's rule set.
# Reports the full component distribution so the call is evidence-based, not a guess.
param([string[]]$Logs = @(), [switch]$IncludeBak)

$ErrorActionPreference = 'Stop'
$DocsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $DocsRoot
$ExamplesRoot = Join-Path $DocsRoot 'PVSS_II_Examples'
. (Join-Path $Root 'Watch\PvssRules.ps1')

$LineRe = [regex]'^([^,]+),\s*(\d{4}\.\d{2}\.\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+),\s*([^,]+),\s*([^,\s]+)'

if ($Logs.Count -eq 0) {
    $files = @(Get-ChildItem $ExamplesRoot -Filter 'PVSS_II*.log' -File)
    if ($IncludeBak) { $files += @(Get-ChildItem $ExamplesRoot -Filter 'PVSS_II*.log.bak' -File) }
}
else { $files = @($Logs | ForEach-Object { Get-Item (Join-Path $ExamplesRoot $_) }) }

$unscoped = @($script:PvssRules | Where-Object { -not $_['Scope'] })
Write-Host ("Unscoped rules: {0} of {1}   Logs: {2}" -f $unscoped.Count, $script:PvssRules.Count, $files.Count) -ForegroundColor Cyan

# ruleId -> component -> count
$hits = @{}
foreach ($r in $unscoped) { $hits[[string]$r['Id']] = @{} }
$compTotals = @{}
$totalLines = 0

foreach ($f in $files) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $n = 0
    $sr = New-Object System.IO.StreamReader($f.FullName)
    while ($null -ne ($line = $sr.ReadLine())) {
        $m = $LineRe.Match($line)
        if (-not $m.Success) { continue }
        $n++
        $comp = $m.Groups[1].Value.Trim()
        if ($compTotals.ContainsKey($comp)) { $compTotals[$comp]++ } else { $compTotals[$comp] = 1 }
        foreach ($r in $unscoped) {
            if (-not $r['Re'].IsMatch($line)) { continue }
            $cm = $hits[[string]$r['Id']]
            if ($cm.ContainsKey($comp)) { $cm[$comp]++ } else { $cm[$comp] = 1 }
        }
    }
    $sr.Close()
    $totalLines += $n
    Write-Host ("  {0,-24} {1,9:N0} lines  {2,6:N1}s" -f $f.Name, $n, $sw.Elapsed.TotalSeconds) -ForegroundColor DarkGray
}

Write-Host ''
Write-Host ("Parsed {0:N0} lines across {1} file(s), {2} distinct components" -f $totalLines, $files.Count, $compTotals.Count) -ForegroundColor Cyan
Write-Host ''

foreach ($r in $unscoped) {
    $id = [string]$r['Id']
    $cm = $hits[$id]
    $total = 0; foreach ($v in $cm.Values) { $total += $v }
    if ($total -eq 0) { Write-Host ("{0,-26} no hits" -f $id) -ForegroundColor DarkGray; continue }

    $rows = @($cm.GetEnumerator() | Sort-Object Value -Descending)
    # Longest common substring shared by every component that fires -> a candidate Scope.
    $names = @($rows | ForEach-Object { $_.Key })
    $cand = ''
    $first = $names[0]
    for ($len = $first.Length; $len -ge 3 -and -not $cand; $len--) {
        for ($s = 0; $s + $len -le $first.Length; $s++) {
            $sub = $first.Substring($s, $len)
            $all = $true
            foreach ($nm in $names) { if ($nm.IndexOf($sub, [StringComparison]::OrdinalIgnoreCase) -lt 0) { $all = $false; break } }
            if ($all) { $cand = $sub; break }
        }
    }
    # How much would that Scope save? Share of parsed lines whose component does NOT match.
    $skip = 0
    if ($cand) {
        foreach ($kv in $compTotals.GetEnumerator()) {
            if ($kv.Key.IndexOf($cand, [StringComparison]::OrdinalIgnoreCase) -lt 0) { $skip += $kv.Value }
        }
    }

    $colour = if ($rows.Count -eq 1) { 'Green' } elseif ($cand) { 'Yellow' } else { 'Red' }
    Write-Host ("{0,-26} {1,8:N0} hits   {2} component(s)" -f $id, $total, $rows.Count) -ForegroundColor $colour
    foreach ($row in ($rows | Select-Object -First 8)) {
        Write-Host ("      {0,8:N0}  {1}" -f $row.Value, $row.Key)
    }
    if ($rows.Count -gt 8) { Write-Host ("      ... +{0} more" -f ($rows.Count - 8)) }
    if ($cand) {
        Write-Host ("      -> candidate Scope '{0}'  skips {1:N0} of {2:N0} lines ({3:N1}%)" -f `
                $cand, $skip, $totalLines, (100.0 * $skip / [math]::Max(1, $totalLines))) -ForegroundColor Cyan
    }
    else { Write-Host '      -> no common substring; must stay unscoped' -ForegroundColor DarkGray }
    Write-Host ''
}
