using DesigoLogWatcher;

namespace DesigoLogWatcher.Tests;

public class WindowAndManagerFilterTests
{
    [Fact]
    public void ResolveLastNCutoff_AnchorsToFileEndNotWallClock()
    {
        var dir = Path.Combine(Path.GetTempPath(), "dlw-win-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, "PVSS_II.log");
        try
        {
            // Old log ending ~1 day ago — wall-clock "last 60m" would be empty.
            File.WriteAllLines(path,
            [
                "WCCOAui, 2026.01.01 10:00:00.000, SYS, INFO, early",
                "WCCOAui, 2026.01.01 12:00:00.000, SYS, ERROR, mid",
                "WCCOAui, 2026.01.01 12:30:00.000, SYS, ERROR, late"
            ]);
            var end = LogParser.GetLogFileEndTimestamp(path);
            Assert.NotNull(end);
            Assert.Equal(new DateTime(2026, 1, 1, 12, 30, 0), end!.Value);

            var (cutoff, anchor, usedWall) = LogParser.ResolveLastNCutoff(path, 60);
            Assert.False(usedWall);
            Assert.Equal(end, anchor);
            Assert.Equal(new DateTime(2026, 1, 1, 11, 30, 0), cutoff);

            var startPos = LogParser.FindWindowStartPosition(path, cutoff);
            Assert.True(startPos >= 0);

            // Empty window when cutoff is after EOF
            var ex = Assert.Throws<InvalidOperationException>(() =>
                LogParser.FindWindowStartPosition(path, new DateTime(2026, 1, 2, 0, 0, 0)));
            Assert.Contains("Empty window", ex.Message);
        }
        finally
        {
            try { Directory.Delete(dir, true); } catch { /* ignore */ }
        }
    }

    [Fact]
    public void ManagerPatterns_HonorAreaFilter()
    {
        var engine = new RuleEngine();
        var state = new AnalysisState();
        state.ProcessLine("MgrX, 2026.09.04 10:00:00.000, SYS, ERROR, boom timeout sys", rules: engine);
        state.ProcessLine("MgrX, 2026.09.04 10:00:01.000, SYS, ERROR, boom timeout sys", rules: engine);
        state.ProcessLine("MgrX, 2026.09.04 10:00:02.000, CTRL, ERROR, boom timeout ctrl", rules: engine);

        var all = ApiBuilders.BuildManagerPayload(state, "MgrX",
            ChartSeriesBuilder.DefaultSevFilter(), 10, 1, ChartSeriesBuilder.AllAreaOn());
        var sysOnly = ApiBuilders.BuildManagerPayload(state, "MgrX",
            ChartSeriesBuilder.DefaultSevFilter(), 10, 1, ChartSeriesBuilder.AreaFilterFromList(["SYS"]));

        var allErr = (object[])((Dictionary<string, object?>)all["patternsBySeverity"]!)["ERROR"]!;
        var sysErr = (object[])((Dictionary<string, object?>)sysOnly["patternsBySeverity"]!)["ERROR"]!;
        Assert.True(allErr.Length >= 1);
        Assert.True(sysErr.Length >= 1);
        var allCount = allErr.Cast<Dictionary<string, object?>>().Sum(r => Convert.ToInt32(r["count"]));
        var sysCount = sysErr.Cast<Dictionary<string, object?>>().Sum(r => Convert.ToInt32(r["count"]));
        Assert.True(allCount >= 3);
        Assert.Equal(2, sysCount);
        Assert.Equal(2, Convert.ToInt32(sysOnly["count"]));
        Assert.Equal(3, Convert.ToInt32(all["count"]));
    }

    [Fact]
    public void ResolveWindow_ReportDefaultsToEntire()
    {
        var o = new Cli().Parse([]);
        var dash = Cli.ResolveWindow(o, defaultEntire: false);
        Assert.False(dash.EntireLog);
        Assert.Equal(60, dash.LastMinutes);

        var report = Cli.ResolveWindow(o, defaultEntire: true);
        Assert.True(report.EntireLog);
    }

    [Fact]
    public void BacnetSvg_DrawsFailedAfterOk()
    {
        var pts = new List<Dictionary<string, object?>>
        {
            new()
            {
                ["t"] = "2026.09.04 10:00", ["bacFailed"] = 5, ["bacOk"] = 3,
                ["FATAL"] = 0, ["SEVERE"] = 0, ["ERROR"] = 0, ["WARNING"] = 0, ["INFO"] = 0,
                ["projectRestart"] = 0
            }
        };
        var svg = ChartSeriesBuilder.BuildBacnetSvg(pts);
        var okIdx = svg.IndexOf("stroke=\"#008000\"", StringComparison.Ordinal);
        var failIdx = svg.IndexOf("stroke=\"#c000a0\"", StringComparison.Ordinal);
        Assert.True(okIdx >= 0 && failIdx > okIdx, "Failed polyline should be drawn after OK (on top)");
    }

    [Fact]
    public void HtmlReport_RendersManagerSeverityColumns()
    {
        var engine = new RuleEngine();
        var state = new AnalysisState();
        state.ProcessLine("WCCOAui, 2026.09.04 10:00:00.000, SYS, ERROR, boom", rules: engine);
        state.ProcessLine("WCCOAui, 2026.09.04 10:00:01.000, SYS, SEVERE, bad", rules: engine);
        var snap = new SnapshotBuilder(state, engine).BuildSnapshot("t.log", 10, "0.5.0-test");
        var html = new ReportWriter().ToHtml(snap);
        // ERROR and SEVERE columns for WCCOAui should not all be zero
        Assert.Contains("WCCOAui", html);
        Assert.DoesNotContain("<td>0</td><td>0</td><td>0</td><td>0</td><td>0</td><td class=\"mono\">WCCOAui</td>", html);
    }
}
