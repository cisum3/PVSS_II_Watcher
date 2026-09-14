using DesigoLogWatcher;

namespace DesigoLogWatcher.Tests;

public class BrowserLauncherTests
{
    [Fact]
    public void ResolveCandidates_DefaultIsEmpty()
    {
        Assert.Empty(BrowserLauncher.ResolveCandidates("default"));
        Assert.Empty(BrowserLauncher.ResolveCandidates(""));
    }

    [Fact]
    public void ResolveCandidates_ChromeAndEdgeReturnKnownPaths()
    {
        var chrome = BrowserLauncher.ResolveCandidates("chrome");
        Assert.Contains(chrome, p => p.EndsWith("chrome.exe", StringComparison.OrdinalIgnoreCase));
        var edge = BrowserLauncher.ResolveCandidates("msedge");
        Assert.Contains(edge, p => p.EndsWith("msedge.exe", StringComparison.OrdinalIgnoreCase));
        Assert.Equal(edge, BrowserLauncher.ResolveCandidates("edge"));
    }

    [Fact]
    public void ResolveCandidates_ExplicitMissingPathIsEmpty()
    {
        Assert.Empty(BrowserLauncher.ResolveCandidates(@"C:\definitely\missing\browser.exe"));
    }
}
