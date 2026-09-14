namespace DesigoLogWatcher;

/// <summary>
/// Entry: CLI parse → config load → dashboard vs report branch.
/// Publish: dotnet publish src\DesigoLogWatcher\DesigoLogWatcher.csproj -c Release -o Watch\
/// </summary>
public static class Program
{
    public const string Version = "0.5.0";

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

        var peekFirst = LogParser.GetProbeTimestamps(log, 0, 65_536L).First;
        var logEnd = LogParser.GetLogFileEndTimestamp(log);
        var window = InteractiveReport.PromptWindow(options, peekFirst, logEnd);

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
                    var endTs = logEnd ?? DateTime.Now;
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
                    Console.WriteLine($"Window: absolute"
                        + (cutoff is not null ? $" from {cutoff}" : "")
                        + (upper is not null ? $" to {upper}" : ""));
                }
            }
            else
            {
                Console.WriteLine("Window: entire file");
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
        if (state.ParsedLines == 0)
            Console.WriteLine("No log lines matched the WinCC OA header inside the selected window.");

        var defaultSev = options.WasBound(nameof(CliOptions.Severities))
            ? Config.ParseSeverityList(options.Severities)
            : config.Effective.DefaultSeverities.ToList();
        if (defaultSev.Count == 0)
            defaultSev = ["FATAL", "SEVERE", "ERROR", "WARNING"];
        var choices = InteractiveReport.PromptAfterScan(
            options, state, config.Effective.TopN, defaultSev);

        if (choices.Quit)
        {
            Console.WriteLine("Quit selected - no report written.");
            if (!options.NoPause)
            {
                Console.WriteLine("Press Enter to close.");
                Console.ReadLine();
            }
            return 0;
        }

        var areas = options.WasBound(nameof(CliOptions.Areas))
            ? Config.ParseAreaList(options.Areas)
            : new List<string> { "SYS", "IMPL", "CTRL", "PARAM", "OTHER" };

        var winMode = window.EntireLog ? "entire"
            : window.LastHours is not null ? "hours"
            : window.LastMinutes is not null ? "minutes"
            : "absolute";
        var lastMinutesLabel = window.LastMinutes
            ?? (window.LastHours is int hours ? hours * 60 : config.Effective.DefaultWindowMinutes);

        var builder = new SnapshotBuilder(state, engine, choices.TopN, config.Effective.BacFlapMin);
        var snap = builder.BuildSnapshot(
            log, fi.Length, Version,
            choices.Organize, choices.Format,
            severities: choices.Severities,
            areas: areas,
            drivers: choices.Drivers,
            windowEntire: window.EntireLog,
            lastMinutes: lastMinutesLabel,
            topN: choices.TopN,
            windowMode: winMode);

        var writer = new ReportWriter();
        var (textPath, htmlPath, jsonPath) = writer.WriteFiles(snap, log, options.OutPath, choices.Format);
        Console.WriteLine();
        if (textPath is not null) Console.WriteLine($"Wrote {textPath}");
        if (htmlPath is not null) Console.WriteLine($"Wrote {htmlPath}");
        if (jsonPath is not null) Console.WriteLine($"Wrote {jsonPath}");

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
        if (server.BoundPort != config.Effective.PreferredPort)
        {
            Console.ForegroundColor = ConsoleColor.Yellow;
            Console.WriteLine($"WARNING: PreferredPort {config.Effective.PreferredPort} was busy — bound {server.BoundPort} instead.");
            Console.WriteLine($"         Another Watch/DesigoLogWatcher is probably still running on {config.Effective.PreferredPort}.");
            Console.WriteLine($"         Use ONLY this URL (do not keep an old tab on :{config.Effective.PreferredPort}):");
            Console.WriteLine($"         {server.ListeningUrl}");
            Console.ResetColor();
        }
        Console.WriteLine($"Config: {config.ConfigPath}  (refresh={config.Effective.RefreshSeconds}s, port prefer={config.Effective.PreferredPort})");
        Console.WriteLine("Log access: FileAccess.Read only (share allows WinCC to append).");
        Console.WriteLine("Ctrl+C to stop (closing the window also releases the port).");

        if (config.Effective.OpenBrowser && !options.NoBrowser && server.ListeningUrl is not null)
            BrowserLauncher.Open(server.ListeningUrl, config.Effective.Browser);

        var exit = new ManualResetEventSlim(false);
        void RequestExit()
        {
            try { exit.Set(); } catch { /* ignore */ }
        }

        Console.CancelKeyPress += (_, e) =>
        {
            e.Cancel = true;
            RequestExit();
        };
        // Console X-button / taskkill soft path — release http.sys URL before process death.
        AppDomain.CurrentDomain.ProcessExit += (_, _) =>
        {
            try { server.Dispose(); } catch { /* ignore */ }
            try { session.Dispose(); } catch { /* ignore */ }
        };

        exit.Wait();
        Console.WriteLine("Stopping… releasing port.");
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
