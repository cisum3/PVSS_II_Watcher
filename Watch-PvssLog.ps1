#Requires -Version 5.1
<#
.SYNOPSIS
  PVSS Log Watch V2  -  localhost host + live dashboard APIs (PRD-V2).
.DESCRIPTION
  Serves ui\ and /api/pulse|/api/section|/api/manager|/api/health.
  Opens the live log read-only (FileAccess.Read + FileShare.ReadWrite).
#>
[CmdletBinding()]
param(
    [string]$LogPath = '',
    [int]$Port = 8787,
    [int]$LastMinutes = 60,
    [int]$RefreshSeconds = 3,
    [switch]$NoBrowser,
    [switch]$NoPause,
    [int]$TopN = 10,
    [int]$SamplePerPattern = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:UiRoot = Join-Path $script:Root 'ui'
$script:Version = (Get-Content (Join-Path $script:Root 'VERSION.txt') -ErrorAction SilentlyContinue | Select-Object -First 1)
if (-not $script:Version) { $script:Version = '2.0-dev' }

# --- helpers (V1.1-aligned) ---
$script:ReNormTs = [regex]'\d{4}\.\d{2}\.\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+'
$script:ReNormTime = [regex]'\b\d{2}:\d{2}:\d{2}\.\d+\b'
$script:ReNormKv = [regex]'\b(?:tid|cc|Sys|Page|ViewId|#DpIdentifier)=[^\s,;)]+'
$script:ReNormDevice = [regex]'(?i)\bdevice\s+\d+\b'
$script:ReNormDp = [regex]'\bDP=\d+\.\d+:[^;\s]+'
$script:ReNormNum = [regex]'\b\d{5,}\b'
$script:ReNormSpace = [regex]'\s+'
$script:ReCohoLockCollapse = [regex]':\s*[\d, ]+'
$script:ReInfoBacStatus = [regex]'Status is now (Failed|OK)'
$script:ReCnsResolve = [regex]'ResolveNodes'
$script:ReCnsReduced = [regex]'ReducedFunction'
$script:ReCnsICns = [regex]'(?i)\bICns\b|ICns\.'
$script:ReCnsRenew = [regex]'TryRenewSession'
$script:ReCohoStuck = [regex]'(?i)got stuck|dropping it'
$script:ReApogeeUpdate = [regex]'(?i)UpdatePoints'
$script:ReApogeeRep = [regex]'(?i)Repetition'

$script:PerfRules = @(
    @{ Name = 'Timeout'; Re = [regex]'(?i)\btimeout\b|\btimed?\s*out\b' }
    @{ Name = 'Buffer/Overrun'; Re = [regex]'(?i)overrun|buffer\s*(full|overflow|overrun)|BufferOverrun' }
    @{ Name = 'Queue/Pending'; Re = [regex]'(?i)pending|backlog|queue\s*(full|overflow)|maxInput|maxPend' }
    @{ Name = 'CNS/Resolve'; Re = [regex]'(?i)ResolveNodes|ReducedFunction|ICns\.|\.cns=' }
    @{ Name = 'Session/Logon'; Re = [regex]'(?i)TryRenewSession|LogonManager|session' }
    @{ Name = 'Memory'; Re = [regex]'(?i)\bmemory\b|\bOOM\b|out of memory|WorkingSet' }
    @{ Name = 'Connection'; Re = [regex]'(?i)disconnect|connection\s*(lost|refused|reset)|cannot connect|Could not get' }
    @{ Name = 'Driver/Device'; Re = [regex]'(?i)object list|device\s+\d+|BACnet|Apogee' }
    @{ Name = 'Restart/Kill'; Re = [regex]'(?i)SecKill|restart|killed|emergency|emergencyKill' }
    @{ Name = 'Slow/Delay'; Re = [regex]'(?i)\bslow\b|\bdelay\b|\blatency\b|took\s+\d+\s*ms' }
)

function Normalize-Message {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = $Text
    $t = $script:ReNormTs.Replace($t, '<TS>')
    $t = $script:ReNormTime.Replace($t, '<TIME>')
    $t = $script:ReNormKv.Replace($t, '<KV>')
    $t = $script:ReNormDevice.Replace($t, 'device <N>')
    $t = $script:ReNormDp.Replace($t, 'DP=<ID>')
    $t = $script:ReNormNum.Replace($t, '<NUM>')
    $t = $script:ReNormSpace.Replace($t, ' ')
    if ($t.Length -gt 180) { $t = $t.Substring(0, 180) + '...' }
    return $t.Trim()
}

function Get-PerfCategory {
    param([string]$Line)
    foreach ($r in $script:PerfRules) {
        if ($r.Re.IsMatch($Line)) { return $r.Name }
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

function ConvertFrom-LogTimestamp {
    param([string]$Ts)
    if ([string]::IsNullOrWhiteSpace($Ts)) { return $null }
    if ($Ts -match '^(\d{4})\.(\d{2})\.(\d{2})\s+(\d{2}):(\d{2}):(\d{2})') {
        try {
            return Get-Date -Year ([int]$Matches[1]) -Month ([int]$Matches[2]) -Day ([int]$Matches[3]) `
                -Hour ([int]$Matches[4]) -Minute ([int]$Matches[5]) -Second ([int]$Matches[6])
        }
        catch { return $null }
    }
    return $null
}

function Get-MinuteKey {
    param([string]$Ts)
    if ($Ts.Length -ge 16) { return $Ts.Substring(0, 16) }
    return $Ts
}

function Read-PrefillPath {
    param([string]$Preferred)
    if (-not [string]::IsNullOrWhiteSpace($Preferred)) { return $Preferred.Trim() }
    $cfg = Join-Path $script:Root 'watch-log-path.txt'
    if (-not (Test-Path -LiteralPath $cfg)) { return '' }
    foreach ($line in Get-Content -LiteralPath $cfg -Encoding UTF8) {
        $t = $line.Trim()
        if ($t -and -not $t.StartsWith('#')) { return $t }
    }
    return ''
}

function Save-WatchLogPath {
    param([string]$Path)
    $cfg = Join-Path $script:Root 'watch-log-path.txt'
    $header = @(
        '# Live PVSS_II.log path for Watch-PvssLog (V2)'
        '# Lines starting with # are ignored. First non-comment line is used as prefill.'
        ''
    )
    ($header + $Path) | Set-Content -LiteralPath $cfg -Encoding UTF8
}

function New-EmptyState {
    return @{
        Severity          = @{}
        Components        = @{}
        CompSev           = @{}
        PatternsBySev     = @{ FATAL = @{}; SEVERE = @{}; ERROR = @{}; WARNING = @{}; INFO = @{} }
        PatternSampleBySev = @{ FATAL = @{}; SEVERE = @{}; ERROR = @{}; WARNING = @{}; INFO = @{} }
        PatternTimeBySev  = @{ FATAL = @{}; SEVERE = @{}; ERROR = @{}; WARNING = @{}; INFO = @{} }
        CompPatterns      = @{}
        CompPatternSamples = @{}
        CompPatternTimes  = @{}
        PerfCats          = @{}
        ByMinute          = @{}  # minuteKey -> counts
        FirstTs           = $null
        LastTs            = $null
        ParsedLines       = 0
        UnparsedLines     = 0
        SevereLines       = 0
        BacFailed         = 0
        BacOk             = 0
        BacFailedByDevice = @{}
        BacOkByDevice     = @{}
        BacLastStatus     = @{}
        BacFlipByDevice   = @{}
        BacObjectList     = 0
        BacObjectListByDevice = @{}
        BacFailedSample   = $null
        BacOkSample       = $null
        BacObjectListSample = $null
        CnsResolve        = 0
        CnsReduced        = 0
        CnsICns           = 0
        CnsTryRenew       = 0
        CnsPatterns       = @{}
        CnsPatternSamples = @{}
        CnsPatternTimes   = @{}
        CohoStuck         = 0
        CohoStuckNames    = @{}
        CohoSample        = $null
        ApogeeEvents      = 0
        ApogeeUpdatePoints = 0
        ApogeeRepetition  = 0
        ApogeeOther       = 0
        ApogeePpcl        = @{}
        ApogeeSample      = $null
    }
}

$script:LineRe = [regex]'^([^,]+),\s*(\d{4}\.\d{2}\.\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+),\s*([^,]+),\s*([^,\s]+)'
$script:ReBacFailed = [regex]'Device\s+(\d+)\s+Status is now Failed'
$script:ReBacOk = [regex]'Device\s+(\d+)\s+Status is now OK'
$script:ReBacObjList = [regex]'(?i)Could not get object list(?:\s+count)?(?:\s+for)?\s+device\s+(\d+)'
$script:ReCohoDiscoveryLoc = [regex]'(?i)DiscoveryLoc:([^\s]+)\s+got stuck\b'
$script:ReCohoDiscoveryCycle = [regex]'(?i)((?:Global|Observer)\s+Discovery Cycle\s+\[[^\]]+\])\s+got stuck\b'
$script:ReApogeePpcl = [regex]'(?i)PPCL Program Name:\s*(\S+?)(?:System\.|$)'
$script:ReApogeeComp = [regex]'(?i)(?:CoHo|Orch)\.Apogee'
$script:BacFlapMin = 3

$script:Sync = [hashtable]::Synchronized(@{
        Generation     = 0
        Loading        = $false
        LoadProgressPct = 0
        LoadMessage    = ''
        LoadStartPos   = 0L
        LoadSpanBytes  = 1L
        LoadLines      = 0
        LoadSkipped    = 0
        LoadSw         = $null
        LoadLastLogPct = -1
        LoadLastLogMs  = 0L
        LoadEnforce    = $false
        LoadCutoff     = [datetime]::MinValue
        LoadCutoffCompare = ''
        CatchUpActive  = $false
        Paused         = $false
        TailRunning    = $false
        Rotated        = $false
        LastError      = $null
        LogPath        = ''
        FileLength     = 0L
        FilePos        = 0L
        WindowEntire   = $false
        LastMinutes    = $LastMinutes
        Cutoff         = $null
        PrefillPath    = (Read-PrefillPath -Preferred $LogPath)
        ListeningUrl   = ''
        BoundPort      = 0
        Data           = (New-EmptyState)
        Stream         = $null
        Reader         = $null
        PartialLine    = ''
    })

function script:Bump-Generation {
    $script:Sync['Generation'] = [int]$script:Sync['Generation'] + 1
    $script:Sync['Rotated'] = $false
}

function script:Reset-Analysis {
    $script:Sync['Data'] = New-EmptyState
    Bump-Generation
}

function script:Ensure-Minute {
    param([hashtable]$Data, [string]$Key)
    if (-not $Data.ByMinute.ContainsKey($Key)) {
        $Data.ByMinute[$Key] = @{
            FATAL = 0; SEVERE = 0; ERROR = 0; WARNING = 0; INFO = 0
            bacFailed = 0; bacOk = 0
        }
    }
    return $Data.ByMinute[$Key]
}

function script:Process-LogLine {
    param(
        [string]$Line,
        [hashtable]$Data = $null,
        [bool]$EnforceCutoff = $false,
        [string]$CutoffCompare = ''
    )
    if ($null -eq $Data) { $Data = $script:Sync['Data'] }
    $m = $script:LineRe.Match($Line)
    if (-not $m.Success) {
        $Data.UnparsedLines++
        return
    }
    $comp = $m.Groups[1].Value.Trim()
    $ts = $m.Groups[2].Value
    $sev = $m.Groups[4].Value.Trim().ToUpperInvariant()
    if ($sev -eq 'WARN') { $sev = 'WARNING' }

    # String compare is far cheaper than Get-Date (V1.1 skips timestamp parse on full-file scans).
    if ($EnforceCutoff -and $CutoffCompare -and $ts.Length -ge 19 -and $ts.Substring(0, 19) -lt $CutoffCompare) {
        return
    }

    $Data.ParsedLines++
    if (-not $Data.FirstTs) { $Data.FirstTs = $ts }
    $Data.LastTs = $ts
    if (-not $Data.Severity.ContainsKey($sev)) { $Data.Severity[$sev] = 0 }
    $Data.Severity[$sev]++
    if (-not $Data.Components.ContainsKey($comp)) { $Data.Components[$comp] = 0 }
    $Data.Components[$comp]++
    if (-not $Data.CompSev.ContainsKey($comp)) { $Data.CompSev[$comp] = @{} }
    if (-not $Data.CompSev[$comp].ContainsKey($sev)) { $Data.CompSev[$comp][$sev] = 0 }
    $Data.CompSev[$comp][$sev]++

    $mk = if ($ts.Length -ge 16) { $ts.Substring(0, 16) } else { $ts }
    if (-not $Data.ByMinute.ContainsKey($mk)) {
        $Data.ByMinute[$mk] = @{
            FATAL = 0; SEVERE = 0; ERROR = 0; WARNING = 0; INFO = 0
            bacFailed = 0; bacOk = 0
        }
    }
    $bucket = $Data.ByMinute[$mk]
    if ($bucket.ContainsKey($sev)) { $bucket[$sev]++ }

    $isWarning = ($sev -eq 'WARNING')
    $isSevere = ($sev -eq 'SEVERE' -or $sev -eq 'FATAL' -or $sev -eq 'ERROR')
    if ($isSevere) { $Data.SevereLines++ }

    $perf = Get-PerfCategory -Line $Line
    if ($perf) {
        if (-not $Data.PerfCats.ContainsKey($perf)) { $Data.PerfCats[$perf] = 0 }
        $Data.PerfCats[$perf]++
    }

    $sevBucket = $null
    if ($sev -eq 'FATAL') { $sevBucket = 'FATAL' }
    elseif ($sev -eq 'SEVERE') { $sevBucket = 'SEVERE' }
    elseif ($sev -eq 'ERROR') { $sevBucket = 'ERROR' }
    elseif ($isWarning) { $sevBucket = 'WARNING' }
    elseif ($sev -eq 'INFO') { $sevBucket = 'INFO' }

    if ($sevBucket -and $sevBucket -ne 'INFO') {
        $norm = Normalize-Message -Text $Line
        Add-Pattern -CountMap $Data.PatternsBySev[$sevBucket] -SampleMap $Data.PatternSampleBySev[$sevBucket] `
            -TimeMap $Data.PatternTimeBySev[$sevBucket] -Norm $norm -Line $Line -Timestamp $ts -SampleLimit $SamplePerPattern
        if (-not $Data.CompPatterns.ContainsKey($comp)) {
            $Data.CompPatterns[$comp] = @{ FATAL = @{}; SEVERE = @{}; ERROR = @{}; WARNING = @{} }
            $Data.CompPatternSamples[$comp] = @{ FATAL = @{}; SEVERE = @{}; ERROR = @{}; WARNING = @{} }
            $Data.CompPatternTimes[$comp] = @{ FATAL = @{}; SEVERE = @{}; ERROR = @{}; WARNING = @{} }
        }
        if ($Data.CompPatterns[$comp].ContainsKey($sevBucket)) {
            Add-Pattern -CountMap $Data.CompPatterns[$comp][$sevBucket] -SampleMap $Data.CompPatternSamples[$comp][$sevBucket] `
                -TimeMap $Data.CompPatternTimes[$comp][$sevBucket] -Norm $norm -Line $Line -Timestamp $ts -SampleLimit $SamplePerPattern
        }
    }
    elseif ($sevBucket -eq 'INFO' -and $script:ReInfoBacStatus.IsMatch($Line)) {
        $norm = Normalize-Message -Text $Line
        Add-Pattern -CountMap $Data.PatternsBySev['INFO'] -SampleMap $Data.PatternSampleBySev['INFO'] `
            -TimeMap $Data.PatternTimeBySev['INFO'] -Norm $norm -Line $Line -Timestamp $ts -SampleLimit $SamplePerPattern
    }

    if ($comp.IndexOf('BACnet', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        $bacNewStatus = $null
        $bacDevId = $null
        $mf = $script:ReBacFailed.Match($Line)
        if ($mf.Success) {
            $Data.BacFailed++
            $bacDevId = $mf.Groups[1].Value
            $bacNewStatus = 'Failed'
            if (-not $Data.BacFailedByDevice.ContainsKey($bacDevId)) { $Data.BacFailedByDevice[$bacDevId] = 0 }
            $Data.BacFailedByDevice[$bacDevId]++
            if (-not $Data.BacFailedSample) { $Data.BacFailedSample = $Line }
            $bucket.bacFailed++
        }
        else {
            $mo = $script:ReBacOk.Match($Line)
            if ($mo.Success) {
                $Data.BacOk++
                $bacDevId = $mo.Groups[1].Value
                $bacNewStatus = 'OK'
                if (-not $Data.BacOkByDevice.ContainsKey($bacDevId)) { $Data.BacOkByDevice[$bacDevId] = 0 }
                $Data.BacOkByDevice[$bacDevId]++
                if (-not $Data.BacOkSample) { $Data.BacOkSample = $Line }
                $bucket.bacOk++
            }
        }
        if ($bacDevId -and $bacNewStatus) {
            if ($Data.BacLastStatus.ContainsKey($bacDevId) -and $Data.BacLastStatus[$bacDevId] -ne $bacNewStatus) {
                if (-not $Data.BacFlipByDevice.ContainsKey($bacDevId)) { $Data.BacFlipByDevice[$bacDevId] = 0 }
                $Data.BacFlipByDevice[$bacDevId]++
            }
            $Data.BacLastStatus[$bacDevId] = $bacNewStatus
        }
        $ml = $script:ReBacObjList.Match($Line)
        if ($ml.Success) {
            $Data.BacObjectList++
            $id = $ml.Groups[1].Value
            if (-not $Data.BacObjectListByDevice.ContainsKey($id)) { $Data.BacObjectListByDevice[$id] = 0 }
            $Data.BacObjectListByDevice[$id]++
            if (-not $Data.BacObjectListSample) { $Data.BacObjectListSample = $Line }
        }
    }

    $isCnsLine = $false
    if ($script:ReCnsResolve.IsMatch($Line)) { $Data.CnsResolve++; $isCnsLine = $true }
    if ($script:ReCnsReduced.IsMatch($Line)) { $Data.CnsReduced++; $isCnsLine = $true }
    if ($script:ReCnsICns.IsMatch($Line)) { $Data.CnsICns++; $isCnsLine = $true }
    if ($script:ReCnsRenew.IsMatch($Line)) { $Data.CnsTryRenew++; $isCnsLine = $true }
    if ($isCnsLine) {
        $norm = Normalize-Message -Text $Line
        Add-Pattern -CountMap $Data.CnsPatterns -SampleMap $Data.CnsPatternSamples -TimeMap $Data.CnsPatternTimes `
            -Norm $norm -Line $Line -Timestamp $ts -SampleLimit $SamplePerPattern
    }

    if ($comp.IndexOf('CoHo', [StringComparison]::OrdinalIgnoreCase) -ge 0 -and $script:ReCohoStuck.IsMatch($Line)) {
        $Data.CohoStuck++
        if (-not $Data.CohoSample) { $Data.CohoSample = $Line }
        $name = $null
        $mLoc = $script:ReCohoDiscoveryLoc.Match($Line)
        if ($mLoc.Success) { $name = 'DiscoveryLoc:' + $mLoc.Groups[1].Value }
        else {
            $mCycle = $script:ReCohoDiscoveryCycle.Match($Line)
            if ($mCycle.Success) {
                $name = $mCycle.Groups[1].Value.Trim()
                $name = $script:ReCohoLockCollapse.Replace($name, ': <N>')
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            if (-not $Data.CohoStuckNames.ContainsKey($name)) { $Data.CohoStuckNames[$name] = 0 }
            $Data.CohoStuckNames[$name]++
        }
    }

    if ($script:ReApogeeComp.IsMatch($Line)) {
        $Data.ApogeeEvents++
        if (-not $Data.ApogeeSample) { $Data.ApogeeSample = $Line }
        if ($script:ReApogeeUpdate.IsMatch($Line)) {
            $Data.ApogeeUpdatePoints++
            $mPpcl = $script:ReApogeePpcl.Match($Line)
            if ($mPpcl.Success) {
                $pn = $mPpcl.Groups[1].Value.Trim()
                if ($pn) {
                    if (-not $Data.ApogeePpcl.ContainsKey($pn)) { $Data.ApogeePpcl[$pn] = 0 }
                    $Data.ApogeePpcl[$pn]++
                }
            }
        }
        elseif ($script:ReApogeeRep.IsMatch($Line)) { $Data.ApogeeRepetition++ }
        else { $Data.ApogeeOther++ }
    }
}

function script:Close-LogStream {
    try { if ($script:Sync['Reader']) { $script:Sync['Reader'].Close() } } catch {}
    try { if ($script:Sync['Stream']) { $script:Sync['Stream'].Close() } } catch {}
    $script:Sync['Reader'] = $null
    $script:Sync['Stream'] = $null
    $script:Sync['PartialLine'] = ''
}

function script:Open-LogStream {
    param([string]$Path, [long]$Position = 0L)
    Close-LogStream
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    if ($Position -gt 0 -and $Position -le $fs.Length) { [void]$fs.Seek($Position, [System.IO.SeekOrigin]::Begin) }
    $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true, 1048576, $true)
    $script:Sync['Stream'] = $fs
    $script:Sync['Reader'] = $reader
    $script:Sync['FilePos'] = $fs.Position
    $script:Sync['FileLength'] = $fs.Length
}

function script:Get-ProbeTimestamps {
    param(
        [string]$Path,
        [long]$SeekPos,
        [long]$MaxBytes = 1048576L
    )
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $len = $fs.Length
        if ($SeekPos -lt 0) { $SeekPos = 0 }
        if ($SeekPos -ge $len) {
            return @{ First = $null; Last = $null; SeekPos = $SeekPos }
        }
        $toRead = [int][math]::Min($MaxBytes, $len - $SeekPos)
        $fs.Position = $SeekPos
        $buf = New-Object byte[] $toRead
        $n = $fs.Read($buf, 0, $toRead)
        if ($n -le 0) {
            return @{ First = $null; Last = $null; SeekPos = $SeekPos }
        }
        $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
        if ($SeekPos -gt 0) {
            $cut = $text.IndexOfAny([char[]]@("`n", "`r"))
            if ($cut -ge 0) {
                if ($cut + 1 -lt $text.Length -and $text[$cut] -eq "`r" -and $text[$cut + 1] -eq "`n") {
                    $text = $text.Substring($cut + 2)
                }
                else {
                    $text = $text.Substring($cut + 1)
                }
            }
            else {
                return @{ First = $null; Last = $null; SeekPos = $SeekPos }
            }
        }
        $first = $null
        $last = $null
        foreach ($line in ($text -split "`r?`n")) {
            if ([string]::IsNullOrEmpty($line)) { continue }
            $m = $script:LineRe.Match($line)
            if (-not $m.Success) { continue }
            $dt = ConvertFrom-LogTimestamp -Ts $m.Groups[2].Value.Trim()
            if (-not $dt) { continue }
            if (-not $first) { $first = $dt }
            $last = $dt
        }
        return @{ First = $first; Last = $last; SeekPos = $SeekPos }
    }
    finally { $fs.Close() }
}

function script:Get-LogFileEndTimestamp {
    param([string]$Path)
    $fi = Get-Item -LiteralPath $Path
    $len = [int64]$fi.Length
    if ($len -le 0) { return $null }
    $seek = [math]::Max([int64]0, $len - 1048576L)
    $probe = Get-ProbeTimestamps -Path $Path -SeekPos $seek -MaxBytes 1048576L
    return $probe.Last
}

function script:Find-WindowStartPosition {
    param(
        [string]$Path,
        [datetime]$Cutoff
    )
    $fi = Get-Item -LiteralPath $Path
    $len = $fi.Length
    if ($len -le 0) { return 0L }

    # Expand backward from EOF until the earliest timestamp in the probe is at/before cutoff (or file start).
    $chunk = [int64]262144  # 256 KB
    $maxChunk = [math]::Min($len, [int64]32MB)
    $startPos = [math]::Max([int64]0, $len - $chunk)
    $guard = 0
    while ($guard -lt 40) {
        $guard++
        $probe = Get-ProbeTimestamps -Path $Path -SeekPos $startPos -MaxBytes ([math]::Min($chunk, [int64]2MB))
        if ($null -eq $probe.First) {
            # No headers in this probe - jump further back
            if ($startPos -eq 0) { return 0L }
            $chunk = [math]::Min($maxChunk, [int64]($chunk * 2))
            $startPos = [math]::Max([int64]0, $len - $chunk)
            continue
        }
        if ($probe.First -le $Cutoff -or $startPos -eq 0) {
            Write-WatchLog ("Window seek landed at byte {0:N0} / {1:N0} (first ts in probe {2})" -f `
                $startPos, $len, $probe.First)
            return $startPos
        }
        $chunk = [math]::Min($maxChunk, [int64]($chunk * 2))
        $next = [math]::Max([int64]0, $len - $chunk)
        if ($next -eq $startPos) {
            return 0L
        }
        $startPos = $next
    }
    return $startPos
}

function script:Write-WatchLog {
    param([string]$Message, [ConsoleColor]$Color = [ConsoleColor]::DarkGray)
    $ts = (Get-Date).ToString('HH:mm:ss')
    Write-Host ("[{0}] {1}" -f $ts, $Message) -ForegroundColor $Color
}

function script:Update-LoadProgress {
    param([switch]$ForceLog)
    if (-not $script:Sync['Loading']) { return }
    $startPos = [int64]$script:Sync['LoadStartPos']
    $span = [math]::Max(1L, [int64]$script:Sync['LoadSpanBytes'])
    $pos = 0L
    if ($script:Sync['Stream']) { $pos = [int64]$script:Sync['Stream'].Position }
    $pct = [int](100.0 * ($pos - $startPos) / $span)
    if ($pct -lt 0) { $pct = 0 }
    if ($pct -gt 99 -and $script:Sync['CatchUpActive']) { $pct = 99 }
    if ($pct -gt 100) { $pct = 100 }
    $script:Sync['LoadProgressPct'] = $pct
    $mode = if ($script:Sync['WindowEntire']) { 'Loading entire file' } else { ("Loading last {0} minutes" -f $script:Sync['LastMinutes']) }
    $script:Sync['LoadMessage'] = ("{0}... {1}%" -f $mode, $pct)

    $lastPct = [int]$script:Sync['LoadLastLogPct']
    $sw = $script:Sync['LoadSw']
    $elapsedMs = if ($sw) { $sw.ElapsedMilliseconds } else { 0L }
    $lastLogMs = [int64]$script:Sync['LoadLastLogMs']
    $dueConsole = $ForceLog -or ($pct -ge ($lastPct + 10)) -or ($elapsedMs -ge ($lastLogMs + 3000))
    if ($dueConsole) {
        $script:Sync['LoadLastLogPct'] = $pct
        $script:Sync['LoadLastLogMs'] = $elapsedMs
        $elapsed = if ($sw) { [math]::Round($sw.Elapsed.TotalSeconds, 1) } else { 0 }
        Write-WatchLog ("Catch-up ... {0}%  scanned={1:N0}  parsed={2:N0}  {3}s" -f `
            $pct, $script:Sync['LoadLines'], $script:Sync['Data'].ParsedLines, $elapsed)
    }
}

function script:Begin-CatchUp {
    param([string]$Path)
    $script:Sync['CatchUpActive'] = $false
    $script:Sync['Loading'] = $true
    $script:Sync['LoadProgressPct'] = 0
    $script:Sync['LastError'] = $null
    $script:Sync['TailRunning'] = $false
    Bump-Generation

    $entire = [bool]$script:Sync['WindowEntire']
    $mode = if ($entire) { 'Entire file' } else { ("last {0} minutes" -f $script:Sync['LastMinutes']) }
    Write-WatchLog ("Catch-up START  mode={0}  path={1}" -f $mode, $Path) Cyan
    $script:Sync['LoadMessage'] = if ($entire) { 'Loading entire file... 0%' } else { ("Loading last {0} minutes... 0%" -f $script:Sync['LastMinutes']) }

    Reset-Analysis
    $cutoff = [datetime]::MinValue
    $enforce = $false
    $startPos = 0L
    if (-not $entire) {
        # Anchor to newest timestamp in the file (not wall clock) so copied/old logs
        # and live tails both mean "last N minutes of this log."
        $anchor = Get-LogFileEndTimestamp -Path $Path
        if ($anchor) {
            $cutoff = $anchor.AddMinutes(-[double]$script:Sync['LastMinutes'])
            Write-WatchLog ("Window anchored to file end {0:yyyy.MM.dd HH:mm:ss}; cutoff {1:yyyy.MM.dd HH:mm:ss}" -f `
                $anchor, $cutoff)
        }
        else {
            $cutoff = (Get-Date).AddMinutes(-[double]$script:Sync['LastMinutes'])
            Write-WatchLog ("No EOF timestamp found; wall-clock cutoff {0:yyyy.MM.dd HH:mm:ss}" -f $cutoff) Yellow
        }
        $enforce = $true
        $script:Sync['Cutoff'] = $cutoff
        Write-WatchLog ("Seeking from EOF for cutoff {0:yyyy.MM.dd HH:mm:ss} ..." -f $cutoff)
        $startPos = Find-WindowStartPosition -Path $Path -Cutoff $cutoff
    }
    else {
        $script:Sync['Cutoff'] = $null
    }

    Open-LogStream -Path $Path -Position $startPos
    $reader = $script:Sync['Reader']
    if ($startPos -gt 0) {
        [void]$reader.ReadLine()
    }

    $totalBytes = [math]::Max(1L, $script:Sync['Stream'].Length)
    $spanBytes = [math]::Max(1L, $totalBytes - $startPos)
    $script:Sync['LoadStartPos'] = $startPos
    $script:Sync['LoadSpanBytes'] = $spanBytes
    $script:Sync['LoadLines'] = 0
    $script:Sync['LoadSkipped'] = 0
    $script:Sync['LoadEnforce'] = $enforce
    $script:Sync['LoadCutoff'] = $cutoff
    $script:Sync['LoadCutoffCompare'] = if ($enforce) { $cutoff.ToString('yyyy.MM.dd HH:mm:ss') } else { '' }
    $script:Sync['LoadSw'] = [System.Diagnostics.Stopwatch]::StartNew()
    $script:Sync['LoadLastLogPct'] = -1
    $script:Sync['LoadLastLogMs'] = 0L
    $script:Sync['CatchUpActive'] = $true
    $script:Sync['FileLength'] = $totalBytes

    Write-WatchLog ("Catch-up reading from byte {0:N0} ({1:N1} MB of {2:N1} MB file)" -f `
        $startPos, ($spanBytes / 1MB), ($totalBytes / 1MB))
    Update-LoadProgress -ForceLog
}

function script:Finish-CatchUp {
    param([string]$Outcome = 'DONE')
    $script:Sync['CatchUpActive'] = $false
    $script:Sync['FilePos'] = if ($script:Sync['Stream']) { $script:Sync['Stream'].Position } else { 0L }
    $script:Sync['FileLength'] = if ($script:Sync['Stream']) { $script:Sync['Stream'].Length } else { 0L }
    if ($Outcome -eq 'DONE') {
        $script:Sync['LoadProgressPct'] = 100
        $script:Sync['LoadMessage'] = ''
        $script:Sync['TailRunning'] = $true
        $script:Sync['Paused'] = $false
        $script:Sync['Loading'] = $false
        $elapsed = 0
        if ($script:Sync['LoadSw']) { $elapsed = $script:Sync['LoadSw'].Elapsed.TotalSeconds }
        Write-WatchLog ("Catch-up DONE   scanned={0:N0} parsed={1:N0} skippedBeforeWindow={2:N0} in {3:N1}s" -f `
            $script:Sync['LoadLines'], $script:Sync['Data'].ParsedLines, $script:Sync['LoadSkipped'], $elapsed) Green
    }
    else {
        $script:Sync['Loading'] = $false
        $script:Sync['TailRunning'] = $false
        $script:Sync['LoadMessage'] = ''
    }
    Bump-Generation
}

function script:Step-CatchUp {
    param(
        [int]$MaxLines = 8000,
        [int]$MaxMilliseconds = 200
    )
    if (-not $script:Sync['CatchUpActive']) { return }
    try {
        $reader = $script:Sync['Reader']
        if (-not $reader) {
            Finish-CatchUp -Outcome 'FAIL'
            return
        }
        $data = $script:Sync['Data']
        $enforce = [bool]$script:Sync['LoadEnforce']
        $cutoffCmp = [string]$script:Sync['LoadCutoffCompare']
        $n = 0
        $skipped = 0
        $slice = [System.Diagnostics.Stopwatch]::StartNew()
        while ($n -lt $MaxLines) {
            if ($MaxMilliseconds -gt 0 -and $slice.ElapsedMilliseconds -ge $MaxMilliseconds) { break }
            $line = $reader.ReadLine()
            if ($null -eq $line) {
                $script:Sync['LoadLines'] = [int]$script:Sync['LoadLines'] + $n
                if ($skipped -gt 0) { $script:Sync['LoadSkipped'] = [int]$script:Sync['LoadSkipped'] + $skipped }
                Finish-CatchUp -Outcome 'DONE'
                return
            }
            $before = $data.ParsedLines
            Process-LogLine -Line $line -Data $data -EnforceCutoff:$enforce -CutoffCompare $cutoffCmp
            $n++
            if ($enforce -and $data.ParsedLines -eq $before) {
                $m = $script:LineRe.Match($line)
                if ($m.Success) {
                    $ts = $m.Groups[2].Value
                    if ($cutoffCmp -and $ts.Length -ge 19 -and $ts.Substring(0, 19) -lt $cutoffCmp) { $skipped++ }
                }
            }
        }
        $script:Sync['LoadLines'] = [int]$script:Sync['LoadLines'] + $n
        if ($skipped -gt 0) { $script:Sync['LoadSkipped'] = [int]$script:Sync['LoadSkipped'] + $skipped }
        Update-LoadProgress
    }
    catch {
        $script:Sync['LastError'] = $_.Exception.Message
        Write-WatchLog ("Catch-up FAILED  {0}" -f $_.Exception.Message) Red
        Close-LogStream
        Finish-CatchUp -Outcome 'FAIL'
    }
}

function script:Invoke-CatchUp {
    param([string]$Path)
    Begin-CatchUp -Path $Path
}

function script:Read-TailBytes {
    if (-not $script:Sync['TailRunning'] -or $script:Sync['Paused'] -or $script:Sync['Loading']) { return }
    if (-not $script:Sync['Stream'] -or -not $script:Sync['LogPath']) { return }
    try {
        if (-not (Test-Path -LiteralPath $script:Sync['LogPath'])) {
            $script:Sync['LastError'] = 'Log file is missing.'
            $script:Sync['TailRunning'] = $false
            Close-LogStream
            Bump-Generation
            return
        }
        $len = (Get-Item -LiteralPath $script:Sync['LogPath']).Length
        if ($len -lt $script:Sync['FilePos']) {
            # rotated
            $script:Sync['Rotated'] = $true
            Invoke-CatchUp -Path $script:Sync['LogPath']
            $script:Sync['Rotated'] = $true
            Bump-Generation
            return
        }
        if ($len -eq $script:Sync['FilePos']) { return }

        [void]$script:Sync['Stream'].Seek($script:Sync['FilePos'], [System.IO.SeekOrigin]::Begin)
        $chunk = $script:Sync['Reader'].ReadToEnd()
        $script:Sync['FilePos'] = $script:Sync['Stream'].Position
        $script:Sync['FileLength'] = $script:Sync['Stream'].Length
        if ([string]::IsNullOrEmpty($chunk)) { return }

        $text = $script:Sync['PartialLine'] + $chunk
        $parts = $text -split "`r?`n", -1
        if (-not $text.EndsWith("`n") -and -not $text.EndsWith("`r")) {
            $script:Sync['PartialLine'] = $parts[-1]
            $limit = $parts.Count - 1
        }
        else {
            $script:Sync['PartialLine'] = ''
            $limit = $parts.Count
            if ($limit -gt 0 -and [string]::IsNullOrEmpty($parts[$limit - 1])) { $limit-- }
        }
        $changed = $false
        for ($i = 0; $i -lt $limit; $i++) {
            if ([string]::IsNullOrEmpty($parts[$i])) { continue }
            Process-LogLine -Line $parts[$i] -EnforceCutoff:$false
            $changed = $true
        }
        if ($changed) { Bump-Generation }
    }
    catch {
        $script:Sync['LastError'] = $_.Exception.Message
        $script:Sync['TailRunning'] = $false
        Bump-Generation
    }
}

function script:Get-TopPatterns {
    param([hashtable]$CountMap, [hashtable]$SampleMap, [hashtable]$TimeMap, [int]$N)
    $out = @()
    if ($null -eq $CountMap -or $CountMap.Count -eq 0) { return $out }
    $sorted = @($CountMap.GetEnumerator() | Sort-Object { $_.Value } -Descending | Select-Object -First $N)
    foreach ($e in $sorted) {
        $first = $null; $last = $null
        if ($null -ne $TimeMap -and $TimeMap.ContainsKey($e.Key)) {
            $first = [string]$TimeMap[$e.Key]['First']
            $last = [string]$TimeMap[$e.Key]['Last']
        }
        $samples = @()
        if ($null -ne $SampleMap -and $SampleMap.ContainsKey($e.Key) -and $null -ne $SampleMap[$e.Key]) {
            foreach ($s in @($SampleMap[$e.Key])) { $samples += [string]$s }
        }
        $out += [pscustomobject]@{
            pattern = [string]$e.Key
            count   = [int]$e.Value
            first   = $first
            last    = $last
            samples = $samples
        }
    }
    return $out
}

function script:Build-Findings {
    $d = $script:Sync['Data']
    $findings = New-Object System.Collections.Generic.List[string]
    if ($d.ParsedLines -gt 0) {
        $pct = [math]::Round(100.0 * $d.SevereLines / $d.ParsedLines, 1)
        if ($pct -ge 5) { [void]$findings.Add("HIGH: Critical-severity lines are $pct% of parsed lines ($($d.SevereLines) combined FATAL/SEVERE/ERROR).") }
        elseif ($pct -ge 2) { [void]$findings.Add("MEDIUM: Critical-severity lines are $pct% of parsed lines ($($d.SevereLines)).") }
    }
    $bacTransitions = $d.BacFailed + $d.BacOk
    $endedFailed = @($d.BacLastStatus.GetEnumerator() | Where-Object { $_.Value -eq 'Failed' }).Count
    $endedOk = @($d.BacLastStatus.GetEnumerator() | Where-Object { $_.Value -eq 'OK' }).Count
    $flappers = @($d.BacFlipByDevice.GetEnumerator() | Where-Object { $_.Value -ge $script:BacFlapMin }).Count
    if ($d.BacFailed -ge 500 -or $bacTransitions -ge 2000) {
        [void]$findings.Add(("BACnet device status chatter: {0:N0} Failed and {1:N0} OK transitions ({2:N0} unique devices Failed)." -f $d.BacFailed, $d.BacOk, $d.BacFailedByDevice.Count))
    }
    if ($endedFailed -ge 20) {
        [void]$findings.Add(("BACnet last-known status: {0:N0} devices ended Failed, {1:N0} ended OK (in analyzed window)." -f $endedFailed, $endedOk))
    }
    if ($flappers -ge 5) {
        [void]$findings.Add(("BACnet flapping: {0:N0} devices with {1}+ Failed/OK status changes." -f $flappers, $script:BacFlapMin))
    }
    if ($d.BacObjectList -ge 100) {
        [void]$findings.Add(("BACnet object-list warnings: {0:N0} events across {1:N0} devices." -f $d.BacObjectList, $d.BacObjectListByDevice.Count))
    }
    if ($d.CnsResolve -ge 100 -or $d.CnsReduced -ge 100) {
        [void]$findings.Add(("CNS volume: ResolveNodes={0:N0}, ReducedFunction={1:N0}, ICns={2:N0}." -f $d.CnsResolve, $d.CnsReduced, $d.CnsICns))
    }
    if ($d.CnsTryRenew -ge 5) { [void]$findings.Add(("CNS/session: TryRenewSession hits={0:N0}." -f $d.CnsTryRenew)) }
    if ($d.CohoStuck -ge 10) { [void]$findings.Add(("CoHo stuck/drop messages: {0:N0}." -f $d.CohoStuck)) }
    if ($d.ApogeeUpdatePoints -ge 10) {
        [void]$findings.Add(("Apogee UpdatePoints failures: {0:N0} across {1:N0} PPCL programs." -f $d.ApogeeUpdatePoints, $d.ApogeePpcl.Count))
    }
    if ($d.PerfCats.ContainsKey('Timeout') -and $d.PerfCats['Timeout'] -ge 5) {
        [void]$findings.Add("HIGH: Timeouts detected ($($d.PerfCats['Timeout'])).")
    }
    if ($findings.Count -eq 0 -and $d.ParsedLines -gt 0) {
        [void]$findings.Add('No strong automated volume findings from current heuristics.')
    }
    return @($findings)
}

function script:Parse-QuerySevs {
    param([System.Collections.Specialized.NameValueCollection]$Q)
    $raw = $Q['severities']
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{ FATAL = $true; SEVERE = $true; ERROR = $true; WARNING = $true; INFO = $false }
    }
    $set = @{}
    foreach ($s in @('FATAL', 'SEVERE', 'ERROR', 'WARNING', 'INFO')) { $set[$s] = $false }
    foreach ($part in ($raw -split ',')) {
        $p = $part.Trim().ToUpperInvariant()
        if ($set.ContainsKey($p)) { $set[$p] = $true }
    }
    return $set
}

function script:Get-ChartGranularity {
    param(
        [string]$FirstTs,
        [string]$LastTs,
        [int]$MinuteBucketCount
    )
    $dtFirst = ConvertFrom-LogTimestamp -Ts $FirstTs
    $dtLast = ConvertFrom-LogTimestamp -Ts $LastTs
    if ($dtFirst -and $dtLast -and $dtLast -ge $dtFirst) {
        $hours = ($dtLast - $dtFirst).TotalHours
        if ($hours -le 6) { return 'minute' }
        if ($hours -le (14 * 24)) { return 'hour' }
        return 'day'
    }
    if ($MinuteBucketCount -gt 400) { return 'hour' }
    if ($MinuteBucketCount -gt 2000) { return 'day' }
    return 'minute'
}

function script:Build-ChartSeries {
    param($Data, $SevFilter)
    $gran = Get-ChartGranularity -FirstTs $Data.FirstTs -LastTs $Data.LastTs -MinuteBucketCount $Data.ByMinute.Count
    if ($gran -eq 'minute' -and $Data.ByMinute.Count -gt 400) { $gran = 'hour' }

    $acc = @{}
    foreach ($e in $Data.ByMinute.GetEnumerator()) {
        $src = $e.Key
        $key = switch ($gran) {
            'day' {
                if ($src.Length -ge 10) { $src.Substring(0, 10) } else { $src }
            }
            'hour' {
                if ($src.Length -ge 13) { $src.Substring(0, 13) } else { $src }
            }
            default { $src }
        }
        if (-not $acc.ContainsKey($key)) {
            $acc[$key] = @{
                FATAL = 0; SEVERE = 0; ERROR = 0; WARNING = 0; INFO = 0
                bacFailed = 0; bacOk = 0
            }
        }
        $dst = $acc[$key]
        $v = $e.Value
        foreach ($s in @('FATAL', 'SEVERE', 'ERROR', 'WARNING', 'INFO')) {
            $dst[$s] += [int]$v[$s]
        }
        $dst.bacFailed += [int]$v.bacFailed
        $dst.bacOk += [int]$v.bacOk
    }

    $rows = @(
        $acc.GetEnumerator() | Sort-Object Name | ForEach-Object {
            $v = $_.Value
            $row = [ordered]@{ t = $_.Key; bacFailed = [int]$v.bacFailed; bacOk = [int]$v.bacOk }
            foreach ($s in @('FATAL', 'SEVERE', 'ERROR', 'WARNING', 'INFO')) {
                if ($SevFilter[$s]) { $row[$s] = [int]$v[$s] } else { $row[$s] = 0 }
            }
            $row
        }
    )
    return [ordered]@{ granularity = $gran; byMinute = $rows }
}

function script:Build-PulseObject {
    param($SevFilter)
    $d = $script:Sync['Data']
    $win = if ($script:Sync['WindowEntire']) {
        [ordered]@{ mode = 'entire'; lastMinutes = 0; first = $d.FirstTs; last = $d.LastTs }
    }
    else {
        [ordered]@{ mode = 'minutes'; lastMinutes = [int]$script:Sync['LastMinutes']; first = $d.FirstTs; last = $d.LastTs }
    }

    # While catch-up runs, keep pulse cheap so % updates do not stall the scan.
    if ($script:Sync['Loading']) {
        $sevCounts = [ordered]@{}
        foreach ($s in @('FATAL', 'SEVERE', 'ERROR', 'WARNING', 'INFO')) {
            $sevCounts[$s] = if ($d.Severity.ContainsKey($s)) { [int]$d.Severity[$s] } else { 0 }
        }
        return [ordered]@{
            generation      = [int]$script:Sync['Generation']
            window          = $win
            loading         = $true
            loadProgressPct = [int]$script:Sync['LoadProgressPct']
            loadMessage     = [string]$script:Sync['LoadMessage']
            paused          = [bool]$script:Sync['Paused']
            tailRunning     = $false
            rotated         = [bool]$script:Sync['Rotated']
            lastError       = $script:Sync['LastError']
            logPath         = $script:Sync['LogPath']
            fileLength      = [int64]$script:Sync['FileLength']
            findings        = @()
            severityCounts  = $sevCounts
            moduleHeadlines = [ordered]@{
                bacnet = [ordered]@{ failed = $d.BacFailed; ok = $d.BacOk; endedFailed = 0; endedOk = 0; flappers = 0; objectList = $d.BacObjectList }
                cns    = [ordered]@{ resolveNodes = $d.CnsResolve; reducedFunction = $d.CnsReduced; tryRenew = $d.CnsTryRenew; icns = $d.CnsICns }
                coho   = [ordered]@{ stuck = $d.CohoStuck }
                apogee = [ordered]@{ events = $d.ApogeeEvents; updatePoints = $d.ApogeeUpdatePoints }
            }
            topManagers     = @()
            series          = [ordered]@{ granularity = 'minute'; byMinute = @() }
        }
    }

    $sevCounts = [ordered]@{}
    foreach ($s in @('FATAL', 'SEVERE', 'ERROR', 'WARNING', 'INFO')) {
        $sevCounts[$s] = if ($d.Severity.ContainsKey($s)) { [int]$d.Severity[$s] } else { 0 }
    }
    $endedFailed = @($d.BacLastStatus.GetEnumerator() | Where-Object { $_.Value -eq 'Failed' }).Count
    $endedOk = @($d.BacLastStatus.GetEnumerator() | Where-Object { $_.Value -eq 'OK' }).Count
    $flappers = @($d.BacFlipByDevice.GetEnumerator() | Where-Object { $_.Value -ge $script:BacFlapMin }).Count
    $topMgr = @(
        $d.Components.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 20 | ForEach-Object {
            [ordered]@{ name = $_.Key; count = [int]$_.Value }
        }
    )
    $series = Build-ChartSeries -Data $d -SevFilter $SevFilter
    return [ordered]@{
        generation      = [int]$script:Sync['Generation']
        window          = $win
        loading         = [bool]$script:Sync['Loading']
        loadProgressPct = [int]$script:Sync['LoadProgressPct']
        loadMessage     = [string]$script:Sync['LoadMessage']
        paused          = [bool]$script:Sync['Paused']
        tailRunning     = [bool]$script:Sync['TailRunning']
        rotated         = [bool]$script:Sync['Rotated']
        lastError       = $script:Sync['LastError']
        logPath         = $script:Sync['LogPath']
        fileLength      = [int64]$script:Sync['FileLength']
        findings        = @(Build-Findings)
        severityCounts  = $sevCounts
        moduleHeadlines = [ordered]@{
            bacnet = [ordered]@{ failed = $d.BacFailed; ok = $d.BacOk; endedFailed = $endedFailed; endedOk = $endedOk; flappers = $flappers; objectList = $d.BacObjectList }
            cns    = [ordered]@{ resolveNodes = $d.CnsResolve; reducedFunction = $d.CnsReduced; tryRenew = $d.CnsTryRenew; icns = $d.CnsICns }
            coho   = [ordered]@{ stuck = $d.CohoStuck }
            apogee = [ordered]@{ events = $d.ApogeeEvents; updatePoints = $d.ApogeeUpdatePoints }
        }
        topManagers     = $topMgr
        series          = $series
    }
}

function script:Build-SectionObject {
    param([string]$Name, $SevFilter)
    $d = $script:Sync['Data']
    $gen = [int]$script:Sync['Generation']
    switch ($Name.ToLowerInvariant()) {
        'patterns' {
            $p = [ordered]@{}
            foreach ($s in @('FATAL', 'SEVERE', 'ERROR', 'WARNING')) {
                if ($SevFilter[$s]) {
                    $p[$s] = @(Get-TopPatterns -CountMap $d.PatternsBySev[$s] -SampleMap $d.PatternSampleBySev[$s] -TimeMap $d.PatternTimeBySev[$s] -N $TopN)
                }
                else { $p[$s] = @() }
            }
            return [ordered]@{ generation = $gen; patternsBySeverity = $p }
        }
        'managers' {
            $list = @(
                $d.Components.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
                    $sevMap = [ordered]@{ FATAL = 0; SEVERE = 0; ERROR = 0; WARNING = 0; INFO = 0 }
                    if ($d.CompSev.ContainsKey($_.Key)) {
                        foreach ($k in $d.CompSev[$_.Key].Keys) { $sevMap[$k] = [int]$d.CompSev[$_.Key][$k] }
                    }
                    [ordered]@{ name = $_.Key; count = [int]$_.Value; severities = $sevMap }
                }
            )
            return [ordered]@{ generation = $gen; managers = $list }
        }
        'bacnet' {
            $endedFailed = @($d.BacLastStatus.GetEnumerator() | Where-Object { $_.Value -eq 'Failed' }).Count
            $endedOk = @($d.BacLastStatus.GetEnumerator() | Where-Object { $_.Value -eq 'OK' }).Count
            $flappers = @($d.BacFlipByDevice.GetEnumerator() | Where-Object { $_.Value -ge $script:BacFlapMin }).Count
            $activity = @(
                $d.BacFailedByDevice.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 20 | ForEach-Object {
                    $id = $_.Key
                    $oc = if ($d.BacOkByDevice.ContainsKey($id)) { $d.BacOkByDevice[$id] } else { 0 }
                    $fl = if ($d.BacFlipByDevice.ContainsKey($id)) { $d.BacFlipByDevice[$id] } else { 0 }
                    $last = if ($d.BacLastStatus.ContainsKey($id)) { $d.BacLastStatus[$id] } else { '?' }
                    [ordered]@{ device = $id; failed = [int]$_.Value; ok = [int]$oc; flips = [int]$fl; last = $last }
                }
            )
            $endedList = @(
                $d.BacLastStatus.GetEnumerator() | Where-Object { $_.Value -eq 'Failed' } | ForEach-Object {
                    $id = $_.Key
                    $fc = if ($d.BacFailedByDevice.ContainsKey($id)) { $d.BacFailedByDevice[$id] } else { 0 }
                    $oc = if ($d.BacOkByDevice.ContainsKey($id)) { $d.BacOkByDevice[$id] } else { 0 }
                    $fl = if ($d.BacFlipByDevice.ContainsKey($id)) { $d.BacFlipByDevice[$id] } else { 0 }
                    [pscustomobject]@{ device = $id; failed = [int]$fc; ok = [int]$oc; flips = [int]$fl }
                } | Sort-Object failed -Descending | Select-Object -First 20 | ForEach-Object {
                    [ordered]@{ device = $_.device; failed = $_.failed; ok = $_.ok; flips = $_.flips }
                }
            )
            $objTop = @(
                $d.BacObjectListByDevice.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 20 | ForEach-Object {
                    [ordered]@{ device = $_.Key; count = [int]$_.Value }
                }
            )
            return [ordered]@{
                generation = $gen
                bacnet     = [ordered]@{
                    failed = $d.BacFailed; ok = $d.BacOk; endedFailed = $endedFailed; endedOk = $endedOk
                    flappers = $flappers; objectList = $d.BacObjectList
                    failedSample = $d.BacFailedSample; okSample = $d.BacOkSample; objectListSample = $d.BacObjectListSample
                    activity = $activity; endedFailedList = $endedList; objectListTop = $objTop
                }
            }
        }
        'cns' {
            return [ordered]@{
                generation = $gen
                cns        = [ordered]@{
                    resolveNodes = $d.CnsResolve; reducedFunction = $d.CnsReduced; icns = $d.CnsICns; tryRenew = $d.CnsTryRenew
                    patterns = @(Get-TopPatterns -CountMap $d.CnsPatterns -SampleMap $d.CnsPatternSamples -TimeMap $d.CnsPatternTimes -N $TopN)
                }
            }
        }
        'coho' {
            $names = @(
                $d.CohoStuckNames.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $TopN | ForEach-Object {
                    [ordered]@{ name = $_.Key; count = [int]$_.Value }
                }
            )
            return [ordered]@{ generation = $gen; coho = [ordered]@{ stuck = $d.CohoStuck; sample = $d.CohoSample; topNames = $names } }
        }
        'apogee' {
            $ppcl = @(
                $d.ApogeePpcl.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $TopN | ForEach-Object {
                    [ordered]@{ name = $_.Key; count = [int]$_.Value }
                }
            )
            return [ordered]@{
                generation = $gen
                apogee     = [ordered]@{
                    events = $d.ApogeeEvents; updatePoints = $d.ApogeeUpdatePoints; repetition = $d.ApogeeRepetition
                    other = $d.ApogeeOther; uniquePpcl = $d.ApogeePpcl.Count; sample = $d.ApogeeSample; topPpcl = $ppcl
                }
            }
        }
        'perf' {
            $perf = @()
            if ($d.PerfCats -and $d.PerfCats.Count -gt 0) {
                foreach ($e in @($d.PerfCats.GetEnumerator() | Sort-Object { $_.Value } -Descending)) {
                    $perf += [pscustomobject]@{ name = [string]$e.Key; count = [int]$e.Value }
                }
            }
            return [pscustomobject]@{
                generation     = $gen
                perfCategories = $perf
                unparsedLines  = [int]$d.UnparsedLines
                parsedLines    = [int]$d.ParsedLines
                health         = [pscustomobject]@{
                    version = [string]$script:Version
                    port    = [int]$script:Sync['BoundPort']
                    url     = [string]$script:Sync['ListeningUrl']
                    logPath = [string]$script:Sync['LogPath']
                }
            }
        }
        default { return [ordered]@{ generation = $gen; error = "Unknown section: $Name" } }
    }
}

