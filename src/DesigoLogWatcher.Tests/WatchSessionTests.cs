using System.Collections.Specialized;
using DesigoLogWatcher;

namespace DesigoLogWatcher.Tests;

public class WatchSessionTests
{
    [Fact]
    public void CatchUp_ExposesProgress_ThenTailsNewLines()
    {
        var dir = Path.Combine(Path.GetTempPath(), "dlw-tail-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        var log = Path.Combine(dir, "PVSS_II.log");
        var cfgPath = Path.Combine(dir, "watch-config.txt");
        File.WriteAllText(cfgPath, "PreferredPort=18790\nRefreshSeconds=1\nDefaultWindowEntire=true\n");
        File.WriteAllLines(log,
        [
            "WCCOAui, 2026.09.04 10:00:00.000, SYS, ERROR, line-a",
            "WCCOAui, 2026.09.04 10:00:01.000, SYS, ERROR, line-b"
        ]);

        try
        {
            var config = new Config(cfgPath, _ => { });
            config.Mode = WatchRunMode.Dashboard;
            config.Load();
            using var session = new WatchSession(config);
            session.WindowEntire = true;
            session.RunCatchUpUnlocked(log);

            Assert.False(session.Loading);
            Assert.True(session.TailRunning);
            Assert.Equal(100, session.LoadProgressPct);
            Assert.True(session.Data.ParsedLines >= 2);

            var pulse = (Dictionary<string, object?>)session.BuildPulse(new NameValueCollection());
            Assert.False((bool)pulse["loading"]!);
            Assert.True((bool)pulse["tailRunning"]!);
            var series = (Dictionary<string, object?>)pulse["series"]!;
            Assert.NotEmpty((Array)series["byMinute"]!);

            File.AppendAllText(log, "WCCOAui, 2026.09.04 10:00:02.000, SYS, WARNING, line-c\n");
            var deadline = DateTime.UtcNow.AddSeconds(5);
            while (DateTime.UtcNow < deadline && session.Data.ParsedLines < 3)
                Thread.Sleep(30);

            Assert.True(session.Data.ParsedLines >= 3);
            Assert.True(session.Data.Severity.GetValueOrDefault("WARNING") >= 1);
        }
        finally
        {
            try { Directory.Delete(dir, true); } catch { /* ignore */ }
        }
    }
}
