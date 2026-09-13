using DesigoLogWatcher;

namespace DesigoLogWatcher.Tests;

public class AnalysisStateTests
{
    private static string L(string comp, string ts, string area, string sev, string msg) =>
        $"{comp}, {ts}, {area}, {sev}, {msg}";

    [Fact]
    public void ProcessLine_ParsesHeaderAndCounts()
    {
        var s = new AnalysisState();
        s.ProcessLine(L("WCCOAui", "2026.09.04 10:00:00.000", "SYS", "ERROR", "boom"));
        s.ProcessLine(L("WCCOAui", "2026.09.04 10:00:01.000", "SYS", "WARN", "warnme"));
        s.ProcessLine("not a header line");

        Assert.Equal(2, s.ParsedLines);
        Assert.Equal(1, s.UnparsedLines);
        Assert.Equal(1, s.Severity["ERROR"]);
        Assert.Equal(1, s.Severity["WARNING"]); // WARN→WARNING
        Assert.Equal(1, s.SevereLines);
        Assert.Equal("2026.09.04 10:00:00.000", s.FirstTs);
        Assert.Equal("2026.09.04 10:00:01.000", s.LastTs);
        Assert.Equal(2, s.Components["WCCOAui"]);
        Assert.Equal(2, s.AreaCounts["SYS"]);
    }

    [Fact]
    public void ProcessLine_BacnetFlipsAndObjectList()
    {
        var s = new AnalysisState();
        var ts = "2026.09.04 10:00:00.000";
        s.ProcessLine(L("WCCOAGmsBACnet", ts, "CTRL", "INFO", "Device 42 Status is now Failed"));
        s.ProcessLine(L("WCCOAGmsBACnet", ts, "CTRL", "INFO", "Device 42 Status is now OK"));
        s.ProcessLine(L("WCCOAGmsBACnet", ts, "CTRL", "INFO", "Device 42 Status is now Failed"));
        s.ProcessLine(L("WCCOAGmsBACnet", ts, "CTRL", "WARNING", "Could not get object list for device 7"));

        Assert.Equal(2, s.BacFailed);
        Assert.Equal(1, s.BacOk);
        Assert.Equal(2, s.BacFlipByDevice["42"]); // Failed→OK, OK→Failed
        Assert.Equal("Failed", s.BacLastStatus["42"]);
        Assert.Equal(1, s.BacObjectList);
        Assert.Equal(1, s.BacObjectListByDevice["7"]);
        // INFO status lines enter PatternsBySev INFO
        Assert.True(s.PatternsBySev["INFO"].Count > 0);
    }

    [Fact]
    public void ProcessLine_BacnetCollectTrendDetail()
    {
        var s = new AnalysisState();
        s.ProcessLine(L("CoHo", "2026.09.04 10:00:00.000", "CTRL", "ERROR",
            @"Error Code 12 for Property ""trend"" and Command ""BACnetCollectTrend"""));
        Assert.Equal(1, s.BacCollectTrend);
        Assert.Equal(1, s.BacCollectTrendByCode["12"]);
        Assert.Equal(1, s.BacCollectTrendByProp["trend"]);
    }

    [Fact]
    public void ProcessLine_LifecycleProjectAndBlocking()
    {
        var s = new AnalysisState();
        var ts = "2026.09.04 10:00:00.000";
        s.ProcessLine(L("pmon", ts, "SYS", "INFO", "The project is up and running"));
        s.ProcessLine(L("pmon", ts, "SYS", "INFO", "Completely stopped the project"));
        s.ProcessLine(L("pmon", ts, "SYS", "INFO", "Got shutdown command"));
        s.ProcessLine(L("pmon", ts, "SYS", "WARNING", "Detected stopped manager WCCOAui(1) - restarting"));
        s.ProcessLine(L("WCCOAui(1)", ts, "SYS", "INFO", "Manager Start, PROJ, foo"));
        s.ProcessLine(L("WCCOAui(1)", ts, "SYS", "INFO", "Manager Stop"));
        s.ProcessLine(L("pmon", ts, "SYS", "SEVERE", "Blocking Manager WCCOAui(1) detected. No heartbeat since 30 seconds"));
        s.ProcessLine(L("pmon", ts, "SYS", "INFO", "Manager WCCOAui(1) is no longer blocking"));

        Assert.Equal(1, s.ProjectUp);
        Assert.Equal(1, s.ProjectStopped);
        Assert.Equal(1, s.ProjectShutdown);
        Assert.Equal(1, s.PmonMgrRestart);
        Assert.Equal(1, s.PmonRestartByComp["WCCOAui(1)"]);
        Assert.Equal(1, s.MgrStartProj);
        Assert.Equal(1, s.MgrStop);
        Assert.Equal(1, s.BlockingDetected);
        Assert.Equal(1, s.BlockingCleared);
        Assert.Equal(3, s.ProjectRestartEvents.Count); // up, stopped, shutdown — wait: up+stopped+shutdown = 3
    }

