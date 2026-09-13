namespace DesigoLogWatcher;

/// <summary>
/// Entry: CLI parse → config load → dashboard vs report branch.
/// Publish: dotnet publish src\DesigoLogWatcher\DesigoLogWatcher.csproj -c Release -o Watch\
/// </summary>
public static class Program
{
    public const string Version = "0.5.0-dev";

    public static int Main(string[] args)
    {
        try
        {
            var cli = new Cli();
            var options = cli.Parse(args);
            if (options.Help)
            {
                Console.WriteLine(Cli.HelpText);
                return 0;
            }

            var watchRoot = ResolveWatchRoot();
            var configPath = Path.Combine(watchRoot, "watch-config.txt");
            var config = new Config(configPath, msg => Console.WriteLine($"Config: {msg}"));
            config.Mode = options.Report ? WatchRunMode.Report : WatchRunMode.Dashboard;
            var load = config.Load(options.ToConfigOverrides());
            foreach (var w in load.Warnings)
                Console.WriteLine($"Config: {w}");

            if (options.Report)
                return RunReportMode(config, options, watchRoot);
            return RunDashboardMode(config, options, watchRoot);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"DesigoLogWatcher failed: {ex.Message}");
            return 1;
        }
    }

    internal static int RunReportMode(Config config, CliOptions options, string watchRoot)
    {
        Console.WriteLine($"DesigoLogWatcher {Version} — report mode");
        var log = LogParser.ResolveLogPath(
            options.WasBound(nameof(CliOptions.LogPath)) ? options.LogPath : config.Effective.LogPath,
            watchRoot);
        var fi = new FileInfo(log);
        Console.WriteLine($"Log : {log}");
        Console.WriteLine($"Size: {fi.Length / (1024.0 * 1024.0):N2} MB");

        var logEnd = LogParser.GetLogFileEndTimestamp(log);
        var window = Cli.ResolveWindow(options, logEnd, defaultEntire: true);
        var engine = new RuleEngine();
        var state = new AnalysisState();
        var sw = System.Diagnostics.Stopwatch.StartNew();

        using (var parser = new LogParser())
        {
            parser.Open(log);
            string? cutoff = null;
            string? upper = null;
            if (!window.EntireLog)
            {
                // Relative windows win and must anchor to log EOF (not wall clock).
                if (window.LastMinutes is int lm)
                {
                    var (cutDt, anchor, usedWall) = LogParser.ResolveLastNCutoff(log, lm);
                    cutoff = LogParser.ToCompareStamp(cutDt);
                    Console.WriteLine(usedWall
                        ? $"Window: wall-clock cutoff {cutDt:yyyy.MM.dd HH:mm:ss} (no EOF timestamp)"
                        : $"Window: last {lm} minutes from file end {anchor:yyyy.MM.dd HH:mm:ss} (cutoff {cutDt:yyyy.MM.dd HH:mm:ss})");
                }
                else if (window.LastHours is int lh)
                {
                    var endTs = LogParser.GetLogFileEndTimestamp(log) ?? DateTime.Now;
                    var cutDt = endTs.AddHours(-lh);
                    cutoff = LogParser.ToCompareStamp(cutDt);
                    upper = LogParser.ToCompareStamp(endTs);
                    Console.WriteLine($"Window: last {lh} hours from file end {endTs:yyyy.MM.dd HH:mm:ss}");
                }
                else
                {
                    if (window.Start is DateTime start)
                        cutoff = LogParser.ToCompareStamp(start);
                    if (window.End is DateTime end)
                        upper = LogParser.ToCompareStamp(end);
                }
            }

            long startPos = 0;
            if (cutoff is not null && ChartSeriesBuilder.TryParseLogTs(cutoff) is DateTime cutParsed)
            {
                try { startPos = LogParser.FindWindowStartPosition(log, cutParsed); }
                catch (Exception ex)
                {
                    Console.WriteLine(ex.Message);
                    return 2;
                }
            }
            parser.BeginCatchUp(startPos);

            foreach (var line in parser.ReadAvailableLines())
            {
                state.ProcessLine(
                    line,
                    samplePerPattern: config.Effective.SamplePerPattern,
                    sampleMaxChars: config.Effective.SampleMaxChars,
                    enforceCutoff: cutoff is not null,
                    cutoffCompare: cutoff,
                    upperCompare: upper,
                    rules: engine);
            }
        }

        sw.Stop();
        Console.WriteLine($"Parsed {state.ParsedLines:N0} lines ({state.UnparsedLines:N0} unparsed) in {sw.Elapsed.TotalSeconds:N1}s.");

        var builder = new SnapshotBuilder(state, engine, config.Effective.TopN, config.Effective.BacFlapMin);
        var snap = builder.BuildSnapshot(
            log, fi.Length, Version,
            options.Organize, options.Format,
            windowEntire: window.EntireLog,
            lastMinutes: window.LastMinutes ?? config.Effective.DefaultWindowMinutes);

        var writer = new ReportWriter();
        var (textPath, htmlPath) = writer.WriteFiles(snap, log, options.OutPath, options.Format);
        if (textPath is not null) Console.WriteLine($"Wrote {textPath}");
        if (htmlPath is not null) Console.WriteLine($"Wrote {htmlPath}");

        if (!options.NoPause)
        {
            Console.WriteLine("Press Enter to close.");
            Console.ReadLine();
        }
        return 0;
    }

    internal static int RunDashboardMode(Config config, CliOptions options, string watchRoot)
    {
        var uiRoot = Path.Combine(watchRoot, "ui");
        if (!Directory.Exists(uiRoot))
            throw new DirectoryNotFoundException($"UI folder missing: {uiRoot}");

        config.BoundPort = config.Effective.PreferredPort;
        using var session = new WatchSession(config);
        using var server = new HttpServer(uiRoot, () => session);
        server.Start(config.Effective.PreferredPort, config.Effective.MaxPortTries);
        config.BoundPort = server.BoundPort;

        Console.WriteLine($"DesigoLogWatcher {Version} by Cisum");
        Console.WriteLine($"Listening: {server.ListeningUrl}");
        Console.WriteLine($"Config: {config.ConfigPath}  (refresh={config.Effective.RefreshSeconds}s, port prefer={config.Effective.PreferredPort})");
        Console.WriteLine("Log access: FileAccess.Read only (share allows WinCC to append).");
        Console.WriteLine("Ctrl+C to stop.");

        if (config.Effective.OpenBrowser && !options.NoBrowser && server.ListeningUrl is not null)
        {
            try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(server.ListeningUrl) { UseShellExecute = true }); }
            catch { /* ignore browser failures */ }
        }

        var exit = new ManualResetEventSlim(false);
        Console.CancelKeyPress += (_, e) => { e.Cancel = true; exit.Set(); };
        exit.Wait();
        return 0;
    }

    internal static string ResolveWatchRoot()
    {
        var baseDir = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (Directory.Exists(Path.Combine(baseDir, "ui")))
            return baseDir;
        var dir = new DirectoryInfo(baseDir);
        while (dir is not null)
        {
            var candidate = Path.Combine(dir.FullName, "Watch");
            if (Directory.Exists(Path.Combine(candidate, "ui")))
                return candidate;
            dir = dir.Parent;
        }
        return baseDir;
    }
}
