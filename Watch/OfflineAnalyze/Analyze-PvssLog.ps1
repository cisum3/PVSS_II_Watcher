<#
.SYNOPSIS
  Standalone WinCC OA / GMS (PVSS_II) log analyzer for performance triage. (v1.3)

.DESCRIPTION
  Streams a large PVSS_II.log without loading it into memory.
  Produces a text report: severity-separated patterns, BACnet/CNS/CoHo/Apogee modules,
  findings, and optional interactive report shaping after the scan.
  Optional HTML report via -Format Html|Both (Run-Analyze.cmd defaults to Html).

  Requires only Windows PowerShell 5.1+ or PowerShell 7+.

.NOTES
  Author: Cisum

.PARAMETER LogPath
  Path to the log file. Defaults to PVSS_II.log next to this script, then cwd.
  Also accepts PVSS_II.log.bak / PVSS_II*.log.bak when the live log is absent.

.PARAMETER OutPath
  Optional path for the report. Default: <LogPath>.analysis.txt

.PARAMETER TopN
  How many top components / message patterns to show per section (default 10).

.PARAMETER SamplePerPattern
  Example lines kept per distinct message pattern (default 1).

.PARAMETER NoPause
  Do not wait for Enter at the end.

.PARAMETER NonInteractive
  Skip prompts; imply -NoPause. Forces Organize=All unless -Organize is set.

.PARAMETER Interactive
  After resolving the log, prompt for an optional time window (Enter = entire file),
  then scan, then prompt for Severity / Driver / All report shaping.

.PARAMETER Organize
  All | Severity | Driver (non-interactive or pre-set).

.PARAMETER Severities
  Comma-separated severities for Organize=Severity (e.g. FATAL,SEVERE,ERROR).

.PARAMETER Driver
  Comma-separated manager names or 1-based indexes (Organize=Driver, non-interactive).

.PARAMETER From
  Include only log lines at/after this time. Accepts WinCC OA style
  (yyyy.MM.dd HH:mm:ss[.fff]) or yyyy-MM-dd variants. Date-only = start of day.

.PARAMETER To
  Include only log lines at/before this time. Same formats as -From.
  Date-only = end of that day.

.PARAMETER LastHours
  Analyze only the last N hours of the log (from the file's last timestamp).
  Overrides -From/-To when greater than 0.

.PARAMETER Format
  Report output format: Text (.analysis.txt), Html (.analysis.html), or Both.

.EXAMPLE
  .\Analyze-PvssLog.ps1 -NonInteractive

.EXAMPLE
  .\Analyze-PvssLog.ps1 -Interactive

.EXAMPLE
  .\Analyze-PvssLog.ps1 -NonInteractive -Format Both

.EXAMPLE
  .\Analyze-PvssLog.ps1 -NonInteractive -From "2026.09.04 09:00" -To "2026.09.04 12:00"

.EXAMPLE
  .\Analyze-PvssLog.ps1 -NonInteractive -LastHours 6
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$LogPath,

    [string]$OutPath,

    [ValidateRange(5, 100)]
    [int]$TopN = 10,

    [ValidateRange(0, 5)]
    [int]$SamplePerPattern = 1,

    [switch]$NoPause,

    [switch]$NonInteractive,

    [switch]$Interactive,

    [ValidateSet('All', 'Severity', 'Driver')]
    [string]$Organize = 'All',

    [string]$Severities,

    [string]$Driver,

    [string]$From,

    [string]$To,

    # 0 = unset; when >0, analyze the last N hours ending at the log's last timestamp
    [ValidateRange(0, 8760)]
    [int]$LastHours = 0,

    [ValidateSet('Text', 'Html', 'Both')]
    [string]$Format = 'Text'
)

if ($NonInteractive) {
    $NoPause = $true
    $Interactive = $false
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ToolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:Version = (Get-Content (Join-Path $script:ToolRoot 'VERSION.txt') -ErrorAction SilentlyContinue | Select-Object -First 1)
if (-not $script:Version) { $script:Version = '1.3' }
$script:Author = 'Cisum'
foreach ($verLine in @(Get-Content (Join-Path $script:ToolRoot 'VERSION.txt') -ErrorAction SilentlyContinue)) {
    if ($verLine -match '^\s*Author\s*:\s*(.+)\s*$') { $script:Author = $Matches[1].Trim(); break }
}

function Wait-IfInteractive {
    if ($NoPause) { return }
    try {
        if ($Host.Name -eq 'ConsoleHost') {
            Write-Host ''
            Write-Host 'Press Enter to close...' -ForegroundColor Yellow
            [void][System.Console]::ReadLine()
        }
    }
    catch { }
}

function Convert-LogTimestamp {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = $Text.Trim()
    $formats = @(
        'yyyy.MM.dd HH:mm:ss.fff',
        'yyyy.MM.dd HH:mm:ss',
        'yyyy.MM.dd HH:mm',
        'yyyy.MM.dd',
        'yyyy-MM-dd HH:mm:ss.fff',
        'yyyy-MM-dd HH:mm:ss',
        'yyyy-MM-dd HH:mm',
        'yyyy-MM-dd'
    )
    foreach ($f in $formats) {
        $dt = [datetime]::MinValue
        if ([datetime]::TryParseExact(
                $t, $f,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::None,
                [ref]$dt)) {
            return $dt
        }
    }
    $dt2 = [datetime]::MinValue
    if ([datetime]::TryParse(
            $t,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeLocal,
            [ref]$dt2)) {
        return $dt2
    }
    return $null
}

function Format-DurationLabel {
    param($Seconds)
    if ($null -eq $Seconds) { return '' }
    try { $s = [int][math]::Round([double]$Seconds) } catch { return '' }
    if ($s -lt 0) { return '' }
    if ($s -lt 60) { return ('{0}s' -f $s) }
    $m = [int][math]::Floor($s / 60)
    $r = $s % 60
    if ($m -lt 60) {
        if ($r -eq 0) { return ('{0}m' -f $m) }
        return ('{0}m {1}s' -f $m, $r)
    }
    $h = [int][math]::Floor($m / 60)
    $m2 = $m % 60
    if ($h -lt 48) {
        if ($m2 -eq 0) { return ('{0}h' -f $h) }
        return ('{0}h {1}m' -f $h, $m2)
    }
    $d = [int][math]::Floor($h / 24)
    $h2 = $h % 24
    if ($h2 -eq 0) { return ('{0}d' -f $d) }
    return ('{0}d {1}h' -f $d, $h2)
}

function Get-LogTimestampDeltaSec {
    param([string]$FromTs, [string]$ToTs)
    $a = Convert-LogTimestamp -Text $FromTs
    $b = Convert-LogTimestamp -Text $ToTs
    if (-not $a -or -not $b) { return $null }
    return ($b - $a).TotalSeconds
}

function Build-ProjectLifecycleCycles {
    param(
        [object[]]$Events,
        [string]$WindowFirst,
        [string]$WindowLast
    )
    # Normalize to t/kind (Watch-compatible) from Offline Kind/Time objects.
    $norm = New-Object System.Collections.Generic.List[object]
    foreach ($ev in @($Events)) {
        if ($null -eq $ev) { continue }
        $t = $null
        $k = $null
        if ($ev.PSObject.Properties['t']) { $t = [string]$ev.t }
        elseif ($ev.PSObject.Properties['Time']) { $t = [string]$ev.Time }
        if ($ev.PSObject.Properties['kind']) { $k = [string]$ev.kind }
        elseif ($ev.PSObject.Properties['Kind']) { $k = [string]$ev.Kind }
        if (-not $t -or -not $k) { continue }
        [void]$norm.Add([ordered]@{ t = $t; kind = $k.ToLowerInvariant() })
    }
    $evs = @($norm | Sort-Object { [string]$_.t }, { [string]$_.kind })
    if ($evs.Count -eq 0) { return @() }
    $cycles = New-Object System.Collections.Generic.List[object]

    $upIdx = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $evs.Count; $i++) {
        if ([string]$evs[$i].kind -eq 'up') { [void]$upIdx.Add($i) }
    }

    $firstUp = if ($upIdx.Count -gt 0) { [int]$upIdx[0] } else { $evs.Count }
    $leadShutdown = $null
    $leadStopped = $null
    for ($i = 0; $i -lt $firstUp; $i++) {
        $k = [string]$evs[$i].kind
        if ($k -eq 'shutdown' -and -not $leadShutdown) { $leadShutdown = $evs[$i] }
        elseif ($k -eq 'stopped' -and -not $leadStopped) { $leadStopped = $evs[$i] }
    }
    if ($leadShutdown -or $leadStopped) {
        $upStart = $WindowFirst
        $shutdownT = if ($leadShutdown) { [string]$leadShutdown.t } else { $null }
        $stoppedT = if ($leadStopped) { [string]$leadStopped.t } else { $null }
        $nextUpT = if ($upIdx.Count -gt 0) { [string]$evs[$upIdx[0]].t } else { $null }
        $uptimeSec = if ($upStart -and $shutdownT) { Get-LogTimestampDeltaSec -FromTs $upStart -ToTs $shutdownT } else { $null }
        $stopSec = if ($shutdownT -and $stoppedT) { Get-LogTimestampDeltaSec -FromTs $shutdownT -ToTs $stoppedT } else { $null }
        $downSec = $null
        if ($stoppedT -and $nextUpT) {
            $downSec = Get-LogTimestampDeltaSec -FromTs $stoppedT -ToTs $nextUpT
        }
        $stillDown = [bool]($stoppedT -and -not $nextUpT)
        [void]$cycles.Add([ordered]@{
                up           = $upStart
                upImplied    = $true
                shutdown     = $shutdownT
                stopped      = $stoppedT
                nextUp       = $nextUpT
                uptimeSec    = $uptimeSec
                uptime       = (Format-DurationLabel -Seconds $uptimeSec)
                stopSec      = $stopSec
                stopDuration = (Format-DurationLabel -Seconds $stopSec)
                downtimeSec  = $downSec
                downtime     = (Format-DurationLabel -Seconds $downSec)
                stillUp      = $false
                stillDown    = $stillDown
            })
    }

    for ($u = 0; $u -lt $upIdx.Count; $u++) {
        $ui = [int]$upIdx[$u]
        $upT = [string]$evs[$ui].t
        $end = if (($u + 1) -lt $upIdx.Count) { [int]$upIdx[$u + 1] } else { $evs.Count }
        $shutdownT = $null
        $stoppedT = $null
        for ($j = $ui + 1; $j -lt $end; $j++) {
            $k = [string]$evs[$j].kind
            if ($k -eq 'shutdown' -and -not $shutdownT) { $shutdownT = [string]$evs[$j].t }
            elseif ($k -eq 'stopped' -and -not $stoppedT) { $stoppedT = [string]$evs[$j].t }
        }
        $nextUpT = if (($u + 1) -lt $upIdx.Count) { [string]$evs[$upIdx[$u + 1]].t } else { $null }
        $stillUp = -not $shutdownT
        $uptimeSec = $null
        if ($shutdownT) { $uptimeSec = Get-LogTimestampDeltaSec -FromTs $upT -ToTs $shutdownT }
        elseif ($stillUp -and -not $nextUpT -and $WindowLast) {
            $uptimeSec = Get-LogTimestampDeltaSec -FromTs $upT -ToTs $WindowLast
        }
        $stopSec = if ($shutdownT -and $stoppedT) { Get-LogTimestampDeltaSec -FromTs $shutdownT -ToTs $stoppedT } else { $null }
        $downSec = $null
        if ($stoppedT -and $nextUpT) {
            $downSec = Get-LogTimestampDeltaSec -FromTs $stoppedT -ToTs $nextUpT
        }
        $stillDown = [bool]($stoppedT -and -not $nextUpT)
        [void]$cycles.Add([ordered]@{
                up           = $upT
                upImplied    = $false
                shutdown     = $shutdownT
                stopped      = $stoppedT
                nextUp       = $nextUpT
                uptimeSec    = $uptimeSec
                uptime       = (Format-DurationLabel -Seconds $uptimeSec)
                stopSec      = $stopSec
                stopDuration = (Format-DurationLabel -Seconds $stopSec)
                downtimeSec  = $downSec
                downtime     = (Format-DurationLabel -Seconds $downSec)
                stillUp      = $stillUp
                stillDown    = $stillDown
            })
    }

    return @($cycles.ToArray())
}

function Convert-WindowBound {
    param(
        [string]$Text,
        [ValidateSet('From', 'To')]
        [string]$Kind
    )
    $dt = Convert-LogTimestamp -Text $Text
    if ($null -eq $dt) {
        throw "Invalid -$Kind value '$Text'. Use e.g. '2026.09.04 09:00' or '2026.09.04'."
    }
    # Date-only -To means through end of that calendar day
    if ($Kind -eq 'To' -and $Text -notmatch '\d{1,2}:\d{2}') {
        $dt = $dt.Date.AddDays(1).AddMilliseconds(-1)
    }
    return $dt
}

function Resolve-LogPath {
    param([string]$Path)

    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "Log file not found: $Path"
        }
        return (Resolve-Path -LiteralPath $Path).Path
    }

    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $searchDirs = @($scriptDir, (Get-Location).Path) | Select-Object -Unique

    # Prefer live log name first
    foreach ($dir in $searchDirs) {
        $exact = Join-Path $dir 'PVSS_II.log'
        if (Test-Path -LiteralPath $exact -PathType Leaf) {
            return (Resolve-Path -LiteralPath $exact).Path
        }
    }

    # Then exact rotated backup name
    foreach ($dir in $searchDirs) {
        $exactBak = Join-Path $dir 'PVSS_II.log.bak'
        if (Test-Path -LiteralPath $exactBak -PathType Leaf) {
            Write-Host ("Using backup log: {0}" -f $exactBak) -ForegroundColor Cyan
            return (Resolve-Path -LiteralPath $exactBak).Path
        }
    }

    # Newest among PVSS_II*.log and PVSS_II*.log.bak
    $found = foreach ($dir in $searchDirs) {
        Get-ChildItem -LiteralPath $dir -Filter 'PVSS_II*.log' -File -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $dir -Filter 'PVSS_II*.log.bak' -File -ErrorAction SilentlyContinue
    }
    $newest = $found | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($newest) {
        Write-Host ("Using newest matching log: {0}" -f $newest.FullName) -ForegroundColor Cyan
        return $newest.FullName
    }

    $hint = ($searchDirs | ForEach-Object { "  - $_" }) -join [Environment]::NewLine
    throw @"
Log file not found.
Looked for PVSS_II.log, PVSS_II.log.bak, PVSS_II*.log, and PVSS_II*.log.bak in:
$hint

Put PVSS_II.log (or a .log.bak) in the same folder as Analyze-PvssLog.ps1, or pass -LogPath.
"@
}

