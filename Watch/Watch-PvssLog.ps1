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
    [ValidateRange(1, 525600)]
    [int]$LastMinutes = 60,
    [ValidateRange(1, 60)]
    [int]$RefreshSeconds = 3,
    [switch]$NoBrowser,
    [switch]$NoPause,
    [ValidateRange(5, 100)]
    [int]$TopN = 10,
    [ValidateRange(0, 5)]
    [int]$SamplePerPattern = 1,
    [ValidateRange(100, 2000)]
    [int]$SampleMaxChars = 500,

    # --- batch report mode (2.4; -Port / -NoBrowser / -RefreshSeconds are ignored here) ---
    [switch]$Report,
    [string]$OutPath = '',
    [ValidateSet('Text', 'Html', 'Both')]
    [string]$Format = 'Both',
    [ValidateSet('All', 'Severity', 'Driver')]
    [string]$Organize = 'All',
    [string]$Severities = '',
    [string]$Areas = '',
    [string]$Driver = '',
    [switch]$Entire,
    [string]$From = '',
    [string]$To = '',
    [ValidateRange(0, 8760)]
    [int]$LastHours = 0,
    [switch]$Interactive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:UiRoot = Join-Path $script:Root 'ui'
$script:ConfigPath = Join-Path $script:Root 'watch-config.txt'
$script:Version = (Get-Content (Join-Path $script:Root 'VERSION.txt') -ErrorAction SilentlyContinue | Select-Object -First 1)
if (-not $script:Version) { $script:Version = '2.3' }
$script:Author = 'Cisum'
foreach ($verLine in @(Get-Content (Join-Path $script:Root 'VERSION.txt') -ErrorAction SilentlyContinue)) {
    if ($verLine -match '^\s*Author\s*:\s*(.+)\s*$') { $script:Author = $Matches[1].Trim(); break }
}

