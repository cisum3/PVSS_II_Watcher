using System.Collections.Specialized;
using DesigoLogWatcher;

namespace DesigoLogWatcher.Tests;

public class ApiParityTests
{
    private static AnalysisState Seed()
    {
        var engine = new RuleEngine();
        var state = new AnalysisState();
        // SYS errors
        state.ProcessLine("WCCOAui, 2026.09.04 10:00:00.000, SYS, ERROR, boom timeout", rules: engine);
        state.ProcessLine("WCCOAui, 2026.09.04 10:00:01.000, SYS, ERROR, boom timeout", rules: engine);
        // CTRL warning on different manager
        state.ProcessLine("CtrlMgr, 2026.09.04 10:00:02.000, CTRL, WARNING, Unexpected state, DrvManager, gotAlertConfigAnswer,", rules: engine);
        state.ProcessLine("CtrlMgr, 2026.09.04 10:00:03.000, CTRL, WARNING, Unexpected state, DrvManager, gotAlertConfigAnswer,", rules: engine);
        // Driver detection rule
        state.ProcessLine(
            "WCCOAGmsCoHoMngr, 2026.09.04 10:00:04.000, SYS, SEVERE, The Driver returned Error Code 70442 for Property \"x\"",
            rules: engine);
        return state;
    }

    [Fact]
    public void AreaFilter_ChangesSeverityCountsAndManagers()
    {
        var state = Seed();
        var all = ChartSeriesBuilder.AllAreaOn();
        var sysOnly = ChartSeriesBuilder.AreaFilterFromList(["SYS"]);

        var sevAll = ApiBuilders.FilteredSeverityCounts(state, all);
        var sevSys = ApiBuilders.FilteredSeverityCounts(state, sysOnly);
        Assert.True(sevAll["WARNING"] >= 2);
        Assert.Equal(0, sevSys["WARNING"]); // CTRL warnings excluded
        Assert.True(sevSys["ERROR"] >= 2);

        var mgrAll = ApiBuilders.FilteredTopManagers(state, all, 20);
        var mgrSys = ApiBuilders.FilteredTopManagers(state, sysOnly, 20);
        Assert.Contains(mgrAll, m => (string)m["name"]! == "CtrlMgr");
        Assert.DoesNotContain(mgrSys, m => (string)m["name"]! == "CtrlMgr");
    }

    [Fact]
    public void ManagerPayload_IncludesPatterns()
    {
        var state = Seed();
        var sev = ChartSeriesBuilder.DefaultSevFilter();
        var payload = ApiBuilders.BuildManagerPayload(state, "WCCOAui", sev, 10, 1);
        var bySev = (Dictionary<string, object?>)payload["patternsBySeverity"]!;
        var errors = (object[])bySev["ERROR"]!;
        Assert.NotEmpty(errors);
        var row = (Dictionary<string, object?>)errors[0];
        Assert.True(Convert.ToInt32(row["count"]) >= 2);
    }

    [Fact]
    public void Detections_AreGroupedWithRules()
    {
        var state = Seed();
        var groups = ApiBuilders.BuildDetectionsObject(state, new RuleEngine().Rules, 10);
        Assert.NotEmpty(groups);
        Assert.Contains(groups, g => g.ContainsKey("group") && g.ContainsKey("rules") && Convert.ToInt32(g["total"]) > 0);
        var first = groups[0];
        Assert.True(first["rules"] is List<Dictionary<string, object?>> { Count: > 0 }
                     or object[] { Length: > 0 });
    }

    [Fact]
    public void Snapshot_HonorsSeverityAndAreaQueryFilters()
    {
        var state = Seed();
        var snap = new SnapshotBuilder(state, new RuleEngine()).BuildSnapshot(
            "t.log", 100, "0.5.0-test",
            severities: ["ERROR"],
            areas: ["SYS"]);
        var sev = (Dictionary<string, int>)snap["severityCounts"]!;
        Assert.True(sev["ERROR"] >= 2);
        // KPIs are area-filtered only (not severity-chip gated). SYS-only excludes CTRL warnings.
        Assert.Equal(0, sev["WARNING"]);
        var meta = (Dictionary<string, object?>)snap["meta"]!;
        Assert.Equal(new[] { "ERROR" }, (string[])meta["severities"]!);
        Assert.Equal(new[] { "SYS" }, (string[])meta["areas"]!);
        var html = new ReportWriter().ToHtml(snap);
        Assert.Contains("Activity charts", html);
        Assert.Contains("Severity filters: ERROR", html);
        // HTML must render real severity KPI numbers (Dictionary<string,int> coercion).
        Assert.Contains("data-sev=\"ERROR\"", html);
        Assert.DoesNotContain("data-sev=\"ERROR\"><div class=\"label\">ERROR</div><div class=\"value\">0</div>", html);
        Assert.Contains("Top managers", html);
        Assert.Contains(">WCCOAui</td>", html);
    }

    [Fact]
    public void Pulse_UsesAreaFilterForSeriesSeverity()
    {
        var dir = Path.Combine(Path.GetTempPath(), "dlw-api-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        var cfg = Path.Combine(dir, "watch-config.txt");
        File.WriteAllText(cfg, "PreferredPort=18791\nDefaultWindowEntire=true\n");
        try
        {
            var config = new Config(cfg, _ => { });
            config.Mode = WatchRunMode.Dashboard;
            config.Load();
            using var session = new WatchSession(config);
            // Inject analyzed state without worker
            typeof(WatchSession).GetProperty(nameof(WatchSession.Data))!
                .SetMethod!.Invoke(session, [Seed()]);
            session.Loading = false;

            var q = new NameValueCollection
            {
                ["severities"] = "FATAL,SEVERE,ERROR,WARNING",
                ["areas"] = "SYS"
            };
            var pulse = (Dictionary<string, object?>)session.BuildPulse(q);
            var sev = (Dictionary<string, int>)pulse["severityCounts"]!;
            Assert.Equal(0, sev["WARNING"]);
            Assert.True(sev["ERROR"] >= 2);
        }
        finally
        {
            try { Directory.Delete(dir, true); } catch { /* ignore */ }
        }
    }

    [Fact]
    public void HtmlReport_DetectionsIncludeBucketsAndSpan()
    {
        var engine = new RuleEngine();
        var state = new AnalysisState();
        state.ProcessLine(
            "WCCOAGmsCoHoMngr(7), 2026.09.04 10:00:00.000, IMPL, SEVERE, The Driver returned Error Code 70442 for Property \"x\" and Command \"BACnetTimeSync\"",
            rules: engine);
        for (var i = 0; i < 260; i++)
            state.ProcessLine(
                $"WCCOAGmsCoHoMngr(7), 2026.09.04 10:00:{(i % 60):D2}.000, IMPL, SEVERE, Command failed because Driver 1 is offline.",
                rules: engine);

        var snap = new SnapshotBuilder(state, engine).BuildSnapshot("t.log", 10, "0.5.0-test", format: ReportFormat.Html);
        var html = new ReportWriter().ToHtml(snap);
        Assert.Contains("<th>First</th><th>Last</th><th>Pattern</th><th>Example</th>", html);
        Assert.Contains("Detections", html);
        Assert.Contains("&times; threshold", html);
        Assert.Contains("rule <span class=\"mono\">", html);
        Assert.True(html.Contains("data kv") || html.Contains("All from"), "expected bucket table or single-value summary");
        Assert.Equal("html", ((Dictionary<string, object?>)snap["options"]!)["format"]?.ToString()?.ToLowerInvariant());
    }
}
