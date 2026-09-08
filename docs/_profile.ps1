# Where does Process-LogLine's per-line time go? Loads Watch's function library (cut at the
# '# --- main ---' marker, same trick Test-WatchSelf uses), then times the whole function and
# each regex battery inside it over the same line sample.
param([string]$Log, [int]$Lines = 60000)

$ErrorActionPreference = 'Stop'
$DocsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $DocsRoot
if (-not $Log) { $Log = Join-Path $DocsRoot 'PVSS_II_Examples\PVSS_II_C2P.log' }

$src = [System.IO.File]::ReadAllText((Join-Path $Root 'Watch\Watch-PvssLog.ps1'))
$cut = $src.IndexOf("`n# --- main ---")
$libDir = Join-Path $env:TEMP 'pvss_profile'
if (-not (Test-Path $libDir)) { New-Item -ItemType Directory -Path $libDir | Out-Null }
Copy-Item (Join-Path $Root 'Watch\PvssRules.ps1') $libDir -Force
$lib = Join-Path $libDir 'lib.ps1'
[System.IO.File]::WriteAllText($lib, $src.Substring(0, $cut))
. $lib

$sample = New-Object 'System.Collections.Generic.List[string]'
$sr = New-Object System.IO.StreamReader($Log)
while ($sample.Count -lt $Lines) { $l = $sr.ReadLine(); if ($null -eq $l) { break }; $sample.Add($l) }
$sr.Close()
Write-Host ("Sample: {0:N0} lines from {1}" -f $sample.Count, (Split-Path -Leaf $Log))

function Time($name, $block) {
    [void][System.GC]::Collect()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $block
    $sw.Stop()
    [pscustomobject]@{ Name = $name; Ms = [math]::Round($sw.Elapsed.TotalMilliseconds) }
}

$results = @()

$data = New-EmptyState
$results += Time 'Process-LogLine (whole)' { foreach ($l in $sample) { Process-LogLine -Line $l -Data $data } }

$results += Time '  header regex only' {
    foreach ($l in $sample) { [void]$script:LineRe.Match($l) }
}

$results += Time '  Get-PerfCategory' {
    foreach ($l in $sample) { [void](Get-PerfCategory -Line $l) }
}

$results += Time '  Normalize-Message' {
    foreach ($l in $sample) { [void](Normalize-Message -Text $l) }
}

# The lifecycle battery runs unconditionally on every line today.
$lifecycle = @($script:ReProjectUp, $script:ReProjectStartMode, $script:ReProjectShutdown,
    $script:ReProjectStopped, $script:RePmonMgrRestart, $script:ReMgrStartProj,
    $script:ReMgrStopMsg, $script:ReDriverReady, $script:ReBlockingStart, $script:ReBlockingEnd)
$results += Time ('  lifecycle battery ({0} regex)' -f $lifecycle.Count) {
    foreach ($l in $sample) { foreach ($re in $lifecycle) { [void]$re.IsMatch($l) } }
}

$bacCmd = @($script:ReBacCmdDetail, $script:ReBacCollectTrend, $script:ReBacTimeSyncCmd)
$results += Time '  BACnet-cmd battery (3 regex)' {
    foreach ($l in $sample) { foreach ($re in $bacCmd) { [void]$re.IsMatch($l) } }
}

$apogee = @($script:ReApogeeComp)
$results += Time '  Apogee gate (1 regex)' {
    foreach ($l in $sample) { foreach ($re in $apogee) { [void]$re.IsMatch($l) } }
}

# Rules, as Process-LogLine runs them: scope-gated per component.
$results += Time '  rule engine (scope-gated)' {
    foreach ($l in $sample) {
        $m = $script:LineRe.Match($l)
        if (-not $m.Success) { continue }
        $comp = $m.Groups[1].Value.Trim()
        $rs = $script:RuleSetCache[$comp]
        if ($null -eq $rs) { $rs = Register-RuleSet -Comp $comp }
        foreach ($r in $rs) { [void]$r['Re'].Match($l) }
    }
}

$results += Time '  empty foreach baseline' { foreach ($l in $sample) { $null = $l.Length } }

# Is the cost the work, or the fact that it is a PowerShell function call?
function script:Noop-Bare { param([string]$A) return $null }
$results += Time '  empty function call x1' { foreach ($l in $sample) { [void](Noop-Bare -A $l) } }

$results += Time '  Add-Pattern x3 (severe path)' {
    $cm = @{}; $sm = @{}; $tm = @{}
    foreach ($l in $sample) {
        $n = Normalize-Message -Text $l
        Add-Pattern -CountMap $cm -SampleMap $sm -TimeMap $tm -Norm $n -Line $l -Timestamp '2026.09.04 10:00:00.000' -SampleLimit 3
        Add-Pattern -CountMap $cm -SampleMap $sm -TimeMap $tm -Norm $n -Line $l -Timestamp '2026.09.04 10:00:00.000' -SampleLimit 3
        Add-Pattern -CountMap $cm -SampleMap $sm -TimeMap $tm -Norm $n -Line $l -Timestamp '2026.09.04 10:00:00.000' -SampleLimit 3
    }
}

$d2 = New-EmptyState
$results += Time '  Ensure-Minute + Area' {
    foreach ($l in $sample) {
        [void](Ensure-Minute -Data $d2 -Key '2026.09.04 10:00')
        [void](Ensure-MinuteArea -Data $d2 -Key '2026.09.04 10:00' -Area 'IMPL')
    }
}

$results += Time '  20 raw hashtable bumps' {
    $h = @{}
    foreach ($l in $sample) {
        for ($i = 0; $i -lt 20; $i++) {
            if (-not $h.ContainsKey($i)) { $h[$i] = 0 }
            $h[$i]++
        }
    }
}

$whole = ($results | Where-Object Name -eq 'Process-LogLine (whole)').Ms
$results | ForEach-Object {
    '{0,-34} {1,7:N0} ms  {2,5:N1}%' -f $_.Name, $_.Ms, (100.0 * $_.Ms / $whole)
}
Write-Host ''
Write-Host ('Per line: {0:N3} ms  -> {1:N0} s for 438,480 lines' -f ($whole / $sample.Count), ($whole / $sample.Count * 438.480))
