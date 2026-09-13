using DesigoLogWatcher;

namespace DesigoLogWatcher.Tests;

public class LifecycleParityTests
{
    [Fact]
    public void LifecycleRows_FiltersByPatternAndTotals()
    {
        var state = new AnalysisState();
        state.MgrStartByComp["WCCOAGmsBACnet"] = 2;
        state.MgrStopByComp["WCCOAGmsBACnet"] = 1;
        state.PmonRestartByComp["WCCOAGmsBACnet"] = 1;
        state.BlockingByComp["CtrlMgr"] = 3;
        state.MgrStartByComp["CtrlMgr"] = 1;

        var bac = LifecycleBuilder.BuildLifecycleRows(state, "(?i)GmsBACnet|WCCOAGmsBACnet");
        var mgrs = (object[])bac["managers"]!;
        Assert.Single(mgrs);
        var row = (Dictionary<string, object?>)mgrs[0];
        Assert.Equal("WCCOAGmsBACnet", row["name"]);
        Assert.Equal(2, Convert.ToInt32(row["starts"]));
        var tot = (Dictionary<string, object?>)bac["totals"]!;
        Assert.Equal(2, Convert.ToInt32(tot["starts"]));
        Assert.Equal(1, Convert.ToInt32(tot["restarts"]));
    }

    [Fact]
    public void ProjectCycles_BuildsUptimeRows()
    {
        var events = new List<Dictionary<string, object?>>
        {
            new() { ["t"] = "2026.09.04 10:00:00.000", ["kind"] = "up", ["area"] = "SYS" },
            new() { ["t"] = "2026.09.04 11:00:00.000", ["kind"] = "shutdown", ["area"] = "SYS" },
            new() { ["t"] = "2026.09.04 11:00:30.000", ["kind"] = "stopped", ["area"] = "SYS" },
            new() { ["t"] = "2026.09.04 12:00:00.000", ["kind"] = "up", ["area"] = "SYS" }
        };
        var cycles = LifecycleBuilder.BuildProjectLifecycleCycles(events, "2026.09.04 09:00:00.000", "2026.09.04 13:00:00.000");
        Assert.NotEmpty(cycles);
        var first = cycles[0];
        Assert.Equal("2026.09.04 10:00:00.000", first["up"]);
        Assert.Equal("2026.09.04 11:00:00.000", first["shutdown"]);
        Assert.Equal(3600.0, Convert.ToDouble(first["uptimeSec"]));
        Assert.Equal("1h", first["uptime"]?.ToString());
        Assert.Equal(30.0, Convert.ToDouble(first["stopSec"]));
        Assert.Equal("30s", first["stopDuration"]?.ToString());
        Assert.Equal(3570.0, Convert.ToDouble(first["downtimeSec"])); // 11:00:30 -> 12:00:00
    }

    [Fact]
    public void DurationLabel_FormatsBands()
    {
        Assert.Equal("45s", LifecycleBuilder.FormatDurationLabel(45));
        Assert.Equal("2m", LifecycleBuilder.FormatDurationLabel(120));
        Assert.Equal("2m 5s", LifecycleBuilder.FormatDurationLabel(125));
        Assert.Equal("3h", LifecycleBuilder.FormatDurationLabel(10800));
        Assert.Equal("3h 1m", LifecycleBuilder.FormatDurationLabel(10860));
        Assert.Equal("2d", LifecycleBuilder.FormatDurationLabel(172800));
    }

    [Fact]
    public void ModuleSections_IncludeLifecycleBlocks()
    {
        var engine = new RuleEngine();
        var state = new AnalysisState();
        state.MgrStartByComp["WCCOAGmsBACnet(1)"] = 1;
        state.MgrStartByComp["ApplicationFramework"] = 2;
        state.MgrStartByComp["WCCOAGmsCoHoMngr"] = 1;
        state.MgrStartByComp["WCCOAApogeeDrv"] = 4;
        state.BacLastStatus["dev1"] = "Failed";
        state.BacFailedByDevice["dev1"] = 5;
        state.ProcessLine(
            "WCCOAGmsCoHoMngr, 2026.09.04 10:00:00.000, SYS, ERROR, Error Code 42 for Property \"propA\" and Command \"BACnetCollectTrend\"",
            rules: engine);

        var bac = ApiBuilders.BuildBacnetSection(state, bacFlapMin: 3, topN: 10);
        Assert.True(bac.ContainsKey("lifecycle"));
        Assert.True(bac.ContainsKey("endedFailedList"));
        Assert.True(bac.ContainsKey("collectTrendCodes"));
        var life = (Dictionary<string, object?>)bac["lifecycle"]!;
        Assert.NotEmpty((object[])life["managers"]!);

        Assert.Contains("lifecycle", ApiBuilders.BuildCnsSection(state, 10).Keys);
        Assert.Contains("lifecycle", ApiBuilders.BuildCohoSection(state, 10).Keys);
        var apo = ApiBuilders.BuildApogeeSection(state, 10);
        Assert.Contains("lifecycle", apo.Keys);
        Assert.Contains("topTrendDevices", apo.Keys);

        var mgr = ApiBuilders.BuildManagerPayload(state, "WCCOAGmsBACnet(1)", ChartSeriesBuilder.DefaultSevFilter(), 10, 1);
        Assert.Contains("lifecycle", mgr.Keys);
        var mLife = (Dictionary<string, object?>)mgr["lifecycle"]!;
        Assert.Single((object[])mLife["managers"]!);
    }

    [Fact]
    public void Snapshot_IncludesCyclesAndModuleLifecycle()
    {
        var engine = new RuleEngine();
        var state = new AnalysisState();
        state.ProcessLine("WCCILpmon, 2026.09.04 10:00:00.000, SYS, INFO, The project is up and running", rules: engine);
        state.ProcessLine("WCCILpmon, 2026.09.04 11:00:00.000, SYS, INFO, Got shutdown command", rules: engine);
        state.ProcessLine("WCCILpmon, 2026.09.04 11:00:30.000, SYS, INFO, Completely stopped the project", rules: engine);
        state.MgrStartByComp["WCCOAGmsBACnet"] = 1;

        var snap = new SnapshotBuilder(state, engine).BuildSnapshot("t.log", 10, "0.5.0-test");
        var pl = (Dictionary<string, object?>)snap["projectLifecycle"]!;
        var cycles = (List<Dictionary<string, object?>>)pl["cycles"]!;
        Assert.NotEmpty(cycles);

        var bac = (Dictionary<string, object?>)snap["bacnet"]!;
        Assert.True(bac.ContainsKey("lifecycle"));

        var html = new ReportWriter().ToHtml(snap);
        Assert.Contains("Project restarts", html);
        Assert.Contains("Uptime", html);
        Assert.DoesNotContain("cycle table not expanded", html);
    }
}
