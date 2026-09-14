using System.Diagnostics;

namespace DesigoLogWatcher;

/// <summary>Open dashboard URL with watch-config Browser choice (PS Open-WatchBrowser).</summary>
public static class BrowserLauncher
{
    public static void Open(string url, string choice)
    {
        choice = string.IsNullOrWhiteSpace(choice) ? "default" : choice.Trim();
        var candidates = ResolveCandidates(choice);
        foreach (var exe in candidates)
        {
            if (!File.Exists(exe)) continue;
            try
            {
                Process.Start(new ProcessStartInfo(exe, url) { UseShellExecute = false });
                return;
            }
            catch
            {
                /* try next / fall through */
            }
        }

        try
        {
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
        }
        catch
        {
            /* ignore browser failures */
        }
    }

    public static List<string> ResolveCandidates(string choice)
    {
        var low = choice.ToLowerInvariant();
        var pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var pf86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        var chrome = new[]
        {
            Path.Combine(pf, "Google", "Chrome", "Application", "chrome.exe"),
            Path.Combine(pf86, "Google", "Chrome", "Application", "chrome.exe")
        };
        var edge = new[]
        {
            Path.Combine(pf86, "Microsoft", "Edge", "Application", "msedge.exe"),
            Path.Combine(pf, "Microsoft", "Edge", "Application", "msedge.exe")
        };

        if (low is "chrome") return chrome.ToList();
        if (low is "msedge" or "edge") return edge.ToList();
        if (low is "default") return [];
        if (File.Exists(choice)) return [choice];
        return [];
    }
}
