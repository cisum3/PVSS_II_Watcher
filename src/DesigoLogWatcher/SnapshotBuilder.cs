using System.Text.Json;
using System.Text.Json.Serialization;

namespace DesigoLogWatcher;

/// <summary>
/// Snapshot / findings / pulse builders (Build-SnapshotObject, Build-Findings).
/// </summary>
public sealed class SnapshotBuilder
{
    private readonly AnalysisState _data;
    private readonly RuleEngine _rules;
    private readonly int _topN;
    private readonly int _bacFlapMin;

    public SnapshotBuilder(AnalysisState data, RuleEngine? rules = null, int topN = 10, int bacFlapMin = 3)
    {
        _data = data;
        _rules = rules ?? new RuleEngine();
        _topN = topN;
        _bacFlapMin = bacFlapMin;
    }

    public List<string> BuildFindings()
    {
        var d = _data;
        var findings = new List<string>();
        if (d.ParsedLines > 0)
        {
            var pct = Math.Round(100.0 * d.SevereLines / d.ParsedLines, 1);
            if (pct >= 5)
                findings.Add($"HIGH: Critical-severity lines are {pct}% of parsed lines ({d.SevereLines} combined FATAL/SEVERE/ERROR).");
            else if (pct >= 2)
                findings.Add($"MEDIUM: Critical-severity lines are {pct}% of parsed lines ({d.SevereLines}).");
        }

        var bacTransitions = d.BacFailed + d.BacOk;
        var endedFailed = d.BacLastStatus.Count(kv => kv.Value == "Failed");
        var endedOk = d.BacLastStatus.Count(kv => kv.Value == "OK");
        var flappers = d.BacFlipByDevice.Count(kv => kv.Value >= _bacFlapMin);

        if (d.BacFailed >= 500 || bacTransitions >= 2000)
            findings.Add($"BACnet device status chatter: {d.BacFailed:N0} Failed and {d.BacOk:N0} OK transitions ({d.BacFailedByDevice.Count:N0} unique devices Failed).");
        if (endedFailed >= 20)
            findings.Add($"BACnet last-known status: {endedFailed:N0} devices ended Failed, {endedOk:N0} ended OK (in analyzed window).");
        if (flappers >= 5)
            findings.Add($"BACnet flapping: {flappers:N0} devices with {_bacFlapMin}+ Failed/OK status changes.");
        if (d.BacObjectList >= 100)
            findings.Add($"BACnet object-list warnings: {d.BacObjectList:N0} events across {d.BacObjectListByDevice.Count:N0} devices.");
        if (d.BacCollectTrend >= 100)
        {
            var topCode = d.BacCollectTrendByCode.OrderByDescending(kv => kv.Value).FirstOrDefault();
            var codeNote = topCode.Key is not null ? $" top error {topCode.Key} x{topCode.Value:N0}" : "";
            findings.Add($"BACnetCollectTrend failures: {d.BacCollectTrend:N0} across {d.BacCollectTrendByProp.Count:N0} properties{codeNote}.");
        }
        if (d.BacTimeSync >= 100)
        {
            var topCode = d.BacTimeSyncByCode.OrderByDescending(kv => kv.Value).FirstOrDefault();
            var codeNote = topCode.Key is not null ? $" top error {topCode.Key} x{topCode.Value:N0}" : "";
            findings.Add($"BACnetTimeSync failures: {d.BacTimeSync:N0} across {d.BacTimeSyncByProp.Count:N0} properties{codeNote}.");
        }

        var cnsResolve = RuleEngine.GetRuleCount(d, "cns.resolveNodes");
        var cnsReduced = RuleEngine.GetRuleCount(d, "cns.reducedFunction");
        var cnsRenew = RuleEngine.GetRuleCount(d, "cns.tryRenew");
        if (cnsResolve >= 100 || cnsReduced >= 100)
            findings.Add($"CNS volume: ResolveNodes={cnsResolve:N0}, ReducedFunction={cnsReduced:N0}, ICns={RuleEngine.GetRuleCount(d, "cns.icns"):N0}.");
        if (cnsRenew >= 5)
            findings.Add($"CNS/session: TryRenewSession hits={cnsRenew:N0}.");
        if (d.CohoStuck >= 10)
            findings.Add($"CoHo stuck/drop messages: {d.CohoStuck:N0}.");
        if (d.ApogeeUpdatePoints >= 10)
            findings.Add($"Apogee UpdatePoints failures: {d.ApogeeUpdatePoints:N0} across {d.ApogeePpcl.Count:N0} PPCL programs.");

        var apOverflow = RuleEngine.GetRuleCount(d, "apogeeDrv.trendOverflow");
        var apAlert = RuleEngine.GetRuleCount(d, "apogeeDrv.alertId");
        var apGetData = RuleEngine.GetRuleCount(d, "apogeeDrv.getDataFail");
        var apTimeout = RuleEngine.GetRuleCount(d, "apogeeDrv.queryTimeout");
        if (apOverflow >= 50)
            findings.Add($"ApogeeDrv trend buffer overflows: {apOverflow:N0} across {RuleEngine.GetRuleBucketCount(d, "apogeeDrv.trendOverflow", "device"):N0} devices ({RuleEngine.GetRuleCount(d, "apogeeDrv.trendSeq"):N0} sequence-gap lines).");
        if (apAlert >= 50)
            findings.Add($"ApogeeDrv AlertID issues: {apAlert:N0}.");
        if (apGetData >= 50)
            findings.Add($"ApogeeDrv get-data failures: {apGetData:N0} across {RuleEngine.GetRuleBucketCount(d, "apogeeDrv.getDataFail", "device"):N0} devices.");
        if (apTimeout >= 50)
            findings.Add($"ApogeeDrv query timeouts: {apTimeout:N0}.");

        if (d.ProjectUp >= 1 || d.ProjectStopped >= 1)
        {
            var upPreview = string.Join(", ", d.ProjectRestartEvents.Where(e => e.Kind == "up").Take(5).Select(e => e.T));
            var line = $"Project lifecycle (pmon): up={d.ProjectUp:N0}, stopped={d.ProjectStopped:N0}, shutdown cmds={d.ProjectShutdown:N0}, START_MODE={d.ProjectStartMode:N0}.";
            if (upPreview.Length > 0) line += $" First ups: {upPreview}.";
            findings.Add(line);
        }
        if (d.PmonMgrRestart >= 1)
        {
            var topRr = string.Join(", ", d.PmonRestartByComp.OrderByDescending(kv => kv.Value).Take(3)
                .Select(kv => $"{kv.Key} x{kv.Value}"));
            findings.Add($"pmon auto-restarted managers: {d.PmonMgrRestart:N0} event(s){(topRr.Length > 0 ? $" ({topRr})" : "")}.");
        }
        if (d.BlockingDetected >= 1)
        {
            var topBl = string.Join(", ", d.BlockingByComp.OrderByDescending(kv => kv.Value).Take(3)
                .Select(kv => $"{kv.Key} x{kv.Value}"));
            findings.Add($"pmon blocking (no heartbeat): {d.BlockingDetected:N0} detection(s), {d.BlockingCleared:N0} cleared{(topBl.Length > 0 ? $" ({topBl})" : "")}.");
        }
        if (d.MgrStartProj >= 5)
            findings.Add($"Manager Start (PROJ) events: {d.MgrStartProj:N0}; Manager Stop: {d.MgrStop:N0}; driver ready: {d.DriverReady:N0}.");
        if (d.PerfCats.TryGetValue("Timeout", out var to) && to >= 5)
            findings.Add($"HIGH: Timeouts detected ({to}).");

        foreach (var rule in _rules.Rules)
        {
            if (rule.FindingAt is not int at) continue;
            var n = RuleEngine.GetRuleCount(d, rule.Id);
            if (n < at) continue;
            var line = $"{rule.Group} - {rule.Label}: {n:N0} line(s).";
            if (d.HitMeasures.TryGetValue(rule.Id, out var mm) && mm.Count > 0)
            {
                var parts = string.Join(", ", mm.Keys.OrderBy(k => k).Select(k => $"{k}={mm[k]:N0}"));
                line += $" Totals: {parts}.";
            }
            if (rule.BucketBy is { Count: > 0 } bb)
            {
                var bname = bb.Keys.OrderBy(k => k).First();
                if (d.HitBuckets.TryGetValue(rule.Id, out var idb) && idb.TryGetValue(bname, out var map))
                {
                    var top = string.Join(", ", map.OrderByDescending(kv => kv.Value).Take(3)
                        .Select(kv => $"{kv.Key} x{kv.Value:N0}"));
                    if (top.Length > 0) line += $" Top {bname}: {top}.";
                }
            }
            findings.Add(line);
        }

        if (findings.Count == 0 && d.ParsedLines > 0)
            findings.Add("No strong automated volume findings from current heuristics.");
        return findings;
    }

