using DesigoLogWatcher;

namespace DesigoLogWatcher.Tests;

public class CliTests
{
    private readonly Cli _cli = new();

    [Fact]
    public void Parse_ReportAndCommonSwitches()
    {
        var o = _cli.Parse(["-Report", "-LogPath", @"C:\a\log.log", "-Format", "Html", "-Organize", "Severity", "-TopN", "25", "-NoPause"]);
        Assert.True(o.Report);
        Assert.Equal(@"C:\a\log.log", o.LogPath);
        Assert.Equal(ReportFormat.Html, o.Format);
        Assert.Equal(OrganizeMode.Severity, o.Organize);
        Assert.Equal(25, o.TopN);
        Assert.True(o.NoPause);
        Assert.True(o.WasBound(nameof(CliOptions.Report)));
        Assert.True(o.WasBound(nameof(CliOptions.LogPath)));
    }

    [Fact]
    public void Parse_SamplePerPattern_CliAllowsZero()
    {
        var o = _cli.Parse(["-SamplePerPattern", "0"]);
        Assert.Equal(0, o.SamplePerPattern);
    }

    [Fact]
    public void ResolveWindow_RelativeBeatsAbsolute()
    {
        var o = _cli.Parse(["-LastHours", "6", "-From", "2026.01.01", "-To", "2026.01.02"]);
        o.Bound.Add(nameof(CliOptions.From));
        o.Bound.Add(nameof(CliOptions.To));
        var w = Cli.ResolveWindow(o, new DateTime(2026, 9, 12, 12, 0, 0));
        Assert.Equal(6, w.LastHours);
        Assert.NotNull(w.Start);
        Assert.Null(w.EntireLog ? true : null);
        Assert.False(w.EntireLog);
    }

    [Fact]
    public void ResolveWindow_Entire()
    {
        var o = _cli.Parse(["-Entire", "-From", "2026.01.01"]);
        var w = Cli.ResolveWindow(o);
        Assert.True(w.EntireLog);
    }

    [Fact]
    public void ConvertWindowBound_DateOnlyTo_IsEndOfDay()
    {
        var dt = Cli.ConvertWindowBound("2026.09.04", isTo: true);
        Assert.Equal(new DateTime(2026, 9, 4, 23, 59, 59, 999), dt);
    }

    [Theory]
    [InlineData("1", new[] { 1 })]
    [InlineData("1,3,5", new[] { 1, 3, 5 })]
    [InlineData("1-3", new[] { 1, 2, 3 })]
    [InlineData("1-3,10", new[] { 1, 2, 3, 10 })]
    [InlineData("5-5", new[] { 5 })]
    [InlineData("1-3,2-4", new[] { 1, 2, 3, 4 })]
    public void ParseManagerRange_Expands(string text, int[] expected)
    {
        Assert.Equal(expected, Cli.ParseManagerRange(text, 10));
    }

    [Theory]
    [InlineData("10-1")]
    [InlineData("abc")]
    [InlineData("999")]
    public void ParseManagerRange_RejectsInvalid(string text)
    {
        Assert.Throws<ArgumentException>(() => Cli.ParseManagerRange(text, 10));
    }

    [Fact]
    public void PromptDefault_EmptyUsesDefault()
    {
        using var input = new StringReader("\n");
        using var output = new StringWriter();
        var v = Cli.PromptDefault("Q?", "def", input, output);
        Assert.Equal("def", v);
    }

    [Fact]
    public void ToConfigOverrides_OnlyBound()
    {
        var o = _cli.Parse(["-Port", "9999"]);
        var ov = o.ToConfigOverrides();
        Assert.Equal(9999, ov.Port);
        Assert.Null(ov.RefreshSeconds);
    }
}
