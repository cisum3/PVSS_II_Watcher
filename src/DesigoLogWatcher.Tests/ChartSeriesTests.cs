using DesigoLogWatcher;

namespace DesigoLogWatcher.Tests;

public class ChartSeriesTests
{
    [Fact]
    public void Build_ProducesNonEmptySeries_FromByMinute()
    {
        var state = new AnalysisState();
        state.ProcessLine("WCCOAui, 2026.09.04 10:00:00.000, SYS, ERROR, boom");
        state.ProcessLine("WCCOAui, 2026.09.04 10:00:30.000, SYS, ERROR, boom");
        state.ProcessLine("WCCOABACnet, 2026.09.04 10:01:00.000, SYS, INFO, Device 12 Status is now Failed");
        state.ProcessLine("pmon, 2026.09.04 10:01:05.000, SYS, INFO, The project is up and running");

        var series = ChartSeriesBuilder.Build(state);
        Assert.Equal("minute", series["granularity"]);
        var rows = (object[])series["byMinute"]!;
        Assert.True(rows.Length >= 2);

        var first = (Dictionary<string, object?>)rows[0];
        Assert.True(ChartSeriesBuilder.Int(first, "ERROR") >= 1 ||
                    rows.Cast<Dictionary<string, object?>>().Any(r => ChartSeriesBuilder.Int(r, "ERROR") >= 1));
        Assert.Contains(rows.Cast<Dictionary<string, object?>>(),
            r => ChartSeriesBuilder.Int(r, "bacFailed") >= 1);
        Assert.Contains(rows.Cast<Dictionary<string, object?>>(),
            r => ChartSeriesBuilder.Int(r, "projectRestart") >= 1);
    }

    [Fact]
    public void ReduceSeriesPoints_CapsLength_PreservingPeaks()
    {
        var points = Enumerable.Range(0, 200)
            .Select(i => new Dictionary<string, object?>
            {
                ["t"] = $"2026.09.04 10:{i % 60:D2}",
                ["FATAL"] = 0, ["SEVERE"] = 0, ["ERROR"] = i == 50 ? 99 : 1,
                ["WARNING"] = 0, ["INFO"] = 0,
                ["bacFailed"] = i == 80 ? 40 : 0, ["bacOk"] = 0, ["projectRestart"] = 0
            }).ToList();

        var reduced = ChartSeriesBuilder.ReduceSeriesPoints(points, 40);
        Assert.True(reduced.Count <= 40);
        Assert.Contains(reduced, r => ChartSeriesBuilder.Int(r, "ERROR") == 99);
    }

    [Fact]
    public void HtmlReport_IncludesSvgCharts()
    {
        var state = new AnalysisState();
        for (var i = 0; i < 5; i++)
            state.ProcessLine($"WCCOAui, 2026.09.04 10:0{i}:00.000, SYS, ERROR, boom {i}");
        state.ProcessLine("WCCOAbac, 2026.09.04 10:02:00.000, SYS, INFO, Device 1 Status is now Failed");

        var snap = new SnapshotBuilder(state).BuildSnapshot("test.log", 1000, "0.5.0-test");
        var html = new ReportWriter().ToHtml(snap);
        Assert.Contains("Activity charts", html);
        Assert.Contains("chart-svg", html);
        Assert.Contains("siemens-petrol", html);
        Assert.Contains("--siemens-petrol", html);
    }
}
