# Times Process-LogLine for ONE build over a fixed line count, in its own process so 2.3 and
# 2.4 function definitions can never collide. Driver: _abrun.ps1.
param(
    [Parameter(Mandatory = $true)][string]$Script,   # Watch-PvssLog.ps1 under test
    [string]$Rules = '',                             # PvssRules.ps1, if the build needs one
    [Parameter(Mandatory = $true)][string]$Log,
    [int]$Lines = 150000,
    [string]$Tag = ''
)

$ErrorActionPreference = 'Stop'

$src = [System.IO.File]::ReadAllText($Script)
$cut = $src.IndexOf("`n# --- main ---")
if ($cut -lt 0) { throw "no '# --- main ---' marker in $Script" }

$dir = Join-Path $env:TEMP ('pvss_ab_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
if ($Rules) { Copy-Item $Rules $dir -Force }
$lib = Join-Path $dir 'lib.ps1'
[System.IO.File]::WriteAllText($lib, $src.Substring(0, $cut))
. $lib

# Same lines for every build; read before timing so file I/O is not in the measurement.
$sample = New-Object 'System.Collections.Generic.List[string]'
$sr = New-Object System.IO.StreamReader($Log)
while ($sample.Count -lt $Lines) { $l = $sr.ReadLine(); if ($null -eq $l) { break }; $sample.Add($l) }
$sr.Close()

$d = New-EmptyState
[void][System.GC]::Collect()
$sw = [System.Diagnostics.Stopwatch]::StartNew()
foreach ($l in $sample) { Process-LogLine -Line $l -Data $d }
$sw.Stop()

$ruleHits = 0
if ($d.ContainsKey('Hits')) { foreach ($v in $d.Hits.Values) { $ruleHits += [int]$v } }

'{0,-6} {1,8:N1} s   {2,10:N0} lines   {3,9:N0} parsed   {4,7:N0} rule hits   {5,6:N3} ms/line' -f `
    $Tag, $sw.Elapsed.TotalSeconds, $sample.Count, [int]$d.ParsedLines, $ruleHits,
($sw.Elapsed.TotalMilliseconds / $sample.Count)

Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