function script:Build-ManagerObject {
    param([string]$MgrName, $SevFilter)
    $d = $script:Sync['Data']
    $count = if ($d.Components.ContainsKey($MgrName)) { [int]$d.Components[$MgrName] } else { 0 }
    $sevMap = [ordered]@{ FATAL = 0; SEVERE = 0; ERROR = 0; WARNING = 0; INFO = 0 }
    if ($d.CompSev.ContainsKey($MgrName)) {
        foreach ($k in $d.CompSev[$MgrName].Keys) { $sevMap[$k] = [int]$d.CompSev[$MgrName][$k] }
    }
    $p = [ordered]@{}
    foreach ($s in @('FATAL', 'SEVERE', 'ERROR', 'WARNING')) {
        if ($SevFilter[$s] -and $d.CompPatterns.ContainsKey($MgrName) -and $d.CompPatterns[$MgrName].ContainsKey($s)) {
            $p[$s] = @(Get-TopPatterns -CountMap $d.CompPatterns[$MgrName][$s] -SampleMap $d.CompPatternSamples[$MgrName][$s] -TimeMap $d.CompPatternTimes[$MgrName][$s] -N $TopN)
        }
        else { $p[$s] = @() }
    }
    return [ordered]@{
        generation         = [int]$script:Sync['Generation']
        name               = $MgrName
        count              = $count
        severities         = $sevMap
        patternsBySeverity = $p
    }
}

