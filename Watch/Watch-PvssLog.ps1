#Requires -Version 5.1
<#
.SYNOPSIS
  PVSS Log Watch V2  -  localhost host + live dashboard APIs (PRD-V2).
.DESCRIPTION
  Serves ui\ and /api/pulse|/api/section|/api/manager|/api/health.
  Opens the live log read-only (FileAccess.Read + FileShare.ReadWrite).
.NOTES
  Author: Cisum
  Preferences: Watch\watch-config.txt (CLI overrides file).
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
$script:ConfigPath = Join-Path $script:Root 'watch-config.txt'
$script:Version = (Get-Content (Join-Path $script:Root 'VERSION.txt') -ErrorAction SilentlyContinue | Select-Object -First 1)
if (-not $script:Version) { $script:Version = '2.2' }
$script:Author = 'Cisum'
foreach ($verLine in @(Get-Content (Join-Path $script:Root 'VERSION.txt') -ErrorAction SilentlyContinue)) {
    if ($verLine -match '^\s*Author\s*:\s*(.+)\s*$') { $script:Author = $Matches[1].Trim(); break }
}

function script:ConvertTo-ConfigBool {
    param([string]$Text, [bool]$Default = $false)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @{ Ok = $false; Value = $Default } }
    switch -Regex ($Text.Trim()) {
        '^(1|true|yes|on)$' { return @{ Ok = $true; Value = $true } }
        '^(0|false|no|off)$' { return @{ Ok = $true; Value = $false } }
        default { return @{ Ok = $false; Value = $Default } }
    }
}

function script:Get-WatchConfigDefaults {
    return [ordered]@{
        PreferredPort         = 8787
        MaxPortTries          = 40
        RefreshSeconds        = 3
        OpenBrowser           = $true
        Browser               = 'default'
        DefaultWindowMinutes  = 60
        DefaultWindowEntire   = $false
        DefaultSeverities     = @('FATAL', 'SEVERE', 'ERROR', 'WARNING')
        TopN                  = 10
        SamplePerPattern      = 1
        BacFlapMin            = 3
        LogPath               = ''
    }
}

function script:Format-WatchConfigValue {
    param([string]$Key, $Value)
    switch ($Key) {
        'OpenBrowser' { if ($Value) { return 'true' } else { return 'false' } }
        'DefaultWindowEntire' { if ($Value) { return 'true' } else { return 'false' } }
        'DefaultSeverities' { return ((@($Value) | ForEach-Object { "$_" }) -join ',') }
        default { return "$Value" }
    }
}

function script:Set-WatchConfigKeys {
    param([hashtable]$Updates)
    if (-not $Updates -or $Updates.Count -eq 0) { return }
    $lines = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $script:ConfigPath) {
        foreach ($ln in Get-Content -LiteralPath $script:ConfigPath -Encoding UTF8) { [void]$lines.Add($ln) }
    }
    else {
        [void]$lines.Add('# Watch preferences (auto-created)')
        [void]$lines.Add('')
    }
    foreach ($key in @($Updates.Keys)) {
        $newLine = ('{0}={1}' -f $key, (Format-WatchConfigValue -Key $key -Value $Updates[$key]))
        $found = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match ('^\s*' + [regex]::Escape($key) + '\s*=')) {
                $lines[$i] = $newLine
                $found = $true
                break
            }
        }
        if (-not $found) {
            [void]$lines.Add('')
            [void]$lines.Add($newLine)
        }
    }
    $lines | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
}

function script:Test-WatchConfigBrowser {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $t = $Text.Trim()
    $low = $t.ToLowerInvariant()
    if ($low -eq 'default' -or $low -eq 'chrome' -or $low -eq 'msedge' -or $low -eq 'edge') { return $true }
    if (Test-Path -LiteralPath $t) { return $true }
    return $false
}

function script:Read-WatchConfig {
    $defaults = Get-WatchConfigDefaults
    $cfg = Get-WatchConfigDefaults
    $warnings = New-Object System.Collections.Generic.List[string]
    $corrections = @{}
    $known = @(
        'PreferredPort', 'MaxPortTries', 'RefreshSeconds', 'OpenBrowser', 'Browser',
        'DefaultWindowMinutes', 'DefaultWindowEntire', 'DefaultSeverities',
        'TopN', 'SamplePerPattern', 'BacFlapMin', 'LogPath'
    )

    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        return [ordered]@{ Config = $cfg; Warnings = @($warnings); Corrections = $corrections }
    }

    $lines = @(Get-Content -LiteralPath $script:ConfigPath -Encoding UTF8 -ErrorAction SilentlyContinue)
    if ($null -eq $lines) {
        [void]$warnings.Add(('Could not read config file; using built-in defaults: {0}' -f $script:ConfigPath))
        return [ordered]@{ Config = $cfg; Warnings = @($warnings); Corrections = $corrections }
    }

    foreach ($raw in $lines) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) {
            [void]$warnings.Add(('Ignored malformed line (expected Key=Value): {0}' -f $line))
            continue
        }
        $key = $line.Substring(0, $eq).Trim()
        $val = $line.Substring($eq + 1).Trim()
        if ($known -notcontains $key) {
            [void]$warnings.Add(('Unknown config key ignored: {0}' -f $key))
            continue
        }

        switch ($key) {
            'PreferredPort' {
                $n = 0
                if ([int]::TryParse($val, [ref]$n) -and $n -ge 1 -and $n -le 65535) { $cfg.PreferredPort = $n }
                else {
                    [void]$warnings.Add(("PreferredPort='{0}' invalid (need integer 1-65535); reset to {1}" -f $val, $defaults.PreferredPort))
                    $cfg.PreferredPort = $defaults.PreferredPort
                    $corrections[$key] = $defaults.PreferredPort
                }
            }
            'MaxPortTries' {
                $n = 0
                if ([int]::TryParse($val, [ref]$n) -and $n -ge 1 -and $n -le 200) { $cfg.MaxPortTries = $n }
                else {
                    [void]$warnings.Add(("MaxPortTries='{0}' invalid (need integer 1-200); reset to {1}" -f $val, $defaults.MaxPortTries))
                    $cfg.MaxPortTries = $defaults.MaxPortTries
                    $corrections[$key] = $defaults.MaxPortTries
                }
            }
            'RefreshSeconds' {
                $n = 0
                if ([int]::TryParse($val, [ref]$n) -and $n -ge 1 -and $n -le 60) { $cfg.RefreshSeconds = $n }
                else {
                    [void]$warnings.Add(("RefreshSeconds='{0}' invalid (need integer 1-60); reset to {1}" -f $val, $defaults.RefreshSeconds))
                    $cfg.RefreshSeconds = $defaults.RefreshSeconds
                    $corrections[$key] = $defaults.RefreshSeconds
                }
            }
            'OpenBrowser' {
                $b = ConvertTo-ConfigBool -Text $val -Default $defaults.OpenBrowser
                if ($b.Ok) { $cfg.OpenBrowser = [bool]$b.Value }
                else {
                    [void]$warnings.Add(("OpenBrowser='{0}' invalid (need true|false); reset to {1}" -f $val, (Format-WatchConfigValue -Key OpenBrowser -Value $defaults.OpenBrowser)))
                    $cfg.OpenBrowser = [bool]$defaults.OpenBrowser
                    $corrections[$key] = $defaults.OpenBrowser
                }
            }
            'Browser' {
                if (Test-WatchConfigBrowser -Text $val) { $cfg.Browser = $val.Trim() }
                else {
                    [void]$warnings.Add(("Browser='{0}' invalid (default|chrome|msedge|existing .exe path); reset to {1}" -f $val, $defaults.Browser))
                    $cfg.Browser = [string]$defaults.Browser
                    $corrections[$key] = $defaults.Browser
                }
            }
            'DefaultWindowMinutes' {
                $n = 0
                if ([int]::TryParse($val, [ref]$n) -and $n -ge 1 -and $n -le 10080) { $cfg.DefaultWindowMinutes = $n }
                else {
                    [void]$warnings.Add(("DefaultWindowMinutes='{0}' invalid (need integer 1-10080); reset to {1}" -f $val, $defaults.DefaultWindowMinutes))
                    $cfg.DefaultWindowMinutes = $defaults.DefaultWindowMinutes
                    $corrections[$key] = $defaults.DefaultWindowMinutes
                }
            }
            'DefaultWindowEntire' {
                $b = ConvertTo-ConfigBool -Text $val -Default $defaults.DefaultWindowEntire
                if ($b.Ok) { $cfg.DefaultWindowEntire = [bool]$b.Value }
                else {
                    [void]$warnings.Add(("DefaultWindowEntire='{0}' invalid (need true|false); reset to {1}" -f $val, (Format-WatchConfigValue -Key DefaultWindowEntire -Value $defaults.DefaultWindowEntire)))
                    $cfg.DefaultWindowEntire = [bool]$defaults.DefaultWindowEntire
                    $corrections[$key] = $defaults.DefaultWindowEntire
                }
            }
            'DefaultSeverities' {
                $rawParts = @($val -split ',' | ForEach-Object { $_.Trim().ToUpperInvariant() } | Where-Object { $_ })
                $good = New-Object System.Collections.Generic.List[string]
                $bad = New-Object System.Collections.Generic.List[string]
                foreach ($p in $rawParts) {
                    if ($p -match '^(FATAL|SEVERE|ERROR|WARNING|INFO)$') {
                        if (-not $good.Contains($p)) { [void]$good.Add($p) }
                    }
                    else { [void]$bad.Add($p) }
                }
                if ($good.Count -gt 0) {
                    $cfg.DefaultSeverities = @($good)
                    if ($bad.Count -gt 0) {
                        [void]$warnings.Add(("DefaultSeverities dropped unknown token(s): {0}; kept {1}" -f ($bad -join ','), ($good -join ',')))
                        $corrections[$key] = @($good)
                    }
                }
                else {
                    [void]$warnings.Add(("DefaultSeverities='{0}' invalid; reset to {1}" -f $val, (($defaults.DefaultSeverities) -join ',')))
                    $cfg.DefaultSeverities = @($defaults.DefaultSeverities)
                    $corrections[$key] = @($defaults.DefaultSeverities)
                }
            }
            'TopN' {
                $n = 0
                if ([int]::TryParse($val, [ref]$n) -and $n -ge 5 -and $n -le 100) { $cfg.TopN = $n }
                else {
                    [void]$warnings.Add(("TopN='{0}' invalid (need integer 5-100); reset to {1}" -f $val, $defaults.TopN))
                    $cfg.TopN = $defaults.TopN
                    $corrections[$key] = $defaults.TopN
                }
            }
            'SamplePerPattern' {
                $n = 0
                if ([int]::TryParse($val, [ref]$n) -and $n -ge 1 -and $n -le 20) { $cfg.SamplePerPattern = $n }
                else {
                    [void]$warnings.Add(("SamplePerPattern='{0}' invalid (need integer 1-20); reset to {1}" -f $val, $defaults.SamplePerPattern))
                    $cfg.SamplePerPattern = $defaults.SamplePerPattern
                    $corrections[$key] = $defaults.SamplePerPattern
                }
            }
            'BacFlapMin' {
                $n = 0
                if ([int]::TryParse($val, [ref]$n) -and $n -ge 1 -and $n -le 50) { $cfg.BacFlapMin = $n }
                else {
                    [void]$warnings.Add(("BacFlapMin='{0}' invalid (need integer 1-50); reset to {1}" -f $val, $defaults.BacFlapMin))
                    $cfg.BacFlapMin = $defaults.BacFlapMin
                    $corrections[$key] = $defaults.BacFlapMin
                }
            }
            'LogPath' {
                # Prefill only; missing file is OK (operator may Start later). Empty allowed.
                $cfg.LogPath = $val
            }
        }
    }

    return [ordered]@{ Config = $cfg; Warnings = @($warnings); Corrections = $corrections }
}

