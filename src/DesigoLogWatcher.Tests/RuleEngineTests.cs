using DesigoLogWatcher;

namespace DesigoLogWatcher.Tests;

public class RuleEngineTests
{
    private static string L(string comp, string ts, string area, string sev, string msg) =>
        $"{comp}, {ts}, {area}, {sev}, {msg}";

    [Fact]
    public void RuleTable_DevGate_Has23Ids()
    {
        var engine = new RuleEngine(RuleGateMode.DevGate);
        Assert.Equal(23, engine.Rules.Count);
        Assert.Contains(engine.Rules, r => r.Id == "afw.traceRepetition");
        Assert.Contains(engine.Rules, r => r.Id == "cns.resolveNodes");
        Assert.DoesNotContain(engine.Rules, r => r.Id.StartsWith("bacnetDrv.", StringComparison.Ordinal));
    }

    [Fact]
    public void RuleTable_ShipGate_HasBacnetDrvFamilies()
    {
        var engine = new RuleEngine(RuleGateMode.ShipGate);
        Assert.Equal(28, engine.Rules.Count);
        Assert.Contains(engine.Rules, r => r.Id == "bacnetDrv.trendOverflow");
        Assert.Contains(engine.Rules, r => r.Id == "bacnetDrv.queryTimeout");
        var seqLess = Assert.Single(engine.Rules, r => r.Id == "trend.seqLess");
        Assert.Equal(new[] { "GmsBACnet", "ApogeeDrv" }, seqLess.Scopes);
    }

    [Fact]
    public void Scope_FiltersApogeeRules()
    {
        var engine = new RuleEngine(RuleGateMode.DevGate);
        var state = new AnalysisState();
        var ts = "2026.09.04 10:00:00.000";
        var line = L("WCCOAui", ts, "CTRL", "WARNING",
            "Trend buffer overflow for trend T1 in device 99");
        state.ProcessLine(line, rules: engine);
        Assert.Equal(0, RuleEngine.GetRuleCount(state, "apogeeDrv.trendOverflow"));

        var line2 = L("WCCOAApogeeDrv", ts, "CTRL", "WARNING",
            "Trend buffer overflow for trend T1 in device 99.");
        state.ProcessLine(line2, rules: engine);
        Assert.Equal(1, RuleEngine.GetRuleCount(state, "apogeeDrv.trendOverflow"));
        Assert.Equal(1, RuleEngine.GetRuleBucketCount(state, "apogeeDrv.trendOverflow", "device"));
        Assert.NotNull(RuleEngine.GetRuleSample(state, "apogeeDrv.trend"));
    }

    [Fact]
    public void BacnetDrv_TrendOverflow_UsesLogObjectWording()
    {
        var engine = new RuleEngine(RuleGateMode.ShipGate);
        var state = new AnalysisState();
        var ts = "2026.09.04 10:00:00.000";
        state.ProcessLine(L("WCCOAGmsBACnet(1)", ts, "SYS", "WARNING",
            "Trend buffer overflow for trend log object 2  in device 9803."), rules: engine);
        Assert.Equal(1, RuleEngine.GetRuleCount(state, "bacnetDrv.trendOverflow"));
        Assert.Equal(0, RuleEngine.GetRuleCount(state, "apogeeDrv.trendOverflow"));
        Assert.Equal(1, RuleEngine.GetRuleBucketCount(state, "bacnetDrv.trendOverflow", "device"));
    }

    [Fact]
    public void MultiScope_SeqLess_OnlyGmsBACnetAndApogeeDrv()
    {
        var engine = new RuleEngine(RuleGateMode.ShipGate);
        var state = new AnalysisState();
        var ts = "2026.09.04 10:00:00.000";
        var msg = "Last sequence number 5 is less than saved";
        state.ProcessLine(L("WCCOAui", ts, "SYS", "ERROR", msg), rules: engine);
        Assert.Equal(0, RuleEngine.GetRuleCount(state, "trend.seqLess"));

        state.ProcessLine(L("WCCOAGmsBACnet(1)", ts, "SYS", "ERROR", msg), rules: engine);
        Assert.Equal(1, RuleEngine.GetRuleCount(state, "trend.seqLess"));

        state.ProcessLine(L("WCCOAApogeeDrv", ts, "SYS", "ERROR", msg), rules: engine);
        Assert.Equal(2, RuleEngine.GetRuleCount(state, "trend.seqLess"));
    }

    [Fact]
    public void DevGate_SeqLess_StillUnscoped()
    {
        var engine = new RuleEngine(RuleGateMode.DevGate);
        var state = new AnalysisState();
        state.ProcessLine(L("WCCOAui", "2026.09.04 10:00:00.000", "SYS", "ERROR",
            "Last sequence number 5 is less than saved"), rules: engine);
        Assert.Equal(1, RuleEngine.GetRuleCount(state, "trend.seqLess"));
    }

    [Fact]
    public void CnsPatternGroup_FeedsSidecar()
    {
        var engine = new RuleEngine(RuleGateMode.DevGate);
        var state = new AnalysisState();
        state.ProcessLine(L("App", "2026.09.04 10:00:00.000", "SYS", "WARNING", "ResolveNodes failed"),
            rules: engine);
        Assert.Equal(1, RuleEngine.GetRuleCount(state, "cns.resolveNodes"));
        Assert.True(state.CnsPatterns.Count > 0);
    }

    [Fact]
    public void Measure_SumAndMax()
    {
        var engine = new RuleEngine(RuleGateMode.DevGate);
        var state = new AnalysisState();
        var ts = "2026.09.04 10:00:00.000";
        state.ProcessLine(L("Mgr", ts, "SYS", "WARNING", "Repetition (#=10) of a former trace"), rules: engine);
        state.ProcessLine(L("Mgr", ts, "SYS", "WARNING", "Repetition (#=3) of a former trace"), rules: engine);
        Assert.Equal(2, RuleEngine.GetRuleCount(state, "afw.traceRepetition"));
        Assert.Equal(13, state.HitMeasures["afw.traceRepetition"]["repeats"]);
        Assert.Equal(10, state.HitMeasures["afw.traceRepetition"]["worstRun"]);
    }

    [Fact]
    public void BucketBy_ComponentVariable()
    {
        var engine = new RuleEngine(RuleGateMode.DevGate);
        var state = new AnalysisState();
        state.ProcessLine(L("WCCOAx", "2026.09.04 10:00:00.000", "SYS", "ERROR",
            "Last sequence number 5 is less than saved"), rules: engine);
        Assert.Equal(1, RuleEngine.GetRuleCount(state, "trend.seqLess"));
        Assert.Equal(1, state.HitBuckets["trend.seqLess"]["manager"]["WCCOAx"]);
    }

    [Fact]
    public void DefaultEngine_IsShipGate()
    {
        var engine = new RuleEngine();
        Assert.Contains(engine.Rules, r => r.Id == "bacnetDrv.trendOverflow");
    }
}
