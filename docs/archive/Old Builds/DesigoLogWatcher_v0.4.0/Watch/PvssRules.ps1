# PvssRules.ps1 - declarative detection rules + generic rule engine.
# Dot-sourced by Watch-PvssLog.ps1 (no new scope: script: bindings land in the caller).
# Spec: docs\archive\PRD-V0.4.md section 4.
#
# A rule is one hashtable row:
#   Id           required  stable key 'group.name'; keys state maps and payloads
#   Group        required  section heading; groups rules in reports and the UI
#   Label        required  human text
#   Re           required  pre-compiled [regex]
#   Scope        optional  component substring gate; absent = every line
#   BucketBy     optional  bucketName -> capture index, '$component'/'$area'/'$severity',
#                          or @{ Group = <index>; TrimEnd = '.' }
#   Measure      optional  name -> @{ Group = <index>; Agg = 'Sum'|'Max' }
#   Sample       optional  keep first matching line
#   SampleSlot   optional  share one sample slot across rules (default: Id)
#   PatternGroup optional  feed the legacy per-module pattern maps
#   Curated      derived   see $script:CuratedGroups

# Groups already rendered by a hand-tuned module card; excluded from generic detections.
$script:CuratedGroups = @('BACnet', 'CNS', 'CoHo', 'Apogee')

