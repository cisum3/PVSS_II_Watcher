using System.Text.RegularExpressions;

namespace DesigoLogWatcher;

/// <summary>
/// Accumulators mirroring New-EmptyState + Process-LogLine (Watch-PvssLog.ps1).
/// Rule hits are optional via <see cref="IRuleHitSink"/> (wired in T6).
/// </summary>
public sealed class AnalysisState
{
    private static readonly string[] AreaKeys = ["SYS", "IMPL", "CTRL", "PARAM", "OTHER"];
    private static readonly string[] SevKeys = ["FATAL", "SEVERE", "ERROR", "WARNING", "INFO"];

    // --- normalization / hand-written regexes (PS L487–758) ---
    private static readonly Regex ReNormTs = new(@"\d{4}\.\d{2}\.\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+", RegexOptions.Compiled);
    private static readonly Regex ReNormTime = new(@"\b\d{2}:\d{2}:\d{2}\.\d+\b", RegexOptions.Compiled);
    private static readonly Regex ReNormKv = new(@"\b(?:tid|cc|Sys|Page|ViewId|#DpIdentifier)=[^\s,;)]+", RegexOptions.Compiled);
    private static readonly Regex ReNormDevice = new(@"(?i)\bdevice\s+\d+\b", RegexOptions.Compiled);
    private static readonly Regex ReNormDp = new(@"\bDP=\d+\.\d+:[^;\s]+", RegexOptions.Compiled);
    private static readonly Regex ReNormNum = new(@"\b\d{5,}\b", RegexOptions.Compiled);
    private static readonly Regex ReNormSpace = new(@"\s+", RegexOptions.Compiled);
    private static readonly Regex ReCohoLockCollapse = new(@":\s*[\d, ]+", RegexOptions.Compiled);
    private static readonly Regex ReInfoBacStatus = new(@"Status is now (Failed|OK)", RegexOptions.Compiled);
    private static readonly Regex ReCohoStuck = new(@"(?i)got stuck|dropping it", RegexOptions.Compiled);
    private static readonly Regex ReApogeeUpdate = new(@"(?i)UpdatePoints", RegexOptions.Compiled);
    private static readonly Regex ReApogeeRep = new(@"(?i)Repetition", RegexOptions.Compiled);

    private static readonly Regex ReBacFailed = new(@"Device\s+(\d+)\s+Status is now Failed", RegexOptions.Compiled);
    private static readonly Regex ReBacOk = new(@"Device\s+(\d+)\s+Status is now OK", RegexOptions.Compiled);
    private static readonly Regex ReBacObjList = new(@"(?i)Could not get object list(?:\s+count)?(?:\s+for)?\s+device\s+(\d+)", RegexOptions.Compiled);
    private static readonly Regex ReBacCollectTrend = new(@"Command\s+""BACnetCollectTrend""", RegexOptions.Compiled);
    private static readonly Regex ReBacTimeSyncCmd = new(@"Command\s+""BACnetTimeSync""", RegexOptions.Compiled);
    private static readonly Regex ReBacCmdDetail = new(
        @"Error Code (\d+) for Property ""([^""]+)"" and Command ""(BACnetCollectTrend|BACnetTimeSync)""",
        RegexOptions.Compiled);

    private static readonly Regex ReCohoDiscoveryLoc = new(@"(?i)DiscoveryLoc:([^\s]+)\s+got stuck\b", RegexOptions.Compiled);
    private static readonly Regex ReCohoDiscoveryCycle = new(
        @"(?i)((?:Global|Observer)\s+Discovery Cycle\s+\[[^\]]+\])\s+got stuck\b", RegexOptions.Compiled);
    private static readonly Regex ReApogeePpcl = new(@"(?i)PPCL Program Name:\s*(\S+?)(?:System\.|$)", RegexOptions.Compiled);
    private static readonly Regex ReApogeeComp = new(@"(?i)(?:CoHo|Orch)\.Apogee", RegexOptions.Compiled);