$script:RulesPath = Join-Path $script:Root 'PvssRules.ps1'
if (-not (Test-Path -LiteralPath $script:RulesPath)) {
    throw "Missing detection rules: $script:RulesPath. Re-copy the Watch folder."
}
. $script:RulesPath

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
        DefaultAreas          = @('SYS', 'IMPL', 'CTRL', 'PARAM', 'OTHER')
        TopN                  = 10
        SamplePerPattern      = 1
        SampleMaxChars        = 500
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
        'DefaultAreas' { return ((@($Value) | ForEach-Object { "$_" }) -join ',') }
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
        'DefaultWindowMinutes', 'DefaultWindowEntire', 'DefaultSeverities', 'DefaultAreas',
        'TopN', 'SamplePerPattern', 'SampleMaxChars', 'BacFlapMin', 'LogPath'
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
            'DefaultAreas' {
                $rawParts = @($val -split ',' | ForEach-Object { $_.Trim().ToUpperInvariant() } | Where-Object { $_ })
                $good = New-Object System.Collections.Generic.List[string]
                $bad = New-Object System.Collections.Generic.List[string]
                foreach ($p in $rawParts) {
                    if ($p -match '^(SYS|IMPL|CTRL|PARAM|OTHER)$') {
                        if (-not $good.Contains($p)) { [void]$good.Add($p) }
                    }
                    else { [void]$bad.Add($p) }
                }
                if ($good.Count -gt 0) {
                    $cfg.DefaultAreas = @($good)
                    if ($bad.Count -gt 0) {
                        [void]$warnings.Add(("DefaultAreas dropped unknown token(s): {0}; kept {1}" -f ($bad -join ','), ($good -join ',')))
                        $corrections[$key] = @($good)
                    }
                }
                else {
                    [void]$warnings.Add(("DefaultAreas='{0}' invalid; reset to {1}" -f $val, (($defaults.DefaultAreas) -join ',')))
                    $cfg.DefaultAreas = @($defaults.DefaultAreas)
                    $corrections[$key] = @($defaults.DefaultAreas)
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
            'SampleMaxChars' {
                $n = 0
                if ([int]::TryParse($val, [ref]$n) -and $n -ge 100 -and $n -le 2000) { $cfg.SampleMaxChars = $n }
                else {
                    [void]$warnings.Add(("SampleMaxChars='{0}' invalid (need integer 100-2000); reset to {1}" -f $val, $defaults.SampleMaxChars))
                    $cfg.SampleMaxChars = $defaults.SampleMaxChars
                    $corrections[$key] = $defaults.SampleMaxChars
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
# Snapshot which parameters came from the command line; $PSBoundParameters is
# only visible here, and Apply-WatchConfig must keep honouring CLI precedence
# when the dashboard Restart re-reads the file.
$script:CliOverrides = @{}
foreach ($cliKey in $PSBoundParameters.Keys) { $script:CliOverrides["$cliKey"] = $true }

# Shared by -Severities / -Areas and the interactive severity prompt. Accepts names or the
# 1-based numbers the V1.3 menu printed ("1,2,3" == the critical pack).
function script:Convert-ToSeverityList {
    param([string]$Text)
    $all = @('FATAL', 'SEVERE', 'ERROR', 'WARNING', 'INFO')
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($part in (([string]$Text) -split '[,;\s]+')) {
        $p = $part.Trim().ToUpperInvariant()
        if (-not $p) { continue }
        if ($p -eq 'WARN') { $p = 'WARNING' }
        if ($p -match '^[1-5]$') { $p = $all[[int]$p - 1] }
        if ($all -contains $p -and -not $out.Contains($p)) { [void]$out.Add($p) }
    }
    # Preserve canonical order regardless of how the operator typed it.
    return @($all | Where-Object { $out.Contains($_) })
}

function script:Convert-ToAreaList {
    param([string]$Text)
    $all = @('SYS', 'IMPL', 'CTRL', 'PARAM', 'OTHER')
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($part in (([string]$Text) -split '[,;\s]+')) {
        $p = $part.Trim().ToUpperInvariant()
        if (-not $p) { continue }
        if ($p -match '^[1-5]$') { $p = $all[[int]$p - 1] }
        if ($all -contains $p -and -not $out.Contains($p)) { [void]$out.Add($p) }
    }
    return @($all | Where-Object { $out.Contains($_) })
}

function script:Apply-WatchConfig {
    # -Runtime re-reads watch-config.txt on a dashboard Restart. Port, MaxPortTries,
    # OpenBrowser and Browser are startup-only (the listener is already bound), so
    # they are skipped and reported instead of applied.
    param([switch]$Runtime)

    $before = $null
    if ($Runtime) {
        $before = [ordered]@{
            RefreshSeconds       = "$($script:RefreshSeconds)"
            TopN                 = "$($script:TopN)"
            SamplePerPattern     = "$($script:SamplePerPattern)"
            SampleMaxChars       = "$($script:SampleMaxChars)"
            BacFlapMin           = "$($script:BacFlapMin)"
            DefaultSeverities    = (@($script:DefaultSeverities) -join ',')
            DefaultAreas         = (@($script:DefaultAreas) -join ',')
            DefaultWindowMinutes = "$($script:LastMinutes)"
            DefaultWindowEntire  = "$($script:DefaultWindowEntire)"
            LogPath              = "$($script:PrefillPath)"
        }
    }

    $load = Read-WatchConfig
    $script:Config = $load.Config
    if ($load.Corrections -and $load.Corrections.Count -gt 0) {
        try { Set-WatchConfigKeys -Updates $load.Corrections } catch { }
    }
    $script:ConfigWarnings = @($load.Warnings)

    $cli = $script:CliOverrides
    if (-not $cli.ContainsKey('LastMinutes')) { $script:LastMinutes = [int]$script:Config.DefaultWindowMinutes }
    if (-not $cli.ContainsKey('RefreshSeconds')) { $script:RefreshSeconds = [int]$script:Config.RefreshSeconds }
    if (-not $cli.ContainsKey('TopN')) { $script:TopN = [int]$script:Config.TopN }
    if (-not $cli.ContainsKey('SamplePerPattern')) { $script:SamplePerPattern = [int]$script:Config.SamplePerPattern }
    if (-not $cli.ContainsKey('SampleMaxChars')) { $script:SampleMaxChars = [int]$script:Config.SampleMaxChars }
    $script:BacFlapMin = [int]$script:Config.BacFlapMin
    # -Severities / -Areas / -Entire shadow these three, so they need the same CLI guard as
    # the numeric settings above or a dashboard Restart would silently undo the switch.
    $cliSevs = @()
    $cliAreas = @()
    if ($cli.ContainsKey('Severities')) { $cliSevs = @(Convert-ToSeverityList -Text $Severities) }
    if ($cli.ContainsKey('Areas')) { $cliAreas = @(Convert-ToAreaList -Text $Areas) }
    if ($cliSevs.Count -gt 0) { $script:DefaultSeverities = $cliSevs }
    else { $script:DefaultSeverities = @($script:Config.DefaultSeverities) }
    if ($cliAreas.Count -gt 0) { $script:DefaultAreas = $cliAreas }
    else { $script:DefaultAreas = @($script:Config.DefaultAreas) }
    if ($cli.ContainsKey('Entire')) { $script:DefaultWindowEntire = [bool]$Entire }
    else { $script:DefaultWindowEntire = [bool]$script:Config.DefaultWindowEntire }
    if ($script:SampleMaxChars -lt 100) { $script:SampleMaxChars = 100 }
    if ($script:SampleMaxChars -gt 2000) { $script:SampleMaxChars = 2000 }
    if ($script:RefreshSeconds -lt 1) { $script:RefreshSeconds = 1 }
    if ($script:RefreshSeconds -gt 60) { $script:RefreshSeconds = 60 }

    if (-not $Runtime) {
        if (-not $cli.ContainsKey('Port')) { $script:Port = [int]$script:Config.PreferredPort }
        $script:MaxPortTries = [int]$script:Config.MaxPortTries
        $script:OpenBrowser = [bool]$script:Config.OpenBrowser
        if ($cli.ContainsKey('NoBrowser')) { $script:OpenBrowser = -not [bool]$NoBrowser }
        $script:BrowserChoice = [string]$script:Config.Browser
    }

    if ($cli.ContainsKey('LogPath') -and -not [string]::IsNullOrWhiteSpace([string]$script:LogPath)) {
        $script:PrefillPath = ([string]$script:LogPath).Trim()
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$script:Config.LogPath)) {
        $script:PrefillPath = ([string]$script:Config.LogPath).Trim()
    }
    else { $script:PrefillPath = '' }

    $changes = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[string]
    if ($Runtime) {
        $after = [ordered]@{
            RefreshSeconds       = "$($script:RefreshSeconds)"
            TopN                 = "$($script:TopN)"
            SamplePerPattern     = "$($script:SamplePerPattern)"
            SampleMaxChars       = "$($script:SampleMaxChars)"
            BacFlapMin           = "$($script:BacFlapMin)"
            DefaultSeverities    = (@($script:DefaultSeverities) -join ',')
            DefaultAreas         = (@($script:DefaultAreas) -join ',')
            DefaultWindowMinutes = "$($script:LastMinutes)"
            DefaultWindowEntire  = "$($script:DefaultWindowEntire)"
            LogPath              = "$($script:PrefillPath)"
        }
        foreach ($k in @($after.Keys)) {
            $old = [string]$before[$k]
            $new = [string]$after[$k]
            if ($old -ne $new) {
                $oldLabel = if ([string]::IsNullOrEmpty($old)) { '(empty)' } else { $old }
                $newLabel = if ([string]::IsNullOrEmpty($new)) { '(empty)' } else { $new }
                [void]$changes.Add(("{0}: {1} -> {2}" -f $k, $oldLabel, $newLabel))
            }
        }
        if (-not $cli.ContainsKey('Port') -and [int]$script:Config.PreferredPort -ne [int]$script:Port) {
            [void]$skipped.Add(("PreferredPort={0} needs a host restart (still on {1})" -f `
                        [int]$script:Config.PreferredPort, [int]$script:Sync['BoundPort']))
        }
        $script:Sync['PrefillPath'] = "$($script:PrefillPath)"
    }

    return [ordered]@{
        Changes  = @($changes)
        Skipped  = @($skipped)
        Warnings = @($script:ConfigWarnings)
    }
}

[void](Apply-WatchConfig)

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
    if ($t.Length -gt $script:SampleMaxChars) { $t = $t.Substring(0, $script:SampleMaxChars) + '...' }
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
        $max = if ($script:SampleMaxChars -gt 0) { [int]$script:SampleMaxChars } else { 500 }
        $sample = if ($Line.Length -gt $max) { $Line.Substring(0, $max) + '...' } else { $Line }
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

# Operator input, not log text. Log lines only ever reach ConvertFrom-LogTimestamp above,
# whose single format is all $script:LineRe can produce; -From / -To and the [W] prompt are
# free-form, which is what the wider list here is for (PRD 5.4).
function script:ConvertFrom-UserTimestamp {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = $Text.Trim()
    $formats = @(
        'yyyy.MM.dd HH:mm:ss.fff', 'yyyy.MM.dd HH:mm:ss', 'yyyy.MM.dd HH:mm', 'yyyy.MM.dd',
        'yyyy-MM-dd HH:mm:ss.fff', 'yyyy-MM-dd HH:mm:ss', 'yyyy-MM-dd HH:mm', 'yyyy-MM-dd'
    )
    foreach ($f in $formats) {
        $dt = [datetime]::MinValue
        if ([datetime]::TryParseExact($t, $f, [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::None, [ref]$dt)) {
            return $dt
        }
    }
    $dt2 = [datetime]::MinValue
    if ([datetime]::TryParse($t, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeLocal, [ref]$dt2)) {
        return $dt2
    }
    return $null
}

function script:Convert-WindowBound {
    param(
        [string]$Text,
        [ValidateSet('From', 'To')]
        [string]$Kind
    )
    $dt = ConvertFrom-UserTimestamp -Text $Text
    if ($null -eq $dt) {
        throw "Invalid -$Kind value '$Text'. Use e.g. '2026.09.04 09:00' or '2026.09.04'."
    }
    # A date-only -To means through the end of that calendar day, not midnight.
    if ($Kind -eq 'To' -and $Text -notmatch '\d{1,2}:\d{2}') {
        $dt = $dt.Date.AddDays(1).AddMilliseconds(-1)
    }
    return $dt
}

function script:Format-LogDateTime {
    param([datetime]$Value)
    return $Value.ToString('yyyy.MM.dd HH:mm:ss')
}

function Get-MinuteKey {
    param([string]$Ts)
    if ($Ts.Length -ge 16) { return $Ts.Substring(0, 16) }
    return $Ts
}

function New-EmptyState {
    $areaKeys = @('SYS', 'IMPL', 'CTRL', 'PARAM', 'OTHER')
    $sevKeys = @('FATAL', 'SEVERE', 'ERROR', 'WARNING', 'INFO')
    $patternsByArea = @{}
    $patternSampleByArea = @{}
    $patternTimeByArea = @{}
    foreach ($a in $areaKeys) {
        $patternsByArea[$a] = @{}
        $patternSampleByArea[$a] = @{}
        $patternTimeByArea[$a] = @{}
        foreach ($s in $sevKeys) {
            $patternsByArea[$a][$s] = @{}
            $patternSampleByArea[$a][$s] = @{}
            $patternTimeByArea[$a][$s] = @{}
        }
    }
    return @{
        Severity          = @{}
        SeverityByArea    = @{}
        AreaCounts        = @{ SYS = 0; IMPL = 0; CTRL = 0; PARAM = 0; OTHER = 0 }
        AreaOtherNames    = @{}
        Components        = @{}
        ComponentsByArea  = @{}
        CompSev           = @{}
        PatternsBySev     = @{ FATAL = @{}; SEVERE = @{}; ERROR = @{}; WARNING = @{}; INFO = @{} }
        PatternSampleBySev = @{ FATAL = @{}; SEVERE = @{}; ERROR = @{}; WARNING = @{}; INFO = @{} }
        PatternTimeBySev  = @{ FATAL = @{}; SEVERE = @{}; ERROR = @{}; WARNING = @{}; INFO = @{} }
        PatternsByArea    = $patternsByArea
        PatternSampleByArea = $patternSampleByArea
        PatternTimeByArea = $patternTimeByArea
        CompPatterns      = @{}
        CompPatternSamples = @{}
        CompPatternTimes  = @{}
        PerfCats          = @{}
        Hits              = @{}  # ruleId -> count
        HitBuckets        = @{}  # ruleId -> bucketName -> value -> count
        HitMeasures       = @{}  # ruleId -> measureName -> aggregate
        HitSevs           = @{}  # ruleId -> severity -> count
        HitSample         = @{}  # sampleSlot -> first matching line
        HitTime           = @{}  # ruleId -> @{ First; Last }
        ByMinute          = @{}  # minuteKey -> counts
        ByMinuteByArea    = @{}  # minuteKey -> area -> counts
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
        LoadUpperCompare  = ''
        WindowFrom     = $null
        WindowTo       = $null
        BatchMode      = $false
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
    # The cache only pays off across dashboard window switches; batch mode exits right after
    # the scan, so cloning the whole state would be pure cost.
    if ([bool]$script:Sync['BatchMode']) { return }
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

function script:Normalize-AreaKey {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return 'OTHER' }
    $a = $Raw.Trim().ToUpperInvariant()
    if ($a -eq 'SYS' -or $a -eq 'IMPL' -or $a -eq 'CTRL' -or $a -eq 'PARAM') { return $a }
    return 'OTHER'
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

function script:Ensure-MinuteArea {
    param([hashtable]$Data, [string]$Key, [string]$Area)
    if (-not $Data.ByMinuteByArea.ContainsKey($Key)) {
        $Data.ByMinuteByArea[$Key] = @{}
    }
    $byArea = $Data.ByMinuteByArea[$Key]
    if (-not $byArea.ContainsKey($Area)) {
        $byArea[$Area] = @{
            FATAL = 0; SEVERE = 0; ERROR = 0; WARNING = 0; INFO = 0
            bacFailed = 0; bacOk = 0; projectRestart = 0
        }
    }
    return $byArea[$Area]
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
        [string]$CutoffCompare = '',
        [string]$UpperCompare = ''
    )
    if ($null -eq $Data) { $Data = $script:Sync['Data'] }
    $m = $script:LineRe.Match($Line)
    if (-not $m.Success) {
        $Data.UnparsedLines++
        return
    }
    $comp = $m.Groups[1].Value.Trim()
    $ts = $m.Groups[2].Value
    $areaRaw = $m.Groups[3].Value.Trim()
    $areaKey = Normalize-AreaKey -Raw $areaRaw
    $sev = $m.Groups[4].Value.Trim().ToUpperInvariant()
    if ($sev -eq 'WARN') { $sev = 'WARNING' }

    # String compare is far cheaper than Get-Date (V1.1 skips timestamp parse on full-file scans).
    if ($EnforceCutoff -and $CutoffCompare -and $ts.Length -ge 19 -and $ts.Substring(0, 19) -lt $CutoffCompare) {
        return
    }
    # Upper bound (-To, batch only). Timestamps are not strictly monotonic across managers,
    # so this filters rather than stopping the read early.
    if ($UpperCompare -and $ts.Length -ge 19 -and $ts.Substring(0, 19) -gt $UpperCompare) {
        return
    }

    $Data.ParsedLines++
    if (-not $Data.FirstTs) { $Data.FirstTs = $ts }
    $Data.LastTs = $ts
    if (-not $Data.Severity.ContainsKey($sev)) { $Data.Severity[$sev] = 0 }
    $Data.Severity[$sev]++
    if (-not $Data.AreaCounts.ContainsKey($areaKey)) { $Data.AreaCounts[$areaKey] = 0 }
    $Data.AreaCounts[$areaKey]++
    if ($areaKey -eq 'OTHER' -and $areaRaw) {
        Add-CountMap -Map $Data.AreaOtherNames -Key $areaRaw
    }
    if (-not $Data.SeverityByArea.ContainsKey($areaKey)) { $Data.SeverityByArea[$areaKey] = @{} }
    if (-not $Data.SeverityByArea[$areaKey].ContainsKey($sev)) { $Data.SeverityByArea[$areaKey][$sev] = 0 }
    $Data.SeverityByArea[$areaKey][$sev]++
    if (-not $Data.Components.ContainsKey($comp)) { $Data.Components[$comp] = 0 }
    $Data.Components[$comp]++
    if (-not $Data.ComponentsByArea.ContainsKey($areaKey)) { $Data.ComponentsByArea[$areaKey] = @{} }
    if (-not $Data.ComponentsByArea[$areaKey].ContainsKey($comp)) { $Data.ComponentsByArea[$areaKey][$comp] = 0 }
    $Data.ComponentsByArea[$areaKey][$comp]++
    if (-not $Data.CompSev.ContainsKey($comp)) { $Data.CompSev[$comp] = @{} }
    if (-not $Data.CompSev[$comp].ContainsKey($sev)) { $Data.CompSev[$comp][$sev] = 0 }
    $Data.CompSev[$comp][$sev]++

    $mk = if ($ts.Length -ge 16) { $ts.Substring(0, 16) } else { $ts }
    $bucket = Ensure-Minute -Data $Data -Key $mk
    $bucketArea = Ensure-MinuteArea -Data $Data -Key $mk -Area $areaKey
    if ($bucket.ContainsKey($sev)) { $bucket[$sev]++; $bucketArea[$sev]++ }

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
        if ($Data.PatternsByArea.ContainsKey($areaKey) -and $Data.PatternsByArea[$areaKey].ContainsKey($sevBucket)) {
            Add-Pattern -CountMap $Data.PatternsByArea[$areaKey][$sevBucket] -SampleMap $Data.PatternSampleByArea[$areaKey][$sevBucket] `
                -TimeMap $Data.PatternTimeByArea[$areaKey][$sevBucket] -Norm $norm -Line $Line -Timestamp $ts -SampleLimit $SamplePerPattern
        }
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
        if ($Data.PatternsByArea.ContainsKey($areaKey) -and $Data.PatternsByArea[$areaKey].ContainsKey('INFO')) {
            Add-Pattern -CountMap $Data.PatternsByArea[$areaKey]['INFO'] -SampleMap $Data.PatternSampleByArea[$areaKey]['INFO'] `
                -TimeMap $Data.PatternTimeByArea[$areaKey]['INFO'] -Norm $norm -Line $Line -Timestamp $ts -SampleLimit $SamplePerPattern
        }
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
            $bucketArea.bacFailed++
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
                $bucketArea.bacOk++
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

    # Declarative detections (PvssRules.ps1). Loop is inlined on purpose - see the note there.
    $ruleSet = $script:RuleSetCache[$comp]
    if ($null -eq $ruleSet) { $ruleSet = Register-RuleSet -Comp $comp }
    $isCnsLine = $false
    foreach ($rule in $ruleSet) {
        $rm = $rule['Re'].Match($Line)
        if (-not $rm.Success) { continue }
        Add-RuleHit -Data $Data -Rule $rule -Match $rm -Line $Line -Comp $comp -Area $areaKey -Sev $sev -Timestamp $ts
        if ($rule['PatternGroup'] -eq 'Cns') { $isCnsLine = $true }
    }
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

    # WCCOAApogeeDrv (not ApogeeBACnet / CoHo.Apogee*). Line count only - the driver's
    # detections are rules in PvssRules.ps1 and were already applied above.
    if ($comp.IndexOf('ApogeeDrv', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        $Data.ApogeeDrvLines++
    }

    # Project / manager lifecycle (pmon + Manager Start/Stop)
    if ($script:ReProjectUp.IsMatch($Line)) {
        $Data.ProjectUp++
        $bucket.projectRestart = 1
        $bucketArea.projectRestart = 1
        if ($Data.ProjectRestartEvents.Count -lt 200) {
            [void]$Data.ProjectRestartEvents.Add([ordered]@{ t = $ts; kind = 'up'; area = $areaKey; sample = $Line })
        }
    }
    if ($script:ReProjectStartMode.IsMatch($Line)) { $Data.ProjectStartMode++ }
    if ($script:ReProjectShutdown.IsMatch($Line)) {
        $Data.ProjectShutdown++
        if ($Data.ProjectRestartEvents.Count -lt 200) {
            [void]$Data.ProjectRestartEvents.Add([ordered]@{ t = $ts; kind = 'shutdown'; area = $areaKey; sample = $Line })
        }
    }
    if ($script:ReProjectStopped.IsMatch($Line)) {
        $Data.ProjectStopped++
        if ($Data.ProjectRestartEvents.Count -lt 200) {
            [void]$Data.ProjectRestartEvents.Add([ordered]@{ t = $ts; kind = 'stopped'; area = $areaKey; sample = $Line })
        }
    }
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

# One implementation of "is this a usable log file", shared by POST /api/logPath and batch
# mode. Returns the resolved full path; throws the operator-facing message on failure.
function script:Assert-LogPathUsable {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Path is required.' }
    if (-not (Test-Path -LiteralPath $Path)) { throw "File not found: $Path" }
    $item = Get-Item -LiteralPath $Path
    if ($item.PSIsContainer) { throw 'Path must be a file, not a directory.' }
    $test = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $test.Close()
    return $item.FullName
}

# Batch mode may be launched by double-clicking a .cmd next to a log, so fall back to the
# same discovery order OfflineAnalyze used.
function script:Resolve-LogPath {
    param([string]$Path)
    if ($Path) { return (Assert-LogPathUsable -Path $Path) }

    $searchDirs = @($script:Root, (Split-Path -Parent $script:Root), (Get-Location).Path) |
        Where-Object { $_ } | Select-Object -Unique
    foreach ($name in @('PVSS_II.log', 'PVSS_II.log.bak')) {
        foreach ($dir in $searchDirs) {
            $cand = Join-Path $dir $name
            if (Test-Path -LiteralPath $cand -PathType Leaf) {
                if ($name -ne 'PVSS_II.log') { Write-WatchLog ("Using backup log: {0}" -f $cand) Cyan }
                return (Assert-LogPathUsable -Path $cand)
            }
        }
    }
    $found = foreach ($dir in $searchDirs) {
        Get-ChildItem -LiteralPath $dir -Filter 'PVSS_II*.log' -File -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $dir -Filter 'PVSS_II*.log.bak' -File -ErrorAction SilentlyContinue
    }
    $newest = @($found) | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($newest) {
        Write-WatchLog ("Using newest matching log: {0}" -f $newest.FullName) Cyan
        return (Assert-LogPathUsable -Path $newest.FullName)
    }
    $hint = ($searchDirs | ForEach-Object { "  - $_" }) -join [Environment]::NewLine
    throw ("Log file not found. Looked for PVSS_II.log, PVSS_II.log.bak, PVSS_II*.log and PVSS_II*.log.bak in:{0}{1}{0}Pass -LogPath explicitly." -f [Environment]::NewLine, $hint)
}

function script:Find-WindowStartPosition {
    param(
        [string]$Path,
        [datetime]$Cutoff
    )
    $fi = Get-Item -LiteralPath $Path
    $len = $fi.Length
    if ($len -le 0) { return 0L }

    # Cheap boundary guards before probing (PRD 5.3.1): a cutoff at or before the first
    # header means the whole file is in window, and one past the last header means none of it is.
    $head = Get-ProbeTimestamps -Path $Path -SeekPos 0L -MaxBytes ([math]::Min($len, [int64]65536))
    if ($head.First -and $head.First -ge $Cutoff) {
        Write-WatchLog ("Window seek short-circuit: cutoff at/before first timestamp {0:yyyy.MM.dd HH:mm:ss}" -f $head.First)
        return 0L
    }
    $tail = Get-LogFileEndTimestamp -Path $Path
    if ($tail -and $tail -lt $Cutoff) {
        throw ("Empty window: the log ends at {0:yyyy.MM.dd HH:mm:ss}, before the requested start {1:yyyy.MM.dd HH:mm:ss}." -f $tail, $Cutoff)
    }

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

    # Absolute -From/-To (batch only) outranks both entire and last-N-minutes.
    $absFrom = $script:Sync['WindowFrom']
    $absTo = $script:Sync['WindowTo']
    $absolute = ($null -ne $absFrom -or $null -ne $absTo)
    $entire = (-not $absolute) -and [bool]$script:Sync['WindowEntire']
    $mode = if ($absolute) {
        ('absolute {0} -> {1}' -f $(if ($absFrom) { Format-LogDateTime -Value $absFrom } else { 'start' }),
            $(if ($absTo) { Format-LogDateTime -Value $absTo } else { 'end' }))
    }
    elseif ($entire) { 'Entire file' }
    else { ("last {0} minutes" -f $script:Sync['LastMinutes']) }
    Write-WatchLog ("Catch-up START  mode={0}  path={1}" -f $mode, $Path) Cyan
    $script:Sync['LoadModeLabel'] = if ($absolute) { 'Loading absolute window' }
    elseif ($entire) { 'Loading entire file' }
    else { ("Loading last {0} minutes" -f $script:Sync['LastMinutes']) }
    $script:Sync['LoadMessage'] = ("{0}... 0%" -f $script:Sync['LoadModeLabel'])

    Reset-Analysis
    $cutoff = [datetime]::MinValue
    $enforce = $false
    $startPos = 0L
    $upperCompare = ''
    if ($absolute) {
        if ($absTo) { $upperCompare = Format-LogDateTime -Value $absTo }
        if ($absFrom) {
            $cutoff = $absFrom
            $enforce = $true
            $script:Sync['Cutoff'] = $cutoff
            $startPos = Find-WindowStartPosition -Path $Path -Cutoff $cutoff
        }
        else { $script:Sync['Cutoff'] = $null }
    }
    elseif (-not $entire) {
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
    $script:Sync['LoadUpperCompare'] = $upperCompare
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
        $upperCmp = [string]$script:Sync['LoadUpperCompare']
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
            Process-LogLine -Line $line -Data $data -EnforceCutoff:$enforce -CutoffCompare $cutoffCmp -UpperCompare $upperCmp
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
    $cnsResolve = Get-RuleCount -Data $d -Id 'cns.resolveNodes'
    $cnsReduced = Get-RuleCount -Data $d -Id 'cns.reducedFunction'
    $cnsRenew = Get-RuleCount -Data $d -Id 'cns.tryRenew'
    if ($cnsResolve -ge 100 -or $cnsReduced -ge 100) {
        [void]$findings.Add(("CNS volume: ResolveNodes={0:N0}, ReducedFunction={1:N0}, ICns={2:N0}." -f $cnsResolve, $cnsReduced, (Get-RuleCount -Data $d -Id 'cns.icns')))
    }
    if ($cnsRenew -ge 5) { [void]$findings.Add(("CNS/session: TryRenewSession hits={0:N0}." -f $cnsRenew)) }
    if ($d.CohoStuck -ge 10) { [void]$findings.Add(("CoHo stuck/drop messages: {0:N0}." -f $d.CohoStuck)) }
    if ($d.ApogeeUpdatePoints -ge 10) {
        [void]$findings.Add(("Apogee UpdatePoints failures: {0:N0} across {1:N0} PPCL programs." -f $d.ApogeeUpdatePoints, $d.ApogeePpcl.Count))
    }
    $apOverflow = Get-RuleCount -Data $d -Id 'apogeeDrv.trendOverflow'
    $apAlert = Get-RuleCount -Data $d -Id 'apogeeDrv.alertId'
    $apGetData = Get-RuleCount -Data $d -Id 'apogeeDrv.getDataFail'
    $apTimeout = Get-RuleCount -Data $d -Id 'apogeeDrv.queryTimeout'
    if ($apOverflow -ge 50) {
        [void]$findings.Add(("ApogeeDrv trend buffer overflows: {0:N0} across {1:N0} devices ({2:N0} sequence-gap lines)." -f `
                $apOverflow, (Get-RuleBucketCount -Data $d -Id 'apogeeDrv.trendOverflow' -Name 'device'), (Get-RuleCount -Data $d -Id 'apogeeDrv.trendSeq')))
    }
    if ($apAlert -ge 50) {
        [void]$findings.Add(("ApogeeDrv AlertID issues: {0:N0}." -f $apAlert))
    }
    if ($apGetData -ge 50) {
        [void]$findings.Add(("ApogeeDrv get-data failures: {0:N0} across {1:N0} devices." -f `
                $apGetData, (Get-RuleBucketCount -Data $d -Id 'apogeeDrv.getDataFail' -Name 'device')))
    }
    if ($apTimeout -ge 50) {
        [void]$findings.Add(("ApogeeDrv query timeouts: {0:N0}." -f $apTimeout))
    }
    if ($d.ProjectUp -ge 1 -or $d.ProjectStopped -ge 1) {
        $upPreview = @($d.ProjectRestartEvents | Where-Object { $_.kind -eq 'up' } | Select-Object -First 5 | ForEach-Object { $_.t }) -join ', '
        $line = ("Project lifecycle (pmon): up={0:N0}, stopped={1:N0}, shutdown cmds={2:N0}, START_MODE={3:N0}." -f `
            $d.ProjectUp, $d.ProjectStopped, $d.ProjectShutdown, $d.ProjectStartMode)
        if ($upPreview) { $line += (" First ups: {0}." -f $upPreview) }
        [void]$findings.Add($line)
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

    # Rule-driven headlines. A rule opts in with FindingAt = <count>; the migrated CNS and
    # Apogee clusters keep their hand-written composite findings above and set no threshold.
    foreach ($rule in $script:PvssRules) {
        $at = $rule['FindingAt']
        if (-not $at) { continue }
        $id = [string]$rule['Id']
        $n = Get-RuleCount -Data $d -Id $id
        if ($n -lt [int]$at) { continue }
        $line = "{0} - {1}: {2:N0} line(s)." -f $rule['Group'], $rule['Label'], $n
        $mm = $d.HitMeasures[$id]
        if ($mm -and $mm.Count -gt 0) {
            $parts = @(@($mm.Keys | Sort-Object) | ForEach-Object { "{0}={1:N0}" -f $_, $mm[$_] }) -join ', '
            $line += " Totals: $parts."
        }
        $bb = $rule['BucketBy']
        if ($bb -and $bb.Count -gt 0) {
            $bname = @($bb.Keys | Sort-Object)[0]
            $top = @(Get-RuleTopBucket -Data $d -Id $id -Name $bname -KeyName 'value' -N 3 |
                    ForEach-Object { "{0} x{1:N0}" -f $_.value, $_.count }) -join ', '
            if ($top) { $line += " Top $bname`: $top." }
        }
        [void]$findings.Add($line)
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

function script:Parse-QueryAreas {
    param([System.Collections.Specialized.NameValueCollection]$Q)
    $raw = $Q['areas']
    $set = @{}
    foreach ($a in @('SYS', 'IMPL', 'CTRL', 'PARAM', 'OTHER')) { $set[$a] = $false }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        foreach ($a in @('SYS', 'IMPL', 'CTRL', 'PARAM', 'OTHER')) { $set[$a] = $true }
        return $set
    }
    foreach ($part in ($raw -split ',')) {
        $p = $part.Trim().ToUpperInvariant()
        if ($set.ContainsKey($p)) { $set[$p] = $true }
    }
    return $set
}

function script:Test-AreaFilterAllOn {
    param($AreaFilter)
    foreach ($a in @('SYS', 'IMPL', 'CTRL', 'PARAM', 'OTHER')) {
        if (-not $AreaFilter[$a]) { return $false }
    }
    return $true
}

function script:Get-EnabledAreas {
    param($AreaFilter)
    $out = @()
    foreach ($a in @('SYS', 'IMPL', 'CTRL', 'PARAM', 'OTHER')) {
        if ($AreaFilter[$a]) { $out += $a }
    }
    return $out
}

function script:Get-FilteredSeverityCounts {
    param($Data, $AreaFilter)
    $sevCounts = [ordered]@{}
    foreach ($s in @('FATAL', 'SEVERE', 'ERROR', 'WARNING', 'INFO')) { $sevCounts[$s] = 0 }
    if (Test-AreaFilterAllOn -AreaFilter $AreaFilter) {
        foreach ($s in @('FATAL', 'SEVERE', 'ERROR', 'WARNING', 'INFO')) {
            if ($Data.Severity.ContainsKey($s)) { $sevCounts[$s] = [int]$Data.Severity[$s] }
        }
        return $sevCounts
    }
    foreach ($a in (Get-EnabledAreas -AreaFilter $AreaFilter)) {
        if (-not $Data.SeverityByArea.ContainsKey($a)) { continue }
        foreach ($s in @('FATAL', 'SEVERE', 'ERROR', 'WARNING', 'INFO')) {
            if ($Data.SeverityByArea[$a].ContainsKey($s)) {
                $sevCounts[$s] = [int]$sevCounts[$s] + [int]$Data.SeverityByArea[$a][$s]
            }
        }
    }
    return $sevCounts
}

function script:Get-FilteredTopManagers {
    param($Data, $AreaFilter, [int]$N = 20)
    if (Test-AreaFilterAllOn -AreaFilter $AreaFilter) {
        return @(
            $Data.Components.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $N | ForEach-Object {
                [ordered]@{ name = $_.Key; count = [int]$_.Value }
            }
        )
    }
    $acc = @{}
    foreach ($a in (Get-EnabledAreas -AreaFilter $AreaFilter)) {
        if (-not $Data.ComponentsByArea.ContainsKey($a)) { continue }
        foreach ($e in $Data.ComponentsByArea[$a].GetEnumerator()) {
            if (-not $acc.ContainsKey($e.Key)) { $acc[$e.Key] = 0 }
            $acc[$e.Key] = [int]$acc[$e.Key] + [int]$e.Value
        }
    }
    return @(
        $acc.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $N | ForEach-Object {
            [ordered]@{ name = $_.Key; count = [int]$_.Value }
        }
    )
}

function script:Get-FilteredTopPatterns {
    param($Data, [string]$Sev, $AreaFilter, [int]$N)
    if (Test-AreaFilterAllOn -AreaFilter $AreaFilter) {
        return @(Get-TopPatterns -CountMap $Data.PatternsBySev[$Sev] -SampleMap $Data.PatternSampleBySev[$Sev] -TimeMap $Data.PatternTimeBySev[$Sev] -N $N)
    }
    $count = @{}
    $sample = @{}
    $time = @{}
    foreach ($a in (Get-EnabledAreas -AreaFilter $AreaFilter)) {
        if (-not $Data.PatternsByArea.ContainsKey($a)) { continue }
        if (-not $Data.PatternsByArea[$a].ContainsKey($Sev)) { continue }
        $cm = $Data.PatternsByArea[$a][$Sev]
        $sm = $Data.PatternSampleByArea[$a][$Sev]
        $tm = $Data.PatternTimeByArea[$a][$Sev]
        foreach ($e in $cm.GetEnumerator()) {
            $k = $e.Key
            if (-not $count.ContainsKey($k)) { $count[$k] = 0 }
            $count[$k] = [int]$count[$k] + [int]$e.Value
            if ($null -ne $sm -and $sm.ContainsKey($k) -and $null -ne $sm[$k]) {
                if (-not $sample.ContainsKey($k)) { $sample[$k] = New-Object System.Collections.ArrayList }
                foreach ($s in @($sm[$k])) {
                    if ($sample[$k].Count -ge $SamplePerPattern) { break }
                    [void]$sample[$k].Add([string]$s)
                }
            }
            if ($null -ne $tm -and $tm.ContainsKey($k)) {
                $first = [string]$tm[$k]['First']
                $last = [string]$tm[$k]['Last']
                if (-not $time.ContainsKey($k)) {
                    $time[$k] = @{ First = $first; Last = $last }
                }
                else {
                    if ($first -and (-not $time[$k]['First'] -or $first -lt $time[$k]['First'])) { $time[$k]['First'] = $first }
                    if ($last -and (-not $time[$k]['Last'] -or $last -gt $time[$k]['Last'])) { $time[$k]['Last'] = $last }
                }
            }
        }
    }
    return @(Get-TopPatterns -CountMap $count -SampleMap $sample -TimeMap $time -N $N)
}

function script:Get-AreaCountsPayload {
    param($Data)
    $counts = [ordered]@{ SYS = 0; IMPL = 0; CTRL = 0; PARAM = 0; OTHER = 0 }
    foreach ($a in @('SYS', 'IMPL', 'CTRL', 'PARAM', 'OTHER')) {
        if ($Data.AreaCounts -and $Data.AreaCounts.ContainsKey($a)) { $counts[$a] = [int]$Data.AreaCounts[$a] }
    }
    $others = @()
    if ($Data.AreaOtherNames) {
        foreach ($e in @($Data.AreaOtherNames.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 20)) {
            $others += [ordered]@{ name = [string]$e.Key; count = [int]$e.Value }
        }
    }
    return [ordered]@{ counts = $counts; otherNames = $others }
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

# Hour rollup for the report's hourly-volume tables. Watch only keeps minute buckets, so
# truncate the minute key to the hour exactly as Build-ChartSeries does.
# V1.3 presentation rule preserved: full table at <=25 hours, otherwise the most recent 24
# plus a busiest-10 table. Unlike V1.3 this honours the area filter, so the hourly numbers
# agree with the rest of the snapshot.
function script:Build-HourlyObject {
    param($Data, $AreaFilter = $null)
    if ($null -eq $AreaFilter) {
        $AreaFilter = @{ SYS = $true; IMPL = $true; CTRL = $true; PARAM = $true; OTHER = $true }
    }
    $sevAll = @('FATAL', 'SEVERE', 'ERROR', 'WARNING', 'INFO')
    $sevBad = @('FATAL', 'SEVERE', 'ERROR')
    $acc = @{}
    $useAreaSplit = -not (Test-AreaFilterAllOn -AreaFilter $AreaFilter)
    $enabledAreas = @(Get-EnabledAreas -AreaFilter $AreaFilter)

    if ($useAreaSplit -and $Data.ByMinuteByArea) {
        foreach ($e in $Data.ByMinuteByArea.GetEnumerator()) {
            $src = $e.Key
            $key = if ($src.Length -ge 13) { $src.Substring(0, 13) } else { $src }
            if (-not $acc.ContainsKey($key)) { $acc[$key] = @{ total = 0; severe = 0; warning = 0 } }
            $dst = $acc[$key]
            foreach ($a in $enabledAreas) {
                if (-not $e.Value.ContainsKey($a)) { continue }
                $v = $e.Value[$a]
                foreach ($s in $sevAll) { $dst.total += [int]$v[$s] }
                foreach ($s in $sevBad) { $dst.severe += [int]$v[$s] }
                $dst.warning += [int]$v['WARNING']
            }
        }
    }
    else {
        foreach ($e in $Data.ByMinute.GetEnumerator()) {
            $src = $e.Key
            $key = if ($src.Length -ge 13) { $src.Substring(0, 13) } else { $src }
            if (-not $acc.ContainsKey($key)) { $acc[$key] = @{ total = 0; severe = 0; warning = 0 } }
            $dst = $acc[$key]
            $v = $e.Value
            foreach ($s in $sevAll) { $dst.total += [int]$v[$s] }
            foreach ($s in $sevBad) { $dst.severe += [int]$v[$s] }
            $dst.warning += [int]$v['WARNING']
        }
    }

    $keys = @($acc.Keys | Sort-Object)
    $hourCount = $keys.Count
    $truncated = ($hourCount -gt 25)
    $shown = if ($truncated) { @($keys | Select-Object -Last 24) } else { $keys }
    $rows = @(foreach ($k in $shown) {
            [ordered]@{ hour = $k; total = [int]$acc[$k].total; severe = [int]$acc[$k].severe; warning = [int]$acc[$k].warning }
        })
    $busiest = @()
    if ($truncated) {
        # Tie-break on the hour key so the table is reproducible run to run (PRD 10.1).
        $busiest = @(
            $acc.GetEnumerator() | Sort-Object @{ E = { $_.Value.total }; Descending = $true }, @{ E = { $_.Key } } |
                Select-Object -First 10 | ForEach-Object {
                    [ordered]@{ hour = $_.Key; total = [int]$_.Value.total; severe = [int]$_.Value.severe; warning = [int]$_.Value.warning }
                }
        )
    }
    return [ordered]@{
        hourCount = $hourCount
        truncated = $truncated
        rows      = $rows
        busiest   = $busiest
    }
}

function script:Build-ChartSeries {
    param($Data, $SevFilter, $AreaFilter = $null)
    if ($null -eq $AreaFilter) {
        $AreaFilter = @{ SYS = $true; IMPL = $true; CTRL = $true; PARAM = $true; OTHER = $true }
    }
    $gran = Get-ChartGranularity -FirstTs $Data.FirstTs -LastTs $Data.LastTs -MinuteBucketCount $Data.ByMinute.Count
    if ($gran -eq 'minute' -and $Data.ByMinute.Count -gt 400) { $gran = 'hour' }

    $acc = @{}
    $useAreaSplit = -not (Test-AreaFilterAllOn -AreaFilter $AreaFilter)
    $enabledAreas = @(Get-EnabledAreas -AreaFilter $AreaFilter)

    if ($useAreaSplit -and $Data.ByMinuteByArea) {
        foreach ($e in $Data.ByMinuteByArea.GetEnumerator()) {
            $src = $e.Key
            $key = switch ($gran) {
                'day' { if ($src.Length -ge 10) { $src.Substring(0, 10) } else { $src } }
                'hour' { if ($src.Length -ge 13) { $src.Substring(0, 13) } else { $src } }
                default { $src }
            }
            if (-not $acc.ContainsKey($key)) {
                $acc[$key] = @{
                    FATAL = 0; SEVERE = 0; ERROR = 0; WARNING = 0; INFO = 0
                    bacFailed = 0; bacOk = 0; projectRestart = 0
                }
            }
            $dst = $acc[$key]
            foreach ($a in $enabledAreas) {
                if (-not $e.Value.ContainsKey($a)) { continue }
                $v = $e.Value[$a]
                foreach ($s in @('FATAL', 'SEVERE', 'ERROR', 'WARNING', 'INFO')) { $dst[$s] += [int]$v[$s] }
                $dst.bacFailed += [int]$v.bacFailed
                $dst.bacOk += [int]$v.bacOk
                if ([int]$v.projectRestart -gt 0) { $dst.projectRestart = 1 }
            }
        }
    }
    else {
        foreach ($e in $Data.ByMinute.GetEnumerator()) {
            $src = $e.Key
            $key = switch ($gran) {
                'day' { if ($src.Length -ge 10) { $src.Substring(0, 10) } else { $src } }
                'hour' { if ($src.Length -ge 13) { $src.Substring(0, 13) } else { $src } }
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
            foreach ($s in @('FATAL', 'SEVERE', 'ERROR', 'WARNING', 'INFO')) { $dst[$s] += [int]$v[$s] }
            $dst.bacFailed += [int]$v.bacFailed
            $dst.bacOk += [int]$v.bacOk
            if ([int]$v.projectRestart -gt 0) { $dst.projectRestart = 1 }
        }
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

function script:Format-DurationLabel {
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

function script:Get-LogTimestampDeltaSec {
    param([string]$FromTs, [string]$ToTs)
    $a = ConvertFrom-LogTimestamp -Ts $FromTs
    $b = ConvertFrom-LogTimestamp -Ts $ToTs
    if (-not $a -or -not $b) { return $null }
    return ($b - $a).TotalSeconds
}

function script:Build-ProjectLifecycleCycles {
    param(
        [object[]]$Events,
        [string]$WindowFirst,
        [string]$WindowLast
    )
    $evs = @($Events | Sort-Object { [string]$_.t }, { [string]$_.kind })
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
        # Downtime is only defined when the next up is known (stopped -> next up).
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
            # Trailing still-up: show uptime through end of window (informative, not a closed cycle).
            $uptimeSec = Get-LogTimestampDeltaSec -FromTs $upT -ToTs $WindowLast
        }
        $stopSec = if ($shutdownT -and $stoppedT) { Get-LogTimestampDeltaSec -FromTs $shutdownT -ToTs $stoppedT } else { $null }
        # Downtime only when next up exists. Do not invent downtime to window end.
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

function script:Build-ProjectLifecycleObject {
    param(
        $Data,
        [object[]]$Events,
        [string]$WindowFirst,
        [string]$WindowLast
    )
    $evs = @($Events)
    $cycles = @(Build-ProjectLifecycleCycles -Events $evs -WindowFirst $WindowFirst -WindowLast $WindowLast)
    $retained = 0
    if ($Data.ProjectRestartEvents) { $retained = @($Data.ProjectRestartEvents).Count }
    elseif ($evs.Count -gt 0) { $retained = $evs.Count }
    return [ordered]@{
        up         = [int]$Data.ProjectUp
        stopped    = [int]$Data.ProjectStopped
        shutdown   = [int]$Data.ProjectShutdown
        startMode  = [int]$Data.ProjectStartMode
        cycles     = $cycles
        capped     = (($Data.ProjectUp + $Data.ProjectStopped + $Data.ProjectShutdown) -gt $retained)
    }
}

# Curated CNS / Apogee headlines. Counters come from the rule engine (PvssRules.ps1);
# the payload keys are frozen so the UI and reports are unaffected.
function script:Build-CnsHeadline {
    param($Data)
    return [ordered]@{
        resolveNodes    = (Get-RuleCount -Data $Data -Id 'cns.resolveNodes')
        reducedFunction = (Get-RuleCount -Data $Data -Id 'cns.reducedFunction')
        tryRenew        = (Get-RuleCount -Data $Data -Id 'cns.tryRenew')
        icns            = (Get-RuleCount -Data $Data -Id 'cns.icns')
    }
}

function script:Build-ApogeeHeadline {
    param($Data)
    return [ordered]@{
        events        = $Data.ApogeeEvents
        updatePoints  = $Data.ApogeeUpdatePoints
        drvLines      = $Data.ApogeeDrvLines
        trendOverflow = (Get-RuleCount -Data $Data -Id 'apogeeDrv.trendOverflow')
        trendSeq      = (Get-RuleCount -Data $Data -Id 'apogeeDrv.trendSeq')
        alertId       = (Get-RuleCount -Data $Data -Id 'apogeeDrv.alertId')
        queryTimeout  = (Get-RuleCount -Data $Data -Id 'apogeeDrv.queryTimeout')
        getDataFail   = (Get-RuleCount -Data $Data -Id 'apogeeDrv.getDataFail')
    }
}

function script:Build-PulseObject {
    param($SevFilter, $AreaFilter = $null)
    if ($null -eq $AreaFilter) {
        $AreaFilter = @{ SYS = $true; IMPL = $true; CTRL = $true; PARAM = $true; OTHER = $true }
    }
    $d = $script:Sync['Data']
    $win = if ($script:Sync['WindowEntire']) {
        [ordered]@{ mode = 'entire'; lastMinutes = 0; first = $d.FirstTs; last = $d.LastTs }
    }
    else {
        [ordered]@{ mode = 'minutes'; lastMinutes = [int]$script:Sync['LastMinutes']; first = $d.FirstTs; last = $d.LastTs }
    }
    $areaPayload = Get-AreaCountsPayload -Data $d

    # While catch-up runs, keep pulse cheap so % updates do not stall the scan.
    if ($script:Sync['Loading']) {
        $sevCounts = Get-FilteredSeverityCounts -Data $d -AreaFilter $AreaFilter
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
            areaCounts      = $areaPayload.counts
            areaOtherNames  = $areaPayload.otherNames
            moduleHeadlines = [ordered]@{
                bacnet = [ordered]@{
                    failed = $d.BacFailed; ok = $d.BacOk; endedFailed = 0; endedOk = 0; flappers = 0; objectList = $d.BacObjectList
                    collectTrend = $d.BacCollectTrend; timeSync = $d.BacTimeSync
                    collectTrendProps = $d.BacCollectTrendByProp.Count; timeSyncProps = $d.BacTimeSyncByProp.Count
                }
                cns    = (Build-CnsHeadline -Data $d)
                coho   = [ordered]@{ stuck = $d.CohoStuck }
                apogee = (Build-ApogeeHeadline -Data $d)
            }
            topManagers     = @()
            series          = [ordered]@{ granularity = 'minute'; byMinute = @() }
            projectLifecycle = [ordered]@{
                up = [int]$d.ProjectUp; stopped = [int]$d.ProjectStopped
                shutdown = [int]$d.ProjectShutdown; startMode = [int]$d.ProjectStartMode
                cycles = @(); capped = $false
            }
        }
    }

    $sevCounts = Get-FilteredSeverityCounts -Data $d -AreaFilter $AreaFilter
    $endedFailed = @($d.BacLastStatus.GetEnumerator() | Where-Object { $_.Value -eq 'Failed' }).Count
    $endedOk = @($d.BacLastStatus.GetEnumerator() | Where-Object { $_.Value -eq 'OK' }).Count
    $flappers = @($d.BacFlipByDevice.GetEnumerator() | Where-Object { $_.Value -ge $script:BacFlapMin }).Count
    $topMgr = @(Get-FilteredTopManagers -Data $d -AreaFilter $AreaFilter -N 20)
    $series = Build-ChartSeries -Data $d -SevFilter $SevFilter -AreaFilter $AreaFilter
    $projEvents = @()
    if ($d.ProjectRestartEvents) {
        $allAreas = Test-AreaFilterAllOn -AreaFilter $AreaFilter
        foreach ($ev in @($d.ProjectRestartEvents)) {
            $evArea = if ($ev.area) { [string]$ev.area } else { 'SYS' }
            if (-not $allAreas -and -not $AreaFilter[$evArea]) { continue }
            $projEvents += [ordered]@{
                t    = [string]$ev.t
                kind = [string]$ev.kind
                area = $evArea
            }
        }
    }
    $projLife = Build-ProjectLifecycleObject -Data $d -Events $projEvents `
        -WindowFirst ([string]$d.FirstTs) -WindowLast ([string]$d.LastTs)
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
        areaCounts      = $areaPayload.counts
        areaOtherNames  = $areaPayload.otherNames
        moduleHeadlines = [ordered]@{
            bacnet = [ordered]@{
                failed = $d.BacFailed; ok = $d.BacOk; endedFailed = $endedFailed; endedOk = $endedOk; flappers = $flappers; objectList = $d.BacObjectList
                collectTrend = $d.BacCollectTrend; timeSync = $d.BacTimeSync
                collectTrendProps = $d.BacCollectTrendByProp.Count; timeSyncProps = $d.BacTimeSyncByProp.Count
            }
            cns    = (Build-CnsHeadline -Data $d)
            coho   = [ordered]@{ stuck = $d.CohoStuck }
            apogee = (Build-ApogeeHeadline -Data $d)
        }
        topManagers     = $topMgr
        series          = $series
        projectLifecycle = $projLife
    }
}

function script:Build-SectionObject {
    param([string]$Name, $SevFilter, $AreaFilter = $null)
    if ($null -eq $AreaFilter) {
        $AreaFilter = @{ SYS = $true; IMPL = $true; CTRL = $true; PARAM = $true; OTHER = $true }
    }
    $d = $script:Sync['Data']
    $gen = [int]$script:Sync['Generation']
    switch ($Name.ToLowerInvariant()) {
        'patterns' {
            $p = [ordered]@{}
            foreach ($s in @('FATAL', 'SEVERE', 'ERROR', 'WARNING')) {
                if ($SevFilter[$s]) {
                    $p[$s] = @(Get-FilteredTopPatterns -Data $d -Sev $s -AreaFilter $AreaFilter -N $TopN)
                }
                else { $p[$s] = @() }
            }
            return [ordered]@{ generation = $gen; patternsBySeverity = $p }
        }
        'managers' {
            $tops = @(Get-FilteredTopManagers -Data $d -AreaFilter $AreaFilter -N 5000)
            $list = @(
                foreach ($row in $tops) {
                    $name = [string]$row.name
                    $sevMap = [ordered]@{ FATAL = 0; SEVERE = 0; ERROR = 0; WARNING = 0; INFO = 0 }
                    if ($d.CompSev.ContainsKey($name)) {
                        foreach ($k in $d.CompSev[$name].Keys) { $sevMap[$k] = [int]$d.CompSev[$name][$k] }
                    }
                    [ordered]@{ name = $name; count = [int]$row.count; severities = $sevMap }
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
                    failedDevices = $d.BacFailedByDevice.Count; okDevices = $d.BacOkByDevice.Count
                    objectListDevices = $d.BacObjectListByDevice.Count
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
                    resolveNodes = (Get-RuleCount -Data $d -Id 'cns.resolveNodes')
                    reducedFunction = (Get-RuleCount -Data $d -Id 'cns.reducedFunction')
                    icns = (Get-RuleCount -Data $d -Id 'cns.icns')
                    tryRenew = (Get-RuleCount -Data $d -Id 'cns.tryRenew')
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
            $trendDev = Get-RuleTopBucket -Data $d -Id 'apogeeDrv.trendOverflow' -Name 'device' -KeyName 'device' -N 20
            $trendNames = Get-RuleTopBucket -Data $d -Id 'apogeeDrv.trendOverflow' -Name 'trend' -KeyName 'trend' -N 20
            $getDev = Get-RuleTopBucket -Data $d -Id 'apogeeDrv.getDataFail' -Name 'device' -KeyName 'device' -N 20
            return [ordered]@{
                generation = $gen
                apogee     = [ordered]@{
                    events = $d.ApogeeEvents; updatePoints = $d.ApogeeUpdatePoints; repetition = $d.ApogeeRepetition
                    other = $d.ApogeeOther; uniquePpcl = $d.ApogeePpcl.Count; sample = $d.ApogeeSample; topPpcl = $ppcl
                    drvLines = $d.ApogeeDrvLines
                    trendOverflow = (Get-RuleCount -Data $d -Id 'apogeeDrv.trendOverflow')
                    trendSeq = (Get-RuleCount -Data $d -Id 'apogeeDrv.trendSeq')
                    alertId = (Get-RuleCount -Data $d -Id 'apogeeDrv.alertId')
                    queryTimeout = (Get-RuleCount -Data $d -Id 'apogeeDrv.queryTimeout')
                    getDataFail = (Get-RuleCount -Data $d -Id 'apogeeDrv.getDataFail')
                    trendDevices = (Get-RuleBucketCount -Data $d -Id 'apogeeDrv.trendOverflow' -Name 'device')
                    trendNames = (Get-RuleBucketCount -Data $d -Id 'apogeeDrv.trendOverflow' -Name 'trend')
                    getDataDevices = (Get-RuleBucketCount -Data $d -Id 'apogeeDrv.getDataFail' -Name 'device')
                    trendSample = (Get-RuleSample -Data $d -Id 'apogeeDrv.trend')
                    alertSample = (Get-RuleSample -Data $d -Id 'apogeeDrv.alertId')
                    timeoutSample = (Get-RuleSample -Data $d -Id 'apogeeDrv.queryTimeout')
                    getDataSample = (Get-RuleSample -Data $d -Id 'apogeeDrv.getDataFail')
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
                    # Meaningless with no listener; kept as empty strings so batch and
                    # dashboard output differ by value, not by structure (PRD 5.1 / 10.1).
                    port    = if ([bool]$script:Sync['BatchMode']) { '' } else { [int]$script:Sync['BoundPort'] }
                    url     = if ([bool]$script:Sync['BatchMode']) { '' } else { [string]$script:Sync['ListeningUrl'] }
                    logPath = [string]$script:Sync['LogPath']
                }
            }
        }
        'detections' {
            return [ordered]@{
                generation = $gen
                detections = @(Build-DetectionsObject -Data $d -TopN $TopN)
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
    param(
        $SevFilter,
        $AreaFilter = $null,
        [ValidateSet('All', 'Severity', 'Driver')][string]$Organize = 'All',
        [string[]]$Drivers = @(),
        [string]$Format = 'html'
    )
    if ($null -eq $AreaFilter) {
        $AreaFilter = @{ SYS = $true; IMPL = $true; CTRL = $true; PARAM = $true; OTHER = $true }
    }
    if (-not $script:Sync['LogPath'] -or -not $script:Sync['Data']) {
        throw 'Start a session before taking a snapshot.'
    }
    if ($script:Sync['Loading']) {
        throw 'Catch-up still running. Wait until loading finishes, then snapshot.'
    }
    $pulse = Build-PulseObject -SevFilter $SevFilter -AreaFilter $AreaFilter
    $patterns = Build-SectionObject -Name 'patterns' -SevFilter $SevFilter -AreaFilter $AreaFilter
    $managers = Build-SectionObject -Name 'managers' -SevFilter $SevFilter -AreaFilter $AreaFilter
    $bacnet = Build-SectionObject -Name 'bacnet' -SevFilter $SevFilter -AreaFilter $AreaFilter
    $cns = Build-SectionObject -Name 'cns' -SevFilter $SevFilter -AreaFilter $AreaFilter
    $coho = Build-SectionObject -Name 'coho' -SevFilter $SevFilter -AreaFilter $AreaFilter
    $apogee = Build-SectionObject -Name 'apogee' -SevFilter $SevFilter -AreaFilter $AreaFilter
    $perf = Build-SectionObject -Name 'perf' -SevFilter $SevFilter -AreaFilter $AreaFilter
    $d = $script:Sync['Data']
    $life = Build-LifecycleRows -Data $d
    $sevList = @()
    foreach ($sk in @('FATAL', 'SEVERE', 'ERROR', 'WARNING', 'INFO')) {
        if ($SevFilter[$sk]) { $sevList += $sk }
    }
    $areaList = @()
    foreach ($ak in @('SYS', 'IMPL', 'CTRL', 'PARAM', 'OTHER')) {
        if ($AreaFilter[$ak]) { $areaList += $ak }
    }
    # Driver deep-dive is only carried when it will be rendered; Build-ManagerObject is not
    # free, and All/Severity never show it.
    $deepDive = @()
    if ($Organize -eq 'Driver') {
        foreach ($drv in @($Drivers)) {
            if (-not $drv) { continue }
            $deepDive += (Build-ManagerObject -MgrName $drv -SevFilter $SevFilter)
        }
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
            areas       = @($areaList)
        }
        options = [ordered]@{
            organize         = $Organize
            severities       = @($sevList)
            areas            = @($areaList)
            drivers          = @($Drivers)
            topN             = [int]$script:TopN
            samplePerPattern = [int]$script:SamplePerPattern
            window           = $pulse.window.mode
            lastMinutes      = [int]$pulse.window.lastMinutes
            format           = $Format
        }
        window          = $pulse.window
        findings        = @($pulse.findings)
        severityCounts  = $pulse.severityCounts
        areaCounts      = $pulse.areaCounts
        series          = $pulse.series
        moduleHeadlines = $pulse.moduleHeadlines
        topManagers     = @($pulse.topManagers)
        patternsBySeverity = $patterns.patternsBySeverity
        managers        = @($managers.managers)
        projectLifecycle = $pulse.projectLifecycle
        managerHealth = [ordered]@{
            totals           = $life.totals
            driverReady      = [int]$d.DriverReady
            blockingSample   = $d.BlockingSample
            unblockingSample = $d.UnblockingSample
            managers         = @(@($life.managers) | Select-Object -First 25)
        }
        bacnet          = $bacnet.bacnet
        cns             = $cns.cns
        coho            = $coho.coho
        apogee          = $apogee.apogee
        detections      = @(Build-DetectionsObject -Data $d -TopN $script:TopN)
        hourly          = (Build-HourlyObject -Data $d -AreaFilter $AreaFilter)
        driverDeepDive  = @($deepDive)
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

function script:Add-SnapCountNameTable {
    param(
        [System.Text.StringBuilder]$Sb,
        $Encode,
        $Rows,
        [string]$NameKey,
        [string]$NameHeader,
        [string]$CountKey = 'count',
        [string]$Class = 'data'
    )
    $list = @($Rows)
    if ($list.Count -eq 0) { return }
    [void]$Sb.AppendLine(('<table class="{1}"><thead><tr><th>Count</th><th>{0}</th></tr></thead><tbody>' -f $NameHeader, $Class))
    foreach ($row in $list) {
        $name = [string]$row.$NameKey
        $n = [int]$row.$CountKey
        [void]$Sb.AppendLine(('<tr><td>{0:N0}</td><td class="mono">{1}</td></tr>' -f $n, (& $Encode $name)))
    }
    [void]$Sb.AppendLine('</tbody></table>')
}

function script:Add-SnapPatternTable {
    param(
        [System.Text.StringBuilder]$Sb,
        $Encode,
        $Rows
    )
    $list = @($Rows)
    if ($list.Count -eq 0) { return }
    [void]$Sb.AppendLine('<table class="data"><thead><tr><th>Count</th><th>First</th><th>Last</th><th>Pattern</th><th>Example</th></tr></thead><tbody>')
    foreach ($row in $list) {
        $ex = ''
        if ($row.samples) {
            $arr = @($row.samples)
            if ($arr.Count -gt 0) { $ex = [string]$arr[0] }
        }
        [void]$Sb.AppendLine(('<tr><td>{0:N0}</td><td class="meta">{1}</td><td class="meta">{2}</td><td class="mono">{3}</td><td class="mono meta">{4}</td></tr>' -f `
            [int]$row.count, (& $Encode ([string]$row.first)), (& $Encode ([string]$row.last)), (& $Encode ([string]$row.pattern)), (& $Encode $ex)))
    }
    [void]$Sb.AppendLine('</tbody></table>')
}

# Generic renderer over the whole rule table - adding a rule needs no edit here.
# "18x threshold" - how this rule's volume compares with its own hand-tuned FindingAt bar,
# which is the count at which it earns a Findings headline. Shown rather than the rate that
# drives the ordering, because a seven-second burst rates at 270,000/hr.
function script:Format-RuleOverLabel {
    param($Rule)
    if (-not $Rule.findingAt -or [int]$Rule.findingAt -le 0) { return $null }
    $o = [double]$Rule.over
    $n = if ($o -ge 10) { '{0:N0}' -f $o } else { '{0:N1}' -f $o }
    return ('{0}x threshold' -f $n)
}

function script:Get-RuleBadgeHtml {
    param($Rule)
    $txt = Format-RuleOverLabel -Rule $Rule
    if (-not $txt) { return '' }
    $cls = if ([double]$Rule.over -ge 1) { 'badge over' } else { 'badge' }
    return (' <span class="{0}" title="Raises a finding at {1:N0} line(s)">{2}</span>' -f `
            $cls, [int]$Rule.findingAt, ($txt -replace 'x threshold', '&times; threshold'))
}

function script:Add-SnapDetectionsSection {
    param([System.Text.StringBuilder]$Sb, $Encode, $Detections)
    [void]$Sb.AppendLine('<section id="detections"><h2>Detections</h2><div class="card">')
    $groups = @($Detections)
    if ($groups.Count -eq 0) {
        [void]$Sb.AppendLine('<p class="muted">No rule detections in this window.</p>')
        [void]$Sb.AppendLine('</div></section>')
        return
    }
    foreach ($g in $groups) {
        [void]$Sb.AppendLine(('<h3>{0} <span class="meta">({1:N0} lines)</span></h3>' -f (& $Encode ([string]$g.group)), [int]$g.total))
        foreach ($r in @($g.rules)) {
            # One severity covering every line just restates the count, so name it in the
            # headline ("161,964 SEVERE line(s)") rather than echoing the number twice.
            $sevWord = ''
            $sevTxt = ''
            if ($r.severities) {
                $sevKeys = @($r.severities.Keys)
                if ($sevKeys.Count -eq 1 -and [int]$r.severities[$sevKeys[0]] -eq [int]$r.count) {
                    $sevWord = (& $Encode ([string]$sevKeys[0])) + ' '
                }
                else {
                    $sp = @()
                    foreach ($sk in $sevKeys) { $sp += ('{0} {1:N0}' -f (& $Encode ([string]$sk)), [int]$r.severities[$sk]) }
                    if ($sp.Count -gt 0) { $sevTxt = ' &middot; ' + ($sp -join ', ') }
                }
            }

            # A rule carrying a Measure leads with the aggregate: counting lines understates
            # things like "We counted N COVs", where the payload is the number.
            $head = ''
            $ms = $r.measures
            if ($ms) {
                $parts = @()
                foreach ($mk in @($ms.Keys)) { $parts += ('{0}: <strong>{1:N0}</strong>' -f (& $Encode ([string]$mk)), $ms[$mk]) }
                if ($parts.Count -gt 0) { $head = ($parts -join ' &middot; ') + (' &middot; over {0:N0} {1}line(s)' -f [int]$r.count, $sevWord) }
            }
            if (-not $head) { $head = '<strong>{0:N0}</strong> {1}line(s)' -f [int]$r.count, $sevWord }
            [void]$Sb.AppendLine(('<h4>{0}{1}</h4>' -f (& $Encode ([string]$r.label)), (Get-RuleBadgeHtml -Rule $r)))
            [void]$Sb.AppendLine(('<p>{0}{1}</p>' -f $head, $sevTxt))
            if ($r.first) {
                # Duration is what makes the ordering legible: 4,563 hits over 4h is an outage,
                # the same count over three weeks is background.
                $span = Format-DurationLabel -Seconds $r.spanSec
                [void]$Sb.AppendLine(('<p class="meta">{0} &rarr; {1} &middot; {2} &middot; rule <span class="mono">{3}</span></p>' -f `
                    (& $Encode ([string]$r.first)), (& $Encode ([string]$r.last)), (& $Encode $span), (& $Encode ([string]$r.id))))
            }
            if ($r.sample) { [void]$Sb.AppendLine(('<p class="muted mono">{0}</p>' -f (& $Encode ([string]$r.sample)))) }
            if ($r.buckets) {
                foreach ($bname in @($r.buckets.Keys)) {
                    $b = $r.buckets[$bname]
                    $rows = @($b.top)
                    if ($rows.Count -eq 0) { continue }
                    # A single distinct value does not need a table around it - say it in words.
                    if ([int]$b.distinct -eq 1 -and $rows.Count -eq 1) {
                        [void]$Sb.AppendLine(('<p class="meta">All from {0} <span class="mono">{1}</span></p>' -f `
                            (& $Encode ([string]$bname)), (& $Encode ([string]$rows[0].value))))
                        continue
                    }
                    [void]$Sb.AppendLine(('<p class="meta">By {0} &mdash; {1:N0} distinct{2}</p>' -f `
                        (& $Encode ([string]$bname)), [int]$b.distinct,
                            $(if ($b.capped) { ' (capped)' } else { '' })))
                    Add-SnapCountNameTable -Sb $Sb -Encode $Encode -Rows $rows -NameKey 'value' `
                        -NameHeader ([string]$bname) -Class 'data kv'
                }
            }
        }
    }
    [void]$Sb.AppendLine('</div></section>')
}

# Which sections an organize mode renders. Mirrors V1.3's eight inclusion flags (1718-1868)
# so text and HTML agree, and so organize stays a render-time concern - the snapshot object
# is identical in all three modes.
function script:Get-ReportSections {
    param($Snap)
    $opt = $Snap.options
    $organize = 'All'
    if ($opt -and $opt.organize) { $organize = [string]$opt.organize }

    $inc = @{
        organize         = $organize
        bacnet           = $true
        cns              = $true
        coho             = $true
        apogee           = $true
        moduleHeadlines  = $false
        severityPatterns = $true
        driverDeepDive   = $false
        fullDefault      = $true
    }
    if ($organize -eq 'Severity') {
        $inc.bacnet = $false; $inc.cns = $false; $inc.coho = $false; $inc.apogee = $false
        $inc.moduleHeadlines = $true
        $inc.fullDefault = $false
    }
    elseif ($organize -eq 'Driver') {
        $inc.fullDefault = $false
        $inc.severityPatterns = $false
        $inc.driverDeepDive = $true
        $inc.bacnet = $false; $inc.cns = $false; $inc.coho = $false; $inc.apogee = $false
        # Re-enable the modules the chosen drivers actually touch (V1.3 1849-1856).
        foreach ($drv in @($opt.drivers)) {
            $name = [string]$drv
            if ($name -match 'BACnet') { $inc.bacnet = $true }
            if ($name -match 'ApplicationFramework|ICns') { $inc.cns = $true }
            if ($name -match 'CoHo') { $inc.coho = $true; $inc.apogee = $true; $inc.bacnet = $true }
            if ($name -match '(?i)Apogee') { $inc.apogee = $true }
        }
        $bac = $Snap.bacnet
        if ($bac -and (([int]$bac.collectTrend + [int]$bac.timeSync) -gt 0)) { $inc.bacnet = $true }
        $apo = $Snap.apogee
        if ($apo -and (([int]$apo.drvLines + [int]$apo.trendOverflow) -gt 0)) { $inc.apogee = $true }
    }
    $inc.managers = ($inc.fullDefault -or $inc.driverDeepDive)
    $inc.perf = $inc.fullDefault
    $inc.hourly = $inc.fullDefault
    $inc.detections = ($organize -ne 'Severity')
    return $inc
}

function script:Add-SnapHourlyTable {
    param([System.Text.StringBuilder]$Sb, $Encode, $Rows)
    [void]$Sb.AppendLine('<table class="data"><thead><tr><th>Hour</th><th>All</th><th>SEVERE</th><th>WARNING</th></tr></thead><tbody>')
    foreach ($r in @($Rows)) {
        [void]$Sb.AppendLine(('<tr><td class="mono">{0}</td><td>{1:N0}</td><td>{2:N0}</td><td>{3:N0}</td></tr>' -f `
            (& $Encode ([string]$r.hour)), [int]$r.total, [int]$r.severe, [int]$r.warning))
    }
    [void]$Sb.AppendLine('</tbody></table>')
}

function script:Convert-SnapshotToHtml {
    param($Snap)
    $e = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
    $inc = Get-ReportSections -Snap $Snap
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
    $areaOn = if ($Snap.meta.areas) { ($Snap.meta.areas -join ', ') } else { 'SYS, IMPL, CTRL, PARAM, OTHER' }

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
  --chrome-h: 5.5rem;
}
* { box-sizing: border-box; }
html { scroll-padding-top: calc(var(--chrome-h) + 0.5rem); }
body {
  margin: 0;
  font-family: var(--font);
  color: var(--text);
  background: var(--bg-deep);
  line-height: 1.45;
}
header.chrome {
  position: sticky;
  top: 0;
  z-index: 5;
  background: var(--bg-panel);
  border-bottom: 1px solid var(--border);
  padding: 0.65rem 1.25rem 0.55rem;
}
.brand { color: var(--siemens-petrol); font-weight: 700; font-size: 1.05rem; letter-spacing: 0.02em; }
.meta { color: var(--text-meta); font-size: 0.88rem; }
.muted { color: var(--text-muted); }
nav.jump {
  display: flex;
  flex-wrap: wrap;
  gap: 0.2rem 0.15rem;
  margin-top: 0.45rem;
}
nav.jump a {
  color: var(--text);
  text-decoration: none;
  font-size: 0.8rem;
  padding: 0.2rem 0.45rem;
  border-radius: 2px;
  border: 1px solid transparent;
}
nav.jump a:hover {
  color: var(--siemens-petrol);
  background: var(--bg-elevated);
  border-color: var(--border);
}
.intro {
  padding: 0.85rem 1.25rem 0;
  max-width: 72rem;
}
main { padding: 0.5rem 1.25rem 2.5rem; max-width: 72rem; }
section {
  scroll-margin-top: 0.35rem;
}
h1 { font-size: 1.05rem; margin: 0.15rem 0 0.2rem; font-weight: 600; }
h2 {
  font-size: 1rem;
  color: var(--siemens-petrol);
  margin: 1.35rem 0 0.55rem;
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
/* Detections: how a rule's volume compares with its own reporting threshold. */
.badge {
  display: inline-block;
  margin-left: 0.5rem;
  padding: 0.05rem 0.4rem;
  border: 1px solid var(--border);
  border-radius: 2px;
  font-size: 0.72rem;
  font-weight: 600;
  letter-spacing: 0.02em;
  vertical-align: middle;
  color: var(--text-muted);
  white-space: nowrap;
}
.badge.over {
  border-color: var(--sev-warning);
  color: #ffd0a0;
}
/* Count/value pairs: a full-width split strands the number far from the value it counts. */
table.data.kv { width: auto; min-width: 22rem; max-width: 100%; }
table.data.kv th:first-child, table.data.kv td:first-child {
  width: 1%;
  white-space: nowrap;
  text-align: right;
  padding-right: 0.9rem;
}
.kind-up { color: #90d090; }
.kind-shutdown { color: #ffd0a0; }
.kind-stopped { color: #ffb0b0; }
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
@media (max-width: 640px) {
  nav.jump a { font-size: 0.75rem; padding: 0.18rem 0.35rem; }
}
'@)
    [void]$sb.AppendLine('</style></head><body>')
    [void]$sb.AppendLine('<header class="chrome">')
    [void]$sb.AppendLine('<div class="brand">PVSS Log Watch</div>')
    [void]$sb.AppendLine(('<h1>Snapshot report <span class="meta">v{0}</span></h1>' -f (& $e $Snap.meta.version)))
    [void]$sb.AppendLine('<nav class="jump" aria-label="Report sections">')
    $navLinks = @(
        @{ H = '#options'; L = 'Options'; On = $true },
        @{ H = '#findings'; L = 'Findings'; On = $true },
        @{ H = '#severity'; L = 'Severity'; On = $true },
        @{ H = '#charts'; L = 'Charts'; On = $true },
        @{ H = '#hourly'; L = 'Hourly'; On = $inc.hourly },
        @{ H = '#project'; L = 'Project restarts'; On = $true },
        @{ H = '#mgr-health'; L = 'Manager health'; On = $true },
        @{ H = '#managers'; L = 'Top managers'; On = $inc.managers },
        @{ H = '#patterns'; L = 'Patterns'; On = $inc.severityPatterns },
        @{ H = '#deep-dive'; L = 'Driver deep-dive'; On = $inc.driverDeepDive },
        @{ H = '#headlines'; L = 'Module headlines'; On = $inc.moduleHeadlines },
        @{ H = '#bacnet'; L = 'BACnet'; On = $inc.bacnet },
        @{ H = '#cns'; L = 'CNS'; On = $inc.cns },
        @{ H = '#coho'; L = 'CoHo'; On = $inc.coho },
        @{ H = '#apogee'; L = 'Apogee'; On = $inc.apogee },
        @{ H = '#detections'; L = 'Detections'; On = $inc.detections },
        @{ H = '#perf'; L = 'Perf'; On = $inc.perf }
    )
    foreach ($link in $navLinks) {
        if (-not $link.On) { continue }
        [void]$sb.AppendLine(('<a href="{0}">{1}</a>' -f $link.H, $link.L))
    }
    [void]$sb.AppendLine('</nav></header>')

    [void]$sb.AppendLine('<div class="intro">')
    [void]$sb.AppendLine(('<p class="meta">Generated {0}</p>' -f (& $e $Snap.meta.generated)))
    [void]$sb.AppendLine(('<p class="meta">Log: <span class="mono">{0}</span></p>' -f (& $e $Snap.meta.logPath)))
    [void]$sb.AppendLine(('<p class="meta">{0}  &middot;  {1}</p>' -f (& $e $winLabel), (& $e $span)))
    [void]$sb.AppendLine(('<p class="meta">Severity filters: {0}  &middot;  Area filters: {1}</p>' -f (& $e $sevOn), (& $e $areaOn)))
    [void]$sb.AppendLine(('<p class="meta">Parsed lines: {0:N0}  &middot;  gen {1}</p>' -f `
        [int]$Snap.meta.parsedLines, [int]$Snap.meta.generation))
    # Keep this file pure ASCII: PS 5.1 parses a BOM-less .ps1 as Windows-1252, so a literal
    # non-ASCII character here is mis-decoded and written out as mojibake. Use entities.
    [void]$sb.AppendLine(('<p class="meta">Module pages (BACnet/CNS/&hellip;) show all areas; area filter applies to charts, patterns, managers, and severity KPIs.</p>'))
    [void]$sb.AppendLine('</div><main>')

    $opt = $Snap.options
    [void]$sb.AppendLine('<section id="options"><h2>Options used</h2><div class="card">')
    if ($opt) {
        [void]$sb.AppendLine('<table class="data"><thead><tr><th>Option</th><th>Value</th></tr></thead><tbody>')
        $winTxt = if ([string]$opt.window -eq 'entire') { 'entire file' } else { ('last {0:N0} minutes' -f [int]$opt.lastMinutes) }
        foreach ($row in @(
                @{ K = 'Organize'; V = [string]$opt.organize },
                @{ K = 'Severities'; V = (@($opt.severities) -join ', ') },
                @{ K = 'Areas'; V = (@($opt.areas) -join ', ') },
                @{ K = 'Drivers'; V = $(if (@($opt.drivers).Count -gt 0) { (@($opt.drivers) -join ', ') } else { '(none)' }) },
                @{ K = 'TopN'; V = ('{0}' -f [int]$opt.topN) },
                @{ K = 'Sample/pattern'; V = ('{0}' -f [int]$opt.samplePerPattern) },
                @{ K = 'Time window'; V = $winTxt },
                @{ K = 'Format'; V = [string]$opt.format }
            )) {
            [void]$sb.AppendLine(('<tr><td>{0}</td><td class="mono">{1}</td></tr>' -f (& $e $row.K), (& $e $row.V)))
        }
        [void]$sb.AppendLine('</tbody></table>')
    }
    else { [void]$sb.AppendLine('<p class="muted">No options recorded.</p>') }
    [void]$sb.AppendLine('</div></section>')

    [void]$sb.AppendLine('<section id="findings"><h2>Findings</h2><ul class="findings">')
    if (-not $Snap.findings -or @($Snap.findings).Count -eq 0) {
        [void]$sb.AppendLine('<li class="muted">No findings.</li>')
    }
    else {
        foreach ($f in @($Snap.findings)) {
            [void]$sb.AppendLine(('<li>{0}</li>' -f (& $e ([string]$f))))
        }
    }
    [void]$sb.AppendLine('</ul></section>')

    [void]$sb.AppendLine('<section id="severity"><h2>Severity counts</h2><div class="kpi-row">')
    foreach ($s in @('FATAL', 'SEVERE', 'ERROR', 'WARNING', 'INFO')) {
        $n = 0
        if ($Snap.severityCounts -and $Snap.severityCounts.$s -ne $null) { $n = [int]$Snap.severityCounts.$s }
        [void]$sb.AppendLine(('<div class="kpi" data-sev="{0}"><div class="label">{0}</div><div class="value">{1:N0}</div></div>' -f $s, $n))
    }
    [void]$sb.AppendLine('</div></section>')

    $gran = 'minute'
    if ($Snap.series -and $Snap.series.granularity) { $gran = [string]$Snap.series.granularity }
    [void]$sb.AppendLine(('<section id="charts"><h2>Activity charts (by {0})</h2>' -f (& $e $gran)))
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
        [void]$sb.AppendLine('<div class="legend"><span><span class="swatch" style="background:#e00000"></span>FATAL</span><span><span class="swatch" style="background:#c000a0"></span>SEVERE</span><span><span class="swatch" style="background:#b00040"></span>ERROR</span><span><span class="swatch" style="background:#e07000"></span>WARNING</span><span><span class="swatch" style="background:#008000"></span>INFO</span><span><span class="swatch" style="background:#e0a000"></span>project up</span></div>')
        [void]$sb.AppendLine((Build-VolumeSvg -Points $points -Gran $gran))
        [void]$sb.AppendLine('<p class="meta">Dashed amber line = project up / restart (pmon).</p>')
        [void]$sb.AppendLine('</div>')
        [void]$sb.AppendLine('<div class="card">')
        [void]$sb.AppendLine('<h3>BACnet Failed / OK</h3>')
        [void]$sb.AppendLine('<div class="legend"><span><span class="swatch" style="background:#c000a0"></span>Failed</span><span><span class="swatch" style="background:#008000"></span>OK</span><span><span class="swatch" style="background:#e0a000"></span>project up</span></div>')
        [void]$sb.AppendLine((Build-BacnetSvg -Points $points -Gran $gran))
        [void]$sb.AppendLine('</div>')
    }
    [void]$sb.AppendLine('</section>')

    if ($inc.hourly) {
        $hr = $Snap.hourly
        [void]$sb.AppendLine('<section id="hourly"><h2>Hourly volume</h2><div class="card">')
        if ($hr -and [int]$hr.hourCount -gt 0) {
            if ($hr.truncated) {
                [void]$sb.AppendLine(('<p class="meta">Hours in analyzed window: {0:N0} (showing most recent 24 + top 10 busiest)</p>' -f [int]$hr.hourCount))
                Add-SnapHourlyTable -Sb $sb -Encode $e -Rows $hr.rows
                [void]$sb.AppendLine('<h3>Busiest hours (top 10 by total lines)</h3>')
                Add-SnapHourlyTable -Sb $sb -Encode $e -Rows $hr.busiest
            }
            else {
                [void]$sb.AppendLine(('<p class="meta">Hours in analyzed window: {0:N0}</p>' -f [int]$hr.hourCount))
                Add-SnapHourlyTable -Sb $sb -Encode $e -Rows $hr.rows
            }
        }
        else { [void]$sb.AppendLine('<p class="muted">No hourly data.</p>') }
        [void]$sb.AppendLine('</div></section>')
    }

    # Project restart cycles
    $pl = $Snap.projectLifecycle
    [void]$sb.AppendLine('<section id="project"><h2>Project restarts (pmon)</h2>')
    [void]$sb.AppendLine('<p class="meta">Each row is one cycle: up &rarr; shutdown &rarr; stopped &rarr; next up. Uptime = up to shutdown; stop = shutdown to stopped; downtime = stopped to next up. START_MODE counted only (too frequent to list).</p>')
    if ($pl) {
        $cycles = @($pl.cycles)
        $capNote = if ($pl.capped) { ' (events capped at 200)' } else { '' }
        [void]$sb.AppendLine(('<p class="meta">up={0:N0}  &middot;  stopped={1:N0}  &middot;  shutdown={2:N0}  &middot;  START_MODE={3:N0}  &middot;  cycles={4:N0}{5}</p>' -f `
            [int]$pl.up, [int]$pl.stopped, [int]$pl.shutdown, [int]$pl.startMode, $cycles.Count, $capNote))
        if ($cycles.Count -gt 0) {
            [void]$sb.AppendLine('<table class="data"><thead><tr><th>Up</th><th>Shutdown</th><th>Uptime</th><th>Stopped</th><th>Stop</th><th>Downtime</th><th>Note</th></tr></thead><tbody>')
            foreach ($c in $cycles) {
                $upLabel = [string]$c.up
                if ($c.upImplied) { $upLabel = "$upLabel (window start)" }
                $note = ''
                if ($c.stillUp -and $c.nextUp) { $note = 'no shutdown before next up' }
                elseif ($c.stillUp) { $note = 'still up' }
                elseif ($c.stillDown) { $note = 'still down' }
                elseif (-not $c.shutdown -and $c.stopped) { $note = 'no shutdown line' }
                [void]$sb.AppendLine(('<tr><td class="mono kind-up">{0}</td><td class="mono kind-shutdown">{1}</td><td>{2}</td><td class="mono kind-stopped">{3}</td><td>{4}</td><td>{5}</td><td class="meta">{6}</td></tr>' -f `
                    (& $e $upLabel),
                    (& $e ([string]$c.shutdown)),
                    (& $e ([string]$c.uptime)),
                    (& $e ([string]$c.stopped)),
                    (& $e ([string]$c.stopDuration)),
                    (& $e ([string]$c.downtime)),
                    (& $e $note)))
            }
            [void]$sb.AppendLine('</tbody></table>')
        }
        elseif (([int]$pl.up + [int]$pl.stopped + [int]$pl.shutdown) -gt 0) {
            [void]$sb.AppendLine('<p class="muted">Counts present but no cycle timestamps were retained (re-run Start after updating Watch).</p>')
        }
        else {
            [void]$sb.AppendLine('<p class="muted">No project up / stop / shutdown events in this window.</p>')
        }
    }
    else {
        [void]$sb.AppendLine('<p class="muted">No project lifecycle data.</p>')
    }
    [void]$sb.AppendLine('</section>')

    # Manager health
    $mh = $Snap.managerHealth
    [void]$sb.AppendLine('<section id="mgr-health"><h2>Manager health (pmon)</h2>')
    [void]$sb.AppendLine('<p class="meta">Start/stop = Manager Start PROJ / Manager Stop. Restarts = Detected stopped manager. Blocking = no heartbeat.</p>')
    if ($mh -and $mh.totals) {
        $t = $mh.totals
        [void]$sb.AppendLine(('<p>Starts: <strong>{0:N0}</strong>  &middot;  Stops: <strong>{1:N0}</strong>  &middot;  Auto-restarts: <strong>{2:N0}</strong>  &middot;  Blocking: <strong>{3:N0}</strong>  &middot;  Unblocked: <strong>{4:N0}</strong>  &middot;  Driver-ready: <strong>{5:N0}</strong></p>' -f `
            [int]$t.starts, [int]$t.stops, [int]$t.restarts, [int]$t.blocking, [int]$t.unblocked, [int]$mh.driverReady))
        if ($mh.blockingSample) {
            [void]$sb.AppendLine(('<p class="meta mono">{0}</p>' -f (& $e ([string]$mh.blockingSample))))
        }
        if ($mh.unblockingSample) {
            [void]$sb.AppendLine(('<p class="meta mono">{0}</p>' -f (& $e ([string]$mh.unblockingSample))))
        }
        $mrows = @($mh.managers)
        if ($mrows.Count -gt 0) {
            [void]$sb.AppendLine('<table class="data"><thead><tr><th>Manager</th><th>Starts</th><th>Stops</th><th>Restarts</th><th>Blocking</th><th>Unblocked</th></tr></thead><tbody>')
            foreach ($r in $mrows) {
                [void]$sb.AppendLine(('<tr><td class="mono">{0}</td><td>{1:N0}</td><td>{2:N0}</td><td>{3:N0}</td><td>{4:N0}</td><td>{5:N0}</td></tr>' -f `
                    (& $e ([string]$r.name)), [int]$r.starts, [int]$r.stops, [int]$r.restarts, [int]$r.blocking, [int]$r.unblocked))
            }
            [void]$sb.AppendLine('</tbody></table>')
        }
        else {
            [void]$sb.AppendLine('<p class="muted">No per-manager start/stop/blocking activity.</p>')
        }
    }
    else {
        [void]$sb.AppendLine('<p class="muted">No manager health data.</p>')
    }
    [void]$sb.AppendLine('</section>')

    if ($inc.managers) {
    [void]$sb.AppendLine('<section id="managers"><h2>Top managers</h2>')
    $mgrs = @($Snap.topManagers)
    if ($mgrs.Count -eq 0) {
        [void]$sb.AppendLine('<p class="muted">No managers.</p>')
    }
    else {
        # Prefer severity breakdown from full managers list when available
        $byName = @{}
        foreach ($m in @($Snap.managers)) {
            if ($m.name) { $byName[[string]$m.name] = $m }
        }
        [void]$sb.AppendLine('<table class="data"><thead><tr><th>Count</th><th>FATAL</th><th>SEVERE</th><th>ERROR</th><th>WARNING</th><th>INFO</th><th>Manager</th></tr></thead><tbody>')
        foreach ($m in $mgrs) {
            $name = [string]$m.name
            $sev = $null
            if ($byName.ContainsKey($name) -and $byName[$name].severities) { $sev = $byName[$name].severities }
            $f = if ($sev) { [int]$sev.FATAL } else { 0 }
            $sv = if ($sev) { [int]$sev.SEVERE } else { 0 }
            $er = if ($sev) { [int]$sev.ERROR } else { 0 }
            $w = if ($sev) { [int]$sev.WARNING } else { 0 }
            $inf = if ($sev) { [int]$sev.INFO } else { 0 }
            [void]$sb.AppendLine(('<tr><td>{0:N0}</td><td>{1:N0}</td><td>{2:N0}</td><td>{3:N0}</td><td>{4:N0}</td><td>{5:N0}</td><td class="mono">{6}</td></tr>' -f `
                [int]$m.count, $f, $sv, $er, $w, $inf, (& $e $name)))
        }
        [void]$sb.AppendLine('</tbody></table>')
    }
    [void]$sb.AppendLine('</section>')
    }

    if ($inc.severityPatterns) {
        [void]$sb.AppendLine('<section id="patterns"><h2>Patterns by severity</h2>')
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
            Add-SnapPatternTable -Sb $sb -Encode $e -Rows $list
        }
        [void]$sb.AppendLine('</section>')
    }

    if ($inc.driverDeepDive) {
        [void]$sb.AppendLine('<section id="deep-dive"><h2>Driver deep-dive</h2>')
        $dds = @($Snap.driverDeepDive)
        if ($dds.Count -eq 0) { [void]$sb.AppendLine('<p class="muted">No drivers selected.</p>') }
        foreach ($dd in $dds) {
            [void]$sb.AppendLine('<div class="card">')
            [void]$sb.AppendLine(('<h3>{0}</h3>' -f (& $e ([string]$dd.name))))
            [void]$sb.AppendLine(('<p>Total lines: <strong>{0:N0}</strong></p>' -f [int]$dd.count))
            if ($dd.severities) {
                $sp = @()
                foreach ($sk in @('FATAL', 'SEVERE', 'ERROR', 'WARNING', 'INFO')) {
                    $sp += ('{0} {1:N0}' -f $sk, [int]$dd.severities.$sk)
                }
                [void]$sb.AppendLine(('<p class="meta">{0}</p>' -f ($sp -join ' &middot; ')))
            }
            foreach ($s in @('FATAL', 'SEVERE', 'ERROR', 'WARNING')) {
                $list = @()
                if ($dd.patternsBySeverity -and $dd.patternsBySeverity.$s) { $list = @($dd.patternsBySeverity.$s) }
                [void]$sb.AppendLine(('<h4>Patterns &mdash; {0} <span class="meta">({1})</span></h4>' -f $s, $list.Count))
                if ($list.Count -eq 0) { [void]$sb.AppendLine('<p class="muted">(none)</p>'); continue }
                Add-SnapPatternTable -Sb $sb -Encode $e -Rows $list
            }
            [void]$sb.AppendLine('</div>')
        }
        [void]$sb.AppendLine('</section>')
    }

    if ($inc.moduleHeadlines) {
        $mh = $Snap.moduleHeadlines
        [void]$sb.AppendLine('<section id="headlines"><h2>Module headlines</h2><div class="card">')
        if ($mh) {
            [void]$sb.AppendLine(('<p>BACnet &mdash; Failed: <strong>{0:N0}</strong> &middot; OK: <strong>{1:N0}</strong> &middot; object list: <strong>{2:N0}</strong> &middot; CollectTrend: <strong>{3:N0}</strong> &middot; TimeSync: <strong>{4:N0}</strong></p>' -f `
                [int]$mh.bacnet.failed, [int]$mh.bacnet.ok, [int]$mh.bacnet.objectList, [int]$mh.bacnet.collectTrend, [int]$mh.bacnet.timeSync))
            [void]$sb.AppendLine(('<p>CNS &mdash; ResolveNodes: <strong>{0:N0}</strong> &middot; ReducedFunction: <strong>{1:N0}</strong> &middot; TryRenewSession: <strong>{2:N0}</strong> &middot; ICns: <strong>{3:N0}</strong></p>' -f `
                [int]$mh.cns.resolveNodes, [int]$mh.cns.reducedFunction, [int]$mh.cns.tryRenew, [int]$mh.cns.icns))
            [void]$sb.AppendLine(('<p>CoHo &mdash; stuck/drop: <strong>{0:N0}</strong></p>' -f [int]$mh.coho.stuck))
            [void]$sb.AppendLine(('<p>Apogee &mdash; events: <strong>{0:N0}</strong> &middot; UpdatePoints: <strong>{1:N0}</strong> &middot; driver lines: <strong>{2:N0}</strong> &middot; trend overflow: <strong>{3:N0}</strong> &middot; get-data fail: <strong>{4:N0}</strong></p>' -f `
                [int]$mh.apogee.events, [int]$mh.apogee.updatePoints, [int]$mh.apogee.drvLines, [int]$mh.apogee.trendOverflow, [int]$mh.apogee.getDataFail))
        }
        else { [void]$sb.AppendLine('<p class="muted">No module headlines.</p>') }
        [void]$sb.AppendLine('</div></section>')
    }

    if ($inc.bacnet) {
    $bac = $Snap.bacnet
    [void]$sb.AppendLine('<section id="bacnet"><h2>BACnet</h2><div class="card">')
    if ($bac) {
        [void]$sb.AppendLine(('<p>Failed: <strong>{0:N0}</strong> ({1:N0} devices) &middot; OK: <strong>{2:N0}</strong> ({3:N0} devices) &middot; ended Failed: <strong>{4:N0}</strong> &middot; ended OK: <strong>{5:N0}</strong> &middot; flappers: <strong>{6:N0}</strong></p>' -f `
            [int]$bac.failed, [int]$bac.failedDevices, [int]$bac.ok, [int]$bac.okDevices, [int]$bac.endedFailed, [int]$bac.endedOk, [int]$bac.flappers))
        [void]$sb.AppendLine(('<p>Object-list: <strong>{0:N0}</strong> ({1:N0} devices) &middot; CollectTrend: <strong>{2:N0}</strong> ({3:N0} properties) &middot; TimeSync: <strong>{4:N0}</strong> ({5:N0} properties)</p>' -f `
            [int]$bac.objectList, [int]$bac.objectListDevices, [int]$bac.collectTrend, [int]$bac.collectTrendProps, [int]$bac.timeSync, [int]$bac.timeSyncProps))
        if ($bac.failedSample) {
            [void]$sb.AppendLine(('<p class="muted mono">Failed example: {0}</p>' -f (& $e ([string]$bac.failedSample))))
        }
        if ($bac.okSample) {
            [void]$sb.AppendLine(('<p class="muted mono">OK example: {0}</p>' -f (& $e ([string]$bac.okSample))))
        }
        if ($bac.activity -and @($bac.activity).Count -gt 0) {
            [void]$sb.AppendLine('<h3>Device status activity</h3><table class="data"><thead><tr><th>Device</th><th>Failed</th><th>OK</th><th>Flips</th><th>Last</th></tr></thead><tbody>')
            foreach ($row in @($bac.activity)) {
                [void]$sb.AppendLine(('<tr><td class="mono">{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td></tr>' -f `
                    (& $e ([string]$row.device)), [int]$row.failed, [int]$row.ok, [int]$row.flips, (& $e ([string]$row.last))))
            }
            [void]$sb.AppendLine('</tbody></table>')
        }
        if ($bac.endedFailedList -and @($bac.endedFailedList).Count -gt 0) {
            [void]$sb.AppendLine('<h3>Devices that ended Failed</h3><table class="data"><thead><tr><th>Device</th><th>Failed</th><th>OK</th><th>Flips</th></tr></thead><tbody>')
            foreach ($row in @($bac.endedFailedList)) {
                [void]$sb.AppendLine(('<tr><td class="mono">{0}</td><td>{1}</td><td>{2}</td><td>{3}</td></tr>' -f `
                    (& $e ([string]$row.device)), [int]$row.failed, [int]$row.ok, [int]$row.flips))
            }
            [void]$sb.AppendLine('</tbody></table>')
        }
        if ($bac.objectListSample) {
            [void]$sb.AppendLine(('<p class="muted mono">Object-list example: {0}</p>' -f (& $e ([string]$bac.objectListSample))))
        }
        if ($bac.objectListTop -and @($bac.objectListTop).Count -gt 0) {
            [void]$sb.AppendLine('<h3>Top object-list devices</h3>')
            Add-SnapCountNameTable -Sb $sb -Encode $e -Rows $bac.objectListTop -NameKey 'device' -NameHeader 'Device'
        }
        if ([int]$bac.collectTrend -gt 0 -or ($bac.collectTrendCodes -and @($bac.collectTrendCodes).Count -gt 0)) {
            [void]$sb.AppendLine('<h3>BACnetCollectTrend</h3>')
            if ($bac.collectTrendSample) {
                [void]$sb.AppendLine(('<p class="muted mono">{0}</p>' -f (& $e ([string]$bac.collectTrendSample))))
            }
            if ($bac.collectTrendCodes -and @($bac.collectTrendCodes).Count -gt 0) {
                [void]$sb.AppendLine('<p class="meta">Error codes</p>')
                Add-SnapCountNameTable -Sb $sb -Encode $e -Rows $bac.collectTrendCodes -NameKey 'code' -NameHeader 'Code'
            }
            if ($bac.collectTrendTop -and @($bac.collectTrendTop).Count -gt 0) {
                [void]$sb.AppendLine('<p class="meta">Top properties</p>')
                Add-SnapCountNameTable -Sb $sb -Encode $e -Rows $bac.collectTrendTop -NameKey 'property' -NameHeader 'Property'
            }
        }
        if ([int]$bac.timeSync -gt 0 -or ($bac.timeSyncCodes -and @($bac.timeSyncCodes).Count -gt 0)) {
            [void]$sb.AppendLine('<h3>BACnetTimeSync</h3>')
            if ($bac.timeSyncSample) {
                [void]$sb.AppendLine(('<p class="muted mono">{0}</p>' -f (& $e ([string]$bac.timeSyncSample))))
            }
            if ($bac.timeSyncCodes -and @($bac.timeSyncCodes).Count -gt 0) {
                [void]$sb.AppendLine('<p class="meta">Error codes</p>')
                Add-SnapCountNameTable -Sb $sb -Encode $e -Rows $bac.timeSyncCodes -NameKey 'code' -NameHeader 'Code'
            }
            if ($bac.timeSyncTop -and @($bac.timeSyncTop).Count -gt 0) {
                [void]$sb.AppendLine('<p class="meta">Top properties</p>')
                Add-SnapCountNameTable -Sb $sb -Encode $e -Rows $bac.timeSyncTop -NameKey 'property' -NameHeader 'Property'
            }
        }
        if ($bac.lifecycle -and $bac.lifecycle.managers -and @($bac.lifecycle.managers).Count -gt 0) {
            [void]$sb.AppendLine('<h3>BACnet manager health</h3><table class="data"><thead><tr><th>Manager</th><th>Starts</th><th>Stops</th><th>Restarts</th><th>Blocking</th><th>Unblocked</th></tr></thead><tbody>')
            foreach ($r in @($bac.lifecycle.managers)) {
                [void]$sb.AppendLine(('<tr><td class="mono">{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td><td>{5}</td></tr>' -f `
                    (& $e ([string]$r.name)), [int]$r.starts, [int]$r.stops, [int]$r.restarts, [int]$r.blocking, [int]$r.unblocked))
            }
            [void]$sb.AppendLine('</tbody></table>')
        }
    }
    else {
        [void]$sb.AppendLine('<p class="muted">No BACnet data.</p>')
    }
    [void]$sb.AppendLine('</div></section>')
    }

    $cns = $Snap.cns
    if ($inc.cns) {
    [void]$sb.AppendLine('<section id="cns"><h2>CNS</h2><div class="card">')
    if ($cns) {
        [void]$sb.AppendLine(('<p>ResolveNodes: <strong>{0:N0}</strong> &middot; ReducedFunction: <strong>{1:N0}</strong> &middot; ICns: <strong>{2:N0}</strong> &middot; TryRenewSession: <strong>{3:N0}</strong></p>' -f `
            [int]$cns.resolveNodes, [int]$cns.reducedFunction, [int]$cns.icns, [int]$cns.tryRenew))
        if ($cns.patterns -and @($cns.patterns).Count -gt 0) {
            [void]$sb.AppendLine('<h3>CNS patterns</h3>')
            Add-SnapPatternTable -Sb $sb -Encode $e -Rows $cns.patterns
        }
        if ($cns.lifecycle -and $cns.lifecycle.managers -and @($cns.lifecycle.managers).Count -gt 0) {
            [void]$sb.AppendLine('<h3>CNS-related manager health</h3><table class="data"><thead><tr><th>Manager</th><th>Starts</th><th>Stops</th><th>Restarts</th><th>Blocking</th><th>Unblocked</th></tr></thead><tbody>')
            foreach ($r in @($cns.lifecycle.managers)) {
                [void]$sb.AppendLine(('<tr><td class="mono">{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td><td>{5}</td></tr>' -f `
                    (& $e ([string]$r.name)), [int]$r.starts, [int]$r.stops, [int]$r.restarts, [int]$r.blocking, [int]$r.unblocked))
            }
            [void]$sb.AppendLine('</tbody></table>')
        }
    }
    else { [void]$sb.AppendLine('<p class="muted">No CNS data.</p>') }
    [void]$sb.AppendLine('</div></section>')
    }

    $coho = $Snap.coho
    if ($inc.coho) {
    [void]$sb.AppendLine('<section id="coho"><h2>CoHo</h2><div class="card">')
    if ($coho) {
        [void]$sb.AppendLine(('<p>Stuck/drop: <strong>{0:N0}</strong></p>' -f [int]$coho.stuck))
        if ($coho.sample) { [void]$sb.AppendLine(('<p class="mono meta">{0}</p>' -f (& $e ([string]$coho.sample)))) }
        if ($coho.topNames -and @($coho.topNames).Count -gt 0) {
            [void]$sb.AppendLine('<h3>Top stuck names</h3>')
            Add-SnapCountNameTable -Sb $sb -Encode $e -Rows $coho.topNames -NameKey 'name' -NameHeader 'Name'
        }
        if ($coho.lifecycle -and $coho.lifecycle.managers -and @($coho.lifecycle.managers).Count -gt 0) {
            [void]$sb.AppendLine('<h3>CoHo manager health</h3><table class="data"><thead><tr><th>Manager</th><th>Starts</th><th>Stops</th><th>Restarts</th><th>Blocking</th><th>Unblocked</th></tr></thead><tbody>')
            foreach ($r in @($coho.lifecycle.managers)) {
                [void]$sb.AppendLine(('<tr><td class="mono">{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td><td>{5}</td></tr>' -f `
                    (& $e ([string]$r.name)), [int]$r.starts, [int]$r.stops, [int]$r.restarts, [int]$r.blocking, [int]$r.unblocked))
            }
            [void]$sb.AppendLine('</tbody></table>')
        }
    }
    else { [void]$sb.AppendLine('<p class="muted">No CoHo data.</p>') }
    [void]$sb.AppendLine('</div></section>')
    }

    $apo = $Snap.apogee
    if ($inc.apogee) {
    [void]$sb.AppendLine('<section id="apogee"><h2>Apogee</h2><div class="card">')
    if ($apo -and (([int]$apo.events + [int]$apo.drvLines + [int]$apo.trendOverflow + [int]$apo.alertId + [int]$apo.getDataFail) -gt 0)) {
        [void]$sb.AppendLine('<h3>CoHo / Orch Apogee</h3>')
        [void]$sb.AppendLine(('<p>Events: <strong>{0:N0}</strong> &middot; UpdatePoints: <strong>{1:N0}</strong> &middot; Trace repetitions: <strong>{2:N0}</strong>{3} &middot; unique PPCL: <strong>{4:N0}</strong></p>' -f `
            [int]$apo.events, [int]$apo.updatePoints, [int]$apo.repetition,
            $(if ([int]$apo.other -gt 0) { (' &middot; Other: <strong>{0:N0}</strong>' -f [int]$apo.other) } else { '' }),
            [int]$apo.uniquePpcl))
        if ($apo.sample) { [void]$sb.AppendLine(('<p class="muted mono">{0}</p>' -f (& $e ([string]$apo.sample)))) }
        if ($apo.topPpcl -and @($apo.topPpcl).Count -gt 0) {
            [void]$sb.AppendLine('<p class="meta">Top PPCL programs by UpdatePoints</p>')
            Add-SnapCountNameTable -Sb $sb -Encode $e -Rows $apo.topPpcl -NameKey 'name' -NameHeader 'PPCL'
        }
        [void]$sb.AppendLine('<h3>WCCOAApogeeDrv</h3>')
        [void]$sb.AppendLine(('<p>Driver lines: <strong>{0:N0}</strong> &middot; trend overflow: <strong>{1:N0}</strong> ({2:N0} devices, {3:N0} trends) &middot; sequence gaps: <strong>{4:N0}</strong></p>' -f `
            [int]$apo.drvLines, [int]$apo.trendOverflow, [int]$apo.trendDevices, [int]$apo.trendNames, [int]$apo.trendSeq))
        [void]$sb.AppendLine(('<p>AlertID: <strong>{0:N0}</strong> &middot; query timeout: <strong>{1:N0}</strong> &middot; get-data fail: <strong>{2:N0}</strong> ({3:N0} devices)</p>' -f `
            [int]$apo.alertId, [int]$apo.queryTimeout, [int]$apo.getDataFail, [int]$apo.getDataDevices))
        if ($apo.trendSample) { [void]$sb.AppendLine(('<p class="muted mono">Trend example: {0}</p>' -f (& $e ([string]$apo.trendSample)))) }
        if ($apo.alertSample) { [void]$sb.AppendLine(('<p class="muted mono">AlertID example: {0}</p>' -f (& $e ([string]$apo.alertSample)))) }
        if ($apo.timeoutSample) { [void]$sb.AppendLine(('<p class="muted mono">Timeout example: {0}</p>' -f (& $e ([string]$apo.timeoutSample)))) }
        if ($apo.getDataSample) { [void]$sb.AppendLine(('<p class="muted mono">Get-data example: {0}</p>' -f (& $e ([string]$apo.getDataSample)))) }
        if ($apo.topTrendDevices -and @($apo.topTrendDevices).Count -gt 0) {
            [void]$sb.AppendLine('<p class="meta">Top devices by trend overflow</p>')
            Add-SnapCountNameTable -Sb $sb -Encode $e -Rows $apo.topTrendDevices -NameKey 'device' -NameHeader 'Device'
        }
        if ($apo.topTrends -and @($apo.topTrends).Count -gt 0) {
            [void]$sb.AppendLine('<p class="meta">Top trends by overflow</p>')
            Add-SnapCountNameTable -Sb $sb -Encode $e -Rows $apo.topTrends -NameKey 'trend' -NameHeader 'Trend'
        }
        if ($apo.topGetDataDevices -and @($apo.topGetDataDevices).Count -gt 0) {
            [void]$sb.AppendLine('<p class="meta">Top devices by get-data failure</p>')
            Add-SnapCountNameTable -Sb $sb -Encode $e -Rows $apo.topGetDataDevices -NameKey 'device' -NameHeader 'Device'
        }
        if ($apo.lifecycle -and $apo.lifecycle.managers -and @($apo.lifecycle.managers).Count -gt 0) {
            [void]$sb.AppendLine('<h3>ApogeeDrv manager health</h3><table class="data"><thead><tr><th>Manager</th><th>Starts</th><th>Stops</th><th>Restarts</th><th>Blocking</th><th>Unblocked</th></tr></thead><tbody>')
            foreach ($r in @($apo.lifecycle.managers)) {
                [void]$sb.AppendLine(('<tr><td class="mono">{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td><td>{5}</td></tr>' -f `
                    (& $e ([string]$r.name)), [int]$r.starts, [int]$r.stops, [int]$r.restarts, [int]$r.blocking, [int]$r.unblocked))
            }
            [void]$sb.AppendLine('</tbody></table>')
        }
    }
    else { [void]$sb.AppendLine('<p class="muted">No Apogee data.</p>') }
    [void]$sb.AppendLine('</div></section>')
    }

    if ($inc.detections) {
        Add-SnapDetectionsSection -Sb $sb -Encode $e -Detections $Snap.detections
    }

    if ($inc.perf) {
    [void]$sb.AppendLine('<section id="perf"><h2>Perf / parse notes</h2><div class="card">')
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
    [void]$sb.AppendLine('</div></section>')
    }

    [void]$sb.AppendLine(('<footer>Snapshot from live Watch state (no re-scan). Watch v{0} &middot; tool by {1}.</footer>' -f `
        (& $e $Snap.meta.version), (& $e $script:Author)))
    [void]$sb.AppendLine('</main></body></html>')
    return $sb.ToString()
}

# Second renderer over the same Build-SnapshotObject result - never text-scraped from HTML.
# Section headers, column widths and wording follow OfflineAnalyze 1.3 so an operator moving
# from the old tool reads the same report.
function script:Convert-SnapshotToText {
    param($Snap)
    $inc = Get-ReportSections -Snap $Snap
    $sb = New-Object System.Text.StringBuilder
    $W = {
        param($Text = '')
        [void]$sb.AppendLine([string]$Text)
    }

    $meta = $Snap.meta
    $win = $Snap.window
    & $W '================================================================================'
    & $W ' PVSS / WinCC OA Log Analysis Report'
    & $W '================================================================================'
    & $W ("Tool      : {0} v{1} by {2}" -f $meta.tool, $meta.version, $script:Author)
    & $W ("Generated : {0}" -f $meta.generated)
    & $W ("Log file  : {0}" -f $meta.logPath)
    & $W ("Size      : {0:N2} MB" -f ([double]$meta.fileLength / 1MB))
    & $W ("Lines     : {0:N0} analyzed (WinCC OA header, in window)" -f [int]$meta.parsedLines)
    & $W ("Time span : {0}  -->  {1}" -f $win.first, $win.last)
    & $W ''

    $opt = $Snap.options
    & $W '--- Options used ---'
    if ($opt) {
        & $W (" Organize      : {0}" -f $opt.organize)
        & $W (" Severities    : {0}" -f ((@($opt.severities)) -join ', '))
        & $W (" Areas         : {0}" -f ((@($opt.areas)) -join ', '))
        if (@($opt.drivers).Count -gt 0) { & $W (" Drivers       : {0}" -f ((@($opt.drivers)) -join ', ')) }
        & $W (" TopN          : {0}" -f [int]$opt.topN)
        & $W (" Sample/patt   : {0}" -f [int]$opt.samplePerPattern)
        & $W (" Time mode     : {0}" -f $(if ([string]$opt.window -eq 'entire') { 'entire file' } else { ('last {0:N0} minutes' -f [int]$opt.lastMinutes) }))
        & $W (" Format        : {0}" -f $opt.format)
    }
    & $W ''

    & $W '--- Findings ---'
    foreach ($f in @($Snap.findings)) { & $W (" * {0}" -f $f) }
    & $W ''

    & $W '--- Severity counts ---'
    foreach ($s in @('FATAL', 'SEVERE', 'ERROR', 'WARNING', 'INFO')) {
        $n = 0
        if ($Snap.severityCounts -and $null -ne $Snap.severityCounts.$s) { $n = [int]$Snap.severityCounts.$s }
        & $W (' {0,8:N0}  {1}' -f $n, $s)
    }
    & $W ''

    & $W '--- Area counts ---'
    foreach ($a in @('SYS', 'IMPL', 'CTRL', 'PARAM', 'OTHER')) {
        $n = 0
        if ($Snap.areaCounts -and $null -ne $Snap.areaCounts.$a) { $n = [int]$Snap.areaCounts.$a }
        & $W (' {0,8:N0}  {1}' -f $n, $a)
    }
    & $W ''

    if ($inc.moduleHeadlines) {
        $mh = $Snap.moduleHeadlines
        & $W '--- Module headlines ---'
        & $W (' BACnet : Failed={0:N0} OK={1:N0} endedFailed={2:N0} endedOK={3:N0} flappers={4:N0} objectList={5:N0} CollectTrend={6:N0} ({7:N0} props) TimeSync={8:N0} ({9:N0} props)' -f `
            [int]$mh.bacnet.failed, [int]$mh.bacnet.ok, [int]$mh.bacnet.endedFailed, [int]$mh.bacnet.endedOk,
                [int]$mh.bacnet.flappers, [int]$mh.bacnet.objectList, [int]$mh.bacnet.collectTrend,
                [int]$mh.bacnet.collectTrendProps, [int]$mh.bacnet.timeSync, [int]$mh.bacnet.timeSyncProps)
        & $W (' CNS    : ResolveNodes={0:N0} ReducedFunction={1:N0} TryRenewSession={2:N0}' -f `
            [int]$mh.cns.resolveNodes, [int]$mh.cns.reducedFunction, [int]$mh.cns.tryRenew)
        & $W (' CoHo   : stuck/drop={0:N0}' -f [int]$mh.coho.stuck)
        & $W (' Apogee : events={0:N0} UpdatePoints={1:N0} | Drv overflow={2:N0} seq={3:N0} AlertID={4:N0} getData={5:N0}' -f `
            [int]$mh.apogee.events, [int]$mh.apogee.updatePoints, [int]$mh.apogee.trendOverflow,
                [int]$mh.apogee.trendSeq, [int]$mh.apogee.alertId, [int]$mh.apogee.getDataFail)
        & $W ''
    }

    $pl = $Snap.projectLifecycle
    & $W '--- Project restarts (pmon) ---'
    & $W ' Each row is one cycle: up -> shutdown -> stopped -> next up. Uptime = up to shutdown; stop = shutdown to stopped; downtime = stopped to next up (blank when still down). START_MODE counted only (too frequent to list).'
    if ($pl) {
        $cycles = @($pl.cycles)
        & $W ('  up={0:N0}  stopped={1:N0}  shutdown={2:N0}  START_MODE={3:N0}  cycles={4:N0}{5}' -f `
            [int]$pl.up, [int]$pl.stopped, [int]$pl.shutdown, [int]$pl.startMode, $cycles.Count,
                $(if ($pl.capped) { '  (events capped at 200)' } else { '' }))
        if ($cycles.Count -gt 0) {
            & $W ' | Up | Shutdown | Uptime | Stopped | Stop | Downtime | Note |'
            foreach ($c in $cycles) {
                $note = @()
                if ($c.upImplied) { $note += 'up implied (window start)' }
                if ($c.stillUp) { $note += 'still up' }
                if ($c.stillDown) { $note += 'still down' }
                & $W (' | {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f `
                    $c.up, $c.shutdown, $c.uptime, $c.stopped, $c.stopDuration, $c.downtime, ($note -join '; '))
            }
        }
        else { & $W '   (none listed)' }
    }
    & $W ''

    $mhz = $Snap.managerHealth
    & $W '--- Manager health (pmon) ---'
    & $W ' Start/stop = Manager Start PROJ / Manager Stop. Restarts = Detected stopped manager. Blocking = no heartbeat (busy/overloaded).'
    if ($mhz -and $mhz.totals) {
        $t = $mhz.totals
        & $W ('  Starts={0:N0}  Stops={1:N0}  Auto-restarts={2:N0}  Blocking={3:N0}  Unblocked={4:N0}  Driver-ready={5:N0}' -f `
            [int]$t.starts, [int]$t.stops, [int]$t.restarts, [int]$t.blocking, [int]$t.unblocked, [int]$mhz.driverReady)
        & $W '  Per-manager (top 25 by activity):'
        & $W ('   {0,-40} {1,7} {2,7} {3,8} {4,9} {5,9}' -f 'Manager', 'Starts', 'Stops', 'Restart', 'Blocking', 'Unblock')
        foreach ($r in @($mhz.managers)) {
            & $W ('   {0,-40} {1,7:N0} {2,7:N0} {3,8:N0} {4,9:N0} {5,9:N0}' -f `
                $r.name, [int]$r.starts, [int]$r.stops, [int]$r.restarts, [int]$r.blocking, [int]$r.unblocked)
        }
    }
    & $W ''

    if ($inc.managers) {
        # Watch ranks 20 managers for the dashboard regardless of TopN, so the heading
        # reports the list length rather than promising TopN like V1.3 did.
        $mgrs = @($Snap.topManagers)
        & $W ('--- Top {0} components (managers) ---' -f $mgrs.Count)
        foreach ($m in $mgrs) { & $W (' {0,8:N0}  {1}' -f [int]$m.count, $m.name) }
        & $W ''
    }

    if ($inc.perf) {
        & $W '--- Performance-related keyword categories ---'
        $pc = @($Snap.perf.perfCategories)
        if ($pc.Count -eq 0) { & $W ' (none matched)' }
        else { foreach ($row in $pc) { & $W (' {0,8:N0}  {1}' -f [int]$row.count, $row.name) } }
        & $W ''
    }

    if ($inc.hourly) {
        $hr = $Snap.hourly
        if ($hr.truncated) {
            & $W '--- Hourly volume (most recent 24 hours) ---'
            & $W (' Hours in analyzed window: {0:N0} (showing most recent 24 + top 10 busiest)' -f [int]$hr.hourCount)
        }
        else {
            & $W '--- Hourly volume (all parsed / SEVERE / WARNING) ---'
            & $W (' Hours in analyzed window: {0:N0}' -f [int]$hr.hourCount)
        }
        & $W (' {0,-16} {1,10} {2,10} {3,10}' -f 'Hour', 'All', 'SEVERE', 'WARNING')
        foreach ($r in @($hr.rows)) {
            & $W (' {0,-16} {1,10:N0} {2,10:N0} {3,10:N0}' -f $r.hour, [int]$r.total, [int]$r.severe, [int]$r.warning)
        }
        if ($hr.truncated) {
            & $W ''
            & $W '--- Busiest hours (top 10 by total lines) ---'
            & $W (' {0,-16} {1,10} {2,10} {3,10}' -f 'Hour', 'All', 'SEVERE', 'WARNING')
            foreach ($r in @($hr.busiest)) {
                & $W (' {0,-16} {1,10:N0} {2,10:N0} {3,10:N0}' -f $r.hour, [int]$r.total, [int]$r.severe, [int]$r.warning)
            }
        }
        & $W ''
    }

    if ($inc.bacnet) {
        $bac = $Snap.bacnet
        & $W '--- BACnet module ---'
        if ($bac) {
            & $W ' Device status (INFO)'
            & $W ('  Failed transitions : {0:N0}  (unique devices: {1:N0})' -f [int]$bac.failed, [int]$bac.failedDevices)
            & $W ('  OK transitions     : {0:N0}  (unique devices: {1:N0})' -f [int]$bac.ok, [int]$bac.okDevices)
            & $W ('  Last-known status  : ended Failed={0:N0}  ended OK={1:N0}  (devices seen in window)' -f [int]$bac.endedFailed, [int]$bac.endedOk)
            & $W ('  Flapping (>= {0} Failed/OK changes): {1:N0} devices' -f [int]$script:BacFlapMin, [int]$bac.flappers)
            $act = @($bac.activity)
            if ($act.Count -gt 0) {
                & $W ''
                & $W '  Device status activity (top 20 by Failed transitions):'
                & $W '   rank   Failed     OK  flips  device'
                $rank = 0
                foreach ($r in $act) {
                    $rank++
                    & $W ('   {0,4}  {1,6:N0}  {2,6:N0}  {3,5:N0}  {4}' -f $rank, [int]$r.failed, [int]$r.ok, [int]$r.flips, $r.device)
                }
            }
            $ended = @($bac.endedFailedList)
            & $W ''
            & $W '  Devices that ended Failed (last-known in window, top 20):'
            if ($ended.Count -eq 0) { & $W '   (none)' }
            else {
                & $W '   rank   Failed     OK  flips  device'
                $rank = 0
                foreach ($r in $ended) {
                    $rank++
                    & $W ('   {0,4}  {1,6:N0}  {2,6:N0}  {3,5:N0}  {4}' -f $rank, [int]$r.failed, [int]$r.ok, [int]$r.flips, $r.device)
                }
            }
            & $W ''
            & $W ' Object list (WARNING)'
            & $W ('  Events            : {0:N0}  (unique devices: {1:N0})' -f [int]$bac.objectList, [int]$bac.objectListDevices)
            $objTop = @($bac.objectListTop)
            if ($objTop.Count -gt 0) {
                & $W '  Top devices by object-list warnings:'
                $rank = 0
                foreach ($r in $objTop) { $rank++; & $W ('   {0,2}. {1,8:N0}  device {2}' -f $rank, [int]$r.count, $r.device) }
            }
            foreach ($cmd in @(
                    @{ Label = ' BACnetCollectTrend (driver trend-collection command failures; often CoHo / Log_Enable)'
                        N = [int]$bac.collectTrend; Props = [int]$bac.collectTrendProps
                        Codes = @($bac.collectTrendCodes); Top = @($bac.collectTrendTop)
                    },
                    @{ Label = ' BACnetTimeSync (driver time-sync command failures; often CoHo / Local_Time)'
                        N = [int]$bac.timeSync; Props = [int]$bac.timeSyncProps
                        Codes = @($bac.timeSyncCodes); Top = @($bac.timeSyncTop)
                    }
                )) {
                & $W ''
                & $W $cmd.Label
                & $W ('  Events             : {0:N0}  (unique properties: {1:N0})' -f $cmd.N, $cmd.Props)
                if (@($cmd.Codes).Count -gt 0) {
                    & $W '  Error codes:'
                    foreach ($c in @($cmd.Codes)) { & $W ('    {0,8}  {1:N0}' -f $c.code, [int]$c.count) }
                }
                if (@($cmd.Top).Count -gt 0) {
                    & $W '  Top properties:'
                    $rank = 0
                    foreach ($c in @($cmd.Top)) { $rank++; & $W ('   {0,4}  {1,6:N0}  {2}' -f $rank, [int]$c.count, $c.property) }
                }
            }
        }
        else { & $W ' (no BACnet data)' }
        & $W ''
    }

    if ($inc.cns) {
        $cns = $Snap.cns
        & $W '--- CNS module (thin) ---'
        & $W ('  ResolveNodes     : {0:N0}' -f [int]$cns.resolveNodes)
        & $W ('  ReducedFunction  : {0:N0}' -f [int]$cns.reducedFunction)
        & $W ('  ICns             : {0:N0}' -f [int]$cns.icns)
        & $W ('  TryRenewSession  : {0:N0}' -f [int]$cns.tryRenew)
        & $W ('  Top CNS-related patterns (top {0}):' -f [int]$opt.topN)
        Add-TextPatternBlock -Writer $W -Rows @($cns.patterns) -Indent '  '
        if (@($cns.patterns).Count -eq 0) { & $W '  (none)' }
        & $W ''
    }

    if ($inc.coho) {
        $coho = $Snap.coho
        & $W '--- CoHo module (thin) ---'
        & $W ('  Stuck/drop messages : {0:N0}' -f [int]$coho.stuck)
        if ($coho.sample) { & $W ("  Example             : {0}" -f $coho.sample) }
        & $W '  Top stuck names:'
        $rank = 0
        foreach ($n in @($coho.topNames)) { $rank++; & $W ('   {0,2}. {1,8:N0}  {2}' -f $rank, [int]$n.count, $n.name) }
        if ($rank -eq 0) { & $W '   (none parsed)' }
        & $W ''
    }

    if ($inc.apogee) {
        $apo = $Snap.apogee
        & $W '--- Apogee module ---'
        & $W ' CoHo.Apogee* / Orch.Apogee* (orchestration / ApogeeBACnet path)'
        & $W ('  Events              : {0:N0}' -f [int]$apo.events)
        & $W ('  UpdatePoints        : {0:N0}' -f [int]$apo.updatePoints)
        & $W ('  Trace repetitions   : {0:N0}' -f [int]$apo.repetition)
        if ([int]$apo.other -gt 0) { & $W ('  Other               : {0:N0}' -f [int]$apo.other) }
        & $W ('  Unique PPCL programs: {0:N0}' -f [int]$apo.uniquePpcl)
        if ($apo.sample) { & $W ("  Example             : {0}" -f $apo.sample) }
        & $W '  Top PPCL programs by UpdatePoints:'
        $rank = 0
        foreach ($p in @($apo.topPpcl)) { $rank++; & $W ('   {0,2}. {1,8:N0}  {2}' -f $rank, [int]$p.count, $p.name) }
        if ($rank -eq 0) { & $W '   (none parsed)' }
        & $W ''
        & $W ' WCCOAApogeeDrv (native Apogee driver)'
        & $W ('  Driver lines        : {0:N0}' -f [int]$apo.drvLines)
        & $W ('  Trend buffer overflow: {0:N0}  (unique devices: {1:N0}, unique trends: {2:N0})' -f `
            [int]$apo.trendOverflow, [int]$apo.trendDevices, [int]$apo.trendNames)
        & $W ('  Sequence-gap lines  : {0:N0}  (Last sequence number... companion warnings)' -f [int]$apo.trendSeq)
        & $W ('  AlertID issues      : {0:N0}' -f [int]$apo.alertId)
        & $W ('  Query timeouts      : {0:N0}' -f [int]$apo.queryTimeout)
        & $W ('  Get-data failures   : {0:N0}  (unique devices: {1:N0})' -f [int]$apo.getDataFail, [int]$apo.getDataDevices)
        if ($apo.trendSample) { & $W ("  Trend example       : {0}" -f $apo.trendSample) }
        if ($apo.alertSample) { & $W ("  AlertID example     : {0}" -f $apo.alertSample) }
        if ($apo.timeoutSample) { & $W ("  Timeout example     : {0}" -f $apo.timeoutSample) }
        if ($apo.getDataSample) { & $W ("  Get-data example    : {0}" -f $apo.getDataSample) }
        foreach ($blk in @(
                @{ H = '  Top devices by trend overflow:'; Rows = @($apo.topTrendDevices); K = 'device' },
                @{ H = '  Top trends by overflow:'; Rows = @($apo.topTrends); K = 'trend' },
                @{ H = '  Top devices by get-data failure:'; Rows = @($apo.topGetDataDevices); K = 'device' }
            )) {
            if (@($blk.Rows).Count -eq 0) { continue }
            & $W $blk.H
            $rank = 0
            foreach ($r in @($blk.Rows)) { $rank++; & $W ('   {0,4}  {1,6:N0}  {2}' -f $rank, [int]$r.count, $r.($blk.K)) }
        }
        & $W ''
    }

    if ($inc.detections) {
        foreach ($g in @($Snap.detections)) {
            & $W ('--- Detections: {0} ---' -f $g.group)
            & $W (' {0:N0} line(s) across {1:N0} rule(s)' -f [int]$g.total, @($g.rules).Count)
            foreach ($r in @($g.rules)) {
                & $W ''
                & $W (' === {0} ===' -f $r.label)
                $ms = $r.measures
                if ($ms -and @($ms.Keys).Count -gt 0) {
                    foreach ($mk in @($ms.Keys)) { & $W ('   {0,-14}: {1:N0}' -f $mk, $ms[$mk]) }
                    & $W ('   {0,-14}: {1:N0}' -f 'lines', [int]$r.count)
                }
                else { & $W ('   {0,-14}: {1:N0}' -f 'lines', [int]$r.count) }
                if ($r.severities -and @($r.severities.Keys).Count -gt 0) {
                    $sp = @(); foreach ($sk in @($r.severities.Keys)) { $sp += ('{0}={1:N0}' -f $sk, [int]$r.severities[$sk]) }
                    & $W ('   {0,-14}: {1}' -f 'severities', ($sp -join ' '))
                }
                & $W ('   {0,-14}: {1}  -->  {2}  ({3})' -f 'window', $r.first, $r.last, (Format-DurationLabel -Seconds $r.spanSec))
                $over = Format-RuleOverLabel -Rule $r
                if ($over) {
                    & $W ('   {0,-14}: {1:N0} line(s) - {2}{3}' -f 'threshold', [int]$r.findingAt, $over,
                        $(if ([double]$r.over -ge 1) { ' EXCEEDED' } else { '' }))
                }
                & $W ('   {0,-14}: {1}' -f 'rule', $r.id)
                if ($r.sample) { & $W ('   {0,-14}: {1}' -f 'example', $r.sample) }
                if ($r.buckets) {
                    foreach ($bn in @($r.buckets.Keys)) {
                        $b = $r.buckets[$bn]
                        $rows = @($b.top)
                        if ($rows.Count -eq 0) { continue }
                        # A single distinct value does not need a ranked list under it.
                        if ([int]$b.distinct -eq 1 -and $rows.Count -eq 1) {
                            & $W ('   {0,-14}: all from {1}' -f $bn, $rows[0].value)
                            continue
                        }
                        & $W ('   By {0} ({1:N0} distinct{2}):' -f $bn, [int]$b.distinct, $(if ($b.capped) { ', capped' } else { '' }))
                        $rank = 0
                        foreach ($x in $rows) { $rank++; & $W ('    {0,3}. {1,8:N0}  {2}' -f $rank, [int]$x.count, $x.value) }
                    }
                }
            }
            & $W ''
        }
    }

    if ($inc.driverDeepDive) {
        & $W '--- Driver deep-dive ---'
        foreach ($dd in @($Snap.driverDeepDive)) {
            & $W ''
            & $W ("=== {0} ===" -f $dd.name)
            & $W (' Total lines: {0:N0}' -f [int]$dd.count)
            & $W ' Severity mix:'
            foreach ($s in @('FATAL', 'SEVERE', 'ERROR', 'WARNING', 'INFO')) {
                & $W ('  {0,8:N0}  {1}' -f [int]$dd.severities.$s, $s)
            }
            foreach ($s in @('FATAL', 'SEVERE', 'ERROR', 'WARNING')) {
                & $W (" Patterns - {0} (top {1}):" -f $s, [int]$opt.topN)
                $list = @()
                if ($dd.patternsBySeverity -and $dd.patternsBySeverity.$s) { $list = @($dd.patternsBySeverity.$s) }
                if ($list.Count -eq 0) { & $W '  (none)'; continue }
                Add-TextPatternBlock -Writer $W -Rows $list -Heading $null -Indent '  '
            }
        }
        & $W ''
    }

    if ($inc.severityPatterns) {
        & $W '--- Top patterns by severity ---'
        foreach ($s in @('FATAL', 'SEVERE', 'ERROR', 'WARNING')) {
            $list = @()
            if ($Snap.patternsBySeverity -and $Snap.patternsBySeverity.$s) { $list = @($Snap.patternsBySeverity.$s) }
            & $W ''
            & $W (" {0} (top {1}):" -f $s, [int]$opt.topN)
            if ($list.Count -eq 0) { & $W '   (none)'; continue }
            Add-TextPatternBlock -Writer $W -Rows $list -Heading $null -Indent '  '
        }
        & $W ''
    }

    & $W '--- Notes ---'
    & $W ' Project restart events are capped at 200; manager health lists the top 25 managers.'
    & $W (' Parsed lines: {0:N0}   Unparsed / skipped: {1:N0}' -f [int]$meta.parsedLines, [int]$Snap.perf.unparsedLines)
    & $W ''
    & $W ("Report from live Watch state (no re-scan). Watch v{0} - tool by {1}." -f $meta.version, $script:Author)
    return $sb.ToString()
}

function script:Add-TextPatternBlock {
    param($Writer, $Rows, [string]$Heading = $null, [string]$Indent = ' ')
    $list = @($Rows)
    if ($list.Count -eq 0) { return }
    if ($Heading) { & $Writer $Heading }
    $rank = 0
    foreach ($row in $list) {
        $rank++
        & $Writer ''
        & $Writer ('{0} #{1}  count={2:N0}' -f $Indent, $rank, [int]$row.count)
        & $Writer ('{0}     pattern: {1}' -f $Indent, $row.pattern)
        if ($row.first) { & $Writer ('{0}     first  : {1}' -f $Indent, $row.first) }
        if ($row.last) { & $Writer ('{0}     last   : {1}' -f $Indent, $row.last) }
        foreach ($ex in @($row.samples)) {
            if ($ex) { & $Writer ('{0}     example: {1}' -f $Indent, $ex) }
        }
    }
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
                    areas        = @($script:DefaultAreas)
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
            Write-WatchLog ("Start accepted  -  validating path: {0}" -f $p) Cyan
            [void](Assert-LogPathUsable -Path $p)
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
                    try {
                        $reload = Apply-WatchConfig -Runtime
                        foreach ($w in $reload.Warnings) { Write-WatchLog ("Config: {0}" -f $w) Yellow }
                        if ($reload.Changes.Count -gt 0) {
                            foreach ($c in $reload.Changes) { Write-WatchLog ("Config reload  {0}" -f $c) Cyan }
                        }
                        else { Write-WatchLog 'Config reload: no changes' DarkCyan }
                        foreach ($s in $reload.Skipped) { Write-WatchLog ("Config reload  {0}" -f $s) Yellow }
                    }
                    catch {
                        Write-WatchLog ("Config reload failed, keeping current settings: {0}" -f $_.Exception.Message) Red
                    }
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
        $areas = Parse-QueryAreas -Q $req.QueryString
        $since = $req.QueryString['sinceGeneration']
        if ($since -and ("$since" -eq "$($script:Sync['Generation'])") -and -not $script:Sync['Loading']) {
            $Context.Response.StatusCode = 304
            $Context.Response.Headers['ETag'] = ('"{0}"' -f $script:Sync['Generation'])
            $Context.Response.Close()
            return
        }
        $obj = Build-PulseObject -SevFilter $sev -AreaFilter $areas
        Write-JsonResponse -Context $Context -Object $obj -ETag ('"{0}"' -f $script:Sync['Generation'])
        return
    }

    if ($path -eq '/api/section' -and $req.HttpMethod -eq 'GET') {
        $name = $req.QueryString['name']
        if (-not $name) { Write-StatusResponse -Context $Context -Code 400 -Message 'name required'; return }
        $sev = Parse-QuerySevs -Q $req.QueryString
        $areas = Parse-QueryAreas -Q $req.QueryString
        $obj = Build-SectionObject -Name $name -SevFilter $sev -AreaFilter $areas
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
            $areas = Parse-QueryAreas -Q $req.QueryString
            $fmt = ([string]$req.QueryString['format']).ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($fmt)) { $fmt = 'html' }
            $org = [string]$req.QueryString['organize']
            if ($org -notin @('All', 'Severity', 'Driver')) { $org = 'All' }
            $drv = @()
            if ($req.QueryString['drivers']) {
                $drv = @(([string]$req.QueryString['drivers']) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            }
            $snap = Build-SnapshotObject -SevFilter $sev -AreaFilter $areas -Organize $org -Drivers $drv -Format $fmt
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
            elseif ($fmt -eq 'text') {
                $text = Convert-SnapshotToText -Snap $snap
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
                Write-DownloadResponse -Context $Context -Bytes $bytes -ContentType 'text/plain; charset=utf-8' -FileName ("PVSS_Log_Watch_Snapshot_{0}.txt" -f $stamp)
            }
            else {
                Write-StatusResponse -Context $Context -Code 400 -Message 'format must be html, text or json'
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

# --- batch report mode (PRD 5 / 7) ------------------------------------------------
# Same Build-SnapshotObject and renderers as the dashboard; the only difference is that
# nothing binds a port and the catch-up loop runs to completion synchronously.

function script:Read-PromptDefault {
    param([string]$PromptText, [string]$DefaultValue)
    Write-Host ($PromptText + " [default: $DefaultValue]") -ForegroundColor Yellow
    $ans = Read-Host
    if ([string]::IsNullOrWhiteSpace($ans)) { return $DefaultValue }
    return $ans.Trim()
}

function script:Read-PromptTimeBound {
    param(
        [string]$PromptText,
        [string]$DefaultLabel,
        [ValidateSet('From', 'To')][string]$Kind
    )
    while ($true) {
        Write-Host ($PromptText + " [default: $DefaultLabel]") -ForegroundColor Yellow
        $ans = Read-Host
        if ([string]::IsNullOrWhiteSpace($ans)) { return '' }
        $ans = $ans.Trim()
        try {
            [void](Convert-WindowBound -Text $ans -Kind $Kind)
            return $ans
        }
        catch {
            Write-Host ("  {0}" -f $_.Exception.Message) -ForegroundColor Red
            Write-Host '  Examples: 2026.09.04 09:00   or   2026.09.04' -ForegroundColor DarkYellow
        }
    }
}

function script:Get-ReportOutPaths {
    param([string]$LogFile, [string]$Requested, [string]$Fmt)
    $wantText = ($Fmt -eq 'Text' -or $Fmt -eq 'Both')
    $wantHtml = ($Fmt -eq 'Html' -or $Fmt -eq 'Both')
    $stem = if ([string]::IsNullOrWhiteSpace($Requested)) {
        $LogFile + '.analysis'
    }
    else {
        [regex]::Replace($Requested, '(?i)\.(txt|html?)$', '')
    }
    return [ordered]@{
        Text = if ($wantText) { $stem + '.txt' } else { $null }
        Html = if ($wantHtml) { $stem + '.html' } else { $null }
    }
}

function script:Invoke-ReportMode {
    $script:Sync['BatchMode'] = $true
    $bound = $script:CliOverrides
    $log = Resolve-LogPath -Path $LogPath
    $fi = Get-Item -LiteralPath $log

    $fmt = $Format
    $organize = $Organize
    $topN = [int]$script:TopN
    $fromText = $From
    $toText = $To
    $hours = [int]$LastHours
    $sevNames = @($script:DefaultSeverities)
    $areaNames = @($script:DefaultAreas)
    $drivers = @()

    Write-Host ''
    Write-Host ("PVSS Log Watch {0} by {1}  -  report mode" -f $script:Version, $script:Author) -ForegroundColor Cyan
    Write-Host ("Log : {0}" -f $log) -ForegroundColor Cyan
    Write-Host ("Size: {0:N2} MB" -f ($fi.Length / 1MB))

    # --- prompt 1: time window (must precede the scan; it sets the seek offset) ---
    $peekFirst = (Get-ProbeTimestamps -Path $log -SeekPos 0L -MaxBytes 65536L).First
    $peekLast = Get-LogFileEndTimestamp -Path $log
    if ($peekFirst -or $peekLast) {
        Write-Host ("Span: {0}  -->  {1}" -f `
            $(if ($peekFirst) { Format-LogDateTime -Value $peekFirst } else { '?' }),
            $(if ($peekLast) { Format-LogDateTime -Value $peekLast } else { '?' })) -ForegroundColor Cyan
    }
    $windowAsked = ($bound.ContainsKey('From') -or $bound.ContainsKey('To') -or
        $bound.ContainsKey('LastHours') -or $bound.ContainsKey('LastMinutes') -or $bound.ContainsKey('Entire'))
    if ($Interactive -and -not $windowAsked) {
        Write-Host ''
        $mode = Read-PromptDefault -PromptText 'Time filter: [E] Entire file  [H] Last N hours  [W] Absolute From/To' -DefaultValue 'E'
        switch -Regex ($mode) {
            '^[Hh]' {
                if (-not $peekLast) { throw 'Cannot use last-N-hours: no timestamp found near the end of the log.' }
                $h = 0
                while ($h -le 0) {
                    $hAns = Read-PromptDefault -PromptText 'How many hours back from end of log?' -DefaultValue '6'
                    $parsed = 0
                    if ([int]::TryParse($hAns, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 8760) { $h = $parsed }
                    else { Write-Host '  Enter a whole number of hours between 1 and 8760.' -ForegroundColor Red }
                }
                $hours = $h
            }
            '^[Ww]' {
                $fromText = Read-PromptTimeBound -PromptText 'From time (e.g. 2026.09.04 09:00)' -DefaultLabel 'start of file' -Kind From
                $toText = Read-PromptTimeBound -PromptText 'To time   (e.g. 2026.09.04 12:00)' -DefaultLabel 'end of file' -Kind To
            }
            default { $fromText = ''; $toText = '' }
        }
    }

    # LastHours wins over From/To, as in V1.3.
    if ($hours -gt 0) {
        if (-not $peekLast) { throw 'Cannot use -LastHours: no timestamp found near the end of the log.' }
        $fromDt = $peekLast.AddHours(-1 * $hours)
        $toDt = $peekLast
        $fromText = Format-LogDateTime -Value $fromDt
        $toText = Format-LogDateTime -Value $toDt
        Write-Host ("Time filter: last {0} hour(s) ending {1}" -f $hours, (Format-LogDateTime -Value $peekLast)) -ForegroundColor Cyan
    }
    else {
        $fromDt = if ($fromText) { Convert-WindowBound -Text $fromText -Kind From } else { $null }
        $toDt = if ($toText) { Convert-WindowBound -Text $toText -Kind To } else { $null }
    }
    if ($fromDt -and $toDt -and $fromDt -gt $toDt) {
        throw ("-From ({0}) is after -To ({1})." -f $fromText, $toText)
    }

    # --- seed the globals the Build-*Object family reads (PRD 5.1) ---
    $script:Sync['LogPath'] = $log
    $script:Sync['PrefillPath'] = $log
    $script:Sync['FileLength'] = [int64]$fi.Length
    $script:Sync['WindowFrom'] = $fromDt
    $script:Sync['WindowTo'] = $toDt
    if ($fromDt -or $toDt) { $script:Sync['WindowEntire'] = $false }
    elseif ($bound.ContainsKey('LastMinutes')) {
        $script:Sync['WindowEntire'] = $false
        $script:Sync['LastMinutes'] = [int]$LastMinutes
    }
    else {
        # Batch default is the whole file (OfflineAnalyze's default, not Watch's 60m).
        $script:Sync['WindowEntire'] = $true
    }

    Begin-CatchUp -Path $log
    while ([bool]$script:Sync['CatchUpActive']) {
        Step-CatchUp -MaxLines 100000 -MaxMilliseconds 1000
    }
    Close-LogStream
    if ($script:Sync['LastError']) { throw ("Scan failed: {0}" -f $script:Sync['LastError']) }
    $d = $script:Sync['Data']
    if ([int]$d.ParsedLines -eq 0) {
        Write-Host 'No log lines matched the WinCC OA header inside the selected window.' -ForegroundColor Yellow
    }

    # --- prompt 2: organize (post-scan) ---
    if ($Interactive -and -not $bound.ContainsKey('Organize')) {
        Write-Host ''
        $ans = Read-PromptDefault -PromptText 'Organize report: [A] All  [S] Severity  [D] Driver  [Q] Quit' -DefaultValue 'A'
        switch -Regex ($ans) {
            '^[Ss]' { $organize = 'Severity' }
            '^[Dd]' { $organize = 'Driver' }
            '^[Qq]' { $organize = 'Quit' }
            default { $organize = 'All' }
        }
    }
    if ($organize -eq 'Quit') {
        Write-Host 'Quit selected - no report written.' -ForegroundColor Yellow
        Write-ReportSummary -Data $d
        return 0
    }

    # --- prompt 3a: severities + TopN (Severity mode only) ---
    if ($organize -eq 'Severity' -and $Interactive -and -not $bound.ContainsKey('Severities')) {
        Write-Host ''
        Write-Host 'Severities: 1=FATAL 2=SEVERE 3=ERROR 4=WARNING 5=INFO  (critical pack = 1,2,3)'
        $sevAns = Read-PromptDefault -PromptText 'Select severities (e.g. 1,2,3 or FATAL,SEVERE)' -DefaultValue '1,2,3'
        $picked = @(Convert-ToSeverityList -Text $sevAns)
        if ($picked.Count -gt 0) { $sevNames = $picked }
        $topAns = Read-PromptDefault -PromptText 'Top N per severity' -DefaultValue "$topN"
        if ($topAns -match '^\d+$' -and [int]$topAns -ge 5 -and [int]$topAns -le 100) { $topN = [int]$topAns }
    }
    $script:TopN = $topN

    # --- prompt 3b: driver picker (Driver mode only) ---
    if ($organize -eq 'Driver') {
        $sevAll = @{ FATAL = $true; SEVERE = $true; ERROR = $true; WARNING = $true; INFO = $true }
        $ranked = @((Build-SectionObject -Name 'managers' -SevFilter $sevAll).managers)
        if ($Driver) {
            foreach ($part in ($Driver -split ',')) {
                $token = $part.Trim()
                if (-not $token) { continue }
                $n = 0
                if ([int]::TryParse($token, [ref]$n) -and $n -ge 1 -and $n -le $ranked.Count) {
                    $drivers += [string]$ranked[$n - 1].name
                }
                else {
                    foreach ($m in $ranked) {
                        if ([string]$m.name -like "*$token*") { $drivers += [string]$m.name }
                    }
                }
            }
            $drivers = @($drivers | Select-Object -Unique)
            if ($drivers.Count -eq 0) { throw "No manager matched -Driver '$Driver'." }
        }
        elseif ($Interactive) {
            $drivers = @(Select-DriversInteractive -Ranked $ranked)
        }
        elseif ($ranked.Count -gt 0) {
            $drivers = @([string]$ranked[0].name)
            Write-Host ("Organize=Driver with no -Driver: using the busiest manager, {0}." -f $drivers[0]) -ForegroundColor Yellow
        }
    }

    # --- prompt 4: format ---
    if ($Interactive -and -not $bound.ContainsKey('Format')) {
        Write-Host ''
        $ans = Read-PromptDefault -PromptText 'Report format: [T] Text  [H] HTML  [B] Both' -DefaultValue 'B'
        switch -Regex ($ans) {
            '^[Hh]' { $fmt = 'Html' }
            '^[Tt]' { $fmt = 'Text' }
            default { $fmt = 'Both' }
        }
    }

    $sevFilter = @{}
    foreach ($s in @('FATAL', 'SEVERE', 'ERROR', 'WARNING', 'INFO')) { $sevFilter[$s] = ($sevNames -contains $s) }
    $areaFilter = @{}
    foreach ($a in @('SYS', 'IMPL', 'CTRL', 'PARAM', 'OTHER')) { $areaFilter[$a] = ($areaNames -contains $a) }

    $snap = Build-SnapshotObject -SevFilter $sevFilter -AreaFilter $areaFilter `
        -Organize $organize -Drivers $drivers -Format 'html'

    $out = Get-ReportOutPaths -LogFile $log -Requested $OutPath -Fmt $fmt
    $enc = New-Object System.Text.UTF8Encoding $false
    Write-Host ''
    # options.format names the file being written, not the -Format switch, so a Both run
    # produces exactly what two single-format runs would (and matches the dashboard).
    if ($out.Text) {
        $snap.options.format = 'text'
        [System.IO.File]::WriteAllText($out.Text, (Convert-SnapshotToText -Snap $snap), $enc)
        Write-Host ("Text report written to: {0}" -f $out.Text) -ForegroundColor Green
    }
    if ($out.Html) {
        $snap.options.format = 'html'
        [System.IO.File]::WriteAllText($out.Html, (Convert-SnapshotToHtml -Snap $snap), $enc)
        Write-Host ("HTML report written to: {0}" -f $out.Html) -ForegroundColor Green
    }
    Write-ReportSummary -Data $d
    return 0
}

function script:Select-DriversInteractive {
    param($Ranked)
    $ranked = @($Ranked)
    if ($ranked.Count -eq 0) { return @() }
    $picked = @()
    $page = 0
    $pageSize = 10
    while ($picked.Count -eq 0) {
        $start = $page * $pageSize
        if ($start -ge $ranked.Count) { $page = 0; $start = 0 }
        $slice = @($ranked | Select-Object -Skip $start -First $pageSize)
        Write-Host ''
        Write-Host ("Drivers/managers (page {0} of {1}, by volume):" -f ($page + 1),
            [math]::Ceiling($ranked.Count / [double]$pageSize)) -ForegroundColor Cyan
        for ($i = 0; $i -lt $slice.Count; $i++) {
            Write-Host ('  {0,2}. {1,8:N0}  {2}' -f ($i + 1), [int]$slice[$i].count, $slice[$i].name)
        }
        $pick = Read-PromptDefault -PromptText '[1-10] or comma-list  [N]ext  [P]rev  Enter=#1' -DefaultValue '1'
        if ($pick -match '^[Nn]') { $page++; continue }
        if ($pick -match '^[Pp]') { if ($page -gt 0) { $page-- } ; continue }
        foreach ($part in ($pick -split ',')) {
            $n = 0
            if ([int]::TryParse($part.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $slice.Count) {
                $picked += [string]$slice[$n - 1].name
            }
        }
        if ($picked.Count -eq 0 -and $slice.Count -gt 0) { $picked = @([string]$slice[0].name) }
    }
    return @($picked | Select-Object -Unique)
}

function script:Write-ReportSummary {
    param([hashtable]$Data)
    $sw = $script:Sync['LoadSw']
    $secs = if ($sw) { [math]::Round($sw.Elapsed.TotalSeconds, 1) } else { 0 }
    Write-Host ''
    Write-Host ("Parsed {0:N0} lines ({1:N0} unparsed / skipped) in {2}s." -f `
        [int]$Data.ParsedLines, [int]$Data.UnparsedLines, $secs) -ForegroundColor DarkGray
}

# --- main ---
if ($Report) {
    $code = 1
    try { $code = [int](Invoke-ReportMode) }
    catch {
        Write-Host ''
        Write-Host ("Report failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
        $code = 1
    }
    finally { Close-LogStream }
    if (-not $NoPause) {
        Write-Host 'Press Enter to close.'
        [void][Console]::ReadLine()
    }
    exit $code
}

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