function script:Write-JsonResponse {
    param($Context, $Object, [int]$StatusCode = 200, [string]$ETag = $null)
    $json = $Object | ConvertTo-Json -Depth 8 -Compress
    $buf = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    $Context.Response.Headers['Cache-Control'] = 'no-store'
    if ($ETag) { $Context.Response.Headers['ETag'] = $ETag }
    $Context.Response.ContentLength64 = $buf.Length
    $Context.Response.OutputStream.Write($buf, 0, $buf.Length)
    $Context.Response.OutputStream.Close()
}

function script:Write-StatusResponse {
    param($Context, [int]$Code, [string]$Message)
    Write-JsonResponse -Context $Context -StatusCode $Code -Object ([ordered]@{ ok = ($Code -lt 400); error = $Message })
}

function script:Get-ContentType {
    param([string]$Path)
    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.html' { return 'text/html; charset=utf-8' }
        '.css' { return 'text/css; charset=utf-8' }
        '.js' { return 'application/javascript; charset=utf-8' }
        '.json' { return 'application/json; charset=utf-8' }
        '.svg' { return 'image/svg+xml' }
        '.png' { return 'image/png' }
        default { return 'application/octet-stream' }
    }
}

function script:Write-FileResponse {
    param($Context, [string]$FilePath)
    if (-not (Test-Path -LiteralPath $FilePath)) {
        $Context.Response.StatusCode = 404
        $Context.Response.Close()
        return
    }
    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    $Context.Response.StatusCode = 200
    $Context.Response.ContentType = (Get-ContentType -Path $FilePath)
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

function script:Read-RequestBody {
    param($Request)
    $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    try { return $reader.ReadToEnd() }
    finally { $reader.Close() }
}

function script:Handle-Api {
    param($Context)
    $req = $Context.Request
    $path = $req.Url.AbsolutePath.TrimEnd('/')
    if ([string]::IsNullOrEmpty($path)) { $path = '/' }

    if ($path -eq '/api/health' -and $req.HttpMethod -eq 'GET') {
        try {
            $obj = [ordered]@{
                ok           = $true
                version      = "$($script:Version)"
                logPath      = "$($script:Sync['LogPath'])"
                prefillPath  = "$($script:Sync['PrefillPath'])"
                listeningUrl = "$($script:Sync['ListeningUrl'])"
                port         = [int]$script:Sync['BoundPort']
                tailRunning  = [bool]$script:Sync['TailRunning']
                paused       = [bool]$script:Sync['Paused']
                loading      = [bool]$script:Sync['Loading']
                fileLength   = [int64]$script:Sync['FileLength']
                lastError    = $(if ($script:Sync['LastError']) { "$($script:Sync['LastError'])" } else { $null })
                generation   = [int]$script:Sync['Generation']
            }
            Write-JsonResponse -Context $Context -Object $obj
        }
        catch {
            throw
        }
        return
    }

    if ($path -eq '/api/logPath' -and $req.HttpMethod -eq 'POST') {
        try {
            $raw = Read-RequestBody -Request $req
            $body = $raw | ConvertFrom-Json
            $p = [string]$body.path
            if ([string]::IsNullOrWhiteSpace($p)) { throw 'Path is required.' }
            if (-not (Test-Path -LiteralPath $p)) { throw "File not found: $p" }
            $item = Get-Item -LiteralPath $p
            if ($item.PSIsContainer) { throw 'Path must be a file, not a directory.' }
            Write-WatchLog ("Start accepted  -  validating path: {0}" -f $p) Cyan
            $test = [System.IO.File]::Open($p, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $test.Close()
            $script:Sync['LogPath'] = $p
            Save-WatchLogPath -Path $p
            $script:Sync['PrefillPath'] = $p
            if ($body.PSObject.Properties.Name -contains 'window' -and [string]$body.window -eq 'entire') {
                $script:Sync['WindowEntire'] = $true
            }
            elseif ($body.PSObject.Properties.Name -contains 'lastMinutes' -and $body.lastMinutes) {
                $script:Sync['WindowEntire'] = $false
                $script:Sync['LastMinutes'] = [int]$body.lastMinutes
            }
            Invoke-CatchUp -Path $p
            Write-JsonResponse -Context $Context -Object ([ordered]@{ ok = $true; logPath = $p; generation = [int]$script:Sync['Generation'] })
        }
        catch {
            Write-WatchLog ("Start failed: {0}" -f $_.Exception.Message) Red
            Write-StatusResponse -Context $Context -Code 400 -Message $_.Exception.Message
        }
        return
    }

    if ($path -eq '/api/control' -and $req.HttpMethod -eq 'POST') {
        try {
            $body = Read-RequestBody -Request $req | ConvertFrom-Json
            $action = [string]$body.action
            if ($action -ne 'note') {
                Write-WatchLog ("Control action={0}" -f $action) DarkCyan
            }
            switch ($action) {
                'pause' { $script:Sync['Paused'] = $true; Bump-Generation }
                'resume' { $script:Sync['Paused'] = $false; Bump-Generation }
                'restart' {
                    $script:Sync['CatchUpActive'] = $false
                    $script:Sync['TailRunning'] = $false
                    $script:Sync['Paused'] = $false
                    $script:Sync['Loading'] = $false
                    $script:Sync['LoadMessage'] = ''
                    $script:Sync['LoadProgressPct'] = 0
                    $script:Sync['LastError'] = $null
                    Close-LogStream
                    Reset-Analysis
                    $script:Sync['LogPath'] = ''
                    Write-WatchLog 'Session restarted (idle)' Yellow
                }
                'setWindow' {
                    if ($body.window -eq 'entire') { $script:Sync['WindowEntire'] = $true }
                    else {
                        $script:Sync['WindowEntire'] = $false
                        if ($body.lastMinutes) { $script:Sync['LastMinutes'] = [math]::Max(1, [int]$body.lastMinutes) }
                    }
                    $wlabel = if ($script:Sync['WindowEntire']) { 'entire' } else { ("{0}m" -f $script:Sync['LastMinutes']) }
                    Write-WatchLog ("Window change → {0}" -f $wlabel) Cyan
                    if ($script:Sync['LogPath']) { Invoke-CatchUp -Path $script:Sync['LogPath'] }
                }
                'note' {
                    $msg = [string]$body.message
                    if (-not [string]::IsNullOrWhiteSpace($msg)) {
                        Write-WatchLog $msg DarkCyan
                    }
                }
                default { throw "Unknown action: $action" }
            }
            Write-JsonResponse -Context $Context -Object ([ordered]@{ ok = $true; generation = [int]$script:Sync['Generation'] })
        }
        catch {
            Write-WatchLog ("Control failed: {0}" -f $_.Exception.Message) Red
            Write-StatusResponse -Context $Context -Code 400 -Message $_.Exception.Message
        }
        return
    }

    if ($path -eq '/api/pulse' -and $req.HttpMethod -eq 'GET') {
        $sev = Parse-QuerySevs -Q $req.QueryString
        $since = $req.QueryString['sinceGeneration']
        if ($since -and ("$since" -eq "$($script:Sync['Generation'])") -and -not $script:Sync['Loading']) {
            $Context.Response.StatusCode = 304
            $Context.Response.Headers['ETag'] = ('"{0}"' -f $script:Sync['Generation'])
            $Context.Response.Close()
            return
        }
        $obj = Build-PulseObject -SevFilter $sev
        Write-JsonResponse -Context $Context -Object $obj -ETag ('"{0}"' -f $script:Sync['Generation'])
        return
    }

    if ($path -eq '/api/section' -and $req.HttpMethod -eq 'GET') {
        $name = $req.QueryString['name']
        if (-not $name) { Write-StatusResponse -Context $Context -Code 400 -Message 'name required'; return }
        $sev = Parse-QuerySevs -Q $req.QueryString
        $obj = Build-SectionObject -Name $name -SevFilter $sev
        Write-JsonResponse -Context $Context -Object $obj -ETag ('"{0}"' -f $script:Sync['Generation'])
        return
    }

    if ($path -eq '/api/manager' -and $req.HttpMethod -eq 'GET') {
        $name = $req.QueryString['name']
        if (-not $name) { Write-StatusResponse -Context $Context -Code 400 -Message 'name required'; return }
        $sev = Parse-QuerySevs -Q $req.QueryString
        $obj = Build-ManagerObject -MgrName $name -SevFilter $sev
        Write-JsonResponse -Context $Context -Object $obj
        return
    }

    Write-StatusResponse -Context $Context -Code 404 -Message 'Not found'
}

function script:Handle-Request {
    param($Context)
    try {
        $req = $Context.Request
        $path = [System.Uri]::UnescapeDataString($req.Url.AbsolutePath)
        if ($path.StartsWith('/api/')) {
            # Skip noisy pulse/health spam  -  log meaningful control calls in Handle-Api
            if ($path -ne '/api/pulse' -and $path -ne '/api/health') {
                Write-WatchLog ("{0} {1}" -f $req.HttpMethod, $path) DarkCyan
            }
            Handle-Api -Context $Context
            return
        }
        if ($path -eq '/' -or $path -eq '') { $path = '/index.html' }
        $rel = $path.TrimStart('/').Replace('/', [IO.Path]::DirectorySeparatorChar)
        if ($rel.Contains('..')) {
            Write-StatusResponse -Context $Context -Code 400 -Message 'Invalid path'
            return
        }
        $full = Join-Path $script:UiRoot $rel
        $uiFull = [System.IO.Path]::GetFullPath($script:UiRoot)
        $fileFull = [System.IO.Path]::GetFullPath($full)
        if (-not $fileFull.StartsWith($uiFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-StatusResponse -Context $Context -Code 400 -Message 'Invalid path'
            return
        }
        Write-FileResponse -Context $Context -FilePath $fileFull
    }
    catch {
        Write-WatchLog ("Request error: {0}" -f $_.Exception.Message) Yellow
        try { Write-StatusResponse -Context $Context -Code 500 -Message $_.Exception.Message } catch {}
    }
}

function script:Start-Listener {
    param([int]$PreferredPort)
    $listener = New-Object System.Net.HttpListener
    $bound = $null
    for ($p = $PreferredPort; $p -lt ($PreferredPort + 40); $p++) {
        $listener = New-Object System.Net.HttpListener
        $prefix = "http://127.0.0.1:$p/"
        $listener.Prefixes.Add($prefix)
        try {
            $listener.Start()
            $bound = $p
            $script:Sync['BoundPort'] = $p
            $script:Sync['ListeningUrl'] = $prefix
            return $listener
        }
        catch {
            try { $listener.Close() } catch {}
        }
    }
    throw "Could not bind a port starting at $PreferredPort"
}

# --- main ---
if (-not (Test-Path -LiteralPath $script:UiRoot)) {
    throw "UI folder missing: $script:UiRoot"
}

$listener = Start-Listener -PreferredPort $Port
$url = $script:Sync['ListeningUrl']
Write-Host ("PVSS Log Watch {0}" -f $script:Version) -ForegroundColor Cyan
Write-Host ("Listening: {0}" -f $url) -ForegroundColor Green
Write-Host 'Log access: FileAccess.Read only (share allows WinCC to append).' -ForegroundColor DarkGray
Write-Host 'Ctrl+C to stop.' -ForegroundColor DarkGray

if (-not $NoBrowser) {
    $opened = $false
    foreach ($browser in @(
            "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
            "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
            "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
            "${env:ProgramFiles}\Microsoft\Edge\Application\msedge.exe"
        )) {
        if (Test-Path -LiteralPath $browser) {
            Start-Process -FilePath $browser -ArgumentList $url | Out-Null
            $opened = $true
            break
        }
    }
    if (-not $opened) { Start-Process $url | Out-Null }
}

# Interleave HTTP with short catch-up time-slices (~200ms) so /api/pulse can report %
# about every UI poll without sleeping between work (WaitOne(0) while loading).
try {
    $iar = $listener.BeginGetContext($null, $null)
    while ($listener.IsListening) {
        $catchingUp = [bool]$script:Sync['CatchUpActive']
        if ($catchingUp) {
            try { Step-CatchUp -MaxLines 100000 -MaxMilliseconds 200 } catch { }
        }
        $waitMs = if ($catchingUp) { 0 } else { 50 }
        if ($iar.AsyncWaitHandle.WaitOne($waitMs)) {
            try {
                $ctx = $listener.EndGetContext($iar)
                Handle-Request -Context $ctx
            }
            catch [System.Net.HttpListenerException] { break }
            catch {
                Write-Host ("Request error: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
            }
            if (-not $listener.IsListening) { break }
            $iar = $listener.BeginGetContext($null, $null)
        }
        if (-not $script:Sync['CatchUpActive']) {
            try { Read-TailBytes } catch { }
        }
    }
}
finally {
    Close-LogStream
    try { $listener.Stop(); $listener.Close() } catch {}
}

if (-not $NoPause) {
    Write-Host 'Stopped. Press Enter to close.'
    [void][Console]::ReadLine()
}