$script:PvssRules = @(
    # --- CNS (migrated from Process-LogLine; feeds the curated CNS card) ---
    @{ Id = 'cns.resolveNodes'; Group = 'CNS'; Label = 'ResolveNodes'
        Re = [regex]'ResolveNodes'; PatternGroup = 'Cns' }
    @{ Id = 'cns.reducedFunction'; Group = 'CNS'; Label = 'ReducedFunction'
        Re = [regex]'ReducedFunction'; PatternGroup = 'Cns' }
    @{ Id = 'cns.icns'; Group = 'CNS'; Label = 'ICns'
        Re = [regex]'(?i)\bICns\b|ICns\.'; PatternGroup = 'Cns' }
    @{ Id = 'cns.tryRenew'; Group = 'CNS'; Label = 'TryRenewSession'
        Re = [regex]'TryRenewSession'; PatternGroup = 'Cns' }

    # --- ApogeeDrv (migrated; feeds the curated Apogee card) ---
    @{ Id = 'apogeeDrv.trendOverflow'; Group = 'Apogee'; Label = 'Trend buffer overflow'
        Scope = 'ApogeeDrv'
        Re = [regex]'(?i)Trend buffer overflow for trend\s+(.+?)\s+in device\s+(.+?)\.?\s*$'
        BucketBy = @{ trend = 1; device = @{ Group = 2; TrimEnd = '.' } }
        Sample = $true; SampleSlot = 'apogeeDrv.trend' }
    @{ Id = 'apogeeDrv.trendSeq'; Group = 'Apogee'; Label = 'Trend sequence gap'
        Scope = 'ApogeeDrv'
        Re = [regex]'(?i)Last sequence number\s+\d+\s+is greater than saved'
        Sample = $true; SampleSlot = 'apogeeDrv.trend' }
    @{ Id = 'apogeeDrv.alertId'; Group = 'Apogee'; Label = 'AlertID issue'
        Scope = 'ApogeeDrv'
        Re = [regex]'AlertID\s+\S+'
        Sample = $true }
    @{ Id = 'apogeeDrv.queryTimeout'; Group = 'Apogee'; Label = 'Query timeout'
        Scope = 'ApogeeDrv'
        Re = [regex]'(?i)pending answer run into timeout'
        Sample = $true }
    @{ Id = 'apogeeDrv.getDataFail'; Group = 'Apogee'; Label = 'Failed to get data'
        Scope = 'ApogeeDrv'
        Re = [regex]'(?i)Failed to get data for object\s+(.+?)\s+on device\s+([^,]+)'
        BucketBy = @{ device = 2 }
        Sample = $true }

    # --- Platform state -----------------------------------------------------
    # One row collapses the whole family: DrvManager/gotAlertConfigAnswer,
    # AlertService/setAlert, AlertService/sendAck, AlertHistory/commitUpdate.
    @{ Id = 'state.unexpected'; Group = 'Platform'; Label = 'Unexpected state'
        Re = [regex]'Unexpected state,\s*([^,]+?)\s*,\s*([^,]+?)\s*,'
        BucketBy = @{ subsystem = 1; method = 2 }
        Sample = $true; FindingAt = 500 }

    # --- Trending -----------------------------------------------------------
    # 0.3.0 only caught the ApogeeDrv "overflow" / "greater than" variants; these are the
    # BACnet-side counterparts and were going entirely unreported.
    # "trend log object" is BACnet's own term for the object, so this cannot come from
    # another driver - the Apogee equivalent is apogeeDrv.trendOverflow above.
    @{ Id = 'trend.dataLoss'; Group = 'Trending'; Label = 'Trend buffer data loss'
        Scope = 'GmsBACnet'
        Re = [regex]'(?i)Trend buffer data loss for trend log object\s+(\S+)\s+in device\s+(\d+)'
        BucketBy = @{ device = 2 }
        Sample = $true; FindingAt = 100 }
    # Deliberately unscoped: fires for both GmsBACnet and ApogeeDrv, and Scope is a single
    # substring. See BACKLOG.md - multi-scope would let this one be gated.
    @{ Id = 'trend.seqLess'; Group = 'Trending'; Label = 'Sequence number lower than saved'
        Re = [regex]'(?i)Last sequence number\s+\d+\s+is less than saved'
        BucketBy = @{ manager = '$component' }
        Sample = $true; FindingAt = 100 }

    # --- Driver commands ----------------------------------------------------
    # Property names are per-datapoint, so they are deliberately not bucketed - the error
    # code is the bounded, actionable dimension.
    @{ Id = 'driver.errorCode'; Group = 'Driver'; Label = 'Driver returned error code'
        Re = [regex]'(?i)The Driver returned Error Code\s+(\d+)'
        BucketBy = @{ code = 1; manager = '$component' }
        Sample = $true; FindingAt = 250 }
    # Both are the command handler reporting on a command it dispatched, so CoHo is the only
    # manager that can raise them.
    @{ Id = 'driver.offline'; Group = 'Driver'; Label = 'Command failed - driver offline'
        Scope = 'CoHo'
        Re = [regex]'(?i)Command failed because Driver\s+(\d+)\s+is offline'
        BucketBy = @{ driver = 1 }
        Sample = $true; FindingAt = 250 }
    @{ Id = 'driver.readFile'; Group = 'Driver'; Label = 'Read File returned error code'
        Scope = 'CoHo'
        Re = [regex]'(?i)Device\s+(\d+)\s+Read File returned error code\s+(\d+)'
        BucketBy = @{ device = 1; code = 2 }
        Sample = $true; FindingAt = 250 }

    # --- Alarms -------------------------------------------------------------
    # AlertIDs are unique per alarm, so bucket the manager instead.
    @{ Id = 'alarm.alertIdUnknown'; Group = 'Alarms'; Label = 'AlertID not known'
        Re = [regex]'(?i)AlertID\s+\S+\s+is not known'
        BucketBy = @{ manager = '$component' }
        Sample = $true; FindingAt = 250 }
    # GetAlarmSummary is a BACnet service.
    @{ Id = 'alarm.getSummaryFail'; Group = 'Alarms'; Label = 'GetAlarmSummary failed'
        Scope = 'GmsBACnet'
        Re = [regex]'(?i)GetAlarmSummary failed for device\s+(\d+)'
        BucketBy = @{ device = 1 }
        Sample = $true; FindingAt = 100 }

    # --- Device access ------------------------------------------------------
    # CPT is BACnet ConfirmedPrivateTransfer; the AES password is the BACnet device
    # credential. Both are driver-internal messages.
    @{ Id = 'device.cptFailed'; Group = 'Devices'; Label = 'CPT failed - device failed'
        Scope = 'GmsBACnet'
        Re = [regex]'(?i)CPT failed:.*?Dev\s*=\s*(\d+)'
        BucketBy = @{ device = 1 }
        Sample = $true; FindingAt = 100 }
    @{ Id = 'device.aesDecrypt'; Group = 'Devices'; Label = 'AES password decryption failed'
        Scope = 'GmsBACnet'
        Re = [regex]'(?i)Device\s+(\d+):\s*AES decryption of password unsuccessful'
        BucketBy = @{ device = 1 }
        Sample = $true; FindingAt = 100 }

    # --- Framework ----------------------------------------------------------
    # $SubAreaRe below captures the sub-area field that precedes the ",,<time>,^N:" marker.
    # Anchoring there rather than on the GMS version token is required: C1P renders
    # "GMSv9.0.44.0e,<subArea>" while C2P/H1P render ", GMSe,<subArea>".
    @{ Id = 'afw.traceRepetition'; Group = 'Framework'; Label = 'Repeated trace'
        Re = [regex]'(?:,([^,]*),,\d{2}:\d{2}:\d{2}\.\d+,\^\d+:)?Repetition \(#=(\d+)\) of a former trace'
        BucketBy = @{ manager = '$component'; subArea = 1 }
        Measure = @{ repeats = @{ Group = 2; Agg = 'Sum' }; worstRun = @{ Group = 2; Agg = 'Max' } }
        Sample = $true; FindingAt = 500 }
    @{ Id = 'afw.covBurst'; Group = 'Framework'; Label = 'COV burst'
        Re = [regex]'(?:,([^,]*),,\d{2}:\d{2}:\d{2}\.\d+,\^\d+:)?We counted\s+(\d+)\s+COVs over the last'
        BucketBy = @{ manager = '$component'; subArea = 1 }
        Measure = @{ covs = @{ Group = 2; Agg = 'Sum' }; worstBurst = @{ Group = 2; Agg = 'Max' } }
        Sample = $true; FindingAt = 250 }
    # The central comm manager marshals the server calls, so it is the one that sees the
    # remote exception come back. 4,683 hits across the corpus, all CComMgr.
    @{ Id = 'afw.serverSideException'; Group = 'Framework'; Label = 'SERVER-SIDE exception'
        Scope = 'CComMgr'
        Re = [regex]'SERVER-SIDE exception:\s*([A-Za-z0-9_.]+)'
        BucketBy = @{ exception = 1; manager = '$component' }
        Sample = $true; FindingAt = 100 }
    @{ Id = 'afw.retainedInvocations'; Group = 'Framework'; Label = 'Examining retained invocations'
        Re = [regex]'(?i)Examining retained invocations'
        BucketBy = @{ manager = '$component' }
        Sample = $true; FindingAt = 500 }
)