    public Dictionary<string, object?> BuildSnapshot(
        string logPath,
        long fileLength,
        string version,
        OrganizeMode organize = OrganizeMode.All,
        ReportFormat format = ReportFormat.Both,
        IReadOnlyList<string>? severities = null,
        IReadOnlyList<string>? areas = null,
        bool windowEntire = true,
        int lastMinutes = 60)
    {
        var sevList = severities ?? new[] { "FATAL", "SEVERE", "ERROR", "WARNING", "INFO" };
        var areaList = areas ?? new[] { "SYS", "IMPL", "CTRL", "PARAM", "OTHER" };
        var sevFilter = ChartSeriesBuilder.SevFilterFromList(sevList);
        var areaFilter = ChartSeriesBuilder.AreaFilterFromList(areaList);

        var findings = BuildFindings();
        // KPI severity counts are area-filtered only (PS Get-FilteredSeverityCounts).
        var sevCounts = ApiBuilders.FilteredSeverityCounts(_data, areaFilter);

        var areaCounts = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var a in new[] { "SYS", "IMPL", "CTRL", "PARAM", "OTHER" })
            areaCounts[a] = _data.AreaCounts.TryGetValue(a, out var n) ? n : 0;

        var endedFailed = _data.BacLastStatus.Count(kv => kv.Value == "Failed");
        var endedOk = _data.BacLastStatus.Count(kv => kv.Value == "OK");
        var flappers = _data.BacFlipByDevice.Count(kv => kv.Value >= _bacFlapMin);
        var series = ChartSeriesBuilder.Build(_data, sevFilter, areaFilter);
        var topManagers = ApiBuilders.FilteredTopManagers(_data, areaFilter, 20).ToArray();
        var managers = ApiBuilders.FilteredTopManagers(_data, areaFilter, 5000).ToArray();