function script:Set-WatchConfigLogPath {
    param([string]$Path)
    Set-WatchConfigKeys -Updates @{ LogPath = $Path }
}

# Load watch-config.txt then apply CLI overrides (bound params win).
$script:ConfigLoad = Read-WatchConfig
$script:Config = $script:ConfigLoad.Config
if ($script:ConfigLoad.Corrections -and $script:ConfigLoad.Corrections.Count -gt 0) {
    try { Set-WatchConfigKeys -Updates $script:ConfigLoad.Corrections } catch { }
}
if (-not $PSBoundParameters.ContainsKey('Port')) { $Port = [int]$script:Config.PreferredPort }
if (-not $PSBoundParameters.ContainsKey('LastMinutes')) { $LastMinutes = [int]$script:Config.DefaultWindowMinutes }
if (-not $PSBoundParameters.ContainsKey('RefreshSeconds')) { $RefreshSeconds = [int]$script:Config.RefreshSeconds }
if (-not $PSBoundParameters.ContainsKey('TopN')) { $TopN = [int]$script:Config.TopN }
if (-not $PSBoundParameters.ContainsKey('SamplePerPattern')) { $SamplePerPattern = [int]$script:Config.SamplePerPattern }
$script:OpenBrowser = [bool]$script:Config.OpenBrowser
if ($PSBoundParameters.ContainsKey('NoBrowser')) { $script:OpenBrowser = -not [bool]$NoBrowser }
$script:BrowserChoice = [string]$script:Config.Browser
$script:MaxPortTries = [int]$script:Config.MaxPortTries
$script:BacFlapMin = [int]$script:Config.BacFlapMin
$script:DefaultSeverities = @($script:Config.DefaultSeverities)
$script:DefaultWindowEntire = [bool]$script:Config.DefaultWindowEntire
$script:RefreshSeconds = [int]$RefreshSeconds
if ($script:RefreshSeconds -lt 1) { $script:RefreshSeconds = 1 }
if ($script:RefreshSeconds -gt 60) { $script:RefreshSeconds = 60 }

$script:PrefillPath = ''
if ($PSBoundParameters.ContainsKey('LogPath') -and -not [string]::IsNullOrWhiteSpace($LogPath)) {
    $script:PrefillPath = $LogPath.Trim()
}
elseif (-not [string]::IsNullOrWhiteSpace([string]$script:Config.LogPath)) {
    $script:PrefillPath = ([string]$script:Config.LogPath).Trim()
}

$script:ConfigWarnings = @($script:ConfigLoad.Warnings)

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
        BacCollectTrend   = 0
        BacTimeSync       = 0
        BacCollectTrendByCode = @{}
        BacCollectTrendByProp = @{}
        BacCollectTrendSample = $null
        BacTimeSyncByCode = @{}
        BacTimeSyncByProp = @{}
        BacTimeSyncSample = $null
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
        ApogeeDrvLines    = 0
        ApogeeTrendOverflow = 0
        ApogeeTrendSeq    = 0
        ApogeeAlertId     = 0
        ApogeeQueryTimeout = 0
        ApogeeGetDataFail = 0
        ApogeeTrendByDevice = @{}
        ApogeeTrendByName = @{}
        ApogeeGetDataByDevice = @{}
        ApogeeAlertSample = $null
        ApogeeTrendSample = $null
        ApogeeTimeoutSample = $null
        ApogeeGetDataSample = $null
        ProjectStartMode  = 0
        ProjectUp         = 0
        ProjectShutdown   = 0
        ProjectStopped    = 0
        PmonMgrRestart    = 0
        MgrStartProj      = 0
        MgrStop           = 0
        DriverReady       = 0
        MgrStartByComp    = @{}
        MgrStopByComp     = @{}
        PmonRestartByComp = @{}
        BlockingByComp    = @{}
        UnblockingByComp  = @{}
        BlockingDetected  = 0
        BlockingCleared   = 0
        BlockingSample    = $null
        UnblockingSample  = $null
        ProjectRestartEvents = New-Object System.Collections.ArrayList
    }
}

$script:LineRe = [regex]'^([^,]+),\s*(\d{4}\.\d{2}\.\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+),\s*([^,]+),\s*([^,\s]+)'
$script:ReBacFailed = [regex]'Device\s+(\d+)\s+Status is now Failed'
$script:ReBacOk = [regex]'Device\s+(\d+)\s+Status is now OK'
$script:ReBacObjList = [regex]'(?i)Could not get object list(?:\s+count)?(?:\s+for)?\s+device\s+(\d+)'
$script:ReBacCollectTrend = [regex]'Command\s+"BACnetCollectTrend"'
$script:ReBacTimeSyncCmd = [regex]'Command\s+"BACnetTimeSync"'
$script:ReBacCmdDetail = [regex]'Error Code (\d+) for Property "([^"]+)" and Command "(BACnetCollectTrend|BACnetTimeSync)"'
$script:ReCohoDiscoveryLoc = [regex]'(?i)DiscoveryLoc:([^\s]+)\s+got stuck\b'
$script:ReCohoDiscoveryCycle = [regex]'(?i)((?:Global|Observer)\s+Discovery Cycle\s+\[[^\]]+\])\s+got stuck\b'
$script:ReApogeePpcl = [regex]'(?i)PPCL Program Name:\s*(\S+?)(?:System\.|$)'
$script:ReApogeeComp = [regex]'(?i)(?:CoHo|Orch)\.Apogee'
$script:ReApogeeTrendOverflow = [regex]'(?i)Trend buffer overflow for trend\s+(.+?)\s+in device\s+(.+?)\.?\s*$'
$script:ReApogeeTrendSeq = [regex]'(?i)Last sequence number\s+\d+\s+is greater than saved'
$script:ReApogeeAlertId = [regex]'AlertID\s+\S+'
$script:ReApogeeQueryTimeout = [regex]'(?i)pending answer run into timeout'
$script:ReApogeeGetData = [regex]'(?i)Failed to get data for object\s+(.+?)\s+on device\s+([^,]+)'
$script:ReProjectUp = [regex]'The project is up and running'
$script:ReProjectStopped = [regex]'Completely stopped the project'
$script:ReProjectShutdown = [regex]'Got shutdown command'
$script:ReProjectStartMode = [regex]'Manager Start,\s*START_MODE'
$script:RePmonMgrRestart = [regex]'Detected stopped manager\s+(\S+)\s+-\s+restarting'
$script:ReMgrStartProj = [regex]'Manager Start,\s*PROJ,'
$script:ReMgrStopMsg = [regex]'Manager Stop\s*$'
$script:ReDriverReady = [regex]'(?i)Driver is configured with .+\s+and is now running'
$script:ReBlockingStart = [regex]'Blocking Manager\s+(\S+)\s+detected(?:\.\s*No heartbeat since\s+(\d+)\s+seconds?)?'
$script:ReBlockingEnd = [regex]'Manager\s+(\S+)\s+is no longer blocking'

