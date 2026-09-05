<#
.SYNOPSIS
  Standalone WinCC OA / GMS (PVSS_II) log analyzer for performance triage. (v1.1)

.DESCRIPTION
  Streams a large PVSS_II.log without loading it into memory.
  Produces a text report: severity-separated patterns, BACnet/CNS/CoHo/Apogee modules,
  findings, and optional interactive report shaping after the scan.
  Optional HTML report via -Format Html|Both (Run-Analyze.cmd defaults to Html).

  Requires only Windows PowerShell 5.1+ or PowerShell 7+.

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
    if ($t.Length -gt 180) { $t = $t.Substring(0, 180) + '...' }
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
        $sample = if ($Line.Length -gt 300) { $Line.Substring(0, 300) + '...' } else { $Line }
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
    # WinCC OA / GMS logs commonly use UTF-8 (facility markers like «MacroManager»).
    # Encoding.Default (Windows-1252) turns UTF-8 C2 AB into mojibake Â«.
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
        [string]$Generated
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
    [void]$sb.AppendLine('<title>PVSS / WinCC OA Log Analysis</title>')
    [void]$sb.AppendLine('<style>')
    [void]$sb.AppendLine(@'
:root {
  --bg: #f4f6f8;
  --card: #ffffff;
  --ink: #1c2430;
  --muted: #5a6a7a;
  --line: #d5dde6;
  --accent: #0b6e4f;
  --fatal: #8b1e1e;
  --severe: #a15c00;
  --warn: #8a6d00;
  --mono: "Cascadia Mono", "Consolas", "Courier New", monospace;
  --sans: "Segoe UI", "Helvetica Neue", Arial, sans-serif;
}
* { box-sizing: border-box; }
html { scroll-padding-top: 6.5rem; }
body {
  margin: 0;
  font-family: var(--sans);
  color: var(--ink);
  background:
    radial-gradient(1200px 500px at 10% -10%, #e7eef5 0%, transparent 55%),
    linear-gradient(180deg, #eef2f6 0%, var(--bg) 40%);
  line-height: 1.45;
}
header.app {
  padding: 1.5rem 1.25rem 1rem;
  border-bottom: 1px solid var(--line);
  background: rgba(255,255,255,0.88);
  backdrop-filter: blur(6px);
  position: sticky;
  top: 0;
  z-index: 2;
}
header.app h1 {
  margin: 0 0 0.35rem;
  font-size: 1.35rem;
  letter-spacing: 0.01em;
  color: var(--accent);
}
header.app .meta { color: var(--muted); font-size: 0.92rem; }
.layout {
  display: grid;
  grid-template-columns: minmax(200px, 260px) 1fr;
  gap: 1rem;
  max-width: 1200px;
  margin: 0 auto;
  padding: 1rem 1.25rem 2.5rem;
}
nav.toc {
  position: sticky;
  top: 5.5rem;
  align-self: start;
  background: var(--card);
  border: 1px solid var(--line);
  border-radius: 8px;
  padding: 0.85rem 0.9rem;
  max-height: calc(100vh - 6.5rem);
  overflow: auto;
}
nav.toc h2 {
  margin: 0 0 0.5rem;
  font-size: 0.8rem;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--muted);
}
nav.toc a {
  display: block;
  color: var(--ink);
  text-decoration: none;
  font-size: 0.88rem;
  padding: 0.22rem 0.2rem;
  border-radius: 4px;
}
nav.toc a:hover { background: #eef5f1; color: var(--accent); }
nav.toc a.sub { padding-left: 0.85rem; color: var(--muted); font-size: 0.82rem; }
main section {
  background: var(--card);
  border: 1px solid var(--line);
  border-radius: 8px;
  padding: 0.9rem 1rem 1rem;
  margin-bottom: 0.9rem;
  box-shadow: 0 1px 0 rgba(28,36,48,0.03);
  scroll-margin-top: 6.5rem;
}
main section h2, main section h3 {
  margin: 0 0 0.65rem;
  font-size: 1.05rem;
  border-bottom: 1px solid var(--line);
  padding-bottom: 0.4rem;
}
main section h3 { font-size: 0.98rem; color: var(--muted); }
main section.sev-FATAL h3 { color: var(--fatal); }
main section.sev-SEVERE h3 { color: var(--severe); }
main section.sev-WARNING h3 { color: var(--warn); }
pre.block {
  margin: 0;
  white-space: pre-wrap;
  word-break: break-word;
  font-family: var(--mono);
  font-size: 0.78rem;
  line-height: 1.4;
  color: #243040;
}
footer {
  max-width: 1200px;
  margin: 0 auto 2rem;
  padding: 0 1.25rem;
  color: var(--muted);
  font-size: 0.85rem;
}
@media (max-width: 860px) {
  .layout { grid-template-columns: 1fr; }
  nav.toc { position: static; max-height: none; }
}
'@)
    [void]$sb.AppendLine('</style>')
    [void]$sb.AppendLine('</head>')
    [void]$sb.AppendLine('<body>')
    [void]$sb.AppendLine('<header class="app">')
    [void]$sb.AppendLine('<h1>PVSS / WinCC OA Log Analysis</h1>')
    [void]$sb.AppendLine(('<div class="meta">Log: {0}<br/>Generated: {1}</div>' -f (& $enc $LogFile), (& $enc $Generated)))
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
        [void]$sb.AppendLine(('<pre class="block">{0}</pre>' -f (& $enc $body)))
        [void]$sb.AppendLine('</section>')
    }

    [void]$sb.AppendLine('</main>')
    [void]$sb.AppendLine('</div>')
    [void]$sb.AppendLine('<footer>Standalone triage aid - not a substitute for Siemens GMS / WinCC OA support.</footer>')
    [void]$sb.AppendLine('</body>')
    [void]$sb.AppendLine('</html>')
    return $sb.ToString()
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
$reBacFailed = [regex]'Device\s+(\d+)\s+Status is now Failed'
$reBacOk = [regex]'Device\s+(\d+)\s+Status is now OK'
$reBacObjList = [regex]'(?i)Could not get object list(?:\s+count)?(?:\s+for)?\s+device\s+(\d+)'
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

# Apogee thin module (CoHo.Apogee* / Orch.Apogee* header lines)
$apogeeEvents = 0
$apogeeUpdatePoints = 0
$apogeeRepetition = 0
$apogeeOther = 0
$apogeePpclNames = @{}
$apogeeSample = $null
$reApogeePpcl = [regex]'(?i)PPCL Program Name:\s*(\S+?)(?:System\.|$)'
$reApogeeComp = [regex]'(?i)(?:CoHo|Orch)\.Apogee'

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

        # --- Apogee (thin; header lines with CoHo.Apogee* / Orch.Apogee*) ---
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
Write-Host (" BACnet    : Failed={0:N0} OK={1:N0} endedFailed={2:N0} endedOK={3:N0} flappers(>={4})={5:N0} objectList={6:N0}" -f `
    $bacFailedEvents, $bacOkEvents, $bacEndedFailed, $bacEndedOk, $bacFlapMinFlips, $bacFlappers.Count, $bacObjectListEvents)
Write-Host (" CNS       : ResolveNodes={0:N0} ReducedFunction={1:N0} TryRenewSession={2:N0}" -f `
    $cnsResolveNodes, $cnsReducedFunction, $cnsTryRenew)
Write-Host (" CoHo      : stuck/drop={0:N0}" -f $cohoStuckEvents)
Write-Host (" Apogee    : events={0:N0} UpdatePoints={1:N0} PPCL={2:N0}" -f `
    $apogeeEvents, $apogeeUpdatePoints, $apogeePpclNames.Count)

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
        if ($d -match 'CoHo') { $includeCohoModule = $true; $includeApogeeModule = $true }
        if ($d -match '(?i)Apogee') { $includeApogeeModule = $true }
    }
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
    W (' BACnet : Failed={0:N0} OK={1:N0} endedFailed={2:N0} endedOK={3:N0} flappers={4:N0} objectList={5:N0}' -f `
        $bacFailedEvents, $bacOkEvents, $bacEndedFailed, $bacEndedOk, $bacFlappers.Count, $bacObjectListEvents)
    W (' CNS    : ResolveNodes={0:N0} ReducedFunction={1:N0} TryRenewSession={2:N0}' -f `
        $cnsResolveNodes, $cnsReducedFunction, $cnsTryRenew)
    W (' CoHo   : stuck/drop={0:N0}' -f $cohoStuckEvents)
    W (' Apogee : events={0:N0} UpdatePoints={1:N0} PPCL={2:N0}' -f `
        $apogeeEvents, $apogeeUpdatePoints, $apogeePpclNames.Count)
    W ''
}

# Module: BACnet
if ($includeBacnetModule -and ($bacFailedEvents -gt 0 -or $bacOkEvents -gt 0 -or $bacObjectListEvents -gt 0)) {
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
if ($includeApogeeModule -and $apogeeEvents -gt 0) {
    W '--- Apogee module (thin) ---'
    W ' CoHo.Apogee* / Orch.Apogee* header events (typically SEVERE).'
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
    $html = Convert-AnalysisReportToHtml -TextReport $report -LogFile $resolvedLog -Generated $generatedStamp
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