        return new Dictionary<string, object?>
        {
            ["meta"] = new Dictionary<string, object?>
            {
                ["tool"] = "PVSS Log Watch",
                ["version"] = version,
                ["generated"] = DateTime.Now.ToString("yyyy.MM.dd HH:mm:ss"),
                ["logPath"] = logPath,
                ["fileLength"] = fileLength,
                ["generation"] = 0,
                ["parsedLines"] = _data.ParsedLines,
                ["severities"] = sevList.ToArray(),
                ["areas"] = areaList.ToArray()
            },
            ["options"] = new Dictionary<string, object?>
            {
                ["organize"] = organize.ToString(),
                ["severities"] = sevList.ToArray(),
                ["areas"] = areaList.ToArray(),
                ["drivers"] = Array.Empty<string>(),
                ["topN"] = _topN,
                ["samplePerPattern"] = 1,
                ["window"] = windowEntire ? "entire" : "minutes",
                ["lastMinutes"] = lastMinutes,
                ["format"] = format.ToString().ToLowerInvariant()
            },
            ["window"] = new Dictionary<string, object?>
            {
                ["mode"] = windowEntire ? "entire" : "minutes",
                ["lastMinutes"] = windowEntire ? 0 : lastMinutes,
                ["first"] = _data.FirstTs,
                ["last"] = _data.LastTs
            },
            ["findings"] = findings,
            ["severityCounts"] = sevCounts,
            ["areaCounts"] = areaCounts,
            ["series"] = series,
            ["hourly"] = ChartSeriesBuilder.BuildHourly(_data, areaFilter),
            ["topManagers"] = topManagers,
            ["managers"] = managers,
            ["patternsBySeverity"] = ApiBuilders.FilteredPatternsBySeverity(_data, sevFilter, areaFilter, _topN),
            ["moduleHeadlines"] = BuildModuleHeadlines(endedFailed, endedOk, flappers),
            ["projectLifecycle"] = ApiBuilders.BuildProjectLifecycle(_data, areaFilter),
            ["managerHealth"] = BuildManagerHealth(),
            ["bacnet"] = ApiBuilders.BuildBacnetSection(_data, _bacFlapMin, _topN),
            ["cns"] = ApiBuilders.BuildCnsSection(_data, _topN),
            ["coho"] = ApiBuilders.BuildCohoSection(_data, _topN),
            ["apogee"] = ApiBuilders.BuildApogeeSection(_data, _topN),
            ["detections"] = ApiBuilders.BuildDetectionsObject(_data, _rules.Rules, _topN),
            ["perf"] = new Dictionary<string, object?>
            {
                ["perfCategories"] = _data.PerfCats.OrderByDescending(kv => kv.Value)
                    .Select(kv => new Dictionary<string, object?> { ["name"] = kv.Key, ["count"] = kv.Value }).ToArray(),
                ["unparsedLines"] = _data.UnparsedLines
            },
            ["driverDeepDive"] = Array.Empty<object>()
        };
    }

    private Dictionary<string, object?> BuildModuleHeadlines(int endedFailed, int endedOk, int flappers) =>
        new()
        {
            ["bacnet"] = new Dictionary<string, object?>
            {
                ["failed"] = _data.BacFailed,
                ["ok"] = _data.BacOk,
                ["endedFailed"] = endedFailed,
                ["endedOk"] = endedOk,
                ["flappers"] = flappers,
                ["objectList"] = _data.BacObjectList,
                ["collectTrend"] = _data.BacCollectTrend,
                ["timeSync"] = _data.BacTimeSync,
                ["collectTrendProps"] = _data.BacCollectTrendByProp.Count,
                ["timeSyncProps"] = _data.BacTimeSyncByProp.Count
            },
            ["cns"] = new Dictionary<string, object?>
            {
                ["resolveNodes"] = RuleEngine.GetRuleCount(_data, "cns.resolveNodes"),
                ["reducedFunction"] = RuleEngine.GetRuleCount(_data, "cns.reducedFunction"),
                ["tryRenew"] = RuleEngine.GetRuleCount(_data, "cns.tryRenew"),
                ["icns"] = RuleEngine.GetRuleCount(_data, "cns.icns")
            },
            ["coho"] = new Dictionary<string, object?> { ["stuck"] = _data.CohoStuck },
            ["apogee"] = new Dictionary<string, object?>
            {
                ["events"] = _data.ApogeeEvents,
                ["updatePoints"] = _data.ApogeeUpdatePoints,
                ["drvLines"] = _data.ApogeeDrvLines,
                ["trendOverflow"] = RuleEngine.GetRuleCount(_data, "apogeeDrv.trendOverflow"),
                ["trendSeq"] = RuleEngine.GetRuleCount(_data, "apogeeDrv.trendSeq"),
                ["alertId"] = RuleEngine.GetRuleCount(_data, "apogeeDrv.alertId"),
                ["getDataFail"] = RuleEngine.GetRuleCount(_data, "apogeeDrv.getDataFail")
            }
        };

    private Dictionary<string, object?> BuildManagerHealth()
    {
        var life = LifecycleBuilder.BuildLifecycleRows(_data, ".");
        var mgrs = life["managers"] is object[] arr
            ? arr.OfType<Dictionary<string, object?>>().Take(25).ToArray()
            : Array.Empty<Dictionary<string, object?>>();
        return new Dictionary<string, object?>
        {
            ["totals"] = life["totals"],
            ["driverReady"] = _data.DriverReady,
            ["blockingSample"] = _data.BlockingSample,
            ["unblockingSample"] = _data.UnblockingSample,
            ["managers"] = mgrs
        };
    }

}

