using DesigoLogWatcher;

namespace DesigoLogWatcher.Tests;

public class RuleEngineTests
{
    private static string L(string comp, string ts, string area, string sev, string msg) =>
        $"{comp}, {ts}, {area}, {sev}, {msg}";

    [Fact]
    public void RuleTable_Has23Ids()
    {
        var engine = new RuleEngine();
        Assert.Equal(23, engine.Rules.Count);
        Assert.Contains(engine.Rules, r => r.Id == "afw.traceRepetition");
        Assert.Contains(engine.Rules, r => r.Id == "cns.resolveNodes");
    }

    [Fact]
    public void Scope_FiltersApogeeRules()
    {
        var engine = new RuleEngine();
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
    public void CnsPatternGroup_FeedsSidecar()
    {
        var engine = new RuleEngine();
        var state = new AnalysisState();
        state.ProcessLine(L("App", "2026.09.04 10:00:00.000", "SYS", "WARNING", "ResolveNodes failed"),
            rules: engine);
        Assert.Equal(1, RuleEngine.GetRuleCount(state, "cns.resolveNodes"));
        Assert.True(state.CnsPatterns.Count > 0);
    }

    [Fact]
    public void Measure_SumAndMax()
    {
        var engine = new RuleEngine();
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
        var engine = new RuleEngine();
        var state = new AnalysisState();
        state.ProcessLine(L("WCCOAx", "2026.09.04 10:00:00.000", "SYS", "ERROR",
            "Last sequence number 5 is less than saved"), rules: engine);
        Assert.Equal(1, RuleEngine.GetRuleCount(state, "trend.seqLess"));
        Assert.Equal(1, state.HitBuckets["trend.seqLess"]["manager"]["WCCOAx"]);
    }

    [Fact]
    public void SingleScope_DevGate_NoListScopesYet()
    {
        foreach (var r in new RuleEngine().Rules)
            Assert.True(r.Scope is null || r.Scope is string);
    }
}