# --- engine ---------------------------------------------------------------

# Component name -> rules whose Scope matches. Component names repeat heavily, so this
# turns the per-line cost into one hashtable lookup after first sight (PRD 4.3).
$script:RuleSetCache = @{}

# Max distinct values kept per bucket map. The corpus tops out near 1,000 (AES failures
# hit 1,008 distinct devices), so this only bites on a rule bucketed by something
# unbounded like a datapoint name.
$script:RuleBucketCap = 2000

$script:RuleSevOrder = @('FATAL', 'SEVERE', 'ERROR', 'WARNING', 'INFO')

# Detections ranking (PRD 6.2). Ordering by raw count, or by count/FindingAt, both put the
# highest-volume rule first - which on the corpus is "Repeated trace", a logging artifact,
# ahead of a driver that was offline for four hours. Rate over the rule's OWN first->last
# span separates the two: the outage reads 1,038 hits/hr, the chatter 82/hr. Note this is
# deliberately not the window span - scaling by the window is the same divisor for every
# rule, so it cancels out of the ordering entirely.
$script:RuleSevWeight = @{ FATAL = 4.0; SEVERE = 3.0; ERROR = 2.0; WARNING = 1.0; INFO = 0.25 }

# Sub-minute bursts are treated as one minute. Without a floor, two hits a second apart
# score higher than a sustained outage.
$script:RuleMinSpanSec = 60

$script:RuleTsFormat = 'yyyy.MM.dd HH:mm:ss.fff'

