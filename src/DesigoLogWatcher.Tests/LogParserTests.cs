using DesigoLogWatcher;

namespace DesigoLogWatcher.Tests;

public class LogParserTests
{
    private static string TempLog(string contents)
    {
        var path = Path.Combine(Path.GetTempPath(), "dlw-log-" + Guid.NewGuid().ToString("N") + ".log");
        File.WriteAllText(path, contents);
        return path;
    }

    [Fact]
    public void Open_UsesReadShare_AndReadsLines()
    {
        var path = TempLog("WCCOAui, 2026.09.04 10:00:00.000, SYS, INFO, hello\nWCCOAui, 2026.09.04 10:00:01.000, SYS, ERROR, boom\n");
        try
        {
            // Concurrent writer share: open a second writer while reader is active.
            using var writer = new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.ReadWrite);
            using var parser = new LogParser();
            parser.Open(path);
            var lines = parser.ReadAvailableLines().ToList();
            Assert.Equal(2, lines.Count);
            Assert.True(LogParser.TryParseHeader(lines[1], out var h));
            Assert.Equal("ERROR", h.Severity);
            Assert.Equal("WCCOAui", h.Component);
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void TryParseHeader_NormalizesWarn()
    {
        Assert.True(LogParser.TryParseHeader(
            "Mgr, 2026.09.04 10:00:00.123, IMPL, WARN, x", out var h));
        Assert.Equal("WARNING", h.Severity);
        Assert.Equal("IMPL", h.AreaRaw);
    }

    [Fact]
    public void ResolveLogPath_PrefersExactThenBak()
    {
        var root = Path.Combine(Path.GetTempPath(), "dlw-disc-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var bak = Path.Combine(root, "PVSS_II.log.bak");
            File.WriteAllText(bak, "x");
            var found = LogParser.ResolveLogPath(null, root, root);
            Assert.Equal(Path.GetFullPath(bak), found);

            var primary = Path.Combine(root, "PVSS_II.log");
            File.WriteAllText(primary, "y");
            found = LogParser.ResolveLogPath(null, root, root);
            Assert.Equal(Path.GetFullPath(primary), found);
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public void CutoffCompare_Lexicographic()
    {
        Assert.True(LogParser.IsBeforeCutoff("2026.09.04 09:00:00.000", "2026.09.04 10:00:00"));
        Assert.False(LogParser.IsBeforeCutoff("2026.09.04 11:00:00.000", "2026.09.04 10:00:00"));
        Assert.True(LogParser.IsAfterUpper("2026.09.04 11:00:00.000", "2026.09.04 10:00:00"));
    }

    [Fact]
    public void Truncation_ReseeksToStart()
    {
        var path = TempLog("WCCOAui, 2026.09.04 10:00:00.000, SYS, INFO, a\nWCCOAui, 2026.09.04 10:00:01.000, SYS, INFO, b\n");
        try
        {
            using var parser = new LogParser();
            parser.Open(path);
            _ = parser.ReadAvailableLines().ToList();
            Assert.True(parser.FilePos > 0);

            File.WriteAllText(path, "WCCOAui, 2026.09.04 12:00:00.000, SYS, INFO, rotated\n");
            Assert.True(parser.DetectTruncationAndReseek());
            var lines = parser.ReadAvailableLines().ToList();
            Assert.Single(lines);
            Assert.Contains("rotated", lines[0]);
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void CatchUpProgress_ReportsPercent()
    {
        var path = TempLog(string.Join('\n', Enumerable.Range(0, 100).Select(i =>
            $"WCCOAui, 2026.09.04 10:00:{i % 60:D2}.000, SYS, INFO, line{i}")));
        try
        {
            using var parser = new LogParser();
            parser.Open(path);
            var progress = parser.BeginCatchUp(0);
            foreach (var _ in parser.ReadAvailableLines())
            {
                progress.Lines++;
                progress.CurrentPos = parser.FilePos;
            }
            Assert.True(progress.Percent >= 99);
            Assert.Equal(100, progress.Lines);
        }
        finally { File.Delete(path); }
    }
}
