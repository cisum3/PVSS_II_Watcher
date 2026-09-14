using DesigoLogWatcher;

namespace DesigoLogWatcher.Tests;

public class SnapshotReportTests
{
    [Fact]
    public void BuildFindings_AndTextReport_EndToEnd()
    {
        var path = Path.Combine(Path.GetTempPath(), "dlw-snap-" + Guid.NewGuid().ToString("N") + ".log");
        File.WriteAllLines(path,
        [
            "WCCOAui, 2026.09.04 10:00:00.000, SYS, ERROR, boom timeout",
            "WCCOAui, 2026.09.04 10:00:01.000, SYS, ERROR, boom timeout",
            "WCCOAui, 2026.09.04 10:00:02.000, SYS, ERROR, boom timeout",
            "WCCOAui, 2026.09.04 10:00:03.000, SYS, ERROR, boom timeout",
            "WCCOAui, 2026.09.04 10:00:04.000, SYS, ERROR, boom timeout",
            "pmon, 2026.09.04 10:00:05.000, SYS, INFO, The project is up and running",
            "Mgr, 2026.09.04 10:00:06.000, SYS, WARNING, Unexpected state, DrvManager, gotAlertConfigAnswer,",
            "Mgr, 2026.09.04 10:00:07.000, SYS, WARNING, Repetition (#=12) of a former trace"
        ]);
        try
        {
            var engine = new RuleEngine();
            var state = new AnalysisState();
            foreach (var line in File.ReadLines(path))
                state.ProcessLine(line, rules: engine);

            var builder = new SnapshotBuilder(state, engine);
            var findings = builder.BuildFindings();
            Assert.Contains(findings, f => f.Contains("Project lifecycle") || f.Contains("Timeout"));

            var snap = builder.BuildSnapshot(path, new FileInfo(path).Length, "0.5.0-test");
            var writer = new ReportWriter();
            var text = writer.ToText(snap);
            Assert.Contains("PVSS / WinCC OA Log Analysis Report", text);
            Assert.Contains("Severity counts", text);
            Assert.Contains("Project restarts (pmon)", text);
            Assert.Contains("Manager health (pmon)", text);
            Assert.Contains("Top patterns by severity", text);
            Assert.Contains("--- Notes ---", text);
            Assert.Contains("ERROR", text);

            var json = writer.ToJson(snap);
            Assert.Contains("\"findings\"", json);
            Assert.Contains("\"severityCounts\"", json);
            Assert.Contains("\"bacnet\"", json);
            Assert.Contains("\"detections\"", json);
            Assert.Contains("\"patternsBySeverity\"", json);
            Assert.Contains("\"projectLifecycle\"", json);
            using (var doc = System.Text.Json.JsonDocument.Parse(json))
            {
                Assert.True(doc.RootElement.TryGetProperty("meta", out _));
                Assert.True(doc.RootElement.TryGetProperty("options", out var opt));
                Assert.Equal("all", opt.GetProperty("format").GetString());
            }

            var html = writer.ToHtml(snap);
            Assert.Contains("<!DOCTYPE html>", html);
            Assert.Contains("Activity charts", html);
            Assert.Contains("siemens-petrol", html);

            var (txt, htm, js) = writer.WriteFiles(snap, path, null, ReportFormat.All);
            Assert.True(File.Exists(txt));
            Assert.True(File.Exists(htm));
            Assert.True(File.Exists(js));
            File.Delete(txt!);
            File.Delete(htm!);
            File.Delete(js!);
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void JsonSnapshot_HasExpectedTopLevelKeysAndFormat()
    {
        var engine = new RuleEngine();
        var state = new AnalysisState();
        state.ProcessLine("WCCOAui, 2026.09.04 10:00:00.000, SYS, ERROR, boom timeout", rules: engine);
        var snap = new SnapshotBuilder(state, engine).BuildSnapshot("t.log", 10, "0.5.0-test", format: ReportFormat.Json);
        var json = new ReportWriter().ToJson(snap);
        using var doc = System.Text.Json.JsonDocument.Parse(json);
        var root = doc.RootElement;
        foreach (var key in new[]
                 {
                     "meta", "options", "window", "findings", "severityCounts", "areaCounts",
                     "series", "hourly", "topManagers", "managers", "patternsBySeverity",
                     "moduleHeadlines", "projectLifecycle", "managerHealth",
                     "bacnet", "cns", "coho", "apogee", "detections", "perf", "driverDeepDive"
                 })
            Assert.True(root.TryGetProperty(key, out _), $"missing JSON key: {key}");
        Assert.Equal("json", root.GetProperty("options").GetProperty("format").GetString());
        Assert.True(root.GetProperty("options").TryGetProperty("bacFlapMin", out _));
    }

    [Fact]
    public void HtmlReport_ApogeeIncludesPpclTable()
    {
        var engine = new RuleEngine();
        var state = new AnalysisState();
        for (var i = 0; i < 2; i++)
        {
            state.ProcessLine(
                $"WCCOAGmsCoHoMngr(100), 2026.08.28 11:05:2{i}.356, IMPL, SEVERE, 0, , GMSe,CoHo.ApogeeBACnet,,11:05:2{i}.356,^2:Function UpdatePoints: Panel instance number is:9219 PPCL Program Name: SW.B.AHUS1.RSTSystem.IndexOutOfRangeException: Index was outside the bounds of the array.",
                rules: engine);
        }

        var snap = new SnapshotBuilder(state, engine).BuildSnapshot("t.log", 10, "0.5.0-test", format: ReportFormat.Html);
        var html = new ReportWriter().ToHtml(snap);
        Assert.Contains("id=\"apogee\"", html);
        Assert.Contains("Top PPCL programs by UpdatePoints", html);
        Assert.Contains("<th>PPCL</th>", html);
        Assert.Contains("SW.B.AHUS1.RST", html);
    }
}