    private static readonly Regex ReProjectUp = new(@"The project is up and running", RegexOptions.Compiled);
    private static readonly Regex ReProjectStopped = new(@"Completely stopped the project", RegexOptions.Compiled);
    private static readonly Regex ReProjectShutdown = new(@"Got shutdown command", RegexOptions.Compiled);
    private static readonly Regex ReProjectStartMode = new(@"Manager Start,\s*START_MODE", RegexOptions.Compiled);
    private static readonly Regex RePmonMgrRestart = new(@"Detected stopped manager\s+(\S+)\s+-\s+restarting", RegexOptions.Compiled);
    private static readonly Regex ReMgrStartProj = new(@"Manager Start,\s*PROJ,", RegexOptions.Compiled);
    private static readonly Regex ReMgrStopMsg = new(@"Manager Stop\s*$", RegexOptions.Compiled);
    private static readonly Regex ReDriverReady = new(@"(?i)Driver is configured with .+\s+and is now running", RegexOptions.Compiled);
    private static readonly Regex ReBlockingStart = new(
        @"Blocking Manager\s+(\S+)\s+detected(?:\.\s*No heartbeat since\s+(\d+)\s+seconds?)?", RegexOptions.Compiled);
    private static readonly Regex ReBlockingEnd = new(@"Manager\s+(\S+)\s+is no longer blocking", RegexOptions.Compiled);

    private static readonly (string Name, Regex Re)[] PerfRules =
    [
        ("Timeout", new Regex(@"(?i)\btimeout\b|\btimed?\s*out\b", RegexOptions.Compiled)),
        ("Buffer/Overrun", new Regex(@"(?i)overrun|buffer\s*(full|overflow|overrun)|BufferOverrun", RegexOptions.Compiled)),
        ("Queue/Pending", new Regex(@"(?i)pending|backlog|queue\s*(full|overflow)|maxInput|maxPend", RegexOptions.Compiled)),
        ("CNS/Resolve", new Regex(@"(?i)ResolveNodes|ReducedFunction|ICns\.|\.cns=", RegexOptions.Compiled)),
        ("Session/Logon", new Regex(@"(?i)TryRenewSession|LogonManager|session", RegexOptions.Compiled)),
        ("Memory", new Regex(@"(?i)\bmemory\b|\bOOM\b|out of memory|WorkingSet", RegexOptions.Compiled)),
        ("Connection", new Regex(@"(?i)disconnect|connection\s*(lost|refused|reset)|cannot connect|Could not get", RegexOptions.Compiled)),
        ("Driver/Device", new Regex(@"(?i)object list|device\s+\d+|BACnet|Apogee", RegexOptions.Compiled)),
        ("Restart/Kill", new Regex(@"(?i)SecKill|restart|killed|emergency|emergencyKill", RegexOptions.Compiled)),
        ("Slow/Delay", new Regex(@"(?i)\bslow\b|\bdelay\b|\blatency\b|took\s+\d+\s*ms", RegexOptions.Compiled)),
    ];

    public AnalysisState()
    {
        foreach (var a in AreaKeys)
        {
            AreaCounts[a] = 0;
            PatternsByArea[a] = NewSevMaps();
            PatternSampleByArea[a] = NewSevSampleMaps();
            PatternTimeByArea[a] = NewSevTimeMaps();
        }
        foreach (var s in SevKeys)
        {
            PatternsBySev[s] = new Dictionary<string, int>(StringComparer.Ordinal);
            PatternSampleBySev[s] = new Dictionary<string, List<string>>(StringComparer.Ordinal);
            PatternTimeBySev[s] = new Dictionary<string, PatternTimeBounds>(StringComparer.Ordinal);
        }
    }

