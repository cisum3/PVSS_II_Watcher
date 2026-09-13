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
            Assert.Contains("ERROR", text);

            var html = writer.ToHtml(snap);
            Assert.Contains("<!DOCTYPE html>", html);
            Assert.Contains("Activity charts", html);
            Assert.Contains("siemens-petrol", html);

            var (txt, htm) = writer.WriteFiles(snap, path, null, ReportFormat.Both);
            Assert.True(File.Exists(txt));
            Assert.True(File.Exists(htm));
            File.Delete(txt!);
            File.Delete(htm!);
        }
        finally { File.Delete(path); }
    }
}