function Normalize-Message {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = $Text
    $t = [regex]::Replace($t, '\d{4}\.\d{2}\.\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+', '<TS>')
    $t = [regex]::Replace($t, '\b\d{2}:\d{2}:\d{2}\.\d+\b', '<TIME>')
    $t = [regex]::Replace($t, '\b(?:tid|cc|Sys|Page|ViewId|#DpIdentifier)=[^\s,;)]+', '<KV>')
    $t = [regex]::Replace($t, '\bdevice\s+\d+\b', 'device <N>', 'IgnoreCase')
    $t = [regex]::Replace($t, '\bDP=\d+\.\d+:[^;\s]+', 'DP=<ID>')
    $t = [regex]::Replace($t, '\b\d{5,}\b', '<NUM>')
    $t = [regex]::Replace($t, '\s+', ' ')
    if ($t.Length -gt 300) { $t = $t.Substring(0, 300) + '...' }
    return $t.Trim()
}

function Get-PerfCategory {
    param([string]$Line)
    $rules = @(
        @{ Name = 'Timeout'; Pattern = '(?i)\btimeout\b|\btimed?\s*out\b' }
        @{ Name = 'Buffer/Overrun'; Pattern = '(?i)overrun|buffer\s*(full|overflow|overrun)|BufferOverrun' }
        @{ Name = 'Queue/Pending'; Pattern = '(?i)pending|backlog|queue\s*(full|overflow)|maxInput|maxPend' }
        @{ Name = 'CNS/Resolve'; Pattern = '(?i)ResolveNodes|ReducedFunction|ICns\.|\.cns=' }
        @{ Name = 'Session/Logon'; Pattern = '(?i)TryRenewSession|LogonManager|session' }
        @{ Name = 'Memory'; Pattern = '(?i)\bmemory\b|\bOOM\b|out of memory|WorkingSet' }
        @{ Name = 'Connection'; Pattern = '(?i)disconnect|connection\s*(lost|refused|reset)|cannot connect|Could not get' }
        @{ Name = 'Driver/Device'; Pattern = '(?i)object list|device\s+\d+|BACnet|Apogee' }
        @{ Name = 'Restart/Kill'; Pattern = '(?i)SecKill|restart|killed|emergency|emergencyKill' }
        @{ Name = 'Slow/Delay'; Pattern = '(?i)\bslow\b|\bdelay\b|\blatency\b|took\s+\d+\s*ms' }
    )
    foreach ($r in $rules) {
        if ($Line -match $r.Pattern) { return $r.Name }
    }
    return $null
}

function Add-Pattern {
    param(
        [hashtable]$CountMap,
        [hashtable]$SampleMap,
        [hashtable]$TimeMap = $null,
        [string]$Norm,
        [string]$Line,
        [string]$Timestamp = $null,
        [int]$SampleLimit
    )
    if (-not $CountMap.ContainsKey($Norm)) {
        $CountMap[$Norm] = 0
        $SampleMap[$Norm] = New-Object System.Collections.Generic.List[string]
        if ($null -ne $TimeMap -and -not [string]::IsNullOrEmpty($Timestamp)) {
            $TimeMap[$Norm] = @{ First = $Timestamp; Last = $Timestamp }
        }
    }
    $CountMap[$Norm]++
    if ($null -ne $TimeMap -and -not [string]::IsNullOrEmpty($Timestamp)) {
        if (-not $TimeMap.ContainsKey($Norm)) {
            $TimeMap[$Norm] = @{ First = $Timestamp; Last = $Timestamp }
        }
        else {
            $bounds = $TimeMap[$Norm]
            if ($Timestamp -lt $bounds.First) { $bounds.First = $Timestamp }
            if ($Timestamp -gt $bounds.Last) { $bounds.Last = $Timestamp }
        }
    }
    if ($SampleLimit -gt 0 -and $SampleMap[$Norm].Count -lt $SampleLimit) {
        $sample = if ($Line.Length -gt 500) { $Line.Substring(0, 500) + '...' } else { $Line }
        [void]$SampleMap[$Norm].Add($sample)
    }
}

function Read-PromptDefault {
    param([string]$PromptText, [string]$DefaultValue)
    Write-Host ($PromptText + " [default: $DefaultValue]") -ForegroundColor Yellow
    $ans = Read-Host
    if ([string]::IsNullOrWhiteSpace($ans)) { return $DefaultValue }
    return $ans.Trim()
}

function Read-PromptOptional {
    param([string]$PromptText, [string]$DefaultLabel)
    Write-Host ($PromptText + " [default: $DefaultLabel]") -ForegroundColor Yellow
    $ans = Read-Host
    if ([string]::IsNullOrWhiteSpace($ans)) { return '' }
    return $ans.Trim()
}

function Read-PromptTimeBound {
    param(
        [string]$PromptText,
        [string]$DefaultLabel,
        [ValidateSet('From', 'To')]
        [string]$Kind,
        [switch]$AllowEmpty
    )
    while ($true) {
        Write-Host ($PromptText + " [default: $DefaultLabel]") -ForegroundColor Yellow
        $ans = Read-Host
        if ([string]::IsNullOrWhiteSpace($ans)) {
            if ($AllowEmpty) { return '' }
            Write-Host '  A value is required.' -ForegroundColor Red
            continue
        }
        $ans = $ans.Trim()
        try {
            [void](Convert-WindowBound -Text $ans -Kind $Kind)
            return $ans
        }
        catch {
            Write-Host ("  Invalid time format: {0}" -f $_.Exception.Message) -ForegroundColor Red
            Write-Host '  Examples: 2026.09.04 09:00   or   2026.09.04' -ForegroundColor DarkYellow
        }
    }
}

function Get-LogTextEncoding {
    # WinCC OA / GMS logs commonly use UTF-8 (facility markers like Â«MacroManagerÂ»).
    # Encoding.Default (Windows-1252) turns UTF-8 C2 AB into mojibake Ã‚Â«.
    return (New-Object System.Text.UTF8Encoding $false)
}