    // --- counters / maps (New-EmptyState) ---
    public Dictionary<string, int> Severity { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, Dictionary<string, int>> SeverityByArea { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, int> AreaCounts { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, int> AreaOtherNames { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, int> Components { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, Dictionary<string, int>> ComponentsByArea { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, Dictionary<string, int>> CompSev { get; } = new(StringComparer.Ordinal);

    public Dictionary<string, Dictionary<string, int>> PatternsBySev { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, Dictionary<string, List<string>>> PatternSampleBySev { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, Dictionary<string, PatternTimeBounds>> PatternTimeBySev { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, Dictionary<string, Dictionary<string, int>>> PatternsByArea { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, Dictionary<string, Dictionary<string, List<string>>>> PatternSampleByArea { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, Dictionary<string, Dictionary<string, PatternTimeBounds>>> PatternTimeByArea { get; } = new(StringComparer.Ordinal);

    public Dictionary<string, Dictionary<string, Dictionary<string, int>>> CompPatterns { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, Dictionary<string, Dictionary<string, List<string>>>> CompPatternSamples { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, Dictionary<string, Dictionary<string, PatternTimeBounds>>> CompPatternTimes { get; } = new(StringComparer.Ordinal);
    /// <summary>Per-manager patterns split by area so /api/manager can honor area filters.</summary>
    public Dictionary<string, Dictionary<string, Dictionary<string, Dictionary<string, int>>>> CompPatternsByArea { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, Dictionary<string, Dictionary<string, Dictionary<string, List<string>>>>> CompPatternSamplesByArea { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, Dictionary<string, Dictionary<string, Dictionary<string, PatternTimeBounds>>>> CompPatternTimesByArea { get; } = new(StringComparer.Ordinal);

    public Dictionary<string, int> PerfCats { get; } = new(StringComparer.Ordinal);

    // Rule engine maps (filled by T6 sink)
    public Dictionary<string, int> Hits { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, Dictionary<string, Dictionary<string, int>>> HitBuckets { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, Dictionary<string, long>> HitMeasures { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, Dictionary<string, int>> HitSevs { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, string> HitSample { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, PatternTimeBounds> HitTime { get; } = new(StringComparer.Ordinal);

    public Dictionary<string, MinuteBucket> ByMinute { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, Dictionary<string, MinuteBucket>> ByMinuteByArea { get; } = new(StringComparer.Ordinal);

    public string? FirstTs { get; private set; }
    public string? LastTs { get; private set; }
    public int ParsedLines { get; private set; }
    public int UnparsedLines { get; private set; }
    public int SevereLines { get; private set; }

    // BACnet
    public int BacFailed { get; private set; }
    public int BacOk { get; private set; }
    public Dictionary<string, int> BacFailedByDevice { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, int> BacOkByDevice { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, string> BacLastStatus { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, int> BacFlipByDevice { get; } = new(StringComparer.Ordinal);
    public int BacObjectList { get; private set; }
    public Dictionary<string, int> BacObjectListByDevice { get; } = new(StringComparer.Ordinal);
    public string? BacFailedSample { get; private set; }
    public string? BacOkSample { get; private set; }
    public string? BacObjectListSample { get; private set; }
    public int BacCollectTrend { get; private set; }
    public int BacTimeSync { get; private set; }
    public Dictionary<string, int> BacCollectTrendByCode { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, int> BacCollectTrendByProp { get; } = new(StringComparer.Ordinal);
    public string? BacCollectTrendSample { get; private set; }
    public Dictionary<string, int> BacTimeSyncByCode { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, int> BacTimeSyncByProp { get; } = new(StringComparer.Ordinal);
    public string? BacTimeSyncSample { get; private set; }

    // CNS sidecar patterns (filled when rules mark PatternGroup=Cns)
    public Dictionary<string, int> CnsPatterns { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, List<string>> CnsPatternSamples { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, PatternTimeBounds> CnsPatternTimes { get; } = new(StringComparer.Ordinal);

    // CoHo / Apogee
    public int CohoStuck { get; private set; }
    public Dictionary<string, int> CohoStuckNames { get; } = new(StringComparer.Ordinal);
    public string? CohoSample { get; private set; }
    public int ApogeeEvents { get; private set; }
    public int ApogeeUpdatePoints { get; private set; }
    public int ApogeeRepetition { get; private set; }
    public int ApogeeOther { get; private set; }
    public Dictionary<string, int> ApogeePpcl { get; } = new(StringComparer.Ordinal);
    public string? ApogeeSample { get; private set; }
    public int ApogeeDrvLines { get; private set; }

    // Lifecycle
    public int ProjectStartMode { get; private set; }
    public int ProjectUp { get; private set; }
    public int ProjectShutdown { get; private set; }
    public int ProjectStopped { get; private set; }
    public int PmonMgrRestart { get; private set; }
    public int MgrStartProj { get; private set; }
    public int MgrStop { get; private set; }
    public int DriverReady { get; private set; }
    public Dictionary<string, int> MgrStartByComp { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, int> MgrStopByComp { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, int> PmonRestartByComp { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, int> BlockingByComp { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, int> UnblockingByComp { get; } = new(StringComparer.Ordinal);
    public int BlockingDetected { get; private set; }
    public int BlockingCleared { get; private set; }
    public string? BlockingSample { get; private set; }
    public string? UnblockingSample { get; private set; }
    public List<ProjectRestartEvent> ProjectRestartEvents { get; } = new();

    /// <summary>
    /// Process one log line (Process-LogLine). Optional rule sink for T6.
    /// </summary>
    public void ProcessLine(
        string line,
        int samplePerPattern = 1,
        int sampleMaxChars = 500,
        bool enforceCutoff = false,
        string? cutoffCompare = null,
        string? upperCompare = null,
        IRuleHitSink? rules = null)
    {
        if (!LogParser.TryParseHeader(line, out var header))
        {
            UnparsedLines++;
            return;
        }

        var ts = header.Timestamp;
        if (enforceCutoff && !string.IsNullOrEmpty(cutoffCompare) &&
            LogParser.IsBeforeCutoff(ts, cutoffCompare))
            return;
        if (!string.IsNullOrEmpty(upperCompare) &&
            LogParser.IsAfterUpper(ts, upperCompare))
            return;

        var comp = header.Component;
        var areaRaw = header.AreaRaw;
        var areaKey = NormalizeAreaKey(areaRaw);
        var sev = header.Severity;

        ParsedLines++;
        FirstTs ??= ts;
        LastTs = ts;

        Bump(Severity, sev);
        Bump(AreaCounts, areaKey);
        if (areaKey == "OTHER" && !string.IsNullOrEmpty(areaRaw))
            Bump(AreaOtherNames, areaRaw);

        if (!SeverityByArea.TryGetValue(areaKey, out var sba))
            SeverityByArea[areaKey] = sba = new Dictionary<string, int>(StringComparer.Ordinal);
        Bump(sba, sev);

        Bump(Components, comp);
        if (!ComponentsByArea.TryGetValue(areaKey, out var cba))
            ComponentsByArea[areaKey] = cba = new Dictionary<string, int>(StringComparer.Ordinal);
        Bump(cba, comp);

        if (!CompSev.TryGetValue(comp, out var cs))
            CompSev[comp] = cs = new Dictionary<string, int>(StringComparer.Ordinal);
        Bump(cs, sev);

        var mk = ts.Length >= 16 ? ts[..16] : ts;
        var bucket = EnsureMinute(mk);
        var bucketArea = EnsureMinuteArea(mk, areaKey);
        if (bucket.TryGet(sev, out _))
        {
            bucket.Bump(sev);
            bucketArea.Bump(sev);
        }

        var isWarning = sev == "WARNING";
        var isSevere = sev is "SEVERE" or "FATAL" or "ERROR";
        if (isSevere) SevereLines++;

        var perf = GetPerfCategory(line);
        if (perf is not null)
            Bump(PerfCats, perf);

        string? sevBucket = sev switch
        {
            "FATAL" => "FATAL",
            "SEVERE" => "SEVERE",
            "ERROR" => "ERROR",
            "WARNING" when isWarning => "WARNING",
            "INFO" => "INFO",
            _ => null
        };

        if (sevBucket is not null && sevBucket != "INFO")
        {
            var norm = NormalizeMessage(line, sampleMaxChars);
            AddPattern(PatternsBySev[sevBucket], PatternSampleBySev[sevBucket], PatternTimeBySev[sevBucket],
                norm, line, ts, samplePerPattern, sampleMaxChars);
            if (PatternsByArea.TryGetValue(areaKey, out var pba) && pba.TryGetValue(sevBucket, out var areaCounts))
            {
                AddPattern(areaCounts, PatternSampleByArea[areaKey][sevBucket], PatternTimeByArea[areaKey][sevBucket],
                    norm, line, ts, samplePerPattern, sampleMaxChars);
            }
            EnsureCompPatterns(comp);
            if (CompPatterns[comp].TryGetValue(sevBucket, out var cp))
            {
                AddPattern(cp, CompPatternSamples[comp][sevBucket], CompPatternTimes[comp][sevBucket],
                    norm, line, ts, samplePerPattern, sampleMaxChars);
            }
            EnsureCompPatternsArea(comp, areaKey);
            if (CompPatternsByArea[comp][areaKey].TryGetValue(sevBucket, out var cpa))
            {
                AddPattern(cpa, CompPatternSamplesByArea[comp][areaKey][sevBucket],
                    CompPatternTimesByArea[comp][areaKey][sevBucket],
                    norm, line, ts, samplePerPattern, sampleMaxChars);
            }
        }
        else if (sevBucket == "INFO" && ReInfoBacStatus.IsMatch(line))
        {
            var norm = NormalizeMessage(line, sampleMaxChars);
            AddPattern(PatternsBySev["INFO"], PatternSampleBySev["INFO"], PatternTimeBySev["INFO"],
                norm, line, ts, samplePerPattern, sampleMaxChars);
            if (PatternsByArea.TryGetValue(areaKey, out var pba) && pba.TryGetValue("INFO", out var areaCounts))
            {
                AddPattern(areaCounts, PatternSampleByArea[areaKey]["INFO"], PatternTimeByArea[areaKey]["INFO"],
                    norm, line, ts, samplePerPattern, sampleMaxChars);
            }
        }

        ProcessBacnet(line, comp, bucket, bucketArea);
        ProcessBacnetCommands(line);

        var cnsHit = false;
        if (rules is not null)
            cnsHit = rules.ApplyRules(this, line, comp, areaKey, sev, ts);
        if (cnsHit)
        {
            var norm = NormalizeMessage(line, sampleMaxChars);
            AddPattern(CnsPatterns, CnsPatternSamples, CnsPatternTimes, norm, line, ts, samplePerPattern, sampleMaxChars);
        }

        ProcessCoho(line, comp);
        ProcessApogee(line, comp);
        ProcessLifecycle(line, comp, areaKey, ts, bucket, bucketArea);
    }

    public void NoteCnsPatternLine(string line, string ts, int samplePerPattern, int sampleMaxChars)
    {
        var norm = NormalizeMessage(line, sampleMaxChars);
        AddPattern(CnsPatterns, CnsPatternSamples, CnsPatternTimes, norm, line, ts, samplePerPattern, sampleMaxChars);
    }

    public static string NormalizeAreaKey(string raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return "OTHER";
        var a = raw.Trim().ToUpperInvariant();
        return a is "SYS" or "IMPL" or "CTRL" or "PARAM" ? a : "OTHER";
    }

    public static string NormalizeManagerKey(string comp)
    {
        if (string.IsNullOrWhiteSpace(comp)) return "";
        return Regex.Replace(comp.Trim(), @"\s+", "");
    }

    public static string NormalizeMessage(string text, int sampleMaxChars)
    {
        if (string.IsNullOrEmpty(text)) return "";
        var t = text;
        t = ReNormTs.Replace(t, "<TS>");
        t = ReNormTime.Replace(t, "<TIME>");
        t = ReNormKv.Replace(t, "<KV>");
        t = ReNormDevice.Replace(t, "device <N>");
        t = ReNormDp.Replace(t, "DP=<ID>");
        t = ReNormNum.Replace(t, "<NUM>");
        t = ReNormSpace.Replace(t, " ").Trim();
        if (sampleMaxChars > 0 && t.Length > sampleMaxChars)
            t = t[..sampleMaxChars] + "...";
        return t;
    }

    public static string? GetPerfCategory(string line)
    {
        foreach (var (name, re) in PerfRules)
        {
            if (re.IsMatch(line)) return name;
        }
        return null;
    }

    private void ProcessBacnet(string line, string comp, MinuteBucket bucket, MinuteBucket bucketArea)
    {
        if (comp.IndexOf("BACnet", StringComparison.OrdinalIgnoreCase) < 0)
            return;

        string? bacNewStatus = null;
        string? bacDevId = null;
        var mf = ReBacFailed.Match(line);
        if (mf.Success)
        {
            BacFailed++;
            bacDevId = mf.Groups[1].Value;
            bacNewStatus = "Failed";
            Bump(BacFailedByDevice, bacDevId);
            BacFailedSample ??= line;
            bucket.BacFailed++;
            bucketArea.BacFailed++;
        }
        else
        {
            var mo = ReBacOk.Match(line);
            if (mo.Success)
            {
                BacOk++;
                bacDevId = mo.Groups[1].Value;
                bacNewStatus = "OK";
                Bump(BacOkByDevice, bacDevId);
                BacOkSample ??= line;
                bucket.BacOk++;
                bucketArea.BacOk++;
            }
        }

        if (bacDevId is not null && bacNewStatus is not null)
        {
            if (BacLastStatus.TryGetValue(bacDevId, out var prev) && prev != bacNewStatus)
                Bump(BacFlipByDevice, bacDevId);
            BacLastStatus[bacDevId] = bacNewStatus;
        }

        var ml = ReBacObjList.Match(line);
        if (ml.Success)
        {
            BacObjectList++;
            var id = ml.Groups[1].Value;
            Bump(BacObjectListByDevice, id);
            BacObjectListSample ??= line;
        }
    }

    private void ProcessBacnetCommands(string line)
    {
        var mBacCmd = ReBacCmdDetail.Match(line);
        if (mBacCmd.Success)
        {
            var code = mBacCmd.Groups[1].Value;
            var prop = mBacCmd.Groups[2].Value;
            var cmd = mBacCmd.Groups[3].Value;
            if (cmd == "BACnetCollectTrend")
            {
                BacCollectTrend++;
                Bump(BacCollectTrendByCode, code);
                Bump(BacCollectTrendByProp, prop);
                BacCollectTrendSample ??= line;
            }
            else if (cmd == "BACnetTimeSync")
            {
                BacTimeSync++;
                Bump(BacTimeSyncByCode, code);
                Bump(BacTimeSyncByProp, prop);
                BacTimeSyncSample ??= line;
            }
            return;
        }

        if (ReBacCollectTrend.IsMatch(line))
        {
            BacCollectTrend++;
            BacCollectTrendSample ??= line;
        }
        else if (ReBacTimeSyncCmd.IsMatch(line))
        {
            BacTimeSync++;
            BacTimeSyncSample ??= line;
        }
    }

    private void ProcessCoho(string line, string comp)
    {
        if (comp.IndexOf("CoHo", StringComparison.OrdinalIgnoreCase) < 0 || !ReCohoStuck.IsMatch(line))
            return;

        CohoStuck++;
        CohoSample ??= line;
        string? name = null;
        var mLoc = ReCohoDiscoveryLoc.Match(line);
        if (mLoc.Success)
            name = "DiscoveryLoc:" + mLoc.Groups[1].Value;
        else
        {
            var mCycle = ReCohoDiscoveryCycle.Match(line);
            if (mCycle.Success)
                name = ReCohoLockCollapse.Replace(mCycle.Groups[1].Value.Trim(), ": <N>");
        }
        if (!string.IsNullOrWhiteSpace(name))
            Bump(CohoStuckNames, name);
    }

    private void ProcessApogee(string line, string comp)
    {
        if (ReApogeeComp.IsMatch(line))
        {
            ApogeeEvents++;
            ApogeeSample ??= line;
            if (ReApogeeUpdate.IsMatch(line))
            {
                ApogeeUpdatePoints++;
                var mPpcl = ReApogeePpcl.Match(line);
                if (mPpcl.Success)
                {
                    var pn = mPpcl.Groups[1].Value.Trim();
                    if (pn.Length > 0) Bump(ApogeePpcl, pn);
                }
            }
            else if (ReApogeeRep.IsMatch(line)) ApogeeRepetition++;
            else ApogeeOther++;
        }

        if (comp.IndexOf("ApogeeDrv", StringComparison.OrdinalIgnoreCase) >= 0)
            ApogeeDrvLines++;
    }

    private void ProcessLifecycle(
        string line, string comp, string areaKey, string ts,
        MinuteBucket bucket, MinuteBucket bucketArea)
    {
        if (ReProjectUp.IsMatch(line))
        {
            ProjectUp++;
            bucket.ProjectRestart = 1;
            bucketArea.ProjectRestart = 1;
            if (ProjectRestartEvents.Count < 200)
                ProjectRestartEvents.Add(new ProjectRestartEvent(ts, "up", areaKey, line));
        }
        if (ReProjectStartMode.IsMatch(line)) ProjectStartMode++;
        if (ReProjectShutdown.IsMatch(line))
        {
            ProjectShutdown++;
            if (ProjectRestartEvents.Count < 200)
                ProjectRestartEvents.Add(new ProjectRestartEvent(ts, "shutdown", areaKey, line));
        }
        if (ReProjectStopped.IsMatch(line))
        {
            ProjectStopped++;
            if (ProjectRestartEvents.Count < 200)
                ProjectRestartEvents.Add(new ProjectRestartEvent(ts, "stopped", areaKey, line));
        }

        var mPmonRr = RePmonMgrRestart.Match(line);
        if (mPmonRr.Success)
        {
            PmonMgrRestart++;
            var rn = mPmonRr.Groups[1].Value.Trim();
            if (rn.Length > 0) Bump(PmonRestartByComp, rn);
        }
        if (ReMgrStartProj.IsMatch(line))
        {
            MgrStartProj++;
            Bump(MgrStartByComp, NormalizeManagerKey(comp));
        }
        if (ReMgrStopMsg.IsMatch(line))
        {
            MgrStop++;
            Bump(MgrStopByComp, NormalizeManagerKey(comp));
        }
        if (ReDriverReady.IsMatch(line)) DriverReady++;

        var mBlock = ReBlockingStart.Match(line);
        if (mBlock.Success)
        {
            BlockingDetected++;
            Bump(BlockingByComp, mBlock.Groups[1].Value.Trim());
            BlockingSample ??= line;
        }
        var mUnblock = ReBlockingEnd.Match(line);
        if (mUnblock.Success)
        {
            BlockingCleared++;
            Bump(UnblockingByComp, mUnblock.Groups[1].Value.Trim());
            UnblockingSample ??= line;
        }
    }

    private MinuteBucket EnsureMinute(string key)
    {
        if (!ByMinute.TryGetValue(key, out var b))
            ByMinute[key] = b = new MinuteBucket();
        return b;
    }

    private MinuteBucket EnsureMinuteArea(string key, string area)
    {
        if (!ByMinuteByArea.TryGetValue(key, out var byArea))
            ByMinuteByArea[key] = byArea = new Dictionary<string, MinuteBucket>(StringComparer.Ordinal);
        if (!byArea.TryGetValue(area, out var b))
            byArea[area] = b = new MinuteBucket();
        return b;
    }

    private void EnsureCompPatterns(string comp)
    {
        if (CompPatterns.ContainsKey(comp)) return;
        CompPatterns[comp] = new Dictionary<string, Dictionary<string, int>>(StringComparer.Ordinal)
        {
            ["FATAL"] = new(StringComparer.Ordinal),
            ["SEVERE"] = new(StringComparer.Ordinal),
            ["ERROR"] = new(StringComparer.Ordinal),
            ["WARNING"] = new(StringComparer.Ordinal)
        };
        CompPatternSamples[comp] = new Dictionary<string, Dictionary<string, List<string>>>(StringComparer.Ordinal)
        {
            ["FATAL"] = new(StringComparer.Ordinal),
            ["SEVERE"] = new(StringComparer.Ordinal),
            ["ERROR"] = new(StringComparer.Ordinal),
            ["WARNING"] = new(StringComparer.Ordinal)
        };
        CompPatternTimes[comp] = new Dictionary<string, Dictionary<string, PatternTimeBounds>>(StringComparer.Ordinal)
        {
            ["FATAL"] = new(StringComparer.Ordinal),
            ["SEVERE"] = new(StringComparer.Ordinal),
            ["ERROR"] = new(StringComparer.Ordinal),
            ["WARNING"] = new(StringComparer.Ordinal)
        };
    }

    private void EnsureCompPatternsArea(string comp, string area)
    {
        if (!CompPatternsByArea.TryGetValue(comp, out var byArea))
        {
            CompPatternsByArea[comp] = byArea = new Dictionary<string, Dictionary<string, Dictionary<string, int>>>(StringComparer.Ordinal);
            CompPatternSamplesByArea[comp] = new Dictionary<string, Dictionary<string, Dictionary<string, List<string>>>>(StringComparer.Ordinal);
            CompPatternTimesByArea[comp] = new Dictionary<string, Dictionary<string, Dictionary<string, PatternTimeBounds>>>(StringComparer.Ordinal);
        }
        if (byArea.ContainsKey(area)) return;
        byArea[area] = new Dictionary<string, Dictionary<string, int>>(StringComparer.Ordinal)
        {
            ["FATAL"] = new(StringComparer.Ordinal),
            ["SEVERE"] = new(StringComparer.Ordinal),
            ["ERROR"] = new(StringComparer.Ordinal),
            ["WARNING"] = new(StringComparer.Ordinal)
        };
        CompPatternSamplesByArea[comp][area] = new Dictionary<string, Dictionary<string, List<string>>>(StringComparer.Ordinal)
        {
            ["FATAL"] = new(StringComparer.Ordinal),
            ["SEVERE"] = new(StringComparer.Ordinal),
            ["ERROR"] = new(StringComparer.Ordinal),
            ["WARNING"] = new(StringComparer.Ordinal)
        };
        CompPatternTimesByArea[comp][area] = new Dictionary<string, Dictionary<string, PatternTimeBounds>>(StringComparer.Ordinal)
        {
            ["FATAL"] = new(StringComparer.Ordinal),
            ["SEVERE"] = new(StringComparer.Ordinal),
            ["ERROR"] = new(StringComparer.Ordinal),
            ["WARNING"] = new(StringComparer.Ordinal)
        };
    }

    private static void AddPattern(
        Dictionary<string, int> countMap,
        Dictionary<string, List<string>> sampleMap,
        Dictionary<string, PatternTimeBounds> timeMap,
        string norm, string line, string timestamp, int sampleLimit, int sampleMaxChars)
    {
        if (!countMap.ContainsKey(norm))
        {
            countMap[norm] = 0;
            sampleMap[norm] = new List<string>();
            if (!string.IsNullOrEmpty(timestamp))
                timeMap[norm] = new PatternTimeBounds(timestamp, timestamp);
        }
        countMap[norm]++;
        if (!string.IsNullOrEmpty(timestamp))
        {
            if (!timeMap.TryGetValue(norm, out var bounds))
                timeMap[norm] = new PatternTimeBounds(timestamp, timestamp);
            else
            {
                var first = string.CompareOrdinal(timestamp, bounds.First) < 0 ? timestamp : bounds.First;
                var last = string.CompareOrdinal(timestamp, bounds.Last) > 0 ? timestamp : bounds.Last;
                timeMap[norm] = new PatternTimeBounds(first, last);
            }
        }
        if (sampleLimit > 0 && sampleMap[norm].Count < sampleLimit)
        {
            var max = sampleMaxChars > 0 ? sampleMaxChars : 500;
            var sample = line.Length > max ? line[..max] + "..." : line;
            sampleMap[norm].Add(sample);
        }
    }

    private static void Bump(Dictionary<string, int> map, string key)
    {
        if (string.IsNullOrWhiteSpace(key)) return;
        map.TryGetValue(key, out var n);
        map[key] = n + 1;
    }

    private static Dictionary<string, Dictionary<string, int>> NewSevMaps()
    {
        var d = new Dictionary<string, Dictionary<string, int>>(StringComparer.Ordinal);
        foreach (var s in SevKeys) d[s] = new Dictionary<string, int>(StringComparer.Ordinal);
        return d;
    }

    private static Dictionary<string, Dictionary<string, List<string>>> NewSevSampleMaps()
    {
        var d = new Dictionary<string, Dictionary<string, List<string>>>(StringComparer.Ordinal);
        foreach (var s in SevKeys) d[s] = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        return d;
    }

    private static Dictionary<string, Dictionary<string, PatternTimeBounds>> NewSevTimeMaps()
    {
        var d = new Dictionary<string, Dictionary<string, PatternTimeBounds>>(StringComparer.Ordinal);
        foreach (var s in SevKeys) d[s] = new Dictionary<string, PatternTimeBounds>(StringComparer.Ordinal);
        return d;
    }
}

public sealed class MinuteBucket
{
    public int Fatal { get; set; }
    public int Severe { get; set; }
    public int Error { get; set; }
    public int Warning { get; set; }
    public int Info { get; set; }
    public int BacFailed { get; set; }
    public int BacOk { get; set; }
    public int ProjectRestart { get; set; }

    public bool TryGet(string sev, out int count)
    {
        count = Get(sev);
        return sev is "FATAL" or "SEVERE" or "ERROR" or "WARNING" or "INFO";
    }

    public int Get(string sev) => sev switch
    {
        "FATAL" => Fatal,
        "SEVERE" => Severe,
        "ERROR" => Error,
        "WARNING" => Warning,
        "INFO" => Info,
        _ => 0
    };

    public void AddFrom(MinuteBucket other)
    {
        Fatal += other.Fatal;
        Severe += other.Severe;
        Error += other.Error;
        Warning += other.Warning;
        Info += other.Info;
        BacFailed += other.BacFailed;
        BacOk += other.BacOk;
        if (other.ProjectRestart > 0) ProjectRestart = 1;
    }

    public void Bump(string sev)
    {
        switch (sev)
        {
            case "FATAL": Fatal++; break;
            case "SEVERE": Severe++; break;
            case "ERROR": Error++; break;
            case "WARNING": Warning++; break;
            case "INFO": Info++; break;
        }
    }
}

public readonly record struct PatternTimeBounds(string First, string Last);
public readonly record struct ProjectRestartEvent(string T, string Kind, string Area, string Sample);

/// <summary>Optional rule engine hook; return true if any CNS PatternGroup rule hit.</summary>
public interface IRuleHitSink
{
    bool ApplyRules(AnalysisState data, string line, string comp, string area, string sev, string timestamp);
}
