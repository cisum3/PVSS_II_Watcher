using DesigoLogWatcher;

namespace DesigoLogWatcher.Tests;

public class ConfigTests
{
    private static string TempConfig(string contents)
    {
        var path = Path.Combine(Path.GetTempPath(), "dlw-cfg-" + Guid.NewGuid().ToString("N") + ".txt");
        File.WriteAllText(path, contents);
        return path;
    }

    [Fact]
    public void ParseRawLines_IgnoresCommentsBlanksAndMalformed()
    {
        var warnings = new List<string>();
        var map = Config.ParseRawLines(
        [
            "# comment",
            "",
            "  # spaced comment",
            "PreferredPort=9000",
            "noequals",
            "=novaluekey",
            "UnknownKey=1",
            "RefreshSeconds=5",
            "LogPath=C:\\a=b\\log.log"
        ], warnings);

        Assert.Equal("9000", map["PreferredPort"]);
        Assert.Equal("5", map["RefreshSeconds"]);
        Assert.Equal(@"C:\a=b\log.log", map["LogPath"]);
        Assert.Contains(warnings, w => w.Contains("malformed", StringComparison.OrdinalIgnoreCase));
        Assert.Contains(warnings, w => w.Contains("Unknown config key", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void Load_ValidFile_ReadsAllKeys()
    {
        var path = TempConfig("""
            PreferredPort=9001
            MaxPortTries=10
            RefreshSeconds=7
            OpenBrowser=false
            Browser=chrome
            DefaultWindowMinutes=120
            DefaultWindowEntire=true
            DefaultSeverities=FATAL,ERROR
            DefaultAreas=SYS,CTRL
            TopN=20
            SamplePerPattern=5
            SampleMaxChars=200
            BacFlapMin=4
            LogPath=D:\logs\PVSS_II.log
            """);
        try
        {
            var cfg = new Config(path);
            var result = cfg.Load(writeCorrections: false);
            Assert.Equal(9001, result.Config.PreferredPort);
            Assert.Equal(10, result.Config.MaxPortTries);
            Assert.Equal(7, result.Config.RefreshSeconds);
            Assert.False(result.Config.OpenBrowser);
            Assert.Equal("chrome", result.Config.Browser);
            Assert.Equal(120, result.Config.DefaultWindowMinutes);
            Assert.True(result.Config.DefaultWindowEntire);
            Assert.Equal(["FATAL", "ERROR"], result.Config.DefaultSeverities);
            Assert.Equal(["SYS", "CTRL"], result.Config.DefaultAreas);
            Assert.Equal(20, result.Config.TopN);
            Assert.Equal(5, result.Config.SamplePerPattern);
            Assert.Equal(200, result.Config.SampleMaxChars);
            Assert.Equal(4, result.Config.BacFlapMin);
            Assert.Equal(@"D:\logs\PVSS_II.log", result.Config.LogPath);
            Assert.Empty(result.Corrections);
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void Load_InvalidValues_SelfCorrectsPreservingComments()
    {
        var path = TempConfig("""
            # keep me
            PreferredPort=99999
            OpenBrowser=maybe
            RefreshSeconds=3
            """);
        try
        {
            var warnings = new List<string>();
            var cfg = new Config(path, warnings.Add);
            var result = cfg.Load(writeCorrections: true);
            Assert.Equal(8787, result.Config.PreferredPort);
            Assert.True(result.Config.OpenBrowser);
            Assert.Equal(3, result.Config.RefreshSeconds);
            Assert.True(result.Corrections.ContainsKey("PreferredPort"));
            Assert.True(result.Corrections.ContainsKey("OpenBrowser"));

            var text = File.ReadAllText(path);
            Assert.Contains("# keep me", text);
            Assert.Contains("PreferredPort=8787", text);
            Assert.Contains("OpenBrowser=true", text);
            Assert.Contains("RefreshSeconds=3", text);
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void CliOverrides_BeatFile_AndDoNotRewriteFile()
    {
        var path = TempConfig("""
            PreferredPort=8787
            RefreshSeconds=5
            OpenBrowser=true
            """);
        try
        {
            var cfg = new Config(path);
            var result = cfg.Load(new CliConfigOverrides
            {
                Port = 9999,
                NoBrowser = true
            }, writeCorrections: true);

            Assert.Equal(9999, result.Config.PreferredPort);
            Assert.Equal(5, result.Config.RefreshSeconds);
            Assert.False(result.Config.OpenBrowser);

            var text = File.ReadAllText(path);
            Assert.Contains("PreferredPort=8787", text);
            Assert.Contains("OpenBrowser=true", text);
            Assert.DoesNotContain("9999", text);
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void WriteLogPath_DashboardOnly()
    {
        var path = TempConfig("LogPath=\r\nRefreshSeconds=3\r\n");
        try
        {
            var cfg = new Config(path) { Mode = WatchRunMode.Report };
            cfg.Load(writeCorrections: false);
            cfg.WriteLogPath(@"C:\report\log.log");
            Assert.DoesNotContain(@"C:\report\log.log", File.ReadAllText(path));

            cfg.Mode = WatchRunMode.Dashboard;
            cfg.WriteLogPath(@"C:\dash\log.log");
            Assert.Contains(@"C:\dash\log.log", File.ReadAllText(path));
            Assert.Contains("RefreshSeconds=3", File.ReadAllText(path));
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void ReloadRuntime_PicksUpFileEdits_SkipsPortChange()
    {
        var path = TempConfig("""
            PreferredPort=8787
            RefreshSeconds=3
            DefaultWindowMinutes=60
            """);
        try
        {
            var cfg = new Config(path) { BoundPort = 8787 };
            cfg.Load(writeCorrections: false);

            File.WriteAllText(path, """
                PreferredPort=9000
                RefreshSeconds=9
                DefaultWindowMinutes=30
                """);

            var reload = cfg.ReloadRuntime();
            Assert.Equal(9, reload.Config.RefreshSeconds);
            Assert.Equal(30, reload.Config.DefaultWindowMinutes);
            Assert.Equal(9000, reload.Config.PreferredPort);
            Assert.Contains(reload.RuntimeSkipped, s => s.Contains("PreferredPort", StringComparison.Ordinal));
            Assert.Contains(reload.RuntimeChanges, c => c.StartsWith("RefreshSeconds", StringComparison.Ordinal));
        }
        finally { File.Delete(path); }
    }

    [Theory]
    [InlineData("true", true)]
    [InlineData("yes", true)]
    [InlineData("1", true)]
    [InlineData("on", true)]
    [InlineData("false", false)]
    [InlineData("no", false)]
    [InlineData("0", false)]
    [InlineData("off", false)]
    public void ConfigBool_ParsesKnownTokens(string text, bool expected)
    {
        Assert.Equal(expected, Config.TryParseConfigBool(text));
    }
}