    [Fact]
    public void ProcessLine_CohoStuckAndApogee()
    {
        var s = new AnalysisState();
        var ts = "2026.09.04 10:00:00.000";
        s.ProcessLine(L("GmsCoHo", ts, "CTRL", "WARNING", "DiscoveryLoc:Foo got stuck and dropping it"));
        s.ProcessLine(L("Orch", ts, "CTRL", "ERROR", "CoHo.Apogee UpdatePoints fail PPCL Program Name: Prog1System.X"));
        s.ProcessLine(L("WCCOAApogeeDrv", ts, "CTRL", "WARNING", "something"));

        Assert.Equal(1, s.CohoStuck);
        Assert.Equal(1, s.CohoStuckNames["DiscoveryLoc:Foo"]);
        Assert.Equal(1, s.ApogeeEvents);
        Assert.Equal(1, s.ApogeeUpdatePoints);
        Assert.Equal(1, s.ApogeePpcl["Prog1"]);
        Assert.Equal(1, s.ApogeeDrvLines);
    }

    [Fact]
    public void ProcessLine_PatternsForError_NotAllInfo()
    {
        var s = new AnalysisState();
        s.ProcessLine(L("Mgr", "2026.09.04 10:00:00.000", "SYS", "ERROR", "alpha timeout happened"));
        s.ProcessLine(L("Mgr", "2026.09.04 10:00:01.000", "SYS", "INFO", "ordinary info"));
        Assert.True(s.PatternsBySev["ERROR"].Count >= 1);
        Assert.Empty(s.PatternsBySev["INFO"]); // only BACnet status INFO enters patterns
        Assert.Equal(1, s.PerfCats["Timeout"]);
    }

    [Fact]
    public void NormalizeMessage_CollapsesNoise()
    {
        var n = AnalysisState.NormalizeMessage(
            "Device 12345 Status at 2026.09.04 10:00:00.123 tid=99", 500);
        Assert.Contains("device <N>", n);
        Assert.Contains("<TS>", n);
        Assert.Contains("<KV>", n);
        Assert.DoesNotContain("12345", n);
    }

    [Fact]
    public void Cutoff_SkipsEarlyLines()
    {
        var s = new AnalysisState();
        s.ProcessLine(L("A", "2026.09.04 09:00:00.000", "SYS", "ERROR", "early"),
            enforceCutoff: true, cutoffCompare: "2026.09.04 10:00:00");
        s.ProcessLine(L("A", "2026.09.04 11:00:00.000", "SYS", "ERROR", "late"),
            enforceCutoff: true, cutoffCompare: "2026.09.04 10:00:00");
        Assert.Equal(1, s.ParsedLines);
        Assert.Equal("2026.09.04 11:00:00.000", s.FirstTs);
    }

    [Fact]
    public void AreaNormalize_UnknownToOther()
    {
        Assert.Equal("SYS", AnalysisState.NormalizeAreaKey("sys"));
        Assert.Equal("OTHER", AnalysisState.NormalizeAreaKey("CUSTOM"));
        var s = new AnalysisState();
        s.ProcessLine(L("M", "2026.09.04 10:00:00.000", "CUSTOM", "ERROR", "x"));
        Assert.Equal(1, s.AreaCounts["OTHER"]);
        Assert.Equal(1, s.AreaOtherNames["CUSTOM"]);
    }
}