function script:ConvertFrom-RuleTimestamp {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $dt = [datetime]::MinValue
    if ([datetime]::TryParseExact($Text, $script:RuleTsFormat,
            [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$dt)) {
        return $dt
    }
    return $null
}

function script:Register-RuleSet {
    param([string]$Comp)
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($r in $script:PvssRules) {
        $sc = $r['Scope']
        if ($sc -and $Comp.IndexOf($sc, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        [void]$list.Add($r)
    }
    $arr = $list.ToArray()
    $script:RuleSetCache[$Comp] = $arr
    return $arr
}

function script:Get-RuleBucketValue {
    param($Spec, $Match, [string]$Comp, [string]$Area, [string]$Sev)
    $idx = $Spec
    $trimEnd = $null
    if ($Spec -is [hashtable]) {
        $idx = $Spec['Group']
        $trimEnd = $Spec['TrimEnd']
    }
    $val = $null
    if ($idx -is [string]) {
        switch ($idx) {
            '$component' { $val = $Comp }
            '$area' { $val = $Area }
            '$severity' { $val = $Sev }
        }
    }
    else {
        $gi = [int]$idx
        if ($Match.Groups.Count -gt $gi) {
            $g = $Match.Groups[$gi]
            if ($g.Success) { $val = $g.Value.Trim() }
        }
    }
    if ([string]::IsNullOrWhiteSpace($val)) { return $null }
    if ($trimEnd) { $val = $val.TrimEnd([char[]]$trimEnd) }
    if ([string]::IsNullOrWhiteSpace($val)) { return $null }
    return $val
}

function script:Add-RuleHit {
    param($Data, $Rule, $Match, [string]$Line, [string]$Comp, [string]$Area, [string]$Sev, [string]$Timestamp)
    $id = [string]$Rule['Id']

    $h = $Data.Hits
    if ($h.ContainsKey($id)) { $h[$id] = [int]$h[$id] + 1 } else { $h[$id] = 1 }

    $hs = $Data.HitSevs
    if (-not $hs.ContainsKey($id)) { $hs[$id] = @{} }
    $sm = $hs[$id]
    if ($sm.ContainsKey($Sev)) { $sm[$Sev] = [int]$sm[$Sev] + 1 } else { $sm[$Sev] = 1 }

    $ht = $Data.HitTime
    if ($ht.ContainsKey($id)) { $ht[$id].Last = $Timestamp }
    else { $ht[$id] = @{ First = $Timestamp; Last = $Timestamp } }

    if ($Rule['Sample']) {
        $slot = [string]$Rule['SampleSlot']
        if (-not $slot) { $slot = $id }
        $hsam = $Data.HitSample
        if (-not $hsam.ContainsKey($slot) -or -not $hsam[$slot]) { $hsam[$slot] = $Line }
    }

    $bb = $Rule['BucketBy']
    if ($bb) {
        $hb = $Data.HitBuckets
        if (-not $hb.ContainsKey($id)) { $hb[$id] = @{} }
        $idb = $hb[$id]
        foreach ($bname in $bb.Keys) {
            $val = Get-RuleBucketValue -Spec $bb[$bname] -Match $Match -Comp $Comp -Area $Area -Sev $Sev
            if ($null -eq $val) { continue }
            if (-not $idb.ContainsKey($bname)) { $idb[$bname] = @{} }
            $bm = $idb[$bname]
            if ($bm.ContainsKey($val)) { $bm[$val] = [int]$bm[$val] + 1 }
            elseif ($bm.Count -lt $script:RuleBucketCap) { $bm[$val] = 1 }
            # else: bucket is full. Counts for values already seen keep rising; new values
            # are dropped so one careless rule cannot grow a map without bound. The payload
            # reports capped=true whenever a map is at the cap.
        }
    }

    $mm = $Rule['Measure']
    if ($mm) {
        $hm = $Data.HitMeasures
        if (-not $hm.ContainsKey($id)) { $hm[$id] = @{} }
        $idm = $hm[$id]
        foreach ($mname in $mm.Keys) {
            $spec = $mm[$mname]
            $gi = [int]$spec['Group']
            if ($Match.Groups.Count -le $gi) { continue }
            $g = $Match.Groups[$gi]
            if (-not $g.Success) { continue }
            $num = 0.0
            if (-not [double]::TryParse($g.Value, [ref]$num)) { continue }
            if (-not $idm.ContainsKey($mname)) { $idm[$mname] = $num }
            elseif ([string]$spec['Agg'] -eq 'Max') { if ($num -gt [double]$idm[$mname]) { $idm[$mname] = $num } }
            else { $idm[$mname] = [double]$idm[$mname] + $num }
        }
    }
}

# NOTE: the match loop itself is inlined in Process-LogLine rather than living here.
# A PowerShell call with a bound param block costs ~120 us; at one call per line that
# alone added 12% to a 48 MB catch-up. Add-RuleHit stays a function because it only
# runs on an actual hit.

# --- accessors used by payload builders -----------------------------------

function script:Get-RuleCount {
    param($Data, [string]$Id)
    if ($Data.Hits.ContainsKey($Id)) { return [int]$Data.Hits[$Id] }
    return 0
}

function script:Get-RuleSample {
    param($Data, [string]$Id)
    if ($Data.HitSample.ContainsKey($Id)) { return $Data.HitSample[$Id] }
    return $null
}

function script:Get-RuleMeasure {
    param($Data, [string]$Id, [string]$Name)
    if ($Data.HitMeasures.ContainsKey($Id) -and $Data.HitMeasures[$Id].ContainsKey($Name)) {
        return $Data.HitMeasures[$Id][$Name]
    }
    return 0
}

function script:Get-RuleBucketMap {
    param($Data, [string]$Id, [string]$Name)
    if ($Data.HitBuckets.ContainsKey($Id)) {
        $idb = $Data.HitBuckets[$Id]
        if ($idb.ContainsKey($Name)) { return $idb[$Name] }
    }
    return @{}
}

function script:Get-RuleBucketCount {
    param($Data, [string]$Id, [string]$Name)
    return (Get-RuleBucketMap -Data $Data -Id $Id -Name $Name).Count
}

# Top-N rows as [ordered]@{ <KeyName> = value; count = n }
function script:Get-RuleTopBucket {
    param($Data, [string]$Id, [string]$Name, [string]$KeyName, [int]$N = 20)
    $map = Get-RuleBucketMap -Data $Data -Id $Id -Name $Name
    if ($map.Count -eq 0) { return @() }
    return @(
        $map.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $N | ForEach-Object {
            [ordered]@{ $KeyName = $_.Key; count = [int]$_.Value }
        }
    )
}

# --- generic detections payload (PRD 6.2) ---------------------------------
# Walks the rule table, so a new row surfaces in text, HTML and the dashboard with no
# renderer edits. Groups with a hand-tuned curated card are skipped so nothing reports
# twice; rules with no hits are omitted. Every map is emitted in a deterministic order -
# the 10.1 equivalence check compares batch and dashboard HTML byte for byte.
function script:Build-DetectionsObject {
    param($Data, [int]$TopN = 20)
    $order = New-Object System.Collections.ArrayList
    $byGroup = @{}

    foreach ($r in $script:PvssRules) {
        $g = [string]$r['Group']
        if ($script:CuratedGroups -contains $g) { continue }
        $id = [string]$r['Id']
        $count = Get-RuleCount -Data $Data -Id $id
        if ($count -le 0) { continue }

        $sevs = [ordered]@{}
        if ($Data.HitSevs.ContainsKey($id)) {
            $sm = $Data.HitSevs[$id]
            foreach ($s in $script:RuleSevOrder) { if ($sm.ContainsKey($s)) { $sevs[$s] = [int]$sm[$s] } }
            foreach ($s in @($sm.Keys | Sort-Object)) { if (-not $sevs.Contains($s)) { $sevs[$s] = [int]$sm[$s] } }
        }

        $measures = [ordered]@{}
        if ($Data.HitMeasures.ContainsKey($id)) {
            $mm = $Data.HitMeasures[$id]
            foreach ($k in @($mm.Keys | Sort-Object)) { $measures[$k] = $mm[$k] }
        }

        $buckets = [ordered]@{}
        if ($Data.HitBuckets.ContainsKey($id)) {
            $idb = $Data.HitBuckets[$id]
            foreach ($bname in @($idb.Keys | Sort-Object)) {
                $map = $idb[$bname]
                $buckets[$bname] = [ordered]@{
                    distinct = $map.Count
                    capped   = ($map.Count -ge $script:RuleBucketCap)
                    top      = @(
                        $map.GetEnumerator() | Sort-Object @{ E = { $_.Value }; Descending = $true }, @{ E = { $_.Key } } |
                            Select-Object -First $TopN | ForEach-Object {
                                [ordered]@{ value = [string]$_.Key; count = [int]$_.Value }
                            }
                    )
                }
            }
        }

        $t = if ($Data.HitTime.ContainsKey($id)) { $Data.HitTime[$id] } else { $null }
        $slot = [string]$r['SampleSlot']; if (-not $slot) { $slot = $id }

        # How intense was this rule while it was active, and how does its volume compare with
        # its own hand-tuned bar? 'score' orders the section; 'over' is what gets displayed,
        # because a seven-second burst rates at 270,000/hr and that is not a readable badge.
        $spanSec = $script:RuleMinSpanSec
        if ($t) {
            $a = ConvertFrom-RuleTimestamp -Text ([string]$t.First)
            $b = ConvertFrom-RuleTimestamp -Text ([string]$t.Last)
            if ($a -and $b -and $b -gt $a) {
                $spanSec = [math]::Max($script:RuleMinSpanSec, ($b - $a).TotalSeconds)
            }
        }
        $rate = $count / $spanSec * 3600.0

        $sevW = 1.0
        if ($sevs.Count -gt 0) {
            $wsum = 0.0; $n = 0
            foreach ($k in $sevs.Keys) {
                $w = if ($script:RuleSevWeight.ContainsKey($k)) { $script:RuleSevWeight[$k] } else { 1.0 }
                $wsum += $w * [int]$sevs[$k]; $n += [int]$sevs[$k]
            }
            if ($n -gt 0) { $sevW = $wsum / $n }
        }

        $findingAt = 0
        if ($r['FindingAt']) { $findingAt = [int]$r['FindingAt'] }

        $row = [ordered]@{
            id         = $id
            label      = [string]$r['Label']
            count      = $count
            first      = $(if ($t) { $t.First } else { $null })
            last       = $(if ($t) { $t.Last } else { $null })
            findingAt  = $findingAt
            over       = $(if ($findingAt -gt 0) { [math]::Round($count / $findingAt, 2) } else { 0 })
            spanSec    = [int][math]::Round($spanSec)
            rate       = [math]::Round($rate, 1)
            score      = [math]::Round($rate * $sevW, 1)
            sample     = (Get-RuleSample -Data $Data -Id $slot)
            severities = $sevs
            measures   = $measures
            buckets    = $buckets
        }

        if (-not $byGroup.ContainsKey($g)) {
            $byGroup[$g] = New-Object System.Collections.ArrayList
            [void]$order.Add($g)
        }
        [void]$byGroup[$g].Add($row)
    }

    # Worst-first, by intensity rather than volume. Groups follow their own worst rule, so the
    # section leads with wherever the sharpest activity was. Every sort carries an id/name
    # tiebreak - the 10.1 equivalence check compares batch and dashboard HTML byte for byte.
    $groups = New-Object System.Collections.ArrayList
    foreach ($g in $order) {
        $rows = @($byGroup[$g] | Sort-Object @{ E = { $_.score }; Descending = $true }, @{ E = { $_.id } })
        $total = 0
        $top = 0.0
        foreach ($row in $rows) {
            $total += [int]$row.count
            if ([double]$row.score -gt $top) { $top = [double]$row.score }
        }
        [void]$groups.Add([ordered]@{ group = $g; total = $total; score = $top; rules = $rows })
    }

    $out = New-Object System.Collections.ArrayList
    foreach ($g in @($groups | Sort-Object @{ E = { $_.score }; Descending = $true }, @{ E = { $_.group } })) {
        [void]$out.Add($g)
    }
    return @($out)
}