/// <summary>HTML / text / JSON report renderers.</summary>
public sealed class ReportWriter
{
    public string ToText(Dictionary<string, object?> snap, string author = "Cisum")
    {
        var sb = new System.Text.StringBuilder();
        var meta = (Dictionary<string, object?>)snap["meta"]!;
        var win = (Dictionary<string, object?>)snap["window"]!;
        var opt = (Dictionary<string, object?>)snap["options"]!;
        void W(string t = "") => sb.AppendLine(t);

        W("================================================================================");
        W(" PVSS / WinCC OA Log Analysis Report");
        W("================================================================================");
        W($"Tool      : {meta["tool"]} v{meta["version"]} by {author}");
        W($"Generated : {meta["generated"]}");
        W($"Log file  : {meta["logPath"]}");
        var len = Convert.ToInt64(meta["fileLength"]);
        W($"Size      : {len / (1024.0 * 1024.0):N2} MB");
        W($"Lines     : {Convert.ToInt32(meta["parsedLines"]):N0} analyzed (WinCC OA header, in window)");
        W($"Time span : {win["first"]}  -->  {win["last"]}");
        W();
        W("--- Options used ---");
        W($" Organize      : {opt["organize"]}");
        W($" Severities    : {string.Join(", ", (string[])opt["severities"]!)}");
        W($" Areas         : {string.Join(", ", (string[])opt["areas"]!)}");
        W($" TopN          : {opt["topN"]}");
        W($" Time mode     : {opt["window"]}");
        W($" Format        : {opt["format"]}");
        W();
        W("--- Findings ---");
        foreach (var f in (List<string>)snap["findings"]!)
            W($" * {f}");
        W();
        W("--- Severity counts ---");
        var sev = (Dictionary<string, int>)snap["severityCounts"]!;
        foreach (var s in new[] { "FATAL", "SEVERE", "ERROR", "WARNING", "INFO" })
            W($" {sev.GetValueOrDefault(s),8:N0}  {s}");
        W();
        W("--- Area counts ---");
        var areas = (Dictionary<string, int>)snap["areaCounts"]!;
        foreach (var a in new[] { "SYS", "IMPL", "CTRL", "PARAM", "OTHER" })
            W($" {areas.GetValueOrDefault(a),8:N0}  {a}");
        W();
        var mh = (Dictionary<string, object?>)snap["moduleHeadlines"]!;
        var bac = (Dictionary<string, object?>)mh["bacnet"]!;
        var cns = (Dictionary<string, object?>)mh["cns"]!;
        var coho = (Dictionary<string, object?>)mh["coho"]!;
        var apo = (Dictionary<string, object?>)mh["apogee"]!;
        W("--- Module headlines ---");
        W($" BACnet : Failed={bac["failed"]:N0} OK={bac["ok"]:N0} endedFailed={bac["endedFailed"]:N0} endedOK={bac["endedOk"]:N0} flappers={bac["flappers"]:N0} objectList={bac["objectList"]:N0} CollectTrend={bac["collectTrend"]:N0} TimeSync={bac["timeSync"]:N0}");
        W($" CNS    : ResolveNodes={cns["resolveNodes"]:N0} ReducedFunction={cns["reducedFunction"]:N0} TryRenewSession={cns["tryRenew"]:N0}");
        W($" CoHo   : stuck/drop={coho["stuck"]:N0}");
        W($" Apogee : events={apo["events"]:N0} UpdatePoints={apo["updatePoints"]:N0} | Drv overflow={apo["trendOverflow"]:N0} seq={apo["trendSeq"]:N0} AlertID={apo["alertId"]:N0} getData={apo["getDataFail"]:N0}");
        W();
        W("--- Detections (non-curated) ---");
        foreach (var g in (List<Dictionary<string, object?>>)snap["detections"]!)
        {
            W($" [{g["group"]}] total={g["total"]:N0}");
            if (g["rules"] is List<Dictionary<string, object?>> rules)
                foreach (var row in rules)
                    W($"   {row["label"]}: {row["count"]:N0}");
            else if (g["rules"] is object[] arr)
                foreach (var o in arr.OfType<Dictionary<string, object?>>())
                    W($"   {o["label"]}: {o["count"]:N0}");
        }
        W();
        W("================================================================================");
        return sb.ToString();
    }

    public string ToHtml(Dictionary<string, object?> snap, string author = "Cisum") =>
        SnapshotHtml.Render(snap, author);

    public string ToJson(Dictionary<string, object?> snap) =>
        JsonSerializer.Serialize(snap, new JsonSerializerOptions
        {
            WriteIndented = true,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
        });

    public (string? TextPath, string? HtmlPath) WriteFiles(
        Dictionary<string, object?> snap, string logPath, string? outPath, ReportFormat format)
    {
        string stem;
        if (string.IsNullOrWhiteSpace(outPath))
            stem = logPath + ".analysis";
        else
            stem = System.Text.RegularExpressions.Regex.Replace(outPath, @"(?i)\.(txt|html?)$", "");

        string? textPath = null, htmlPath = null;
        if (format is ReportFormat.Text or ReportFormat.Both)
        {
            textPath = stem + ".txt";
            File.WriteAllText(textPath, ToText(snap));
        }
        if (format is ReportFormat.Html or ReportFormat.Both)
        {
            htmlPath = stem + ".html";
            File.WriteAllText(htmlPath, ToHtml(snap));
        }
        return (textPath, htmlPath);
    }
}