$script:Sync = [hashtable]::Synchronized(@{
        Generation     = 0
        Loading        = $false
        LoadProgressPct = 0
        LoadMessage    = ''
        LoadModeLabel  = ''
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
        WindowEntire   = [bool]$script:DefaultWindowEntire
        LastMinutes    = $LastMinutes
        Cutoff         = $null
        PrefillPath    = "$($script:PrefillPath)"
        ListeningUrl   = ''
        BoundPort      = 0
        Data           = (New-EmptyState)
        EntireCache    = @{
            Valid   = $false
            LogPath = ''
            FilePos = 0L
            Data    = $null
        }
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

function script:Clone-ObjectGraph {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [hashtable]) {
        $copy = @{}
        foreach ($k in @($Value.Keys)) {
            $copy[$k] = Clone-ObjectGraph $Value[$k]
        }
        return $copy
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = @{}
        foreach ($k in @($Value.Keys)) {
            $copy[$k] = Clone-ObjectGraph $Value[$k]
        }
        return $copy
    }
    if ($Value -is [System.Array]) {
        $n = $Value.Length
        $arr = New-Object object[] $n
        for ($i = 0; $i -lt $n; $i++) {
            $arr[$i] = Clone-ObjectGraph $Value[$i]
        }
        return $arr
    }
    if ($Value -is [System.Collections.IList] -and -not ($Value -is [string])) {
        $copy = New-Object System.Collections.ArrayList
        foreach ($item in @($Value)) {
            [void]$copy.Add((Clone-ObjectGraph $item))
        }
        return $copy
    }
    return $Value
}

function script:Clone-AnalysisState {
    param([hashtable]$Data)
    return [hashtable](Clone-ObjectGraph $Data)
}

function script:Clear-EntireCache {
    param([string]$Reason = '')
    $c = $script:Sync['EntireCache']
    if ($c -and [bool]$c.Valid) {
        Write-WatchLog ("Entire cache INVALIDATE reason={0}" -f $Reason) Yellow
    }
    $script:Sync['EntireCache'] = @{
        Valid   = $false
        LogPath = ''
        FilePos = 0L
        Data    = $null
    }
}

function script:Save-EntireCache {
    if (-not [bool]$script:Sync['WindowEntire']) { return }
    if ([bool]$script:Sync['CatchUpActive'] -or [bool]$script:Sync['Loading']) { return }
    if (-not [bool]$script:Sync['TailRunning']) { return }
    $path = [string]$script:Sync['LogPath']
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    if ($null -eq $script:Sync['Data']) { return }

    $script:Sync['EntireCache'] = @{
        Valid   = $true
        LogPath = $path
        FilePos = [int64]$script:Sync['FilePos']
        Data    = (Clone-AnalysisState -Data $script:Sync['Data'])
    }
    Write-WatchLog ("Entire cache SAVE  pos={0:N0}  parsed={1:N0}" -f `
        $script:Sync['FilePos'], $script:Sync['Data'].ParsedLines) DarkCyan
}

function script:Ensure-Minute {
    param([hashtable]$Data, [string]$Key)
    if (-not $Data.ByMinute.ContainsKey($Key)) {
        $Data.ByMinute[$Key] = @{
            FATAL = 0; SEVERE = 0; ERROR = 0; WARNING = 0; INFO = 0
            bacFailed = 0; bacOk = 0; projectRestart = 0
        }
    }
    return $Data.ByMinute[$Key]
}

function script:Normalize-ManagerKey {
    param([string]$Comp)
    if ([string]::IsNullOrWhiteSpace($Comp)) { return '' }
    # Keep instance number: CoHo(7) vs CoHo(100) are different managers.
    return ([regex]::Replace($Comp.Trim(), '\s+', ''))
}

function script:Add-CountMap {
    param([hashtable]$Map, [string]$Key)
    if ([string]::IsNullOrWhiteSpace($Key)) { return }
    if (-not $Map.ContainsKey($Key)) { $Map[$Key] = 0 }
    $Map[$Key]++
}

function script:Build-LifecycleRows {
    param(
        [hashtable]$Data,
        [string]$MatchPattern = '.'
    )
    $keys = New-Object System.Collections.Generic.HashSet[string]
    foreach ($map in @($Data.MgrStartByComp, $Data.MgrStopByComp, $Data.PmonRestartByComp, $Data.BlockingByComp, $Data.UnblockingByComp)) {
        if (-not $map) { continue }
        foreach ($k in @($map.Keys)) {
            if ($k -match $MatchPattern) { [void]$keys.Add($k) }
        }
    }
    $rows = @(
        $keys | ForEach-Object {
            $name = $_
            [ordered]@{
                name       = $name
                starts     = if ($Data.MgrStartByComp.ContainsKey($name)) { [int]$Data.MgrStartByComp[$name] } else { 0 }
                stops      = if ($Data.MgrStopByComp.ContainsKey($name)) { [int]$Data.MgrStopByComp[$name] } else { 0 }
                restarts   = if ($Data.PmonRestartByComp.ContainsKey($name)) { [int]$Data.PmonRestartByComp[$name] } else { 0 }
                blocking   = if ($Data.BlockingByComp.ContainsKey($name)) { [int]$Data.BlockingByComp[$name] } else { 0 }
                unblocked  = if ($Data.UnblockingByComp.ContainsKey($name)) { [int]$Data.UnblockingByComp[$name] } else { 0 }
            }
        } | Sort-Object { -([int]$_.blocking + [int]$_.restarts + [int]$_.starts + [int]$_.stops) }, name
    )
    $tot = [ordered]@{
        starts = 0; stops = 0; restarts = 0; blocking = 0; unblocked = 0
    }
    foreach ($r in $rows) {
        $tot.starts += [int]$r.starts
        $tot.stops += [int]$r.stops
        $tot.restarts += [int]$r.restarts
        $tot.blocking += [int]$r.blocking
        $tot.unblocked += [int]$r.unblocked
    }
    return [ordered]@{ totals = $tot; managers = @($rows) }
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
    $bucket = Ensure-Minute -Data $Data -Key $mk
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

    # BACnet orchestration commands often log under CoHo, not WCCOAGmsBACnet
    $mBacCmd = $script:ReBacCmdDetail.Match($Line)
    if ($mBacCmd.Success) {
        $code = $mBacCmd.Groups[1].Value
        $prop = $mBacCmd.Groups[2].Value
        $cmd = $mBacCmd.Groups[3].Value
        if ($cmd -eq 'BACnetCollectTrend') {
            $Data.BacCollectTrend++
            if (-not $Data.BacCollectTrendByCode.ContainsKey($code)) { $Data.BacCollectTrendByCode[$code] = 0 }
            $Data.BacCollectTrendByCode[$code]++
            if (-not $Data.BacCollectTrendByProp.ContainsKey($prop)) { $Data.BacCollectTrendByProp[$prop] = 0 }
            $Data.BacCollectTrendByProp[$prop]++
            if (-not $Data.BacCollectTrendSample) { $Data.BacCollectTrendSample = $Line }
        }
        elseif ($cmd -eq 'BACnetTimeSync') {
            $Data.BacTimeSync++
            if (-not $Data.BacTimeSyncByCode.ContainsKey($code)) { $Data.BacTimeSyncByCode[$code] = 0 }
            $Data.BacTimeSyncByCode[$code]++
            if (-not $Data.BacTimeSyncByProp.ContainsKey($prop)) { $Data.BacTimeSyncByProp[$prop] = 0 }
            $Data.BacTimeSyncByProp[$prop]++
            if (-not $Data.BacTimeSyncSample) { $Data.BacTimeSyncSample = $Line }
        }
    }
    elseif ($script:ReBacCollectTrend.IsMatch($Line)) {
        $Data.BacCollectTrend++
        if (-not $Data.BacCollectTrendSample) { $Data.BacCollectTrendSample = $Line }
    }
    elseif ($script:ReBacTimeSyncCmd.IsMatch($Line)) {
        $Data.BacTimeSync++
        if (-not $Data.BacTimeSyncSample) { $Data.BacTimeSyncSample = $Line }
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

    # WCCOAApogeeDrv (not ApogeeBACnet / CoHo.Apogee*)
    if ($comp.IndexOf('ApogeeDrv', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        $Data.ApogeeDrvLines++
        $mOv = $script:ReApogeeTrendOverflow.Match($Line)
        if ($mOv.Success) {
            $Data.ApogeeTrendOverflow++
            $tName = $mOv.Groups[1].Value.Trim()
            $tDev = $mOv.Groups[2].Value.Trim().TrimEnd('.')
            if ($tName) {
                if (-not $Data.ApogeeTrendByName.ContainsKey($tName)) { $Data.ApogeeTrendByName[$tName] = 0 }
                $Data.ApogeeTrendByName[$tName]++
            }
            if ($tDev) {
                if (-not $Data.ApogeeTrendByDevice.ContainsKey($tDev)) { $Data.ApogeeTrendByDevice[$tDev] = 0 }
                $Data.ApogeeTrendByDevice[$tDev]++
            }
            if (-not $Data.ApogeeTrendSample) { $Data.ApogeeTrendSample = $Line }
        }
        elseif ($script:ReApogeeTrendSeq.IsMatch($Line)) {
            $Data.ApogeeTrendSeq++
            if (-not $Data.ApogeeTrendSample) { $Data.ApogeeTrendSample = $Line }
        }
        if ($script:ReApogeeAlertId.IsMatch($Line)) {
            $Data.ApogeeAlertId++
            if (-not $Data.ApogeeAlertSample) { $Data.ApogeeAlertSample = $Line }
        }
        if ($script:ReApogeeQueryTimeout.IsMatch($Line)) {
            $Data.ApogeeQueryTimeout++
            if (-not $Data.ApogeeTimeoutSample) { $Data.ApogeeTimeoutSample = $Line }
        }
        $mGd = $script:ReApogeeGetData.Match($Line)
        if ($mGd.Success) {
            $Data.ApogeeGetDataFail++
            $gdDev = $mGd.Groups[2].Value.Trim()
            if ($gdDev) {
                if (-not $Data.ApogeeGetDataByDevice.ContainsKey($gdDev)) { $Data.ApogeeGetDataByDevice[$gdDev] = 0 }
                $Data.ApogeeGetDataByDevice[$gdDev]++
            }
            if (-not $Data.ApogeeGetDataSample) { $Data.ApogeeGetDataSample = $Line }
        }
    }

    # Project / manager lifecycle (pmon + Manager Start/Stop)
    if ($script:ReProjectUp.IsMatch($Line)) {
        $Data.ProjectUp++
        $bucket.projectRestart = 1
        if ($Data.ProjectRestartEvents.Count -lt 200) {
            [void]$Data.ProjectRestartEvents.Add([ordered]@{ t = $mk; kind = 'up'; sample = $Line })
        }
    }
    if ($script:ReProjectStartMode.IsMatch($Line)) { $Data.ProjectStartMode++ }
    if ($script:ReProjectShutdown.IsMatch($Line)) { $Data.ProjectShutdown++ }
    if ($script:ReProjectStopped.IsMatch($Line)) { $Data.ProjectStopped++ }
    $mPmonRr = $script:RePmonMgrRestart.Match($Line)
    if ($mPmonRr.Success) {
        $Data.PmonMgrRestart++
        $rn = $mPmonRr.Groups[1].Value.Trim()
        if ($rn) {
            if (-not $Data.PmonRestartByComp.ContainsKey($rn)) { $Data.PmonRestartByComp[$rn] = 0 }
            $Data.PmonRestartByComp[$rn]++
        }
    }
    if ($script:ReMgrStartProj.IsMatch($Line)) {
        $Data.MgrStartProj++
        Add-CountMap -Map $Data.MgrStartByComp -Key (Normalize-ManagerKey -Comp $comp)
    }
    if ($script:ReMgrStopMsg.IsMatch($Line)) {
        $Data.MgrStop++
        Add-CountMap -Map $Data.MgrStopByComp -Key (Normalize-ManagerKey -Comp $comp)
    }
    if ($script:ReDriverReady.IsMatch($Line)) { $Data.DriverReady++ }
    $mBlock = $script:ReBlockingStart.Match($Line)
    if ($mBlock.Success) {
        $Data.BlockingDetected++
        Add-CountMap -Map $Data.BlockingByComp -Key $mBlock.Groups[1].Value.Trim()
        if (-not $Data.BlockingSample) { $Data.BlockingSample = $Line }
    }
    $mUnblock = $script:ReBlockingEnd.Match($Line)
    if ($mUnblock.Success) {
        $Data.BlockingCleared++
        Add-CountMap -Map $Data.UnblockingByComp -Key $mUnblock.Groups[1].Value.Trim()
        if (-not $Data.UnblockingSample) { $Data.UnblockingSample = $Line }
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
    $mode = [string]$script:Sync['LoadModeLabel']
    if ([string]::IsNullOrWhiteSpace($mode)) {
        $mode = if ($script:Sync['WindowEntire']) { 'Loading entire file' } else { ("Loading last {0} minutes" -f $script:Sync['LastMinutes']) }
    }
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
    $script:Sync['LoadModeLabel'] = if ($entire) { 'Loading entire file' } else { ("Loading last {0} minutes" -f $script:Sync['LastMinutes']) }
    $script:Sync['LoadMessage'] = ("{0}... 0%" -f $script:Sync['LoadModeLabel'])

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
        if ([bool]$script:Sync['WindowEntire']) { Save-EntireCache }
    }
    else {
        $script:Sync['Loading'] = $false
        $script:Sync['TailRunning'] = $false
        $script:Sync['LoadMessage'] = ''
        Clear-EntireCache -Reason 'catch-up fail'
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

function script:Begin-IncrementalEntireCatchUp {
    param(
        [string]$Path,
        [long]$StartPos,
        [hashtable]$Data
    )
    $script:Sync['CatchUpActive'] = $false
    $script:Sync['Loading'] = $true
    $script:Sync['LoadProgressPct'] = 0
    $script:Sync['LastError'] = $null
    $script:Sync['TailRunning'] = $false
    $script:Sync['WindowEntire'] = $true
    $script:Sync['Cutoff'] = $null
    Bump-Generation

    Write-WatchLog ("Entire cache HIT  restore pos={0:N0}  then incremental" -f $StartPos) Cyan
    $script:Sync['LoadModeLabel'] = 'Updating entire file'
    $script:Sync['LoadMessage'] = 'Updating entire file... 0%'
    $script:Sync['Data'] = $Data

    Open-LogStream -Path $Path -Position $StartPos

    $totalBytes = [math]::Max(1L, $script:Sync['Stream'].Length)
    $spanBytes = [math]::Max(1L, $totalBytes - $StartPos)
    $script:Sync['LoadStartPos'] = $StartPos
    $script:Sync['LoadSpanBytes'] = $spanBytes
    $script:Sync['LoadLines'] = 0
    $script:Sync['LoadSkipped'] = 0
    $script:Sync['LoadEnforce'] = $false
    $script:Sync['LoadCutoff'] = [datetime]::MinValue
    $script:Sync['LoadCutoffCompare'] = ''
    $script:Sync['LoadSw'] = [System.Diagnostics.Stopwatch]::StartNew()
    $script:Sync['LoadLastLogPct'] = -1
    $script:Sync['LoadLastLogMs'] = 0L
    $script:Sync['CatchUpActive'] = $true
    $script:Sync['FileLength'] = $totalBytes

    Write-WatchLog ("Incremental Entire from byte {0:N0} ({1:N1} MB remaining of {2:N1} MB)" -f `
        $StartPos, ($spanBytes / 1MB), ($totalBytes / 1MB))
    Update-LoadProgress -ForceLog
}

function script:Try-Begin-EntireFromCache {
    param([string]$Path)
    $c = $script:Sync['EntireCache']
    if (-not $c -or -not [bool]$c.Valid) {
        Write-WatchLog 'Entire cache MISS  (no snapshot)' DarkYellow
        return $false
    }
    if ([string]$c.LogPath -ne $Path) {
        Write-WatchLog 'Entire cache MISS  (path mismatch)' DarkYellow
        return $false
    }
    if ($null -eq $c.Data) {
        Clear-EntireCache -Reason 'empty snapshot'
        Write-WatchLog 'Entire cache MISS  (empty snapshot)' DarkYellow
        return $false
    }
    try {
        $len = [int64](Get-Item -LiteralPath $Path).Length
    }
    catch {
        Clear-EntireCache -Reason 'path missing'
        return $false
    }
    $pos = [int64]$c.FilePos
    if ($pos -gt $len) {
        Clear-EntireCache -Reason 'file shrank'
        Write-WatchLog 'Entire cache MISS  (file shrank below cached pos)' DarkYellow
        return $false
    }
    $restored = Clone-AnalysisState -Data $c.Data
    Begin-IncrementalEntireCatchUp -Path $Path -StartPos $pos -Data $restored
    return $true
}

function script:Read-TailBytes {
    if (-not $script:Sync['TailRunning'] -or $script:Sync['Paused'] -or $script:Sync['Loading']) { return }
    if (-not $script:Sync['Stream'] -or -not $script:Sync['LogPath']) { return }
    try {
        if (-not (Test-Path -LiteralPath $script:Sync['LogPath'])) {
            $script:Sync['LastError'] = 'Log file is missing.'
            $script:Sync['TailRunning'] = $false
            Clear-EntireCache -Reason 'file missing'
            Close-LogStream
            Bump-Generation
            return
        }
        $len = (Get-Item -LiteralPath $script:Sync['LogPath']).Length
        if ($len -lt $script:Sync['FilePos']) {
            # rotated
            Clear-EntireCache -Reason 'rotate'
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
    if ($d.BacCollectTrend -ge 100) {
        $topCode = ($d.BacCollectTrendByCode.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1)
        $codeNote = if ($topCode) { (" top error {0} x{1:N0}" -f $topCode.Key, $topCode.Value) } else { '' }
        [void]$findings.Add(("BACnetCollectTrend failures: {0:N0} across {1:N0} properties{2}." -f `
            $d.BacCollectTrend, $d.BacCollectTrendByProp.Count, $codeNote))
    }
    if ($d.BacTimeSync -ge 100) {
        $topCode = ($d.BacTimeSyncByCode.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1)
        $codeNote = if ($topCode) { (" top error {0} x{1:N0}" -f $topCode.Key, $topCode.Value) } else { '' }
        [void]$findings.Add(("BACnetTimeSync failures: {0:N0} across {1:N0} properties{2}." -f `
            $d.BacTimeSync, $d.BacTimeSyncByProp.Count, $codeNote))
    }
    if ($d.CnsResolve -ge 100 -or $d.CnsReduced -ge 100) {
        [void]$findings.Add(("CNS volume: ResolveNodes={0:N0}, ReducedFunction={1:N0}, ICns={2:N0}." -f $d.CnsResolve, $d.CnsReduced, $d.CnsICns))
    }
    if ($d.CnsTryRenew -ge 5) { [void]$findings.Add(("CNS/session: TryRenewSession hits={0:N0}." -f $d.CnsTryRenew)) }
    if ($d.CohoStuck -ge 10) { [void]$findings.Add(("CoHo stuck/drop messages: {0:N0}." -f $d.CohoStuck)) }
    if ($d.ApogeeUpdatePoints -ge 10) {
        [void]$findings.Add(("Apogee UpdatePoints failures: {0:N0} across {1:N0} PPCL programs." -f $d.ApogeeUpdatePoints, $d.ApogeePpcl.Count))
    }
    if ($d.ApogeeTrendOverflow -ge 50) {
        [void]$findings.Add(("ApogeeDrv trend buffer overflows: {0:N0} across {1:N0} devices ({2:N0} sequence-gap lines)." -f `
            $d.ApogeeTrendOverflow, $d.ApogeeTrendByDevice.Count, $d.ApogeeTrendSeq))
    }
    if ($d.ApogeeAlertId -ge 50) {
        [void]$findings.Add(("ApogeeDrv AlertID issues: {0:N0}." -f $d.ApogeeAlertId))
    }
    if ($d.ApogeeGetDataFail -ge 50) {
        [void]$findings.Add(("ApogeeDrv get-data failures: {0:N0} across {1:N0} devices." -f `
            $d.ApogeeGetDataFail, $d.ApogeeGetDataByDevice.Count))
    }
    if ($d.ApogeeQueryTimeout -ge 50) {
        [void]$findings.Add(("ApogeeDrv query timeouts: {0:N0}." -f $d.ApogeeQueryTimeout))
    }
    if ($d.ProjectUp -ge 1 -or $d.ProjectStopped -ge 1) {
        [void]$findings.Add(("Project lifecycle (pmon): up={0:N0}, stopped={1:N0}, shutdown cmds={2:N0}, START_MODE={3:N0}." -f `
            $d.ProjectUp, $d.ProjectStopped, $d.ProjectShutdown, $d.ProjectStartMode))
    }
    if ($d.PmonMgrRestart -ge 1) {
        $topRr = ($d.PmonRestartByComp.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3 | ForEach-Object { ("{0} x{1}" -f $_.Key, $_.Value) }) -join ', '
        [void]$findings.Add(("pmon auto-restarted managers: {0:N0} event(s){1}." -f `
            $d.PmonMgrRestart, $(if ($topRr) { " ($topRr)" } else { '' })))
    }
    if ($d.BlockingDetected -ge 1) {
        $topBl = ($d.BlockingByComp.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3 | ForEach-Object { ("{0} x{1}" -f $_.Key, $_.Value) }) -join ', '
        [void]$findings.Add(("pmon blocking (no heartbeat): {0:N0} detection(s), {1:N0} cleared{2}." -f `
            $d.BlockingDetected, $d.BlockingCleared, $(if ($topBl) { " ($topBl)" } else { '' })))
    }
    if ($d.MgrStartProj -ge 5) {
        [void]$findings.Add(("Manager Start (PROJ) events: {0:N0}; Manager Stop: {1:N0}; driver ready: {2:N0}." -f `
            $d.MgrStartProj, $d.MgrStop, $d.DriverReady))
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
                bacFailed = 0; bacOk = 0; projectRestart = 0
            }
        }
        $dst = $acc[$key]
        $v = $e.Value
        foreach ($s in @('FATAL', 'SEVERE', 'ERROR', 'WARNING', 'INFO')) {
            $dst[$s] += [int]$v[$s]
        }
        $dst.bacFailed += [int]$v.bacFailed
        $dst.bacOk += [int]$v.bacOk
        if ([int]$v.projectRestart -gt 0) { $dst.projectRestart = 1 }
    }

    $rows = @(
        $acc.GetEnumerator() | Sort-Object Name | ForEach-Object {
            $v = $_.Value
            $row = [ordered]@{
                t = $_.Key; bacFailed = [int]$v.bacFailed; bacOk = [int]$v.bacOk
                projectRestart = [int]$v.projectRestart
            }
            foreach ($s in @('FATAL', 'SEVERE', 'ERROR', 'WARNING', 'INFO')) {
                if ($SevFilter[$s]) { $row[$s] = [int]$v[$s] } else { $row[$s] = 0 }
            }
            $row
        }
    )
    return [ordered]@{
        granularity = $gran
        byMinute = $rows
        projectUp = [int]$Data.ProjectUp
        projectStopped = [int]$Data.ProjectStopped
    }
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
                bacnet = [ordered]@{
                    failed = $d.BacFailed; ok = $d.BacOk; endedFailed = 0; endedOk = 0; flappers = 0; objectList = $d.BacObjectList
                    collectTrend = $d.BacCollectTrend; timeSync = $d.BacTimeSync
                    collectTrendProps = $d.BacCollectTrendByProp.Count; timeSyncProps = $d.BacTimeSyncByProp.Count
                }
                cns    = [ordered]@{ resolveNodes = $d.CnsResolve; reducedFunction = $d.CnsReduced; tryRenew = $d.CnsTryRenew; icns = $d.CnsICns }
                coho   = [ordered]@{ stuck = $d.CohoStuck }
                apogee = [ordered]@{
                    events = $d.ApogeeEvents; updatePoints = $d.ApogeeUpdatePoints
                    drvLines = $d.ApogeeDrvLines; trendOverflow = $d.ApogeeTrendOverflow; trendSeq = $d.ApogeeTrendSeq
                    alertId = $d.ApogeeAlertId; queryTimeout = $d.ApogeeQueryTimeout; getDataFail = $d.ApogeeGetDataFail
                }
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
            bacnet = [ordered]@{
                failed = $d.BacFailed; ok = $d.BacOk; endedFailed = $endedFailed; endedOk = $endedOk; flappers = $flappers; objectList = $d.BacObjectList
                collectTrend = $d.BacCollectTrend; timeSync = $d.BacTimeSync
                collectTrendProps = $d.BacCollectTrendByProp.Count; timeSyncProps = $d.BacTimeSyncByProp.Count
            }
            cns    = [ordered]@{ resolveNodes = $d.CnsResolve; reducedFunction = $d.CnsReduced; tryRenew = $d.CnsTryRenew; icns = $d.CnsICns }
            coho   = [ordered]@{ stuck = $d.CohoStuck }
            apogee = [ordered]@{
                events = $d.ApogeeEvents; updatePoints = $d.ApogeeUpdatePoints
                drvLines = $d.ApogeeDrvLines; trendOverflow = $d.ApogeeTrendOverflow; trendSeq = $d.ApogeeTrendSeq
                alertId = $d.ApogeeAlertId; queryTimeout = $d.ApogeeQueryTimeout; getDataFail = $d.ApogeeGetDataFail
            }
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
            $ctCodes = @(
                $d.BacCollectTrendByCode.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 10 | ForEach-Object {
                    [ordered]@{ code = $_.Key; count = [int]$_.Value }
                }
            )
            $ctProps = @(
                $d.BacCollectTrendByProp.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 20 | ForEach-Object {
                    [ordered]@{ property = $_.Key; count = [int]$_.Value }
                }
            )
            $tsCodes = @(
                $d.BacTimeSyncByCode.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 10 | ForEach-Object {
                    [ordered]@{ code = $_.Key; count = [int]$_.Value }
                }
            )
            $tsProps = @(
                $d.BacTimeSyncByProp.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 20 | ForEach-Object {
                    [ordered]@{ property = $_.Key; count = [int]$_.Value }
                }
            )
            return [ordered]@{
                generation = $gen
                bacnet     = [ordered]@{
                    failed = $d.BacFailed; ok = $d.BacOk; endedFailed = $endedFailed; endedOk = $endedOk
                    flappers = $flappers; objectList = $d.BacObjectList
                    collectTrend = $d.BacCollectTrend; timeSync = $d.BacTimeSync
                    collectTrendProps = $d.BacCollectTrendByProp.Count; timeSyncProps = $d.BacTimeSyncByProp.Count
                    collectTrendSample = $d.BacCollectTrendSample; timeSyncSample = $d.BacTimeSyncSample
                    collectTrendCodes = $ctCodes; collectTrendTop = $ctProps
                    timeSyncCodes = $tsCodes; timeSyncTop = $tsProps
                    failedSample = $d.BacFailedSample; okSample = $d.BacOkSample; objectListSample = $d.BacObjectListSample
                    activity = $activity; endedFailedList = $endedList; objectListTop = $objTop
                    lifecycle = (Build-LifecycleRows -Data $d -MatchPattern '(?i)GmsBACnet|WCCOAGmsBACnet')
                }
            }
        }
        'cns' {
            return [ordered]@{
                generation = $gen
                cns        = [ordered]@{
                    resolveNodes = $d.CnsResolve; reducedFunction = $d.CnsReduced; icns = $d.CnsICns; tryRenew = $d.CnsTryRenew
                    patterns = @(Get-TopPatterns -CountMap $d.CnsPatterns -SampleMap $d.CnsPatternSamples -TimeMap $d.CnsPatternTimes -N $TopN)
                    lifecycle = (Build-LifecycleRows -Data $d -MatchPattern '(?i)ApplicationFramework|ICns')
                }
            }
        }
        'coho' {
            $names = @(
                $d.CohoStuckNames.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $TopN | ForEach-Object {
                    [ordered]@{ name = $_.Key; count = [int]$_.Value }
                }
            )
            return [ordered]@{
                generation = $gen
                coho = [ordered]@{
                    stuck = $d.CohoStuck; sample = $d.CohoSample; topNames = $names
                    lifecycle = (Build-LifecycleRows -Data $d -MatchPattern '(?i)CoHo|GmsCoHo')
                    blockingSample = $d.BlockingSample; unblockingSample = $d.UnblockingSample
                }
            }
        }
        'apogee' {
            $ppcl = @(
                $d.ApogeePpcl.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $TopN | ForEach-Object {
                    [ordered]@{ name = $_.Key; count = [int]$_.Value }
                }
            )
            $trendDev = @(
                $d.ApogeeTrendByDevice.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 20 | ForEach-Object {
                    [ordered]@{ device = $_.Key; count = [int]$_.Value }
                }
            )
            $trendNames = @(
                $d.ApogeeTrendByName.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 20 | ForEach-Object {
                    [ordered]@{ trend = $_.Key; count = [int]$_.Value }
                }
            )
            $getDev = @(
                $d.ApogeeGetDataByDevice.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 20 | ForEach-Object {
                    [ordered]@{ device = $_.Key; count = [int]$_.Value }
                }
            )
            return [ordered]@{
                generation = $gen
                apogee     = [ordered]@{
                    events = $d.ApogeeEvents; updatePoints = $d.ApogeeUpdatePoints; repetition = $d.ApogeeRepetition
                    other = $d.ApogeeOther; uniquePpcl = $d.ApogeePpcl.Count; sample = $d.ApogeeSample; topPpcl = $ppcl
                    drvLines = $d.ApogeeDrvLines
                    trendOverflow = $d.ApogeeTrendOverflow; trendSeq = $d.ApogeeTrendSeq
                    alertId = $d.ApogeeAlertId; queryTimeout = $d.ApogeeQueryTimeout; getDataFail = $d.ApogeeGetDataFail
                    trendDevices = $d.ApogeeTrendByDevice.Count; trendNames = $d.ApogeeTrendByName.Count
                    getDataDevices = $d.ApogeeGetDataByDevice.Count
                    trendSample = $d.ApogeeTrendSample; alertSample = $d.ApogeeAlertSample
                    timeoutSample = $d.ApogeeTimeoutSample; getDataSample = $d.ApogeeGetDataSample
                    topTrendDevices = $trendDev; topTrends = $trendNames; topGetDataDevices = $getDev
                    lifecycle = (Build-LifecycleRows -Data $d -MatchPattern '(?i)ApogeeDrv')
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
        lifecycle          = (Build-LifecycleRows -Data $d -MatchPattern ('^' + [regex]::Escape((Normalize-ManagerKey -Comp $MgrName)) + '$'))
    }
}

function script:HtmlEncode {
    param([string]$s)
    if ($null -eq $s) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($s)
}

function script:Build-SnapshotObject {
    param($SevFilter)
    if (-not $script:Sync['LogPath'] -or -not $script:Sync['Data']) {
        throw 'Start a session before taking a snapshot.'
    }
    if ($script:Sync['Loading']) {
        throw 'Catch-up still running. Wait until loading finishes, then snapshot.'
    }
    $pulse = Build-PulseObject -SevFilter $SevFilter
    $patterns = Build-SectionObject -Name 'patterns' -SevFilter $SevFilter
    $managers = Build-SectionObject -Name 'managers' -SevFilter $SevFilter
    $bacnet = Build-SectionObject -Name 'bacnet' -SevFilter $SevFilter
    $cns = Build-SectionObject -Name 'cns' -SevFilter $SevFilter
    $coho = Build-SectionObject -Name 'coho' -SevFilter $SevFilter
    $apogee = Build-SectionObject -Name 'apogee' -SevFilter $SevFilter
    $perf = Build-SectionObject -Name 'perf' -SevFilter $SevFilter
    $sevList = @()
    foreach ($sk in @('FATAL', 'SEVERE', 'ERROR', 'WARNING', 'INFO')) {
        if ($SevFilter[$sk]) { $sevList += $sk }
    }
    return [ordered]@{
        meta = [ordered]@{
            tool        = 'PVSS Log Watch'
            version     = [string]$script:Version
            generated   = (Get-Date).ToString('yyyy.MM.dd HH:mm:ss')
            logPath     = [string]$script:Sync['LogPath']
            fileLength  = [int64]$script:Sync['FileLength']
            generation  = [int]$script:Sync['Generation']
            parsedLines = [int]$script:Sync['Data'].ParsedLines
            severities  = @($sevList)
        }
        window          = $pulse.window
        findings        = @($pulse.findings)
        severityCounts  = $pulse.severityCounts
        series          = $pulse.series
        moduleHeadlines = $pulse.moduleHeadlines
        topManagers     = @($pulse.topManagers)
        patternsBySeverity = $patterns.patternsBySeverity
        managers        = @($managers.managers)
        bacnet          = $bacnet.bacnet
        cns             = $cns.cns
        coho            = $coho.coho
        apogee          = $apogee.apogee
        perf            = $perf
    }
}

function script:Reduce-SeriesPoints {
    param(
        $Points,
        [int]$MaxBars = 60,
        [ValidateSet('Max', 'MaxBac', 'Sum')]
        [string]$Aggregate = 'Max'
    )
    $pts = @($Points)
    if ($pts.Count -le $MaxBars -or $MaxBars -lt 2) { return $pts }
    $group = [int][math]::Ceiling($pts.Count / [double]$MaxBars)
    if ($group -lt 1) { $group = 1 }
    $out = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $pts.Count; $i += $group) {
        $end = [math]::Min($i + $group - 1, $pts.Count - 1)
        $chunk = @($pts[$i..$end])
        $best = $chunk[0]
        $bestScore = -1
        foreach ($row in $chunk) {
            if ($Aggregate -eq 'Sum') { break }
            if ($Aggregate -eq 'MaxBac') {
                $score = [int]$row.bacFailed + [int]$row.bacOk
            }
            else {
                $score = [int]$row.FATAL + [int]$row.SEVERE + [int]$row.ERROR + [int]$row.WARNING + [int]$row.INFO
            }
            if ($score -gt $bestScore) {
                $bestScore = $score
                $best = $row
            }
        }
        if ($Aggregate -eq 'Max' -or $Aggregate -eq 'MaxBac') {
            $hadRestart = 0
            foreach ($row in $chunk) {
                if ([int]$row.projectRestart -gt 0) { $hadRestart = 1; break }
            }
            $agg = [ordered]@{
                t         = [string]$best.t
                FATAL     = [int]$best.FATAL
                SEVERE    = [int]$best.SEVERE
                ERROR     = [int]$best.ERROR
                WARNING   = [int]$best.WARNING
                INFO      = [int]$best.INFO
                bacFailed = [int]$best.bacFailed
                bacOk     = [int]$best.bacOk
                projectRestart = $hadRestart
            }
            [void]$out.Add($agg)
            continue
        }
        $mid = $chunk[[int][math]::Floor(($chunk.Count - 1) / 2)]
        $agg = [ordered]@{
            t         = [string]$mid.t
            FATAL     = 0; SEVERE = 0; ERROR = 0; WARNING = 0; INFO = 0
            bacFailed = 0; bacOk = 0; projectRestart = 0
        }
        foreach ($row in $chunk) {
            foreach ($k in @('FATAL', 'SEVERE', 'ERROR', 'WARNING', 'INFO', 'bacFailed', 'bacOk')) {
                $v = [int]$row.$k
                $agg[$k] = [int]$agg[$k] + $v
            }
            if ([int]$row.projectRestart -gt 0) { $agg.projectRestart = 1 }
        }
        [void]$out.Add($agg)
    }
    return @($out.ToArray())
}

function script:Format-SnapAxisLabel {
    param([string]$T, [string]$Gran = 'minute')
    if ([string]::IsNullOrWhiteSpace($T)) { return '' }
    if ($T.Contains('..')) { $T = ($T -split '\.\.', 2)[0] }
    switch ($Gran) {
        'day' {
            if ($T.Length -ge 10) { return $T.Substring(0, 10) }
            return $T
        }
        'hour' {
            if ($T.Length -ge 13) { return $T.Substring(5, [math]::Min(8, $T.Length - 5)) }
            return $T
        }
        default {
            if ($T.Length -ge 16) { return $T.Substring(5, 11) }
            return $T
        }
    }
}

function script:Get-SeriesPeakSummary {
    param($Points)
    $pts = @($Points)
    $peakVol = $null
    $peakVolN = -1
    $peakBac = $null
    $peakBacN = -1
    foreach ($row in $pts) {
        $vol = [int]$row.FATAL + [int]$row.SEVERE + [int]$row.ERROR + [int]$row.WARNING + [int]$row.INFO
        if ($vol -gt $peakVolN) {
            $peakVolN = $vol
            $peakVol = $row
        }
        $bf = [int]$row.bacFailed
        if ($bf -gt $peakBacN) {
            $peakBacN = $bf
            $peakBac = $row
        }
    }
    return [ordered]@{
        buckets  = $pts.Count
        peakVol  = $peakVol
        peakVolN = [math]::Max(0, $peakVolN)
        peakBac  = $peakBac
        peakBacN = [math]::Max(0, $peakBacN)
    }
}

function script:Add-SnapChartAxes {
    param(
        [System.Text.StringBuilder]$Sb,
        [int]$PadL,
        [int]$PadR,
        [int]$PadT,
        [int]$PadB,
        [int]$Width,
        [int]$Height,
        [int]$MaxY,
        $Points,
        [string]$Gran
    )
    $plotW = $Width - $PadL - $PadR
    $plotH = $Height - $PadT - $PadB
    $n = @($Points).Count
    foreach ($frac in @(0.0, 0.5, 1.0)) {
        $y = $PadT + $plotH * (1.0 - $frac)
        $val = [int][math]::Round($MaxY * $frac)
        [void]$Sb.Append(('<line x1="{0}" y1="{1:0.##}" x2="{2}" y2="{1:0.##}" stroke="rgba(135,155,170,0.25)" stroke-width="1"/>' -f $PadL, [double]$y, ($Width - $PadR)))
        [void]$Sb.Append(('<text x="{0}" y="{1:0.##}" fill="#879baa" font-size="10" text-anchor="end" dominant-baseline="middle">{2}</text>' -f ($PadL - 4), [double]$y, $val))
    }
    if ($n -lt 1) { return }
    $slot = $plotW / [double]$n
    $labelIdx = @(0)
    if ($n -gt 2) { $labelIdx += [int][math]::Floor(($n - 1) / 2.0) }
    if ($n -gt 1) { $labelIdx += ($n - 1) }
    foreach ($i in @($labelIdx | Select-Object -Unique)) {
        $x = $PadL + $i * $slot + $slot / 2.0
        $label = Format-SnapAxisLabel -T ([string]$Points[$i].t) -Gran $Gran
        $label = [System.Net.WebUtility]::HtmlEncode($label)
        $anchor = 'middle'
        if ($i -eq 0) { $anchor = 'start'; $x = $PadL }
        elseif ($i -eq ($n - 1)) { $anchor = 'end'; $x = $Width - $PadR }
        [void]$Sb.Append(('<text x="{0:0.##}" y="{1}" fill="#aaaa96" font-size="10" text-anchor="{2}">{3}</text>' -f [double]$x, ($Height - 10), $anchor, $label))
    }
}

function script:Build-VolumeSvg {
    param($Points, [string]$Gran = 'minute', [int]$Width = 840, [int]$Height = 200)
    $rawN = @($Points).Count
    $maxBars = 56
    $pts = @(Reduce-SeriesPoints -Points $Points -MaxBars $maxBars -Aggregate Max)
    if ($pts.Count -eq 0) { return '<p class="muted">No volume series.</p>' }
    $padL = 40; $padR = 12; $padT = 12; $padB = 32
    $plotW = $Width - $padL - $padR
    $plotH = $Height - $padT - $padB
    $maxY = 1
    foreach ($row in $pts) {
        $v = [int]$row.FATAL + [int]$row.SEVERE + [int]$row.ERROR + [int]$row.WARNING + [int]$row.INFO
        if ($v -gt $maxY) { $maxY = $v }
    }
    $n = $pts.Count
    $slot = $plotW / [double]$n
    $barW = [math]::Max(2.5, $slot * 0.88)
    $colors = [ordered]@{
        FATAL = '#e00000'; SEVERE = '#c000a0'; ERROR = '#b00040'; WARNING = '#e07000'; INFO = '#008000'
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append(('<svg class="chart-svg" viewBox="0 0 {0} {1}" role="img" aria-label="Message volume by bucket">' -f $Width, $Height))
    [void]$sb.Append('<rect x="0" y="0" width="100%" height="100%" fill="#1c2834"/>')
    Add-SnapChartAxes -Sb $sb -PadL $padL -PadR $padR -PadT $padT -PadB $padB -Width $Width -Height $Height -MaxY $maxY -Points $pts -Gran $Gran
    # Chart.js stack order: first dataset at bottom (FATAL .. INFO)
    for ($i = 0; $i -lt $n; $i++) {
        $row = $pts[$i]
        $x = $padL + $i * $slot + ($slot - $barW) / 2.0
        $yBase = $padT + $plotH
        foreach ($s in @('FATAL', 'SEVERE', 'ERROR', 'WARNING', 'INFO')) {
            $c = 0
            if ($null -ne $row[$s]) { $c = [int]$row[$s] }
            elseif ($null -ne $row.$s) { $c = [int]$row.$s }
            if ($c -le 0) { continue }
            $h = ($c / [double]$maxY) * $plotH
            if ($h -gt 0 -and $h -lt 1.0) { $h = 1.0 }
            $yBase -= $h
            [void]$sb.Append(('<rect x="{0:0.##}" y="{1:0.##}" width="{2:0.##}" height="{3:0.##}" fill="{4}"/>' -f [double]$x, [double]$yBase, [double]$barW, [double]$h, [string]$colors[$s]))
        }
    }
    for ($i = 0; $i -lt $n; $i++) {
        if ([int]$pts[$i].projectRestart -le 0) { continue }
        $x = $padL + $i * $slot + $slot / 2.0
        [void]$sb.Append(('<line x1="{0:0.##}" y1="{1}" x2="{0:0.##}" y2="{2}" stroke="#e0a000" stroke-width="2" stroke-dasharray="4 3" opacity="0.9"/>' -f [double]$x, $padT, ($padT + $plotH)))
    }
    if ($rawN -gt $pts.Count) {
        [void]$sb.Append(('<text x="{0}" y="14" fill="#879baa" font-size="9" text-anchor="end">display {1}/{2} (peak-preserving)</text>' -f ($Width - $padR), $pts.Count, $rawN))
    }
    [void]$sb.Append('</svg>')
    return $sb.ToString()
}

function script:Build-BacnetSvg {
    param($Points, [string]$Gran = 'minute', [int]$Width = 840, [int]$Height = 200)
    $rawN = @($Points).Count
    # Lines tolerate denser samples than bars
    $pts = @(Reduce-SeriesPoints -Points $Points -MaxBars 120 -Aggregate MaxBac)
    if ($pts.Count -eq 0) { return '<p class="muted">No BACnet series.</p>' }
    $padL = 40; $padR = 12; $padT = 12; $padB = 32
    $plotW = $Width - $padL - $padR
    $plotH = $Height - $padT - $padB
    $maxY = 1
    foreach ($row in $pts) {
        $v = [math]::Max([int]$row.bacFailed, [int]$row.bacOk)
        if ($v -gt $maxY) { $maxY = $v }
    }
    $n = $pts.Count
    $slot = $plotW / [double]$n
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append(('<svg class="chart-svg" viewBox="0 0 {0} {1}" role="img" aria-label="BACnet Failed and OK by bucket">' -f $Width, $Height))
    [void]$sb.Append('<rect x="0" y="0" width="100%" height="100%" fill="#1c2834"/>')
    Add-SnapChartAxes -Sb $sb -PadL $padL -PadR $padR -PadT $padT -PadB $padB -Width $Width -Height $Height -MaxY $maxY -Points $pts -Gran $Gran

    $failPts = New-Object System.Collections.Generic.List[string]
    $okPts = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $n; $i++) {
        $row = $pts[$i]
        $x = $padL + $i * $slot + $slot / 2.0
        $yf = $padT + $plotH - (([int]$row.bacFailed / [double]$maxY) * $plotH)
        $yo = $padT + $plotH - (([int]$row.bacOk / [double]$maxY) * $plotH)
        [void]$failPts.Add(('{0:0.##},{1:0.##}' -f [double]$x, [double]$yf))
        [void]$okPts.Add(('{0:0.##},{1:0.##}' -f [double]$x, [double]$yo))
    }
    # Match dashboard line colors: Failed=SEVERE magenta, OK=INFO green
    [void]$sb.Append(('<polyline fill="none" stroke="#c000a0" stroke-width="2" stroke-linejoin="round" stroke-linecap="round" points="{0}"/>' -f ($failPts -join ' ')))
    [void]$sb.Append(('<polyline fill="none" stroke="#008000" stroke-width="2" stroke-linejoin="round" stroke-linecap="round" points="{0}"/>' -f ($okPts -join ' ')))
    for ($i = 0; $i -lt $n; $i++) {
        if ([int]$pts[$i].projectRestart -le 0) { continue }
        $x = $padL + $i * $slot + $slot / 2.0
        [void]$sb.Append(('<line x1="{0:0.##}" y1="{1}" x2="{0:0.##}" y2="{2}" stroke="#e0a000" stroke-width="2" stroke-dasharray="4 3" opacity="0.9"/>' -f [double]$x, $padT, ($padT + $plotH)))
    }
    if ($rawN -gt $pts.Count) {
        [void]$sb.Append(('<text x="{0}" y="14" fill="#879baa" font-size="9" text-anchor="end">display {1}/{2} (peak-preserving)</text>' -f ($Width - $padR), $pts.Count, $rawN))
    }
    [void]$sb.Append('</svg>')
    return $sb.ToString()
}

function script:Convert-SnapshotToHtml {
    param($Snap)
    $e = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
    $sb = New-Object System.Text.StringBuilder
    $win = $Snap.window
    $winLabel = if ($win.mode -eq 'entire') {
        'Entire file'
    }
    else {
        ('Last {0} minutes of file' -f $win.lastMinutes)
    }
    $span = if ($win.first -or $win.last) {
        ('{0}  ->  {1}' -f $win.first, $win.last)
    }
    else { '' }
    $sevOn = if ($Snap.meta.severities) { ($Snap.meta.severities -join ', ') } else { '(none)' }

    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine('<html lang="en"><head><meta charset="utf-8" />')
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1" />')
    [void]$sb.AppendLine('<title>PVSS Log Watch Snapshot</title>')
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
  --font: "Segoe UI", "Candara", "Calibri", sans-serif;
  --mono: "Cascadia Mono", "Consolas", monospace;
}
* { box-sizing: border-box; }
body {
  margin: 0;
  font-family: var(--font);
  color: var(--text);
  background: var(--bg-deep);
  line-height: 1.45;
}
header {
  background: var(--bg-panel);
  border-bottom: 1px solid var(--border);
  padding: 1rem 1.25rem 1.1rem;
}
.brand { color: var(--siemens-petrol); font-weight: 700; font-size: 1.15rem; letter-spacing: 0.02em; }
.meta { color: var(--text-meta); font-size: 0.88rem; }
.muted { color: var(--text-muted); }
main { padding: 1rem 1.25rem 2.5rem; max-width: 72rem; }
h1 { font-size: 1.15rem; margin: 0 0 0.35rem; }
h2 {
  font-size: 1rem;
  color: var(--siemens-petrol);
  margin: 1.4rem 0 0.55rem;
  padding-bottom: 0.25rem;
  border-bottom: 1px solid var(--border);
}
h3 { font-size: 0.92rem; margin: 0.85rem 0 0.4rem; }
.findings { margin: 0.5rem 0 1rem; padding-left: 1.1rem; }
.findings li { margin: 0.25rem 0; }
.kpi-row {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(7rem, 1fr));
  gap: 0.5rem;
  margin: 0.75rem 0 1rem;
}
.kpi {
  background: var(--bg-panel);
  border: 1px solid var(--border);
  border-radius: 2px;
  padding: 0.55rem 0.65rem;
}
.kpi .label { font-size: 0.75rem; letter-spacing: 0.04em; color: var(--text-muted); }
.kpi .value { font-size: 1.25rem; font-variant-numeric: tabular-nums; font-weight: 600; }
.kpi[data-sev="FATAL"] .value { color: #ffb0b0; }
.kpi[data-sev="SEVERE"] .value { color: #f0a0e0; }
.kpi[data-sev="ERROR"] .value { color: #f0a0c0; }
.kpi[data-sev="WARNING"] .value { color: #ffd0a0; }
.kpi[data-sev="INFO"] .value { color: #90d090; }
table.data {
  width: 100%;
  border-collapse: collapse;
  font-size: 0.86rem;
  font-variant-numeric: tabular-nums;
  margin: 0.35rem 0 0.85rem;
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
.mono { font-family: var(--mono); font-size: 0.8rem; word-break: break-word; }
.card {
  background: var(--bg-panel);
  border: 1px solid var(--border);
  border-radius: 2px;
  padding: 0.65rem 0.75rem;
  margin: 0.5rem 0;
}
footer { margin-top: 2rem; color: var(--text-meta); font-size: 0.8rem; }
.chart-svg { width: 100%; max-width: 48rem; height: auto; display: block; margin: 0.35rem 0 0.25rem; border: 1px solid var(--border); border-radius: 2px; }
.legend { font-size: 0.8rem; color: var(--text-muted); margin: 0.2rem 0 0.85rem; }
.legend span { margin-right: 0.9rem; white-space: nowrap; }
.swatch { display: inline-block; width: 0.65rem; height: 0.65rem; margin-right: 0.28rem; vertical-align: middle; border-radius: 1px; }
'@)
    [void]$sb.AppendLine('</style></head><body>')
    [void]$sb.AppendLine('<header>')
    [void]$sb.AppendLine('<div class="brand">PVSS Log Watch</div>')
    [void]$sb.AppendLine(('<h1>Snapshot report <span class="meta">v{0}</span></h1>' -f (& $e $Snap.meta.version)))
    [void]$sb.AppendLine(('<p class="meta">Generated {0}  &middot;  by {1}</p>' -f (& $e $Snap.meta.generated), (& $e $script:Author)))
    [void]$sb.AppendLine(('<p class="meta">Log: <span class="mono">{0}</span></p>' -f (& $e $Snap.meta.logPath)))
    [void]$sb.AppendLine(('<p class="meta">{0}  &middot;  {1}</p>' -f (& $e $winLabel), (& $e $span)))
    [void]$sb.AppendLine(('<p class="meta">Severity filters: {0}  &middot;  parsed lines: {1:N0}  &middot;  gen {2}</p>' -f `
        (& $e $sevOn), [int]$Snap.meta.parsedLines, [int]$Snap.meta.generation))
    [void]$sb.AppendLine('</header><main>')

    [void]$sb.AppendLine('<h2>Findings</h2><ul class="findings">')
    if (-not $Snap.findings -or @($Snap.findings).Count -eq 0) {
        [void]$sb.AppendLine('<li class="muted">No findings.</li>')
    }
    else {
        foreach ($f in @($Snap.findings)) {
            [void]$sb.AppendLine(('<li>{0}</li>' -f (& $e ([string]$f))))
        }
    }
    [void]$sb.AppendLine('</ul>')

    [void]$sb.AppendLine('<h2>Severity counts</h2><div class="kpi-row">')
    foreach ($s in @('FATAL', 'SEVERE', 'ERROR', 'WARNING', 'INFO')) {
        $n = 0
        if ($Snap.severityCounts -and $Snap.severityCounts.$s -ne $null) { $n = [int]$Snap.severityCounts.$s }
        [void]$sb.AppendLine(('<div class="kpi" data-sev="{0}"><div class="label">{0}</div><div class="value">{1:N0}</div></div>' -f $s, $n))
    }
    [void]$sb.AppendLine('</div>')

    $gran = 'minute'
    if ($Snap.series -and $Snap.series.granularity) { $gran = [string]$Snap.series.granularity }
    [void]$sb.AppendLine(('<h2>Activity charts (by {0})</h2>' -f (& $e $gran)))
    $points = @()
    if ($Snap.series -and $Snap.series.byMinute) { $points = @($Snap.series.byMinute) }
    if ($points.Count -eq 0) {
        [void]$sb.AppendLine('<p class="muted">No series points in window.</p>')
    }
    else {
        $sum = Get-SeriesPeakSummary -Points $points
        [void]$sb.AppendLine(('<p class="meta">{0:N0} {1} buckets in series. Charts are peak-preserving downsamples (not every bucket drawn).</p>' -f [int]$sum.buckets, (& $e $gran)))
        if ($sum.peakVol -and $sum.peakVolN -gt 0) {
            $pv = $sum.peakVol
            [void]$sb.AppendLine(('<p class="meta">Peak message volume: <strong>{0:N0}</strong> at <span class="mono">{1}</span> (FATAL {2}, SEVERE {3}, ERROR {4}, WARNING {5}, INFO {6}).</p>' -f `
                [int]$sum.peakVolN, (& $e ([string]$pv.t)), [int]$pv.FATAL, [int]$pv.SEVERE, [int]$pv.ERROR, [int]$pv.WARNING, [int]$pv.INFO))
        }
        if ($sum.peakBac -and $sum.peakBacN -gt 0) {
            [void]$sb.AppendLine(('<p class="meta">Peak BACnet Failed: <strong>{0:N0}</strong> at <span class="mono">{1}</span> (OK in that bucket: {2:N0}).</p>' -f `
                [int]$sum.peakBacN, (& $e ([string]$sum.peakBac.t)), [int]$sum.peakBac.bacOk))
        }
        [void]$sb.AppendLine('<div class="card">')
        [void]$sb.AppendLine('<h3>Message volume</h3>')
        [void]$sb.AppendLine('<div class="legend"><span><span class="swatch" style="background:#e00000"></span>FATAL</span><span><span class="swatch" style="background:#c000a0"></span>SEVERE</span><span><span class="swatch" style="background:#b00040"></span>ERROR</span><span><span class="swatch" style="background:#e07000"></span>WARNING</span><span><span class="swatch" style="background:#008000"></span>INFO</span></div>')
        [void]$sb.AppendLine((Build-VolumeSvg -Points $points -Gran $gran))
        [void]$sb.AppendLine('</div>')
        [void]$sb.AppendLine('<div class="card">')
        [void]$sb.AppendLine('<h3>BACnet Failed / OK</h3>')
        [void]$sb.AppendLine('<div class="legend"><span><span class="swatch" style="background:#c000a0"></span>Failed</span><span><span class="swatch" style="background:#008000"></span>OK</span></div>')
        [void]$sb.AppendLine((Build-BacnetSvg -Points $points -Gran $gran))
        [void]$sb.AppendLine('</div>')
    }

    [void]$sb.AppendLine('<h2>Patterns by severity</h2>')
    foreach ($s in @('FATAL', 'SEVERE', 'ERROR', 'WARNING')) {
        $color = switch ($s) {
            'FATAL' { 'var(--sev-fatal)' }
            'SEVERE' { 'var(--sev-severe)' }
            'ERROR' { 'var(--sev-error)' }
            default { 'var(--sev-warning)' }
        }
        $list = @()
        if ($Snap.patternsBySeverity -and $Snap.patternsBySeverity.$s) { $list = @($Snap.patternsBySeverity.$s) }
        [void]$sb.AppendLine(('<h3 style="color:{0}">{1} <span class="meta">({2})</span></h3>' -f $color, $s, $list.Count))
        if ($list.Count -eq 0) {
            [void]$sb.AppendLine('<p class="muted">No patterns (filtered out or none in window).</p>')
            continue
        }
        [void]$sb.AppendLine('<table class="data"><thead><tr><th>Count</th><th>First</th><th>Last</th><th>Pattern</th></tr></thead><tbody>')
        foreach ($row in $list) {
            [void]$sb.AppendLine(('<tr><td>{0:N0}</td><td class="meta">{1}</td><td class="meta">{2}</td><td class="mono">{3}</td></tr>' -f `
                [int]$row.count, (& $e ([string]$row.first)), (& $e ([string]$row.last)), (& $e ([string]$row.pattern))))
        }
        [void]$sb.AppendLine('</tbody></table>')
    }

    [void]$sb.AppendLine('<h2>Top managers</h2>')
    $mgrs = @($Snap.topManagers)
    if ($mgrs.Count -eq 0) {
        [void]$sb.AppendLine('<p class="muted">No managers.</p>')
    }
    else {
        [void]$sb.AppendLine('<table class="data"><thead><tr><th>Count</th><th>Manager</th></tr></thead><tbody>')
        foreach ($m in $mgrs) {
            [void]$sb.AppendLine(('<tr><td>{0:N0}</td><td class="mono">{1}</td></tr>' -f [int]$m.count, (& $e ([string]$m.name))))
        }
        [void]$sb.AppendLine('</tbody></table>')
    }

    $bac = $Snap.bacnet
    [void]$sb.AppendLine('<h2>BACnet</h2><div class="card">')
    if ($bac) {
        [void]$sb.AppendLine(('<p>Failed: <strong>{0:N0}</strong> &middot; OK: <strong>{1:N0}</strong> &middot; ended Failed: <strong>{2:N0}</strong> &middot; ended OK: <strong>{3:N0}</strong> &middot; flappers: <strong>{4:N0}</strong> &middot; object-list: <strong>{5:N0}</strong></p>' -f `
            [int]$bac.failed, [int]$bac.ok, [int]$bac.endedFailed, [int]$bac.endedOk, [int]$bac.flappers, [int]$bac.objectList))
        [void]$sb.AppendLine(('<p>CollectTrend: <strong>{0:N0}</strong> ({1:N0} properties) &middot; TimeSync: <strong>{2:N0}</strong> ({3:N0} properties)</p>' -f `
            [int]$bac.collectTrend, [int]$bac.collectTrendProps, [int]$bac.timeSync, [int]$bac.timeSyncProps))
        if ($bac.collectTrendSample) {
            [void]$sb.AppendLine(('<p class="muted mono">{0}</p>' -f (& $e ([string]$bac.collectTrendSample))))
        }
        if ($bac.timeSyncSample) {
            [void]$sb.AppendLine(('<p class="muted mono">{0}</p>' -f (& $e ([string]$bac.timeSyncSample))))
        }
        if ($bac.activity -and @($bac.activity).Count -gt 0) {
            [void]$sb.AppendLine('<h3>Device status activity</h3><table class="data"><thead><tr><th>Device</th><th>Failed</th><th>OK</th><th>Flips</th><th>Last</th></tr></thead><tbody>')
            foreach ($row in @($bac.activity)) {
                [void]$sb.AppendLine(('<tr><td class="mono">{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td></tr>' -f `
                    (& $e ([string]$row.device)), [int]$row.failed, [int]$row.ok, [int]$row.flips, (& $e ([string]$row.last))))
            }
            [void]$sb.AppendLine('</tbody></table>')
        }
    }
    else {
        [void]$sb.AppendLine('<p class="muted">No BACnet data.</p>')
    }
    [void]$sb.AppendLine('</div>')

    $cns = $Snap.cns
    [void]$sb.AppendLine('<h2>CNS</h2><div class="card">')
    if ($cns) {
        [void]$sb.AppendLine(('<p>ResolveNodes: <strong>{0:N0}</strong> &middot; ReducedFunction: <strong>{1:N0}</strong> &middot; ICns: <strong>{2:N0}</strong> &middot; TryRenewSession: <strong>{3:N0}</strong></p>' -f `
            [int]$cns.resolveNodes, [int]$cns.reducedFunction, [int]$cns.icns, [int]$cns.tryRenew))
    }
    else { [void]$sb.AppendLine('<p class="muted">No CNS data.</p>') }
    [void]$sb.AppendLine('</div>')

    $coho = $Snap.coho
    [void]$sb.AppendLine('<h2>CoHo</h2><div class="card">')
    if ($coho) {
        [void]$sb.AppendLine(('<p>Stuck/drop: <strong>{0:N0}</strong></p>' -f [int]$coho.stuck))
        if ($coho.sample) { [void]$sb.AppendLine(('<p class="mono meta">{0}</p>' -f (& $e ([string]$coho.sample)))) }
    }
    else { [void]$sb.AppendLine('<p class="muted">No CoHo data.</p>') }
    [void]$sb.AppendLine('</div>')

    $apo = $Snap.apogee
    [void]$sb.AppendLine('<h2>Apogee</h2><div class="card">')
    if ($apo -and (([int]$apo.events + [int]$apo.drvLines + [int]$apo.trendOverflow + [int]$apo.alertId + [int]$apo.getDataFail) -gt 0)) {
        [void]$sb.AppendLine(('<p>CoHo/Orch events: <strong>{0:N0}</strong> &middot; UpdatePoints: <strong>{1:N0}</strong> &middot; unique PPCL: <strong>{2:N0}</strong></p>' -f `
            [int]$apo.events, [int]$apo.updatePoints, [int]$apo.uniquePpcl))
        [void]$sb.AppendLine(('<p>ApogeeDrv: lines <strong>{0:N0}</strong> &middot; trend overflow <strong>{1:N0}</strong> &middot; sequence gaps <strong>{2:N0}</strong> &middot; AlertID <strong>{3:N0}</strong> &middot; query timeout <strong>{4:N0}</strong> &middot; get-data fail <strong>{5:N0}</strong></p>' -f `
            [int]$apo.drvLines, [int]$apo.trendOverflow, [int]$apo.trendSeq, [int]$apo.alertId, [int]$apo.queryTimeout, [int]$apo.getDataFail))
        if ($apo.trendSample) { [void]$sb.AppendLine(('<p class="muted mono">{0}</p>' -f (& $e ([string]$apo.trendSample)))) }
        if ($apo.alertSample) { [void]$sb.AppendLine(('<p class="muted mono">{0}</p>' -f (& $e ([string]$apo.alertSample)))) }
    }
    else { [void]$sb.AppendLine('<p class="muted">No Apogee data.</p>') }
    [void]$sb.AppendLine('</div>')

    [void]$sb.AppendLine('<h2>Perf / parse notes</h2><div class="card">')
    if ($Snap.perf -and $Snap.perf.perfCategories) {
        [void]$sb.AppendLine('<table class="data"><thead><tr><th>Count</th><th>Category</th></tr></thead><tbody>')
        foreach ($row in @($Snap.perf.perfCategories)) {
            [void]$sb.AppendLine(('<tr><td>{0:N0}</td><td>{1}</td></tr>' -f [int]$row.count, (& $e ([string]$row.name))))
        }
        [void]$sb.AppendLine('</tbody></table>')
    }
    if ($Snap.perf -and $null -ne $Snap.perf.unparsedLines) {
        [void]$sb.AppendLine(('<p class="meta">Unparsed / skipped lines: {0:N0}</p>' -f [int]$Snap.perf.unparsedLines))
    }
    [void]$sb.AppendLine('</div>')

    [void]$sb.AppendLine(('<footer>Snapshot from live Watch state (no re-scan). Watch v{0} by {1}.</footer>' -f `
        (& $e $Snap.meta.version), (& $e $script:Author)))
    [void]$sb.AppendLine('</main></body></html>')
    return $sb.ToString()
}

function script:Write-DownloadResponse {
    param(
        $Context,
        [byte[]]$Bytes,
        [string]$ContentType,
        [string]$FileName
    )
    $Context.Response.StatusCode = 200
    $Context.Response.ContentType = $ContentType
    $Context.Response.Headers['Cache-Control'] = 'no-store'
    $Context.Response.Headers['Content-Disposition'] = ('attachment; filename="{0}"' -f $FileName)
    $Context.Response.ContentLength64 = $Bytes.Length
    $Context.Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $Context.Response.OutputStream.Close()
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
                author       = "$($script:Author)"
                logPath      = "$($script:Sync['LogPath'])"
                prefillPath  = "$($script:Sync['PrefillPath'])"
                listeningUrl = "$($script:Sync['ListeningUrl'])"
                port         = [int]$script:Sync['BoundPort']
                preferredPort = [int]$Port
                refreshSeconds = [int]$script:RefreshSeconds
                defaults     = [ordered]@{
                    lastMinutes  = [int]$script:Sync['LastMinutes']
                    windowEntire = [bool]$script:Sync['WindowEntire']
                    severities   = @($script:DefaultSeverities)
                    topN         = [int]$TopN
                }
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
            Clear-EntireCache -Reason 'path change'
            $script:Sync['LogPath'] = $p
            Set-WatchConfigLogPath -Path $p
            $script:Sync['PrefillPath'] = $p
            $script:PrefillPath = $p
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
                    Clear-EntireCache -Reason 'restart'
                    Reset-Analysis
                    $script:Sync['LogPath'] = ''
                    Write-WatchLog 'Session restarted (idle)' Yellow
                }
                'setWindow' {
                    $wasEntire = [bool]$script:Sync['WindowEntire']
                    $wantEntire = ($body.window -eq 'entire')
                    if ($wasEntire -and -not $wantEntire) {
                        Save-EntireCache
                    }
                    if ($wantEntire) { $script:Sync['WindowEntire'] = $true }
                    else {
                        $script:Sync['WindowEntire'] = $false
                        if ($body.lastMinutes) { $script:Sync['LastMinutes'] = [math]::Max(1, [int]$body.lastMinutes) }
                    }
                    $wlabel = if ($script:Sync['WindowEntire']) { 'entire' } else { ("{0}m" -f $script:Sync['LastMinutes']) }
                    Write-WatchLog ("Window change -> {0}" -f $wlabel) Cyan
                    if ($script:Sync['LogPath']) {
                        if ($wantEntire -and $wasEntire) {
                            Write-WatchLog 'Window unchanged (already Entire); keeping live analysis' DarkCyan
                        }
                        elseif ($wantEntire -and (Try-Begin-EntireFromCache -Path $script:Sync['LogPath'])) {
                            # restored snapshot + incremental catch-up started
                        }
                        else {
                            Invoke-CatchUp -Path $script:Sync['LogPath']
                        }
                    }
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

    
    if ($path -eq '/api/snapshot' -and $req.HttpMethod -eq 'GET') {
        try {
            if (-not $script:Sync['LogPath'] -or -not $script:Sync['Data']) {
                Write-StatusResponse -Context $Context -Code 400 -Message 'Start a session before taking a snapshot.'
                return
            }
            if ($script:Sync['Loading']) {
                Write-StatusResponse -Context $Context -Code 409 -Message 'Catch-up still running. Wait until loading finishes, then snapshot.'
                return
            }
            $sev = Parse-QuerySevs -Q $req.QueryString
            $fmt = ([string]$req.QueryString['format']).ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($fmt)) { $fmt = 'html' }
            $snap = Build-SnapshotObject -SevFilter $sev
            $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
            if ($fmt -eq 'json') {
                $json = $snap | ConvertTo-Json -Depth 10 -Compress
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                Write-DownloadResponse -Context $Context -Bytes $bytes -ContentType 'application/json; charset=utf-8' -FileName ("PVSS_Log_Watch_Snapshot_{0}.json" -f $stamp)
            }
            elseif ($fmt -eq 'html') {
                $html = Convert-SnapshotToHtml -Snap $snap
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
                Write-DownloadResponse -Context $Context -Bytes $bytes -ContentType 'text/html; charset=utf-8' -FileName ("PVSS_Log_Watch_Snapshot_{0}.html" -f $stamp)
            }
            else {
                Write-StatusResponse -Context $Context -Code 400 -Message 'format must be html or json'
            }
        }
        catch {
            Write-WatchLog ("Snapshot failed: {0}" -f $_.Exception.Message) Red
            Write-StatusResponse -Context $Context -Code 500 -Message $_.Exception.Message
        }
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
    param([int]$PreferredPort, [int]$MaxTries = 40)
    if ($MaxTries -lt 1) { $MaxTries = 1 }
    $listener = New-Object System.Net.HttpListener
    $bound = $null
    for ($p = $PreferredPort; $p -lt ($PreferredPort + $MaxTries); $p++) {
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
    throw "Could not bind a port starting at $PreferredPort (tried $MaxTries)"
}

function script:Open-WatchBrowser {
    param([string]$Url, [string]$Choice = 'default')
    $choice = if ([string]::IsNullOrWhiteSpace($Choice)) { 'default' } else { $Choice.Trim() }
    $chrome = @(
        "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    )
    $edge = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles}\Microsoft\Edge\Application\msedge.exe"
    )
    $candidates = @()
    switch -Regex ($choice.ToLowerInvariant()) {
        '^chrome$' { $candidates = $chrome }
        '^(msedge|edge)$' { $candidates = $edge }
        '^default$' { $candidates = @() }
        default {
            if (Test-Path -LiteralPath $choice) { $candidates = @($choice) }
            else { $candidates = @() }
        }
    }
    foreach ($browser in $candidates) {
        if (Test-Path -LiteralPath $browser) {
            Start-Process -FilePath $browser -ArgumentList $Url | Out-Null
            return
        }
    }
    Start-Process $Url | Out-Null
}

# --- main ---
if (-not (Test-Path -LiteralPath $script:UiRoot)) {
    throw "UI folder missing: $script:UiRoot"
}

$listener = Start-Listener -PreferredPort $Port -MaxTries $script:MaxPortTries
$url = $script:Sync['ListeningUrl']
Write-Host ("PVSS Log Watch {0} by {1}" -f $script:Version, $script:Author) -ForegroundColor Cyan
Write-Host ("Listening: {0}" -f $url) -ForegroundColor Green
Write-Host ("Config: {0}  (refresh={1}s, port prefer={2})" -f $script:ConfigPath, $script:RefreshSeconds, $Port) -ForegroundColor DarkGray
if ($script:ConfigWarnings -and $script:ConfigWarnings.Count -gt 0) {
    Write-Host 'Config issues (invalid values reset to defaults in watch-config.txt):' -ForegroundColor Yellow
    foreach ($w in $script:ConfigWarnings) {
        Write-Host ("  - {0}" -f $w) -ForegroundColor Yellow
    }
}
Write-Host 'Log access: FileAccess.Read only (share allows WinCC to append).' -ForegroundColor DarkGray
Write-Host 'Ctrl+C to stop.' -ForegroundColor DarkGray

if ($script:OpenBrowser) {
    Open-WatchBrowser -Url $url -Choice $script:BrowserChoice
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