function Get-SiblingReportPath {
    param(
        [string]$Path,
        [ValidateSet('txt', 'html')]
        [string]$Extension
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if ($Path -match '\.analysis\.(txt|html)$') {
        return ($Path -replace '\.analysis\.(txt|html)$', ('.analysis.' + $Extension))
    }
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    if ([string]::IsNullOrEmpty($dir)) {
        return ($base + '.' + $Extension)
    }
    return (Join-Path $dir ($base + '.' + $Extension))
}

function Convert-AnalysisReportToHtml {
    param(
        [string]$TextReport,
        [string]$LogFile,
        [string]$Generated,
        [string]$Version = '1.3',
        [string]$Author = 'Cisum'
    )

    $enc = {
        param([string]$s)
        if ($null -eq $s) { return '' }
        return [System.Net.WebUtility]::HtmlEncode($s)
    }

    $sections = New-Object System.Collections.Generic.List[object]
    $current = [ordered]@{ Kind = 'header'; Title = 'Report header'; Lines = New-Object System.Collections.Generic.List[string] }
    foreach ($raw in ($TextReport -split "`r?`n")) {
        # Banner / rule lines (must run before === title === matching)
        if ($raw -match '^[=-]{5,}\s*$') { continue }
        if ($raw -match '^\s*PVSS / WinCC OA Log Analysis Report\s*$') { continue }
        if ($raw -match '^\s*End of report\s*$') { continue }

        if ($raw -match '^---\s*(.+?)\s*---\s*$') {
            $title = $Matches[1].Trim()
            if ($title -match '^[=-]+$') { continue }
            $sections.Add($current)
            $current = [ordered]@{ Kind = 'section'; Title = $title; Lines = New-Object System.Collections.Generic.List[string] }
            continue
        }
        if ($raw -match '^===\s*(.+?)\s*===\s*$') {
            $title = $Matches[1].Trim()
            # Ignore decoy matches from long ==== banners
            if ($title -match '^[=-]+$' -or $title -notmatch '[A-Za-z0-9]') { continue }
            $sections.Add($current)
            $current = [ordered]@{ Kind = 'subsection'; Title = $title; Lines = New-Object System.Collections.Generic.List[string] }
            continue
        }
        [void]$current.Lines.Add($raw)
    }
    $sections.Add($current)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine('<html lang="en">')
    [void]$sb.AppendLine('<head>')
    [void]$sb.AppendLine('<meta charset="utf-8" />')
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1" />')
    [void]$sb.AppendLine('<title>PVSS_II Offline analysis report</title>')
    [void]$sb.AppendLine('<style>')
    [void]$sb.AppendLine(@'
:root {
  --siemens-petrol: #009999;
  --siemens-snow: #ffffff;
  --siemens-stone: #879baa;
  --siemens-sand: #aaaa96;
  --bg-deep: #0f1923;
  --bg-panel: #15202b;
  --bg-elevated: #1c2834;
  --border: rgba(135, 155, 170, 0.35);
  --text: #ffffff;
  --text-muted: #879baa;
  --text-meta: #aaaa96;
  --sev-fatal: #e00000;
  --sev-severe: #c000a0;
  --sev-error: #b00040;
  --sev-warning: #e07000;
  --sev-info: #008000;
  --mono: "Cascadia Mono", "Consolas", "Courier New", monospace;
  --sans: "Segoe UI", "Candara", "Calibri", sans-serif;
  --chrome-h: 4.75rem;
}
* { box-sizing: border-box; }
/* Only one scroll offset â€” padding + margin were stacking and landing TOC jumps too low. */
html { scroll-padding-top: calc(var(--chrome-h) + 0.5rem); }
body {
  margin: 0;
  font-family: var(--sans);
  color: var(--text);
  background: var(--bg-deep);
  line-height: 1.45;
}
header.app {
  padding: 0.55rem 1.15rem 0.5rem;
  border-bottom: 1px solid var(--border);
  background: var(--bg-panel);
  position: sticky;
  top: 0;
  z-index: 2;
}
header.app h1 {
  margin: 0 0 0.2rem;
  font-size: 1.05rem;
  font-weight: 700;
  letter-spacing: 0.01em;
  color: var(--siemens-petrol);
}
header.app .meta {
  color: var(--text-meta);
  font-size: 0.8rem;
  line-height: 1.35;
}
header.app .meta .mono {
  font-family: var(--mono);
  font-size: 0.76rem;
  word-break: break-all;
}
.layout {
  display: grid;
  grid-template-columns: minmax(200px, 260px) 1fr;
  gap: 1rem;
  max-width: 1200px;
  margin: 0 auto;
  padding: 0.85rem 1.15rem 2.5rem;
}
nav.toc {
  position: sticky;
  top: calc(var(--chrome-h) + 0.35rem);
  align-self: start;
  background: var(--bg-panel);
  border: 1px solid var(--border);
  border-radius: 2px;
  padding: 0.75rem 0.85rem;
  max-height: calc(100vh - var(--chrome-h) - 1rem);
  overflow: auto;
}
nav.toc h2 {
  margin: 0 0 0.45rem;
  font-size: 0.72rem;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--text-muted);
}
nav.toc a {
  display: block;
  color: var(--text);
  text-decoration: none;
  font-size: 0.88rem;
  padding: 0.22rem 0.28rem;
  border-radius: 2px;
}
nav.toc a:hover {
  background: var(--bg-elevated);
  color: var(--siemens-petrol);
}
nav.toc a.sub {
  padding-left: 0.85rem;
  color: var(--text-muted);
  font-size: 0.82rem;
}
main section {
  background: var(--bg-panel);
  border: 1px solid var(--border);
  border-radius: 2px;
  padding: 0.85rem 0.95rem 0.95rem;
  margin-bottom: 0.85rem;
  scroll-margin-top: 0;
}
main section h2, main section h3 {
  margin: 0 0 0.55rem;
  font-size: 1.02rem;
  border-bottom: 1px solid var(--border);
  padding-bottom: 0.35rem;
  color: var(--siemens-petrol);
}
main section h3 { font-size: 0.95rem; color: var(--text-muted); }
main section.sev-FATAL h3 { color: var(--sev-fatal); }
main section.sev-SEVERE h3 { color: var(--sev-severe); }
main section.sev-ERROR h3 { color: var(--sev-error); }
main section.sev-WARNING h3 { color: var(--sev-warning); }
main section.sev-INFO h3 { color: var(--sev-info); }
pre.block {
  margin: 0;
  white-space: pre-wrap;
  word-break: break-word;
  font-family: var(--mono);
  font-size: 0.78rem;
  line-height: 1.4;
  color: var(--text);
  background: var(--bg-elevated);
  border: 1px solid var(--border);
  border-radius: 2px;
  padding: 0.65rem 0.75rem;
}
pre.block.preamble { margin-bottom: 0.65rem; }
table.data {
  width: 100%;
  border-collapse: collapse;
  font-size: 0.82rem;
  font-variant-numeric: tabular-nums;
  margin: 0.35rem 0 0.5rem;
}
table.data th, table.data td {
  text-align: left;
  padding: 0.35rem 0.45rem;
  border-bottom: 1px solid var(--border);
  vertical-align: top;
}
table.data th {
  color: var(--text-muted);
  background: var(--bg-elevated);
  font-weight: 600;
}
.kind-up { color: #90d090; }
.kind-shutdown { color: #ffd0a0; }
.kind-stopped { color: #ffb0b0; }
.mono { font-family: var(--mono); font-size: 0.78rem; word-break: break-word; }
.pattern-list {
  display: flex;
  flex-direction: column;
  gap: 0.7rem;
}
.pattern-card {
  background: var(--bg-elevated);
  border: 1px solid var(--border);
  border-left: 3px solid var(--siemens-petrol);
  border-radius: 2px;
  padding: 0.65rem 0.8rem 0.7rem;
}
main section.sev-FATAL .pattern-card { border-left-color: var(--sev-fatal); }
main section.sev-SEVERE .pattern-card { border-left-color: var(--sev-severe); }
main section.sev-ERROR .pattern-card { border-left-color: var(--sev-error); }
main section.sev-WARNING .pattern-card { border-left-color: var(--sev-warning); }
main section.sev-INFO .pattern-card { border-left-color: var(--sev-info); }
.pattern-card .head {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 0.55rem 0.85rem;
  margin: 0 0 0.5rem;
  padding-bottom: 0.4rem;
  border-bottom: 1px solid var(--border);
}
.pattern-card .rank {
  font-weight: 700;
  font-size: 0.95rem;
  letter-spacing: 0.02em;
}
.pattern-card .count {
  color: var(--text-muted);
  font-family: var(--mono);
  font-size: 0.8rem;
}
.pattern-card .row {
  display: grid;
  grid-template-columns: 4.75rem 1fr;
  gap: 0.2rem 0.65rem;
  margin: 0.28rem 0;
  font-size: 0.78rem;
  line-height: 1.4;
}
.pattern-card .lbl {
  color: var(--text-muted);
  font-family: var(--sans);
  font-size: 0.72rem;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  padding-top: 0.12rem;
}
.pattern-card .val {
  font-family: var(--mono);
  word-break: break-word;
  white-space: pre-wrap;
  color: var(--text);
}
.pattern-card .row.example {
  margin-top: 0.45rem;
  padding-top: 0.45rem;
  border-top: 1px dashed var(--border);
}
.pattern-card .row.example .val { color: var(--text-meta); }
footer {
  max-width: 1200px;
  margin: 0 auto 2rem;
  padding: 0 1.15rem;
  color: var(--text-meta);
  font-size: 0.85rem;
}
@media (max-width: 860px) {
  .layout { grid-template-columns: 1fr; }
  nav.toc { position: static; max-height: none; }
  .pattern-card .row { grid-template-columns: 1fr; gap: 0.1rem; }
  .pattern-card .lbl { padding-top: 0; }
}
'@)
    [void]$sb.AppendLine('</style>')
    [void]$sb.AppendLine('</head>')
    [void]$sb.AppendLine('<body>')
    [void]$sb.AppendLine('<header class="app">')
    [void]$sb.AppendLine('<h1>PVSS_II Offline analysis report</h1>')
    [void]$sb.AppendLine(('<div class="meta">Log: <span class="mono">{0}</span> &middot; Generated: {1} &middot; OfflineAnalyze v{2} by {3}</div>' -f (& $enc $LogFile), (& $enc $Generated), (& $enc $Version), (& $enc $Author)))
    [void]$sb.AppendLine('</header>')
    [void]$sb.AppendLine('<div class="layout">')
    [void]$sb.AppendLine('<nav class="toc">')
    [void]$sb.AppendLine('<h2>Contents</h2>')

    $idx = 0
    foreach ($sec in $sections) {
        $body = ($sec.Lines -join "`n").Trim()
        if ([string]::IsNullOrWhiteSpace($body) -and $sec.Kind -ne 'header') { continue }
        $idx++
        $id = 's' + $idx
        $cls = if ($sec.Kind -eq 'subsection') { ' class="sub"' } else { '' }
        [void]$sb.AppendLine(('<a href="#{0}"{1}>{2}</a>' -f $id, $cls, (& $enc $sec.Title)))
    }

    [void]$sb.AppendLine('</nav>')
    [void]$sb.AppendLine('<main>')

    $idx = 0
    foreach ($sec in $sections) {
        $body = ($sec.Lines -join "`n").TrimEnd()
        # trim leading blank lines
        while ($body.StartsWith("`n")) { $body = $body.Substring(1) }
        if ([string]::IsNullOrWhiteSpace($body) -and $sec.Kind -ne 'header') { continue }
        $idx++
        $id = 's' + $idx
        $sevClass = ''
        if ($sec.Title -match '^(FATAL|SEVERE|ERROR|WARNING|INFO)\b') {
            $sevClass = ' sev-' + $Matches[1]
        }
        [void]$sb.AppendLine(('<section id="{0}" class="{1}{2}">' -f $id, $sec.Kind, $sevClass))
        if ($sec.Kind -eq 'subsection') {
            [void]$sb.AppendLine(('<h3>{0}</h3>' -f (& $enc $sec.Title)))
        }
        else {
            [void]$sb.AppendLine(('<h2>{0}</h2>' -f (& $enc $sec.Title)))
        }
        [void]$sb.AppendLine((Format-ReportSectionBodyHtml -Body $body -Encode $enc))
        [void]$sb.AppendLine('</section>')
    }

    [void]$sb.AppendLine('</main>')
    [void]$sb.AppendLine('</div>')
    [void]$sb.AppendLine(('<footer>Standalone triage aid by {0} - not a substitute for Siemens GMS / WinCC OA support.</footer>' -f (& $enc $Author)))
    [void]$sb.AppendLine('</body>')
    [void]$sb.AppendLine('</html>')
    return $sb.ToString()
}

function Format-ReportSectionBodyHtml {
    param(
        [string]$Body,
        [scriptblock]$Encode
    )
    if ([string]::IsNullOrWhiteSpace($Body)) {
        return '<p class="meta">(empty)</p>'
    }

    $lines = $Body -split "`r?`n"
    $hasPatterns = $false
    $hasPipeTable = $false
    foreach ($ln in $lines) {
        if ($ln -match '^\s*#\d+\s+count=') { $hasPatterns = $true; break }
        if ($ln -match '^\s*\|\s*Up\s*\|') { $hasPipeTable = $true }
    }
    if ($hasPipeTable -and -not $hasPatterns) {
        $preamble = New-Object System.Collections.Generic.List[string]
        $rows = New-Object System.Collections.Generic.List[string[]]
        $header = $null
        foreach ($ln in $lines) {
            if ($ln -match '^\s*\|(.+)\|\s*$') {
                $cells = @($Matches[1].Split('|') | ForEach-Object { $_.Trim() })
                if ($null -eq $header) { $header = $cells; continue }
                [void]$rows.Add($cells)
            }
            elseif (-not [string]::IsNullOrWhiteSpace($ln)) {
                [void]$preamble.Add($ln)
            }
        }
        $out = New-Object System.Text.StringBuilder
        if ($preamble.Count -gt 0) {
            [void]$out.AppendLine(('<pre class="block preamble">{0}</pre>' -f (& $Encode ($preamble -join "`n"))))
        }
        if ($null -ne $header) {
            [void]$out.AppendLine('<table class="data"><thead><tr>')
            foreach ($h in $header) {
                [void]$out.AppendLine(('<th>{0}</th>' -f (& $Encode $h)))
            }
            [void]$out.AppendLine('</tr></thead><tbody>')
            foreach ($r in $rows) {
                [void]$out.AppendLine('<tr>')
                for ($ci = 0; $ci -lt $header.Count; $ci++) {
                    $val = if ($ci -lt $r.Count) { $r[$ci] } else { '' }
                    $cls = ''
                    $hn = $header[$ci]
                    if ($hn -eq 'Up') { $cls = ' class="mono kind-up"' }
                    elseif ($hn -eq 'Shutdown') { $cls = ' class="mono kind-shutdown"' }
                    elseif ($hn -eq 'Stopped') { $cls = ' class="mono kind-stopped"' }
                    elseif ($hn -eq 'Note') { $cls = ' class="meta"' }
                    [void]$out.AppendLine(('<td{0}>{1}</td>' -f $cls, (& $Encode $val)))
                }
                [void]$out.AppendLine('</tr>')
            }
            [void]$out.AppendLine('</tbody></table>')
        }
        return $out.ToString()
    }
    if (-not $hasPatterns) {
        return ('<pre class="block">{0}</pre>' -f (& $Encode $Body))
    }

    $preamble = New-Object System.Collections.Generic.List[string]
    $cards = New-Object System.Collections.Generic.List[hashtable]
    $cur = $null
    foreach ($ln in $lines) {
        if ($ln -match '^\s*#(\d+)\s+count=(.+)\s*$') {
            if ($null -ne $cur) { [void]$cards.Add($cur) }
            $cur = @{
                Rank     = $Matches[1]
                Count    = $Matches[2].Trim()
                Pattern  = ''
                First    = ''
                Last     = ''
                Examples = New-Object System.Collections.Generic.List[string]
            }
            continue
        }
        if ($null -eq $cur) {
            if (-not [string]::IsNullOrWhiteSpace($ln)) { [void]$preamble.Add($ln) }
            continue
        }
        if ($ln -match '^\s*pattern:\s*(.*)$') { $cur.Pattern = $Matches[1]; continue }
        if ($ln -match '^\s*first\s*:\s*(.*)$') { $cur.First = $Matches[1]; continue }
        if ($ln -match '^\s*last\s*:\s*(.*)$') { $cur.Last = $Matches[1]; continue }
        if ($ln -match '^\s*example:\s*(.*)$') { [void]$cur.Examples.Add($Matches[1]); continue }
    }
    if ($null -ne $cur) { [void]$cards.Add($cur) }

    $out = New-Object System.Text.StringBuilder
    if ($preamble.Count -gt 0) {
        [void]$out.AppendLine(('<pre class="block preamble">{0}</pre>' -f (& $Encode ($preamble -join "`n"))))
    }
    [void]$out.AppendLine('<div class="pattern-list">')
    foreach ($c in $cards) {
        [void]$out.AppendLine('<article class="pattern-card">')
        [void]$out.AppendLine(('<div class="head"><span class="rank">#{0}</span><span class="count">count={1}</span></div>' -f `
            (& $Encode $c.Rank), (& $Encode $c.Count)))
        if (-not [string]::IsNullOrWhiteSpace($c.Pattern)) {
            [void]$out.AppendLine(('<div class="row"><span class="lbl">pattern</span><span class="val">{0}</span></div>' -f (& $Encode $c.Pattern)))
        }
        if (-not [string]::IsNullOrWhiteSpace($c.First)) {
            [void]$out.AppendLine(('<div class="row"><span class="lbl">first</span><span class="val">{0}</span></div>' -f (& $Encode $c.First)))
        }
        if (-not [string]::IsNullOrWhiteSpace($c.Last)) {
            [void]$out.AppendLine(('<div class="row"><span class="lbl">last</span><span class="val">{0}</span></div>' -f (& $Encode $c.Last)))
        }
        foreach ($ex in $c.Examples) {
            [void]$out.AppendLine(('<div class="row example"><span class="lbl">example</span><span class="val">{0}</span></div>' -f (& $Encode $ex)))
        }
        [void]$out.AppendLine('</article>')
    }
    [void]$out.AppendLine('</div>')
    return $out.ToString()
}

function Get-LogTimeSpanPeek {
    param(
        [string]$Path,
        [regex]$HeaderRe
    )
    $firstTs = $null
    $lastTs = $null
    $enc = Get-LogTextEncoding

    $fs1 = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $r1 = New-Object System.IO.StreamReader($fs1, $enc, $true, 65536, $true)
        try {
            while ($null -ne ($line = $r1.ReadLine())) {
                $m = $HeaderRe.Match($line)
                if ($m.Success) {
                    $firstTs = $m.Groups[2].Value
                    break
                }
            }
        }
        finally { $r1.Close() }
    }
    finally { $fs1.Close() }

    $fs2 = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $len = $fs2.Length
        $seek = [math]::Max([int64]0, $len - [int64]524288)
        $fs2.Position = $seek
        $r2 = New-Object System.IO.StreamReader($fs2, $enc, $true, 65536, $true)
        try {
            if ($seek -gt 0) { [void]$r2.ReadLine() }  # drop possible partial first line
            while ($null -ne ($line = $r2.ReadLine())) {
                $m = $HeaderRe.Match($line)
                if ($m.Success) { $lastTs = $m.Groups[2].Value }
            }
        }
        finally { $r2.Close() }
    }
    finally { $fs2.Close() }

    return @{ First = $firstTs; Last = $lastTs }
}

function Format-LogDateTime {
    param([datetime]$Value)
    return $Value.ToString('yyyy.MM.dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
}

try {

# --- setup ---
$resolvedLog = Resolve-LogPath -Path $LogPath
if (-not $OutPath) {
    $OutPath = $resolvedLog + '.analysis.txt'
}
else {
    if (-not [System.IO.Path]::IsPathRooted($OutPath)) {
        $base = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $OutPath = Join-Path $base $OutPath
    }
}

$fileInfo = Get-Item -LiteralPath $resolvedLog
$peekHeaderRe = [regex]'^([^,]+),\s*(\d{4}\.\d{2}\.\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+),\s*([^,]+),\s*([^,\s]+)'
$timeModeLabel = 'Entire file'

# Resolve time window before streaming (one-pass filter).
# Priority: -LastHours > interactive menu > -From/-To params.
if ($LastHours -gt 0) {
    $peek = Get-LogTimeSpanPeek -Path $resolvedLog -HeaderRe $peekHeaderRe
    if (-not $peek.Last) {
        throw "Could not find a timestamp in the log to apply -LastHours $LastHours."
    }
    $endDt = Convert-LogTimestamp -Text $peek.Last
    if ($null -eq $endDt) {
        throw "Could not parse last log timestamp '$($peek.Last)' for -LastHours."
    }
    $startDt = $endDt.AddHours(-1 * $LastHours)
    $From = Format-LogDateTime -Value $startDt
    $To = Format-LogDateTime -Value $endDt
    $timeModeLabel = "Last $LastHours hour(s)"
    Write-Host ("Time filter: last {0} hour(s) ending {1}" -f $LastHours, $peek.Last) -ForegroundColor Cyan
}
elseif ($Interactive -and [string]::IsNullOrWhiteSpace($From) -and [string]::IsNullOrWhiteSpace($To)) {
    Write-Host ''
    Write-Host ("Log: {0}" -f $resolvedLog) -ForegroundColor Cyan
    Write-Host ("Size: {0:N2} MB" -f ($fileInfo.Length / 1MB))
    $peek = Get-LogTimeSpanPeek -Path $resolvedLog -HeaderRe $peekHeaderRe
    if ($peek.First -or $peek.Last) {
        Write-Host ("Log span (peek): {0}  -->  {1}" -f $(if ($peek.First) { $peek.First } else { '?' }), $(if ($peek.Last) { $peek.Last } else { '?' })) -ForegroundColor Cyan
    }

    $mode = Read-PromptDefault -PromptText 'Time filter: [E] Entire file  [H] Last N hours  [W] Absolute From/To' -DefaultValue 'E'
    switch -Regex ($mode) {
        '^[Hh]' {
            if (-not $peek.Last) {
                throw 'Cannot use last-N-hours: no timestamp found near the end of the log.'
            }
            $endDt = Convert-LogTimestamp -Text $peek.Last
            if ($null -eq $endDt) {
                throw "Cannot parse last log timestamp '$($peek.Last)' for last-N-hours."
            }
            $hours = 0
            while ($hours -le 0) {
                $hAns = Read-PromptDefault -PromptText 'How many hours back from end of log?' -DefaultValue '6'
                $parsedH = 0
                if ([int]::TryParse($hAns, [ref]$parsedH) -and $parsedH -ge 1 -and $parsedH -le 8760) {
                    $hours = $parsedH
                }
                else {
                    Write-Host '  Enter a whole number of hours between 1 and 8760.' -ForegroundColor Red
                }
            }
            $startDt = $endDt.AddHours(-1 * $hours)
            $From = Format-LogDateTime -Value $startDt
            $To = Format-LogDateTime -Value $endDt
            $LastHours = $hours
            $timeModeLabel = "Last $hours hour(s)"
            Write-Host (" Using: {0}  -->  {1}" -f $From, $To) -ForegroundColor DarkGray
        }
        '^[Ww]' {
            $From = Read-PromptTimeBound -PromptText 'From time (e.g. 2026.09.04 09:00)' -DefaultLabel 'start of file' -Kind From -AllowEmpty
            $To = Read-PromptTimeBound -PromptText 'To time   (e.g. 2026.09.04 12:00)' -DefaultLabel 'end of file' -Kind To -AllowEmpty
            if ($From -or $To) {
                $timeModeLabel = 'Absolute From/To'
            }
            else {
                $timeModeLabel = 'Entire file'
            }
        }
        default {
            $From = ''
            $To = ''
            $timeModeLabel = 'Entire file'
        }
    }
}
elseif ($Interactive) {
    # Interactive but From/To already provided on the command line
    Write-Host ''
    Write-Host ("Log: {0}" -f $resolvedLog) -ForegroundColor Cyan
    Write-Host ("Size: {0:N2} MB" -f ($fileInfo.Length / 1MB))
    if ($From) { Write-Host (" From (parameter): {0}" -f $From) -ForegroundColor DarkGray }
    if ($To) { Write-Host (" To   (parameter): {0}" -f $To) -ForegroundColor DarkGray }
    $timeModeLabel = 'Absolute From/To (parameter)'
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()

$fromDt = $null
$toDt = $null
if (-not [string]::IsNullOrWhiteSpace($From)) {
    try { $fromDt = Convert-WindowBound -Text $From -Kind From }
    catch {
        if ($Interactive) {
            Write-Host $_.Exception.Message -ForegroundColor Red
            $From = Read-PromptTimeBound -PromptText 'From time (retry)' -DefaultLabel 'start of file' -Kind From -AllowEmpty
            if ($From) { $fromDt = Convert-WindowBound -Text $From -Kind From }
        }
        else { throw }
    }
}
if (-not [string]::IsNullOrWhiteSpace($To)) {
    try { $toDt = Convert-WindowBound -Text $To -Kind To }
    catch {
        if ($Interactive) {
            Write-Host $_.Exception.Message -ForegroundColor Red
            $To = Read-PromptTimeBound -PromptText 'To time (retry)' -DefaultLabel 'end of file' -Kind To -AllowEmpty
            if ($To) { $toDt = Convert-WindowBound -Text $To -Kind To }
        }
        else { throw }
    }
}
if ($fromDt -and $toDt -and $fromDt -gt $toDt) {
    if ($Interactive) {
        Write-Host ("-From ($From) is after -To ($To). Re-enter the absolute window.") -ForegroundColor Red
        $From = Read-PromptTimeBound -PromptText 'From time' -DefaultLabel 'start of file' -Kind From -AllowEmpty
        $To = Read-PromptTimeBound -PromptText 'To time' -DefaultLabel 'end of file' -Kind To -AllowEmpty
        $fromDt = $null; $toDt = $null
        if ($From) { $fromDt = Convert-WindowBound -Text $From -Kind From }
        if ($To) { $toDt = Convert-WindowBound -Text $To -Kind To }
        if ($fromDt -and $toDt -and $fromDt -gt $toDt) {
            throw "-From ($From) is still after -To ($To)."
        }
    }
    else {
        throw "-From ($From) is after -To ($To)."
    }
}
$filterByTime = ($null -ne $fromDt -or $null -ne $toDt)
$outsideWindow = 0

$severity = @{}
$components = @{}
$patternsBySev = @{
    FATAL = @{}; SEVERE = @{}; ERROR = @{}; WARNING = @{}; INFO = @{}
}
$patternSampleBySev = @{
    FATAL = @{}; SEVERE = @{}; ERROR = @{}; WARNING = @{}; INFO = @{}
}
$patternTimeBySev = @{
    FATAL = @{}; SEVERE = @{}; ERROR = @{}; WARNING = @{}; INFO = @{}
}
$compSev = @{}              # comp -> @{ SEV -> count }
$compPatterns = @{}         # comp -> @{ SEV -> @{ norm -> count } }
$compPatternSamples = @{}   # comp -> @{ SEV -> @{ norm -> samples } }
$compPatternTimes = @{}     # comp -> @{ SEV -> @{ norm -> @{First;Last} } }
$perfCats = @{}
$hourly = @{}
$hourlySevere = @{}
$hourlyWarning = @{}
$firstTs = $null
$lastTs = $null
$totalLines = 0
$parsedLines = 0
$severeLines = 0
$warningLines = 0

# BACnet module
$bacFailedEvents = 0
$bacOkEvents = 0
$bacFailedByDevice = @{}
$bacOkByDevice = @{}
$bacLastStatus = @{}       # device id -> Failed|OK (last seen in window)
$bacFlipByDevice = @{}     # device id -> count of Failed<->OK changes
$bacObjectListEvents = 0
$bacObjectListByDevice = @{}
$bacObjectListSample = $null
$bacFailedSample = $null
$bacOkSample = $null
$bacCollectTrend = 0
$bacTimeSync = 0
$bacCollectTrendByCode = @{}
$bacCollectTrendByProp = @{}
$bacCollectTrendSample = $null
$bacTimeSyncByCode = @{}
$bacTimeSyncByProp = @{}
$bacTimeSyncSample = $null
$reBacFailed = [regex]'Device\s+(\d+)\s+Status is now Failed'
$reBacOk = [regex]'Device\s+(\d+)\s+Status is now OK'
$reBacObjList = [regex]'(?i)Could not get object list(?:\s+count)?(?:\s+for)?\s+device\s+(\d+)'
$reBacCollectTrend = [regex]'Command\s+"BACnetCollectTrend"'
$reBacTimeSyncCmd = [regex]'Command\s+"BACnetTimeSync"'
$reBacCmdDetail = [regex]'Error Code (\d+) for Property "([^"]+)" and Command "(BACnetCollectTrend|BACnetTimeSync)"'
$bacFlapMinFlips = 3       # count as flapper when Failed<->OK changes >= this

# CNS thin module
$cnsResolveNodes = 0
$cnsReducedFunction = 0
$cnsICns = 0
$cnsTryRenew = 0
$cnsPatterns = @{}
$cnsPatternSamples = @{}
$cnsPatternTimes = @{}

# CoHo thin module
$cohoStuckEvents = 0
$cohoStuckNames = @{}
$cohoStuckSample = $null
$reCohoDiscoveryLoc = [regex]'(?i)DiscoveryLoc:([^\s]+)\s+got stuck\b'
$reCohoDiscoveryCycle = [regex]'(?i)((?:Global|Observer)\s+Discovery Cycle\s+\[[^\]]+\])\s+got stuck\b'

# Apogee thin module (CoHo.Apogee* / Orch.Apogee* header lines) + WCCOAApogeeDrv
$apogeeEvents = 0
$apogeeUpdatePoints = 0
$apogeeRepetition = 0
$apogeeOther = 0
$apogeePpclNames = @{}
$apogeeSample = $null
$apogeeDrvLines = 0
$apogeeTrendOverflow = 0
$apogeeTrendSeq = 0
$apogeeAlertId = 0
$apogeeQueryTimeout = 0
$apogeeGetDataFail = 0
$apogeeTrendByDevice = @{}
$apogeeTrendByName = @{}
$apogeeGetDataByDevice = @{}
$apogeeAlertSample = $null
$apogeeTrendSample = $null
$apogeeTimeoutSample = $null
$apogeeGetDataSample = $null
$reApogeePpcl = [regex]'(?i)PPCL Program Name:\s*(\S+?)(?:System\.|$)'
$reApogeeComp = [regex]'(?i)(?:CoHo|Orch)\.Apogee'
$reApogeeTrendOverflow = [regex]'(?i)Trend buffer overflow for trend\s+(.+?)\s+in device\s+(.+?)\.?\s*$'
$reApogeeTrendSeq = [regex]'(?i)Last sequence number\s+\d+\s+is greater than saved'
$reApogeeAlertId = [regex]'AlertID\s+\S+'
$reApogeeQueryTimeout = [regex]'(?i)pending answer run into timeout'
$reApogeeGetData = [regex]'(?i)Failed to get data for object\s+(.+?)\s+on device\s+([^,]+)'

# Project / manager lifecycle
$projectStartMode = 0
$projectUp = 0
$projectShutdown = 0
$projectStopped = 0
$pmonMgrRestart = 0
$mgrStartProj = 0
$mgrStop = 0
$driverReady = 0
$pmonRestartByComp = @{}
$mgrStartByComp = @{}
$mgrStopByComp = @{}
$blockingByComp = @{}
$unblockingByComp = @{}
$blockingDetected = 0
$blockingCleared = 0
$blockingSample = $null
$unblockingSample = $null
$projectLifecycleEvents = New-Object System.Collections.ArrayList
$reProjectUp = [regex]'The project is up and running'
$reProjectStopped = [regex]'Completely stopped the project'
$reProjectShutdown = [regex]'Got shutdown command'
$reProjectStartMode = [regex]'Manager Start,\s*START_MODE'
$rePmonMgrRestart = [regex]'Detected stopped manager\s+(\S+)\s+-\s+restarting'
$reMgrStartProj = [regex]'Manager Start,\s*PROJ,'
$reMgrStopMsg = [regex]'Manager Stop\s*$'
$reDriverReady = [regex]'(?i)Driver is configured with .+\s+and is now running'
$reBlockingStart = [regex]'Blocking Manager\s+(\S+)\s+detected(?:\.\s*No heartbeat since\s+(\d+)\s+seconds?)?'
$reBlockingEnd = [regex]'Manager\s+(\S+)\s+is no longer blocking'

$lineRe = [regex]'^([^,]+),\s*(\d{4}\.\d{2}\.\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+),\s*([^,]+),\s*([^,\s]+)'

Write-Host "Analyzing: $resolvedLog"
Write-Host ("Size: {0:N2} MB" -f ($fileInfo.Length / 1MB))
Write-Host ("Report format: {0}" -f $Format) -ForegroundColor DarkGray
if ($filterByTime) {
    $fromLabel = if ($From) { $From } else { '(start)' }
    $toLabel = if ($To) { $To } else { '(end)' }
    Write-Host ("Time window: {0}  -->  {1}" -f $fromLabel, $toLabel) -ForegroundColor Cyan
}
Write-Host "Streaming..."

$fileLength = [math]::Max(1L, $fileInfo.Length)
$lastProgressPct = -1

$reader = [System.IO.StreamReader]::new($resolvedLog, (Get-LogTextEncoding), $true)
try {
    while ($null -ne ($line = $reader.ReadLine())) {
        $totalLines++

        $pct = [int](100.0 * $reader.BaseStream.Position / $fileLength)
        if ($pct -ne $lastProgressPct -and ($pct % 5 -eq 0 -or $pct -ge 100)) {
            $lastProgressPct = $pct
            Write-Host ("  Progress: {0,3}%  ({1:N0} lines)" -f $pct, $totalLines) -ForegroundColor DarkGray
        }

        $m = $lineRe.Match($line)
        if (-not $m.Success) { continue }

        $comp = $m.Groups[1].Value.Trim()
        $ts = $m.Groups[2].Value
        $sev = $m.Groups[4].Value.Trim().ToUpperInvariant()

        if ($filterByTime) {
            $tsDt = Convert-LogTimestamp -Text $ts
            if ($null -eq $tsDt) {
                $outsideWindow++
                continue
            }
            if ($fromDt -and $tsDt -lt $fromDt) { $outsideWindow++; continue }
            if ($toDt -and $tsDt -gt $toDt) { $outsideWindow++; continue }
        }

        $parsedLines++

        if (-not $firstTs) { $firstTs = $ts }
        $lastTs = $ts

        if (-not $severity.ContainsKey($sev)) { $severity[$sev] = 0 }
        $severity[$sev]++

        if (-not $components.ContainsKey($comp)) { $components[$comp] = 0 }
        $components[$comp]++

        if (-not $compSev.ContainsKey($comp)) { $compSev[$comp] = @{} }
        if (-not $compSev[$comp].ContainsKey($sev)) { $compSev[$comp][$sev] = 0 }
        $compSev[$comp][$sev]++

        $hourKey = if ($ts.Length -ge 13) { $ts.Substring(0, 13) } else { $ts }
        if (-not $hourly.ContainsKey($hourKey)) { $hourly[$hourKey] = 0 }
        $hourly[$hourKey]++

        $isSevere = ($sev -eq 'SEVERE' -or $sev -eq 'FATAL' -or $sev -eq 'ERROR')
        $isWarning = ($sev -eq 'WARNING' -or $sev -eq 'WARN')
        if ($isSevere) {
            $severeLines++
            if (-not $hourlySevere.ContainsKey($hourKey)) { $hourlySevere[$hourKey] = 0 }
            $hourlySevere[$hourKey]++
        }
        if ($isWarning) {
            $warningLines++
            if (-not $hourlyWarning.ContainsKey($hourKey)) { $hourlyWarning[$hourKey] = 0 }
            $hourlyWarning[$hourKey]++
        }

        $perf = Get-PerfCategory -Line $line
        if ($perf) {
            if (-not $perfCats.ContainsKey($perf)) { $perfCats[$perf] = 0 }
            $perfCats[$perf]++
        }

        $sevBucket = $null
        if ($sev -eq 'FATAL') { $sevBucket = 'FATAL' }
        elseif ($sev -eq 'SEVERE') { $sevBucket = 'SEVERE' }
        elseif ($sev -eq 'ERROR') { $sevBucket = 'ERROR' }
        elseif ($isWarning) { $sevBucket = 'WARNING' }
        elseif ($sev -eq 'INFO') { $sevBucket = 'INFO' }

        if ($sevBucket -and $sevBucket -ne 'INFO') {
            $norm = Normalize-Message -Text $line
            Add-Pattern -CountMap $patternsBySev[$sevBucket] -SampleMap $patternSampleBySev[$sevBucket] `
                -TimeMap $patternTimeBySev[$sevBucket] -Norm $norm -Line $line -Timestamp $ts -SampleLimit $SamplePerPattern

            if (-not $compPatterns.ContainsKey($comp)) {
                $compPatterns[$comp] = @{ FATAL = @{}; SEVERE = @{}; ERROR = @{}; WARNING = @{} }
                $compPatternSamples[$comp] = @{ FATAL = @{}; SEVERE = @{}; ERROR = @{}; WARNING = @{} }
                $compPatternTimes[$comp] = @{ FATAL = @{}; SEVERE = @{}; ERROR = @{}; WARNING = @{} }
            }
            if ($compPatterns[$comp].ContainsKey($sevBucket)) {
                Add-Pattern -CountMap $compPatterns[$comp][$sevBucket] -SampleMap $compPatternSamples[$comp][$sevBucket] `
                    -TimeMap $compPatternTimes[$comp][$sevBucket] -Norm $norm -Line $line -Timestamp $ts -SampleLimit $SamplePerPattern
            }
        }
        elseif ($sevBucket -eq 'INFO') {
            # Keep INFO patterns only for notable BACnet status lines (avoids huge INFO maps)
            if ($line -match 'Status is now (Failed|OK)') {
                $norm = Normalize-Message -Text $line
                Add-Pattern -CountMap $patternsBySev['INFO'] -SampleMap $patternSampleBySev['INFO'] `
                    -TimeMap $patternTimeBySev['INFO'] -Norm $norm -Line $line -Timestamp $ts -SampleLimit $SamplePerPattern
            }
        }

        # --- BACnet ---
        if ($comp -match 'BACnet') {
            $bacNewStatus = $null
            $bacDevId = $null
            $mf = $reBacFailed.Match($line)
            if ($mf.Success) {
                $bacFailedEvents++
                $bacDevId = $mf.Groups[1].Value
                $bacNewStatus = 'Failed'
                if (-not $bacFailedByDevice.ContainsKey($bacDevId)) { $bacFailedByDevice[$bacDevId] = 0 }
                $bacFailedByDevice[$bacDevId]++
                if (-not $bacFailedSample) { $bacFailedSample = $line }
            }
            else {
                $mo = $reBacOk.Match($line)
                if ($mo.Success) {
                    $bacOkEvents++
                    $bacDevId = $mo.Groups[1].Value
                    $bacNewStatus = 'OK'
                    if (-not $bacOkByDevice.ContainsKey($bacDevId)) { $bacOkByDevice[$bacDevId] = 0 }
                    $bacOkByDevice[$bacDevId]++
                    if (-not $bacOkSample) { $bacOkSample = $line }
                }
            }
            if ($bacDevId -and $bacNewStatus) {
                if ($bacLastStatus.ContainsKey($bacDevId) -and $bacLastStatus[$bacDevId] -ne $bacNewStatus) {
                    if (-not $bacFlipByDevice.ContainsKey($bacDevId)) { $bacFlipByDevice[$bacDevId] = 0 }
                    $bacFlipByDevice[$bacDevId]++
                }
                $bacLastStatus[$bacDevId] = $bacNewStatus
            }
            $ml = $reBacObjList.Match($line)
            if ($ml.Success) {
                $bacObjectListEvents++
                $id = $ml.Groups[1].Value
                if (-not $bacObjectListByDevice.ContainsKey($id)) { $bacObjectListByDevice[$id] = 0 }
                $bacObjectListByDevice[$id]++
                if (-not $bacObjectListSample) { $bacObjectListSample = $line }
            }
        }

        # BACnet orchestration commands often log under CoHo, not WCCOAGmsBACnet
        $mBacCmd = $reBacCmdDetail.Match($line)
        if ($mBacCmd.Success) {
            $code = $mBacCmd.Groups[1].Value
            $prop = $mBacCmd.Groups[2].Value
            $cmd = $mBacCmd.Groups[3].Value
            if ($cmd -eq 'BACnetCollectTrend') {
                $bacCollectTrend++
                if (-not $bacCollectTrendByCode.ContainsKey($code)) { $bacCollectTrendByCode[$code] = 0 }
                $bacCollectTrendByCode[$code]++
                if (-not $bacCollectTrendByProp.ContainsKey($prop)) { $bacCollectTrendByProp[$prop] = 0 }
                $bacCollectTrendByProp[$prop]++
                if (-not $bacCollectTrendSample) { $bacCollectTrendSample = $line }
            }
            elseif ($cmd -eq 'BACnetTimeSync') {
                $bacTimeSync++
                if (-not $bacTimeSyncByCode.ContainsKey($code)) { $bacTimeSyncByCode[$code] = 0 }
                $bacTimeSyncByCode[$code]++
                if (-not $bacTimeSyncByProp.ContainsKey($prop)) { $bacTimeSyncByProp[$prop] = 0 }
                $bacTimeSyncByProp[$prop]++
                if (-not $bacTimeSyncSample) { $bacTimeSyncSample = $line }
            }
        }
        elseif ($reBacCollectTrend.IsMatch($line)) {
            $bacCollectTrend++
            if (-not $bacCollectTrendSample) { $bacCollectTrendSample = $line }
        }
        elseif ($reBacTimeSyncCmd.IsMatch($line)) {
            $bacTimeSync++
            if (-not $bacTimeSyncSample) { $bacTimeSyncSample = $line }
        }

        # --- CNS ---
        $isCnsLine = $false
        if ($line -match 'ResolveNodes') { $cnsResolveNodes++; $isCnsLine = $true }
        if ($line -match 'ReducedFunction') { $cnsReducedFunction++; $isCnsLine = $true }
        if ($line -match '(?i)\bICns\b|ICns\.') { $cnsICns++; $isCnsLine = $true }
        if ($line -match 'TryRenewSession') { $cnsTryRenew++; $isCnsLine = $true }
        if ($isCnsLine) {
            $norm = Normalize-Message -Text $line
            Add-Pattern -CountMap $cnsPatterns -SampleMap $cnsPatternSamples -TimeMap $cnsPatternTimes `
                -Norm $norm -Line $line -Timestamp $ts -SampleLimit $SamplePerPattern
        }

        # --- CoHo ---
        if ($comp -match 'CoHo' -and $line -match '(?i)got stuck|dropping it') {
            $cohoStuckEvents++
            if (-not $cohoStuckSample) { $cohoStuckSample = $line }
            $name = $null
            $mLoc = $reCohoDiscoveryLoc.Match($line)
            if ($mLoc.Success) {
                $name = 'DiscoveryLoc:' + $mLoc.Groups[1].Value
            }
            else {
                $mCycle = $reCohoDiscoveryCycle.Match($line)
                if ($mCycle.Success) {
                    $name = $mCycle.Groups[1].Value.Trim()
                    # Collapse lock counter lists inside brackets
                    $name = [regex]::Replace($name, ':\s*[\d, ]+', ': <N>')
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                if (-not $cohoStuckNames.ContainsKey($name)) { $cohoStuckNames[$name] = 0 }
                $cohoStuckNames[$name]++
            }
        }

        # --- Apogee (CoHo.Apogee* / Orch.Apogee*) ---
        if ($reApogeeComp.IsMatch($line)) {
            $apogeeEvents++
            if (-not $apogeeSample) { $apogeeSample = $line }
            if ($line -match '(?i)UpdatePoints') {
                $apogeeUpdatePoints++
                $mPpcl = $reApogeePpcl.Match($line)
                if ($mPpcl.Success) {
                    $pn = $mPpcl.Groups[1].Value.Trim()
                    if (-not [string]::IsNullOrWhiteSpace($pn)) {
                        if (-not $apogeePpclNames.ContainsKey($pn)) { $apogeePpclNames[$pn] = 0 }
                        $apogeePpclNames[$pn]++
                    }
                }
            }
            elseif ($line -match '(?i)Repetition') {
                $apogeeRepetition++
            }
            else {
                $apogeeOther++
            }
        }

        # --- WCCOAApogeeDrv (not ApogeeBACnet) ---
        if ($comp -match 'ApogeeDrv') {
            $apogeeDrvLines++
            $mOv = $reApogeeTrendOverflow.Match($line)
            if ($mOv.Success) {
                $apogeeTrendOverflow++
                $tName = $mOv.Groups[1].Value.Trim()
                $tDev = $mOv.Groups[2].Value.Trim().TrimEnd('.')
                if ($tName) {
                    if (-not $apogeeTrendByName.ContainsKey($tName)) { $apogeeTrendByName[$tName] = 0 }
                    $apogeeTrendByName[$tName]++
                }
                if ($tDev) {
                    if (-not $apogeeTrendByDevice.ContainsKey($tDev)) { $apogeeTrendByDevice[$tDev] = 0 }
                    $apogeeTrendByDevice[$tDev]++
                }
                if (-not $apogeeTrendSample) { $apogeeTrendSample = $line }
            }
            elseif ($reApogeeTrendSeq.IsMatch($line)) {
                $apogeeTrendSeq++
                if (-not $apogeeTrendSample) { $apogeeTrendSample = $line }
            }
            if ($reApogeeAlertId.IsMatch($line)) {
                $apogeeAlertId++
                if (-not $apogeeAlertSample) { $apogeeAlertSample = $line }
            }
            if ($reApogeeQueryTimeout.IsMatch($line)) {
                $apogeeQueryTimeout++
                if (-not $apogeeTimeoutSample) { $apogeeTimeoutSample = $line }
            }
            $mGd = $reApogeeGetData.Match($line)
            if ($mGd.Success) {
                $apogeeGetDataFail++
                $gdDev = $mGd.Groups[2].Value.Trim()
                if ($gdDev) {
                    if (-not $apogeeGetDataByDevice.ContainsKey($gdDev)) { $apogeeGetDataByDevice[$gdDev] = 0 }
                    $apogeeGetDataByDevice[$gdDev]++
                }
                if (-not $apogeeGetDataSample) { $apogeeGetDataSample = $line }
            }
        }

        if ($reProjectUp.IsMatch($line)) {
            $projectUp++
            if ($projectLifecycleEvents.Count -lt 200) {
                [void]$projectLifecycleEvents.Add([pscustomobject]@{ Kind = 'up'; Time = $ts; Sample = $line })
            }
        }
        if ($reProjectStartMode.IsMatch($line)) { $projectStartMode++ }
        if ($reProjectShutdown.IsMatch($line)) {
            $projectShutdown++
            if ($projectLifecycleEvents.Count -lt 200) {
                [void]$projectLifecycleEvents.Add([pscustomobject]@{ Kind = 'shutdown'; Time = $ts; Sample = $line })
            }
        }
        if ($reProjectStopped.IsMatch($line)) {
            $projectStopped++
            if ($projectLifecycleEvents.Count -lt 200) {
                [void]$projectLifecycleEvents.Add([pscustomobject]@{ Kind = 'stopped'; Time = $ts; Sample = $line })
            }
        }
        $mPmonRr = $rePmonMgrRestart.Match($line)
        if ($mPmonRr.Success) {
            $pmonMgrRestart++
            $rn = $mPmonRr.Groups[1].Value.Trim()
            if ($rn) {
                if (-not $pmonRestartByComp.ContainsKey($rn)) { $pmonRestartByComp[$rn] = 0 }
                $pmonRestartByComp[$rn]++
            }
        }
        if ($reMgrStartProj.IsMatch($line)) {
            $mgrStartProj++
            $sk = ($comp -replace '\s+', '')
            if ($sk) {
                if (-not $mgrStartByComp.ContainsKey($sk)) { $mgrStartByComp[$sk] = 0 }
                $mgrStartByComp[$sk]++
            }
        }
        if ($reMgrStopMsg.IsMatch($line)) {
            $mgrStop++
            $sk = ($comp -replace '\s+', '')
            if ($sk) {
                if (-not $mgrStopByComp.ContainsKey($sk)) { $mgrStopByComp[$sk] = 0 }
                $mgrStopByComp[$sk]++
            }
        }
        if ($reDriverReady.IsMatch($line)) { $driverReady++ }
        $mBlock = $reBlockingStart.Match($line)
        if ($mBlock.Success) {
            $blockingDetected++
            $bk = $mBlock.Groups[1].Value.Trim()
            if ($bk) {
                if (-not $blockingByComp.ContainsKey($bk)) { $blockingByComp[$bk] = 0 }
                $blockingByComp[$bk]++
            }
            if (-not $blockingSample) { $blockingSample = $line }
        }
        $mUnblock = $reBlockingEnd.Match($line)
        if ($mUnblock.Success) {
            $blockingCleared++
            $uk = $mUnblock.Groups[1].Value.Trim()
            if ($uk) {
                if (-not $unblockingByComp.ContainsKey($uk)) { $unblockingByComp[$uk] = 0 }
                $unblockingByComp[$uk]++
            }
            if (-not $unblockingSample) { $unblockingSample = $line }
        }
    }
}
finally {
    $reader.Close()
}

$sw.Stop()

# BACnet last-known status + flapping ranks (from stream maps)
$bacEndedFailed = @($bacLastStatus.GetEnumerator() | Where-Object { $_.Value -eq 'Failed' }).Count
$bacEndedOk = @($bacLastStatus.GetEnumerator() | Where-Object { $_.Value -eq 'OK' }).Count
$bacFlappers = @(
    $bacFlipByDevice.GetEnumerator() |
        Where-Object { $_.Value -ge $bacFlapMinFlips } |
        Sort-Object Value -Descending
)

# Sorted manager list for driver picker / Path D
$managersRanked = @($components.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { $_.Key })

# --- console scan summary (before prompts) ---
Write-Host ''
Write-Host '--- Scan summary ---' -ForegroundColor Cyan
Write-Host (" Lines     : {0:N0} total, {1:N0} analyzed (in window)" -f $totalLines, $parsedLines)
if ($filterByTime) {
    Write-Host (" Outside window (header matches skipped): {0:N0}" -f $outsideWindow)
}
Write-Host (" Time span : {0}  -->  {1}" -f $firstTs, $lastTs)
Write-Host (" Runtime   : {0:N1} s" -f $sw.Elapsed.TotalSeconds)
Write-Host ' Severity  :'
foreach ($e in ($severity.GetEnumerator() | Sort-Object Value -Descending)) {
    Write-Host ('   {0,8:N0}  {1}' -f $e.Value, $e.Key)
}
Write-Host ' Top managers:'
foreach ($e in ($components.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5)) {
    Write-Host ('   {0,8:N0}  {1}' -f $e.Value, $e.Key)
}
Write-Host (" BACnet    : Failed={0:N0} OK={1:N0} endedFailed={2:N0} endedOK={3:N0} flappers(>={4})={5:N0} objectList={6:N0} CollectTrend={7:N0} ({8:N0} props) TimeSync={9:N0} ({10:N0} props)" -f `
    $bacFailedEvents, $bacOkEvents, $bacEndedFailed, $bacEndedOk, $bacFlapMinFlips, $bacFlappers.Count, $bacObjectListEvents, `
    $bacCollectTrend, $bacCollectTrendByProp.Count, $bacTimeSync, $bacTimeSyncByProp.Count)
Write-Host (" CNS       : ResolveNodes={0:N0} ReducedFunction={1:N0} TryRenewSession={2:N0}" -f `
    $cnsResolveNodes, $cnsReducedFunction, $cnsTryRenew)
Write-Host (" CoHo      : stuck/drop={0:N0}" -f $cohoStuckEvents)
Write-Host (" Apogee    : events={0:N0} UpdatePoints={1:N0} PPCL={2:N0} | Drv={3:N0} overflow={4:N0} seq={5:N0} AlertID={6:N0} qTimeout={7:N0} getData={8:N0}" -f `
    $apogeeEvents, $apogeeUpdatePoints, $apogeePpclNames.Count, `
    $apogeeDrvLines, $apogeeTrendOverflow, $apogeeTrendSeq, $apogeeAlertId, $apogeeQueryTimeout, $apogeeGetDataFail)
Write-Host (" Managers  : starts={0:N0} stops={1:N0} pmon-restarts={2:N0} blocking={3:N0} unblocked={4:N0}" -f `
    $mgrStartProj, $mgrStop, $pmonMgrRestart, $blockingDetected, $blockingCleared)
Write-Host (" Project   : up={0:N0} stopped={1:N0} shutdown={2:N0} START_MODE={3:N0}" -f `
    $projectUp, $projectStopped, $projectShutdown, $projectStartMode)
if ($projectUp -gt 0) {
    $upTimesPreview = @($projectLifecycleEvents | Where-Object { $_.Kind -eq 'up' } | Select-Object -First 5 | ForEach-Object { $_.Time })
    if ($upTimesPreview.Count -gt 0) {
        $moreUp = $projectUp - $upTimesPreview.Count
        $upLabel = $upTimesPreview -join ', '
        if ($moreUp -gt 0) { $upLabel = '{0} ... (+{1:N0} more)' -f $upLabel, $moreUp }
        Write-Host ("   up at   : {0}" -f $upLabel) -ForegroundColor DarkGray
    }
}

# --- interactive / organize composition ---
$organizeMode = $Organize
$reportSeverities = @('FATAL', 'SEVERE', 'ERROR', 'WARNING')
$reportDrivers = @()
$writeReport = $true
$includeBacnetModule = $true
$includeCnsModule = $true
$includeCohoModule = $true
$includeApogeeModule = $true
$includeModuleHeadlines = $false  # short one-liners (Severity path)
$includeSeverityPatterns = $true
$includeDriverDeepDive = $false
$includeFullDefault = $true

if ($Interactive) {
    Write-Host ''
    $modeAns = Read-PromptDefault -PromptText 'Organize report: [S] Severity  [D] Driver  [A] All  [Q] Quit' -DefaultValue 'A'
    switch -Regex ($modeAns) {
        '^[Ss]' { $organizeMode = 'Severity' }
        '^[Dd]' { $organizeMode = 'Driver' }
        '^[Qq]' { $organizeMode = 'Quit'; $writeReport = $false }
        default { $organizeMode = 'All' }
    }
}

if ($organizeMode -eq 'Severity') {
    $includeFullDefault = $false
    $includeDriverDeepDive = $false
    # Full driver modules stay off; short headlines + findings only
    $includeBacnetModule = $false
    $includeCnsModule = $false
    $includeCohoModule = $false
    $includeApogeeModule = $false
    $includeModuleHeadlines = $true
    $includeSeverityPatterns = $true
    if ($Interactive -and [string]::IsNullOrWhiteSpace($Severities)) {
        Write-Host 'Severities: 1=FATAL 2=SEVERE 3=ERROR 4=WARNING 5=INFO  (critical pack = 1,2,3)'
        $sevAns = Read-PromptDefault -PromptText 'Select severities (e.g. 1,2,3 or FATAL,SEVERE)' -DefaultValue '1,2,3'
        $topAns = Read-PromptDefault -PromptText 'Top N per severity' -DefaultValue "$TopN"
        if ($topAns -match '^\d+$') {
            $tn = [int]$topAns
            if ($tn -ge 5 -and $tn -le 100) { $TopN = $tn }
        }
    }
    else {
        $sevAns = if ($Severities) { $Severities } else { 'FATAL,SEVERE,ERROR' }
    }

    $selected = New-Object System.Collections.Generic.List[string]
    foreach ($part in ($sevAns -split '[,;\s]+')) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        $p = $part.Trim().ToUpperInvariant()
        switch ($p) {
            '1' { [void]$selected.Add('FATAL') }
            '2' { [void]$selected.Add('SEVERE') }
            '3' { [void]$selected.Add('ERROR') }
            '4' { [void]$selected.Add('WARNING') }
            '5' { [void]$selected.Add('INFO') }
            'FATAL' { [void]$selected.Add('FATAL') }
            'SEVERE' { [void]$selected.Add('SEVERE') }
            'ERROR' { [void]$selected.Add('ERROR') }
            'WARNING' { [void]$selected.Add('WARNING') }
            'WARN' { [void]$selected.Add('WARNING') }
            'INFO' { [void]$selected.Add('INFO') }
        }
    }
    if ($selected.Count -eq 0) {
        $reportSeverities = @('FATAL', 'SEVERE', 'ERROR')
    }
    else {
        $reportSeverities = @($selected | Select-Object -Unique)
    }
    # Ensure INFO pattern map exists if selected
    foreach ($s in $reportSeverities) {
        if (-not $patternsBySev.ContainsKey($s)) {
            $patternsBySev[$s] = @{}
            $patternSampleBySev[$s] = @{}
            $patternTimeBySev[$s] = @{}
        }
    }
}
elseif ($organizeMode -eq 'Driver') {
    $includeFullDefault = $false
    $includeSeverityPatterns = $false
    $includeDriverDeepDive = $true
    $includeBacnetModule = $false
    $includeCnsModule = $false
    $includeCohoModule = $false
    $includeApogeeModule = $false

    if ($Interactive -and [string]::IsNullOrWhiteSpace($Driver)) {
        $page = 0
        $pageSize = 10
        $donePick = $false
        while (-not $donePick) {
            $start = $page * $pageSize
            if ($start -ge $managersRanked.Count) { $page = 0; $start = 0 }
            $slice = @($managersRanked | Select-Object -Skip $start -First $pageSize)
            Write-Host ''
            Write-Host ("Drivers/managers (page {0}, by volume):" -f ($page + 1)) -ForegroundColor Cyan
            for ($i = 0; $i -lt $slice.Count; $i++) {
                $name = $slice[$i]
                Write-Host ('  {0,2}. {1,8:N0}  {2}' -f ($i + 1), $components[$name], $name)
            }
            $pick = Read-PromptDefault -PromptText '[1-10] or comma-list  [N]ext  [P]rev  Enter=#1' -DefaultValue '1'
            if ($pick -match '^[Nn]') { $page++; continue }
            if ($pick -match '^[Pp]') { if ($page -gt 0) { $page-- }; continue }
            foreach ($part in ($pick -split ',')) {
                $n = 0
                if ([int]::TryParse($part.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $slice.Count) {
                    $reportDrivers += $slice[$n - 1]
                }
            }
            if ($reportDrivers.Count -eq 0 -and $slice.Count -gt 0) {
                $reportDrivers = @($slice[0])
            }
            $donePick = $true
        }
    }
    else {
        # Non-interactive -Driver: names or indexes into ranked list
        foreach ($part in (($Driver -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            $n = 0
            if ([int]::TryParse($part, [ref]$n) -and $n -ge 1 -and $n -le $managersRanked.Count) {
                $reportDrivers += $managersRanked[$n - 1]
            }
            else {
                $match = @($managersRanked | Where-Object { $_ -like "*$part*" })
                if ($match.Count -gt 0) { $reportDrivers += $match[0] }
            }
        }
        if ($reportDrivers.Count -eq 0 -and $managersRanked.Count -gt 0) {
            $reportDrivers = @($managersRanked[0])
        }
    }

    foreach ($d in $reportDrivers) {
        if ($d -match 'BACnet') { $includeBacnetModule = $true }
        if ($d -match 'ApplicationFramework|ICns') { $includeCnsModule = $true }
        if ($d -match 'CoHo') { $includeCohoModule = $true; $includeApogeeModule = $true; $includeBacnetModule = $true }
        if ($d -match '(?i)Apogee') { $includeApogeeModule = $true }
    }
    if ($bacCollectTrend -gt 0 -or $bacTimeSync -gt 0) { $includeBacnetModule = $true }
    if ($apogeeDrvLines -gt 0 -or $apogeeTrendOverflow -gt 0) { $includeApogeeModule = $true }
}
else {
    # All
    $organizeMode = 'All'
    $reportSeverities = @('FATAL', 'SEVERE', 'ERROR', 'WARNING')
    $includeBacnetModule = $true
    $includeCnsModule = $true
    $includeCohoModule = $true
    $includeApogeeModule = $true
    $includeSeverityPatterns = $true
    $includeDriverDeepDive = $false
    $includeFullDefault = $true
}

if ($Interactive) {
    Write-Host ''
    $fmtAns = Read-PromptDefault -PromptText 'Report format: [T] Text  [H] HTML  [B] Both' -DefaultValue 'B'
    switch -Regex ($fmtAns) {
        '^[Hh]' { $Format = 'Html' }
        '^[Tt]' { $Format = 'Text' }
        default { $Format = 'Both' }
    }
}

# INFO patterns are collected during the scan for optional Path S inclusion.

# --- findings ---
$findings = New-Object System.Collections.Generic.List[string]

if ($severeLines -gt 0 -and $parsedLines -gt 0) {
    $pct = [math]::Round(100.0 * $severeLines / $parsedLines, 1)
    if ($pct -ge 10) {
        $findings.Add("HIGH: Critical-severity lines are $pct% of parsed lines ($severeLines combined FATAL/SEVERE/ERROR).")
    }
    elseif ($pct -ge 2) {
        $findings.Add("MEDIUM: Critical-severity lines are $pct% of parsed lines ($severeLines).")
    }
}

# BACnet chatter finding (even when INFO patterns omitted)
$bacTransitions = $bacFailedEvents + $bacOkEvents
if ($bacFailedEvents -ge 500 -or $bacTransitions -ge 2000) {
    $findings.Add(("BACnet device status chatter: {0:N0} Failed and {1:N0} OK transitions ({2:N0} unique devices Failed)." -f `
        $bacFailedEvents, $bacOkEvents, $bacFailedByDevice.Count))
}
if ($bacEndedFailed -ge 20) {
    $findings.Add(("BACnet last-known status: {0:N0} devices ended Failed, {1:N0} ended OK (in analyzed window)." -f `
        $bacEndedFailed, $bacEndedOk))
}
if ($bacFlappers.Count -ge 5) {
    $findings.Add(("BACnet flapping: {0:N0} devices with {1}+ Failed/OK status changes." -f `
        $bacFlappers.Count, $bacFlapMinFlips))
}
if ($bacObjectListEvents -ge 100) {
    $findings.Add(("BACnet object-list warnings: {0:N0} events across {1:N0} devices." -f `
        $bacObjectListEvents, $bacObjectListByDevice.Count))
}
if ($bacCollectTrend -ge 100) {
    $topCode = ($bacCollectTrendByCode.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1)
    $codeNote = if ($topCode) { (" top error {0} x{1:N0}" -f $topCode.Key, $topCode.Value) } else { '' }
    $findings.Add(("BACnetCollectTrend failures: {0:N0} across {1:N0} properties{2}." -f `
        $bacCollectTrend, $bacCollectTrendByProp.Count, $codeNote))
}
if ($bacTimeSync -ge 100) {
    $topCode = ($bacTimeSyncByCode.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1)
    $codeNote = if ($topCode) { (" top error {0} x{1:N0}" -f $topCode.Key, $topCode.Value) } else { '' }
    $findings.Add(("BACnetTimeSync failures: {0:N0} across {1:N0} properties{2}." -f `
        $bacTimeSync, $bacTimeSyncByProp.Count, $codeNote))
}

if ($cnsResolveNodes -ge 100 -or $cnsReducedFunction -ge 100) {
    $findings.Add(("CNS volume: ResolveNodes={0:N0}, ReducedFunction={1:N0}, ICns={2:N0}." -f `
        $cnsResolveNodes, $cnsReducedFunction, $cnsICns))
}
if ($cnsTryRenew -ge 5) {
    $findings.Add(("CNS/session: TryRenewSession hits={0:N0}." -f $cnsTryRenew))
}
if ($cohoStuckEvents -ge 10) {
    $findings.Add(("CoHo stuck/drop messages: {0:N0}." -f $cohoStuckEvents))
}
if ($apogeeUpdatePoints -ge 10) {
    $findings.Add(("Apogee UpdatePoints failures: {0:N0} across {1:N0} PPCL programs." -f `
        $apogeeUpdatePoints, $apogeePpclNames.Count))
}
if ($apogeeTrendOverflow -ge 50) {
    $findings.Add(("ApogeeDrv trend buffer overflows: {0:N0} across {1:N0} devices ({2:N0} sequence-gap lines)." -f `
        $apogeeTrendOverflow, $apogeeTrendByDevice.Count, $apogeeTrendSeq))
}
if ($apogeeAlertId -ge 50) {
    $findings.Add(("ApogeeDrv AlertID issues: {0:N0}." -f $apogeeAlertId))
}
if ($apogeeGetDataFail -ge 50) {
    $findings.Add(("ApogeeDrv get-data failures: {0:N0} across {1:N0} devices." -f `
        $apogeeGetDataFail, $apogeeGetDataByDevice.Count))
}
if ($apogeeQueryTimeout -ge 50) {
    $findings.Add(("ApogeeDrv query timeouts: {0:N0}." -f $apogeeQueryTimeout))
}
if ($projectUp -ge 1 -or $projectStopped -ge 1) {
    $upTimes = @($projectLifecycleEvents | Where-Object { $_.Kind -eq 'up' } | ForEach-Object { $_.Time })
    $upTimesNote = ''
    if ($upTimes.Count -gt 0) {
        $show = @($upTimes | Select-Object -First 5)
        $upTimesNote = ' up at: ' + ($show -join ', ')
        if ($upTimes.Count -gt 5) { $upTimesNote += (' ... (+{0} more)' -f ($upTimes.Count - 5)) }
    }
    $findings.Add(("Project lifecycle (pmon): up={0:N0}, stopped={1:N0}, shutdown cmds={2:N0}, START_MODE={3:N0}.{4}" -f `
        $projectUp, $projectStopped, $projectShutdown, $projectStartMode, $upTimesNote))
}
if ($pmonMgrRestart -ge 1) {
    $topRr = ($pmonRestartByComp.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3 | ForEach-Object { ("{0} x{1}" -f $_.Key, $_.Value) }) -join ', '
    $findings.Add(("pmon auto-restarted managers: {0:N0} event(s){1}." -f `
        $pmonMgrRestart, $(if ($topRr) { " ($topRr)" } else { '' })))
}
if ($blockingDetected -ge 1) {
    $topBl = ($blockingByComp.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3 | ForEach-Object { ("{0} x{1}" -f $_.Key, $_.Value) }) -join ', '
    $findings.Add(("pmon blocking (no heartbeat): {0:N0} detection(s), {1:N0} cleared{2}." -f `
        $blockingDetected, $blockingCleared, $(if ($topBl) { " ($topBl)" } else { '' })))
}
if ($mgrStartProj -ge 5) {
    $findings.Add(("Manager Start (PROJ) events: {0:N0}; Manager Stop: {1:N0}; driver ready: {2:N0}." -f `
        $mgrStartProj, $mgrStop, $driverReady))
}

if ($perfCats.ContainsKey('Timeout') -and $perfCats['Timeout'] -ge 5) {
    $findings.Add("HIGH: Timeouts detected ($($perfCats['Timeout'])).")
}
if ($perfCats.ContainsKey('Buffer/Overrun') -and $perfCats['Buffer/Overrun'] -ge 1) {
    $findings.Add("HIGH: Buffer overrun / buffer-full messages ($($perfCats['Buffer/Overrun'])).")
}
if ($perfCats.ContainsKey('Queue/Pending') -and $perfCats['Queue/Pending'] -ge 1) {
    $findings.Add("MEDIUM: Queue/pending pressure ($($perfCats['Queue/Pending'])).")
}

$sevHours = @($hourlySevere.GetEnumerator() | Sort-Object Name)
if ($sevHours.Count -ge 3) {
    $vals = @($sevHours | ForEach-Object { $_.Value } | Sort-Object)
    $median = $vals[[int]([math]::Floor(($vals.Count - 1) / 2))]
    if ($median -lt 1) { $median = 1 }
    $spikes = @($sevHours | Where-Object { $_.Value -ge ($median * 5) -and $_.Value -ge 50 })
    foreach ($sp in ($spikes | Sort-Object Value -Descending | Select-Object -First 5)) {
        $findings.Add(("SPIKE: SEVERE burst in hour {0} - {1} lines (median ~{2}/hr)." -f $sp.Name, $sp.Value, $median))
    }
}

if ($findings.Count -eq 0) {
    $findings.Add("No strong automated volume findings from current heuristics.")
}

Write-Host ' Findings  :'
foreach ($f in $findings) {
    Write-Host ("   * {0}" -f $f)
}

if (-not $writeReport) {
    Write-Host ''
    Write-Host 'Quit selected - no report file written.' -ForegroundColor Yellow
    exit 0
}

# --- build report ---
$sb = New-Object System.Text.StringBuilder
function script:W([string]$s) { [void]$sb.AppendLine($s) }

W '================================================================================'
W ' PVSS / WinCC OA Log Analysis Report'
W '================================================================================'
W ("Tool      : OfflineAnalyze v{0} by {1}" -f $script:Version, $script:Author)
W ("Generated : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
W ("Log file  : {0}" -f $resolvedLog)
W ("Size      : {0:N2} MB" -f ($fileInfo.Length / 1MB))
W ("Lines     : {0:N0} total, {1:N0} analyzed (WinCC OA header, in window)" -f $totalLines, $parsedLines)
if ($filterByTime) {
    W ("Outside win: {0:N0} header lines skipped by -From/-To" -f $outsideWindow)
}
W ("Time span : {0}  -->  {1}" -f $firstTs, $lastTs)
W ("Runtime   : {0:N1} s" -f $sw.Elapsed.TotalSeconds)
W ''
W '--- Options used ---'
W (" Organize      : {0}" -f $organizeMode)
W (" Severities    : {0}" -f ($reportSeverities -join ', '))
if ($reportDrivers.Count -gt 0) {
    W (" Drivers       : {0}" -f ($reportDrivers -join ', '))
}
W (" TopN          : {0}" -f $TopN)
W (" Sample/patt   : {0}" -f $SamplePerPattern)
W (" From          : {0}" -f $(if ($From) { $From } else { '(none)' }))
W (" To            : {0}" -f $(if ($To) { $To } else { '(none)' }))
W (" Time mode     : {0}" -f $timeModeLabel)
if ($LastHours -gt 0) {
    W (" LastHours     : {0}" -f $LastHours)
}
W (" Format        : {0}" -f $Format)
W (" Interactive   : {0}" -f $(if ($Interactive) { 'yes' } else { 'no' }))
W (" NonInteractive: {0}" -f $(if ($NonInteractive) { 'yes' } else { 'no' }))
W ''

W '--- Findings ---'
foreach ($f in $findings) { W (" * {0}" -f $f) }
W ''

W '--- Severity counts ---'
foreach ($e in ($severity.GetEnumerator() | Sort-Object Value -Descending)) {
    W (' {0,8:N0}  {1}' -f $e.Value, $e.Key)
}
W ''

# Short module headlines (Severity organize) - not full driver breakdowns
if ($includeModuleHeadlines) {
    W '--- Module headlines ---'
    W (' BACnet : Failed={0:N0} OK={1:N0} endedFailed={2:N0} endedOK={3:N0} flappers={4:N0} objectList={5:N0} CollectTrend={6:N0} ({7:N0} props) TimeSync={8:N0} ({9:N0} props)' -f `
        $bacFailedEvents, $bacOkEvents, $bacEndedFailed, $bacEndedOk, $bacFlappers.Count, $bacObjectListEvents, `
        $bacCollectTrend, $bacCollectTrendByProp.Count, $bacTimeSync, $bacTimeSyncByProp.Count)
    W (' CNS    : ResolveNodes={0:N0} ReducedFunction={1:N0} TryRenewSession={2:N0}' -f `
        $cnsResolveNodes, $cnsReducedFunction, $cnsTryRenew)
    W (' CoHo   : stuck/drop={0:N0}' -f $cohoStuckEvents)
    W (' Apogee : events={0:N0} UpdatePoints={1:N0} PPCL={2:N0} | Drv overflow={3:N0} seq={4:N0} AlertID={5:N0} getData={6:N0}' -f `
        $apogeeEvents, $apogeeUpdatePoints, $apogeePpclNames.Count, `
        $apogeeTrendOverflow, $apogeeTrendSeq, $apogeeAlertId, $apogeeGetDataFail)
    W ''
}

if ($projectLifecycleEvents.Count -gt 0 -or $projectUp -gt 0 -or $projectStopped -gt 0 -or $projectShutdown -gt 0) {
    W '--- Project restarts (pmon) ---'
    W ' Each row is one cycle: up -> shutdown -> stopped -> next up. Uptime = up to shutdown; stop = shutdown to stopped; downtime = stopped to next up (blank when still down). START_MODE counted only (too frequent to list).'
    $projCycles = @(Build-ProjectLifecycleCycles -Events @($projectLifecycleEvents) -WindowFirst ([string]$firstTs) -WindowLast ([string]$lastTs))
    $capNote = if (($projectUp + $projectStopped + $projectShutdown) -gt $projectLifecycleEvents.Count) { ' (events capped at 200)' } else { '' }
    W ('  up={0:N0}  stopped={1:N0}  shutdown={2:N0}  START_MODE={3:N0}  cycles={4:N0}{5}' -f `
        $projectUp, $projectStopped, $projectShutdown, $projectStartMode, $projCycles.Count, $capNote)
    if ($projCycles.Count -gt 0) {
        W ' | Up | Shutdown | Uptime | Stopped | Stop | Downtime | Note |'
        foreach ($c in $projCycles) {
            $upLabel = [string]$c.up
            if ($c.upImplied) { $upLabel = "$upLabel (window start)" }
            $note = ''
            if ($c.stillUp -and $c.nextUp) { $note = 'no shutdown before next up' }
            elseif ($c.stillUp) { $note = 'still up' }
            elseif ($c.stillDown) { $note = 'still down' }
            elseif (-not $c.shutdown -and $c.stopped) { $note = 'no shutdown line' }
            W (' | {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f `
                $upLabel,
                ([string]$c.shutdown),
                ([string]$c.uptime),
                ([string]$c.stopped),
                ([string]$c.stopDuration),
                ([string]$c.downtime),
                $note)
        }
    }
    elseif (($projectUp + $projectStopped + $projectShutdown) -gt 0) {
        W '   Counts present but no cycle timestamps were retained.'
    }
    else {
        W '   (none listed)'
    }
    W ''
}

if ($mgrStartProj -gt 0 -or $mgrStop -gt 0 -or $pmonMgrRestart -gt 0 -or $blockingDetected -gt 0) {
    W '--- Manager health (pmon) ---'
    W ' Start/stop = Manager Start PROJ / Manager Stop. Restarts = Detected stopped manager. Blocking = no heartbeat (busy/overloaded).'
    W ('  Starts={0:N0}  Stops={1:N0}  Auto-restarts={2:N0}  Blocking={3:N0}  Unblocked={4:N0}  Driver-ready={5:N0}' -f `
        $mgrStartProj, $mgrStop, $pmonMgrRestart, $blockingDetected, $blockingCleared, $driverReady)
    if ($blockingSample) { W ("  Blocking example   : {0}" -f $blockingSample) }
    if ($unblockingSample) { W ("  Unblocked example  : {0}" -f $unblockingSample) }
    W '  Per-manager (top 25 by activity):'
    W ('   {0,-40} {1,7} {2,7} {3,8} {4,9} {5,9}' -f 'Manager', 'Starts', 'Stops', 'Restart', 'Blocking', 'Unblock')
    $lifeKeys = New-Object System.Collections.Generic.HashSet[string]
    foreach ($map in @($mgrStartByComp, $mgrStopByComp, $pmonRestartByComp, $blockingByComp, $unblockingByComp)) {
        foreach ($k in @($map.Keys)) { [void]$lifeKeys.Add($k) }
    }
    $lifeRows = @(
        $lifeKeys | ForEach-Object {
            $n = $_
            $st = if ($mgrStartByComp.ContainsKey($n)) { [int]$mgrStartByComp[$n] } else { 0 }
            $sp = if ($mgrStopByComp.ContainsKey($n)) { [int]$mgrStopByComp[$n] } else { 0 }
            $rr = if ($pmonRestartByComp.ContainsKey($n)) { [int]$pmonRestartByComp[$n] } else { 0 }
            $bl = if ($blockingByComp.ContainsKey($n)) { [int]$blockingByComp[$n] } else { 0 }
            $ub = if ($unblockingByComp.ContainsKey($n)) { [int]$unblockingByComp[$n] } else { 0 }
            [pscustomobject]@{ Name = $n; Starts = $st; Stops = $sp; Restarts = $rr; Blocking = $bl; Unblocked = $ub; Score = ($st + $sp + $rr + $bl + $ub) }
        } | Sort-Object Score -Descending | Select-Object -First 25
    )
    $rank = 0
    foreach ($r in $lifeRows) {
        $rank++
        W ('   {0,-40} {1,7:N0} {2,7:N0} {3,8:N0} {4,9:N0} {5,9:N0}' -f $r.Name, $r.Starts, $r.Stops, $r.Restarts, $r.Blocking, $r.Unblocked)
    }
    if ($rank -eq 0) { W '   (none)' }
    W ''
}

if ($includeFullDefault -or $includeDriverDeepDive) {
    W ('--- Top {0} components (managers) ---' -f $TopN)
    foreach ($e in ($components.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $TopN)) {
        W (' {0,8:N0}  {1}' -f $e.Value, $e.Key)
    }
    W ''
}

if ($includeFullDefault) {
    W '--- Performance-related keyword categories ---'
    if ($perfCats.Count -eq 0) {
        W ' (none matched)'
    }
    else {
        foreach ($e in ($perfCats.GetEnumerator() | Sort-Object Value -Descending)) {
            W (' {0,8:N0}  {1}' -f $e.Value, $e.Key)
        }
    }
    W ''

}

# Module: BACnet
if ($includeBacnetModule -and ($bacFailedEvents -gt 0 -or $bacOkEvents -gt 0 -or $bacObjectListEvents -gt 0 -or $bacCollectTrend -gt 0 -or $bacTimeSync -gt 0)) {
    W '--- BACnet module ---'
    W ' Device status (INFO)'
    W ' Individual devices entering/leaving Failed.'
    W ('  Failed transitions : {0:N0}  (unique devices: {1:N0})' -f $bacFailedEvents, $bacFailedByDevice.Count)
    W ('  OK transitions     : {0:N0}  (unique devices: {1:N0})' -f $bacOkEvents, $bacOkByDevice.Count)
    W ('  Last-known status  : ended Failed={0:N0}  ended OK={1:N0}  (devices seen in window)' -f $bacEndedFailed, $bacEndedOk)
    W ('  Flapping (>= {0} Failed/OK changes): {1:N0} devices' -f $bacFlapMinFlips, $bacFlappers.Count)
    if ($bacFailedSample) { W ("  Failed example    : {0}" -f $bacFailedSample) }
    if ($bacOkSample) { W ("  OK example        : {0}" -f $bacOkSample) }
    W ''
    W '  Device status activity (top 20 by Failed transitions):'
    W '   rank   Failed     OK  flips  last    device'
    $rank = 0
    foreach ($e in ($bacFailedByDevice.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 20)) {
        $rank++
        $id = $e.Key
        $oc = if ($bacOkByDevice.ContainsKey($id)) { $bacOkByDevice[$id] } else { 0 }
        $flips = if ($bacFlipByDevice.ContainsKey($id)) { $bacFlipByDevice[$id] } else { 0 }
        $last = if ($bacLastStatus.ContainsKey($id)) { $bacLastStatus[$id] } else { '?' }
        W ('   {0,4}  {1,6:N0}  {2,6:N0}  {3,5:N0}  {4,-7} {5}' -f $rank, $e.Value, $oc, $flips, $last, $id)
    }
    if ($rank -eq 0) { W '   (none)' }
    W ''
    W '  Devices that ended Failed (last-known in window, top 20):'
    $endedFailedList = @(
        $bacLastStatus.GetEnumerator() |
            Where-Object { $_.Value -eq 'Failed' } |
            ForEach-Object {
                $id = $_.Key
                $fc = if ($bacFailedByDevice.ContainsKey($id)) { $bacFailedByDevice[$id] } else { 0 }
                $oc = if ($bacOkByDevice.ContainsKey($id)) { $bacOkByDevice[$id] } else { 0 }
                $flips = if ($bacFlipByDevice.ContainsKey($id)) { $bacFlipByDevice[$id] } else { 0 }
                [pscustomobject]@{ Id = $id; Failed = $fc; Ok = $oc; Flips = $flips }
            } |
            Sort-Object Failed -Descending |
            Select-Object -First 20
    )
    if ($endedFailedList.Count -eq 0) {
        W '   (none)'
    }
    else {
        W '   rank   Failed     OK  flips  device'
        $rank = 0
        foreach ($row in $endedFailedList) {
            $rank++
            W ('   {0,4}  {1,6:N0}  {2,6:N0}  {3,5:N0}  {4}' -f $rank, $row.Failed, $row.Ok, $row.Flips, $row.Id)
        }
    }
    W ''
    W ' Object list (WARNING)'
    W ('  Events            : {0:N0}  (unique devices: {1:N0})' -f $bacObjectListEvents, $bacObjectListByDevice.Count)
    if ($bacObjectListSample) { W ("  Example           : {0}" -f $bacObjectListSample) }
    W '  Top devices by object-list warnings:'
    $rank = 0
    foreach ($e in ($bacObjectListByDevice.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 20)) {
        $rank++
        W ('   {0,2}. {1,8:N0}  device {2}' -f $rank, $e.Value, $e.Key)
    }
    if ($rank -eq 0) { W '   (none)' }
    W ''
    W ' BACnetCollectTrend (driver trend-collection command failures; often CoHo / Log_Enable)'
    W ('  Events             : {0:N0}  (unique properties: {1:N0})' -f $bacCollectTrend, $bacCollectTrendByProp.Count)
    if ($bacCollectTrendSample) { W ("  Example            : {0}" -f $bacCollectTrendSample) }
    if ($bacCollectTrendByCode.Count -gt 0) {
        W '  Error codes:'
        foreach ($e in ($bacCollectTrendByCode.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 10)) {
            W ('    {0,8}  {1:N0}' -f $e.Key, $e.Value)
        }
    }
    if ($bacCollectTrendByProp.Count -gt 0) {
        W '  Top properties:'
        $rank = 0
        foreach ($e in ($bacCollectTrendByProp.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 20)) {
            $rank++
            W ('   {0,4}  {1,6:N0}  {2}' -f $rank, $e.Value, $e.Key)
        }
    }
    W ''
    W ' BACnetTimeSync (driver time-sync command failures; often CoHo / Local_Time)'
    W ('  Events             : {0:N0}  (unique properties: {1:N0})' -f $bacTimeSync, $bacTimeSyncByProp.Count)
    if ($bacTimeSyncSample) { W ("  Example            : {0}" -f $bacTimeSyncSample) }
    if ($bacTimeSyncByCode.Count -gt 0) {
        W '  Error codes:'
        foreach ($e in ($bacTimeSyncByCode.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 10)) {
            W ('    {0,8}  {1:N0}' -f $e.Key, $e.Value)
        }
    }
    if ($bacTimeSyncByProp.Count -gt 0) {
        W '  Top properties:'
        $rank = 0
        foreach ($e in ($bacTimeSyncByProp.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 20)) {
            $rank++
            W ('   {0,4}  {1,6:N0}  {2}' -f $rank, $e.Value, $e.Key)
        }
    }
    W ''
}

# Module: CNS
if ($includeCnsModule -and ($cnsResolveNodes -gt 0 -or $cnsReducedFunction -gt 0 -or $cnsTryRenew -gt 0)) {
    W '--- CNS module (thin) ---'
    W ('  ResolveNodes     : {0:N0}' -f $cnsResolveNodes)
    W ('  ReducedFunction  : {0:N0}' -f $cnsReducedFunction)
    W ('  ICns             : {0:N0}' -f $cnsICns)
    W ('  TryRenewSession  : {0:N0}' -f $cnsTryRenew)
    W ('  Top CNS-related patterns (top {0}):' -f $TopN)
    $rank = 0
    foreach ($e in ($cnsPatterns.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $TopN)) {
        $rank++
        W ''
        W ('  #{0}  count={1:N0}' -f $rank, $e.Value)
        W ('      pattern: {0}' -f $e.Key)
        if ($cnsPatternTimes.ContainsKey($e.Key)) {
            $tb = $cnsPatternTimes[$e.Key]
            W ('      first  : {0}' -f $tb.First)
            W ('      last   : {0}' -f $tb.Last)
        }
        if ($cnsPatternSamples.ContainsKey($e.Key)) {
            foreach ($ex in $cnsPatternSamples[$e.Key]) {
                W ('      example: {0}' -f $ex)
            }
        }
    }
    if ($rank -eq 0) { W '  (none)' }
    W ''
}

# Module: CoHo
if ($includeCohoModule -and $cohoStuckEvents -gt 0) {
    W '--- CoHo module (thin) ---'
    W ('  Stuck/drop messages : {0:N0}' -f $cohoStuckEvents)
    if ($cohoStuckSample) { W ("  Example             : {0}" -f $cohoStuckSample) }
    W '  Top stuck names:'
    $rank = 0
    foreach ($e in ($cohoStuckNames.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $TopN)) {
        $rank++
        W ('   {0,2}. {1,8:N0}  {2}' -f $rank, $e.Value, $e.Key)
    }
    if ($rank -eq 0) { W '   (none parsed)' }
    W ''
}

# Module: Apogee
if ($includeApogeeModule -and ($apogeeEvents -gt 0 -or $apogeeDrvLines -gt 0 -or $apogeeTrendOverflow -gt 0 -or $apogeeAlertId -gt 0 -or $apogeeGetDataFail -gt 0)) {
    W '--- Apogee module ---'
    W ' CoHo.Apogee* / Orch.Apogee* (orchestration / ApogeeBACnet path)'
    W ('  Events              : {0:N0}' -f $apogeeEvents)
    W ('  UpdatePoints        : {0:N0}' -f $apogeeUpdatePoints)
    W ('  Trace repetitions   : {0:N0}' -f $apogeeRepetition)
    if ($apogeeOther -gt 0) {
        W ('  Other               : {0:N0}' -f $apogeeOther)
    }
    W ('  Unique PPCL programs: {0:N0}' -f $apogeePpclNames.Count)
    if ($apogeeSample) { W ("  Example             : {0}" -f $apogeeSample) }
    W '  Top PPCL programs by UpdatePoints:'
    $rank = 0
    foreach ($e in ($apogeePpclNames.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $TopN)) {
        $rank++
        W ('   {0,2}. {1,8:N0}  {2}' -f $rank, $e.Value, $e.Key)
    }
    if ($rank -eq 0) { W '   (none parsed)' }
    W ''
    W ' WCCOAApogeeDrv (native Apogee driver)'
    W ('  Driver lines        : {0:N0}' -f $apogeeDrvLines)
    W ('  Trend buffer overflow: {0:N0}  (unique devices: {1:N0}, unique trends: {2:N0})' -f `
        $apogeeTrendOverflow, $apogeeTrendByDevice.Count, $apogeeTrendByName.Count)
    W ('  Sequence-gap lines  : {0:N0}  (Last sequence numberâ€¦ companion warnings)' -f $apogeeTrendSeq)
    W ('  AlertID issues      : {0:N0}' -f $apogeeAlertId)
    W ('  Query timeouts      : {0:N0}' -f $apogeeQueryTimeout)
    W ('  Get-data failures   : {0:N0}  (unique devices: {1:N0})' -f $apogeeGetDataFail, $apogeeGetDataByDevice.Count)
    if ($apogeeTrendSample) { W ("  Trend example       : {0}" -f $apogeeTrendSample) }
    if ($apogeeAlertSample) { W ("  AlertID example     : {0}" -f $apogeeAlertSample) }
    if ($apogeeTimeoutSample) { W ("  Timeout example     : {0}" -f $apogeeTimeoutSample) }
    if ($apogeeGetDataSample) { W ("  Get-data example    : {0}" -f $apogeeGetDataSample) }
    if ($apogeeTrendByDevice.Count -gt 0) {
        W '  Top devices by trend overflow:'
        $rank = 0
        foreach ($e in ($apogeeTrendByDevice.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 20)) {
            $rank++
            W ('   {0,4}  {1,6:N0}  {2}' -f $rank, $e.Value, $e.Key)
        }
    }
    if ($apogeeTrendByName.Count -gt 0) {
        W '  Top trends by overflow:'
        $rank = 0
        foreach ($e in ($apogeeTrendByName.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 20)) {
            $rank++
            W ('   {0,4}  {1,6:N0}  {2}' -f $rank, $e.Value, $e.Key)
        }
    }
    if ($apogeeGetDataByDevice.Count -gt 0) {
        W '  Top devices by get-data failure:'
        $rank = 0
        foreach ($e in ($apogeeGetDataByDevice.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 20)) {
            $rank++
            W ('   {0,4}  {1,6:N0}  {2}' -f $rank, $e.Value, $e.Key)
        }
    }
    W ''
}

if ($includeFullDefault) {
    $allHourKeys = @($hourly.Keys | Sort-Object)
    $hourCount = $allHourKeys.Count
    if ($hourCount -le 25) {
        W '--- Hourly volume (all parsed / SEVERE / WARNING) ---'
        W (' Hours in analyzed window: {0:N0}' -f $hourCount)
        W (' {0,-16} {1,10} {2,10} {3,10}' -f 'Hour', 'All', 'SEVERE', 'WARNING')
        foreach ($h in $allHourKeys) {
            $s = if ($hourlySevere.ContainsKey($h)) { $hourlySevere[$h] } else { 0 }
            $w = if ($hourlyWarning.ContainsKey($h)) { $hourlyWarning[$h] } else { 0 }
            W (' {0,-16} {1,10:N0} {2,10:N0} {3,10:N0}' -f $h, $hourly[$h], $s, $w)
        }
    }
    else {
        W '--- Hourly volume (most recent 24 hours) ---'
        W (' Hours in analyzed window: {0:N0} (showing most recent 24 + top 10 busiest)' -f $hourCount)
        W (' {0,-16} {1,10} {2,10} {3,10}' -f 'Hour', 'All', 'SEVERE', 'WARNING')
        foreach ($h in ($allHourKeys | Select-Object -Last 24)) {
            $s = if ($hourlySevere.ContainsKey($h)) { $hourlySevere[$h] } else { 0 }
            $w = if ($hourlyWarning.ContainsKey($h)) { $hourlyWarning[$h] } else { 0 }
            W (' {0,-16} {1,10:N0} {2,10:N0} {3,10:N0}' -f $h, $hourly[$h], $s, $w)
        }
        W ''
        W '--- Busiest hours (top 10 by total lines) ---'
        W (' {0,-16} {1,10} {2,10} {3,10}' -f 'Hour', 'All', 'SEVERE', 'WARNING')
        foreach ($e in ($hourly.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 10)) {
            $h = $e.Key
            $s = if ($hourlySevere.ContainsKey($h)) { $hourlySevere[$h] } else { 0 }
            $w = if ($hourlyWarning.ContainsKey($h)) { $hourlyWarning[$h] } else { 0 }
            W (' {0,-16} {1,10:N0} {2,10:N0} {3,10:N0}' -f $h, $e.Value, $s, $w)
        }
    }
    W ''
}

# Driver deep-dive
if ($includeDriverDeepDive) {
    W '--- Driver deep-dive ---'
    foreach ($d in $reportDrivers) {
        W ''
        W ("=== {0} ===" -f $d)
        W (' Total lines: {0:N0}' -f $(if ($components.ContainsKey($d)) { $components[$d] } else { 0 }))
        W ' Severity mix:'
        if ($compSev.ContainsKey($d)) {
            foreach ($e in ($compSev[$d].GetEnumerator() | Sort-Object Value -Descending)) {
                W ('  {0,8:N0}  {1}' -f $e.Value, $e.Key)
            }
        }
        else {
            W '  (none)'
        }
        foreach ($sevName in @('FATAL', 'SEVERE', 'ERROR', 'WARNING')) {
            W (" Patterns - {0} (top {1}):" -f $sevName, $TopN)
            if (-not $compPatterns.ContainsKey($d) -or -not $compPatterns[$d].ContainsKey($sevName) -or $compPatterns[$d][$sevName].Count -eq 0) {
                W '  (none)'
                continue
            }
            $rank = 0
            foreach ($e in ($compPatterns[$d][$sevName].GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $TopN)) {
                $rank++
                W ''
                W ('  #{0}  count={1:N0}' -f $rank, $e.Value)
                W ('      pattern: {0}' -f $e.Key)
                if ($compPatternTimes.ContainsKey($d) -and $compPatternTimes[$d][$sevName].ContainsKey($e.Key)) {
                    $tb = $compPatternTimes[$d][$sevName][$e.Key]
                    W ('      first  : {0}' -f $tb.First)
                    W ('      last   : {0}' -f $tb.Last)
                }
                if ($compPatternSamples[$d][$sevName].ContainsKey($e.Key)) {
                    foreach ($ex in $compPatternSamples[$d][$sevName][$e.Key]) {
                        W ('      example: {0}' -f $ex)
                    }
                }
            }
        }
    }
    W ''
}

if ($includeSeverityPatterns) {
    W '--- Top patterns by severity ---'
    foreach ($sevName in $reportSeverities) {
        W ''
        W ('=== {0} (top {1}) ===' -f $sevName, $TopN)
        if (-not $patternsBySev.ContainsKey($sevName) -or $patternsBySev[$sevName].Count -eq 0) {
            W ' (none)'
            continue
        }
        $pMap = $patternsBySev[$sevName]
        $sMap = $patternSampleBySev[$sevName]
        $tMap = $patternTimeBySev[$sevName]
        $rank = 0
        foreach ($e in ($pMap.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $TopN)) {
            $rank++
            W ''
            W (' #{0}  count={1:N0}' -f $rank, $e.Value)
            W ('     pattern: {0}' -f $e.Key)
            if ($tMap.ContainsKey($e.Key)) {
                $tb = $tMap[$e.Key]
                W ('     first  : {0}' -f $tb.First)
                W ('     last   : {0}' -f $tb.Last)
            }
            if ($sMap.ContainsKey($e.Key)) {
                foreach ($ex in $sMap[$e.Key]) {
                    W ('     example: {0}' -f $ex)
                }
            }
        }
    }
    W ''
}

W '================================================================================'
W ' End of report'
W '================================================================================'

$report = $sb.ToString()
$generatedStamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$writeText = ($Format -eq 'Text' -or $Format -eq 'Both')
$writeHtml = ($Format -eq 'Html' -or $Format -eq 'Both')

$textOutPath = $null
$htmlOutPath = $null
if ($writeText) {
    if ($OutPath -match '\.html$') {
        $textOutPath = Get-SiblingReportPath -Path $OutPath -Extension 'txt'
    }
    else {
        $textOutPath = $OutPath
    }
}
if ($writeHtml) {
    if ($OutPath -match '\.html$') {
        $htmlOutPath = $OutPath
    }
    elseif ($OutPath -match '\.txt$') {
        $htmlOutPath = Get-SiblingReportPath -Path $OutPath -Extension 'html'
    }
    else {
        $htmlOutPath = $OutPath + '.html'
    }
}

Write-Host ''
if ($writeText) {
    [System.IO.File]::WriteAllText($textOutPath, $report, (Get-LogTextEncoding))
    Write-Host ("Text report written to: {0}" -f $textOutPath) -ForegroundColor Green
}
if ($writeHtml) {
    $html = Convert-AnalysisReportToHtml -TextReport $report -LogFile $resolvedLog -Generated $generatedStamp `
        -Version $script:Version -Author $script:Author
    [System.IO.File]::WriteAllText($htmlOutPath, $html, (Get-LogTextEncoding))
    Write-Host ("HTML report written to: {0}" -f $htmlOutPath) -ForegroundColor Green
}
Write-Host '(Full detail is in the report file(s).)' -ForegroundColor DarkGray

}
catch {
    Write-Host ''
    Write-Host 'ERROR: Analysis failed.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        Write-Host $_.InvocationInfo.PositionMessage
    }
    Write-Host ''
    Write-Host 'Tip: Run via Run-Analyze.cmd, or from PowerShell:' -ForegroundColor Yellow
    Write-Host '  powershell -NoProfile -ExecutionPolicy Bypass -File .\Analyze-PvssLog.ps1 -NonInteractive'
    exit 1
}
finally {
    Wait-IfInteractive
}

