namespace DesigoLogWatcher;

/// <summary>
/// Enter-defaulted -Interactive prompts for report mode (parity with Watch-PvssLog.ps1 Invoke-ReportMode).
/// Manager picks accept absolute 1-based ranges (e.g. 1-3,10) — intentional 0.5 delta vs page-local 0.4 picks.
/// </summary>
internal static class InteractiveReport
{
    public sealed class Choices
    {
        public TimeWindow Window { get; init; } = new() { EntireLog = true };
        public OrganizeMode Organize { get; set; } = OrganizeMode.All;
        public bool Quit { get; set; }
        public ReportFormat Format { get; set; } = ReportFormat.All;
        public List<string> Severities { get; set; } = ["FATAL", "SEVERE", "ERROR", "WARNING", "INFO"];
        public int TopN { get; set; } = 10;
        public List<string> Drivers { get; set; } = [];
    }

    /// <summary>Prompt 1 (pre-scan): time window when -Interactive and no window switch was bound.</summary>
    public static TimeWindow PromptWindow(
        CliOptions options,
        DateTime? peekFirst,
        DateTime? peekLast,
        TextReader? input = null,
        TextWriter? output = null)
    {
        output ??= Console.Out;
        input ??= Console.In;

        if (peekFirst is not null || peekLast is not null)
        {
            var a = peekFirst?.ToString("yyyy.MM.dd HH:mm:ss") ?? "?";
            var b = peekLast?.ToString("yyyy.MM.dd HH:mm:ss") ?? "?";
            output.WriteLine($"Span: {a}  -->  {b}");
        }

        var windowAsked = options.WasBound(nameof(CliOptions.From))
            || options.WasBound(nameof(CliOptions.To))
            || options.WasBound(nameof(CliOptions.LastHours))
            || options.WasBound(nameof(CliOptions.LastMinutes))
            || options.WasBound(nameof(CliOptions.Entire));

        if (!options.Interactive || windowAsked)
            return Cli.ResolveWindow(options, peekLast, defaultEntire: true);

        output.WriteLine();
        var mode = Cli.PromptDefault(
            "Time filter: [E] Entire file  [H] Last N hours  [W] Absolute From/To",
            "E", input, output);

        if (mode.StartsWith('H') || mode.StartsWith('h'))
        {
            if (peekLast is null)
                throw new InvalidOperationException("Cannot use last-N-hours: no timestamp found near the end of the log.");
            var h = 0;
            while (h <= 0)
            {
                var hAns = Cli.PromptDefault("How many hours back from end of log?", "6", input, output);
                if (int.TryParse(hAns, out var parsed) && parsed is >= 1 and <= 8760)
                    h = parsed;
                else
                    output.WriteLine("  Enter a whole number of hours between 1 and 8760.");
            }
            options.LastHours = h;
            options.Bound.Add(nameof(CliOptions.LastHours));
            return Cli.ResolveWindow(options, peekLast, defaultEntire: true);
        }

        if (mode.StartsWith('W') || mode.StartsWith('w'))
        {
            options.From = PromptTimeBound("From time (e.g. 2026.09.04 09:00)", "start of file", isTo: false, input, output);
            options.To = PromptTimeBound("To time   (e.g. 2026.09.04 12:00)", "end of file", isTo: true, input, output);
            if (!string.IsNullOrWhiteSpace(options.From))
                options.Bound.Add(nameof(CliOptions.From));
            if (!string.IsNullOrWhiteSpace(options.To))
                options.Bound.Add(nameof(CliOptions.To));
            return Cli.ResolveWindow(options, peekLast, defaultEntire: true);
        }

        options.Entire = true;
        options.Bound.Add(nameof(CliOptions.Entire));
        return new TimeWindow { EntireLog = true };
    }

    public static string PromptTimeBound(
        string promptText, string defaultLabel, bool isTo,
        TextReader? input = null, TextWriter? output = null)
    {
        output ??= Console.Out;
        input ??= Console.In;
        while (true)
        {
            output.WriteLine($"{promptText} [default: {defaultLabel}]");
            var ans = input.ReadLine();
            if (string.IsNullOrWhiteSpace(ans)) return "";
            ans = ans.Trim();
            try
            {
                _ = Cli.ConvertWindowBound(ans, isTo);
                return ans;
            }
            catch (Exception ex)
            {
                output.WriteLine($"  {ex.Message}");
                output.WriteLine("  Examples: 2026.09.04 09:00   or   2026.09.04");
            }
        }
    }

    /// <summary>Prompts 2–4 (post-scan): organize, severity/driver details, format.</summary>
    public static Choices PromptAfterScan(
        CliOptions options,
        AnalysisState data,
        int defaultTopN,
        IReadOnlyList<string> defaultSeverities,
        TextReader? input = null,
        TextWriter? output = null)
    {
        output ??= Console.Out;
        input ??= Console.In;

        var choices = new Choices
        {
            Organize = options.Organize,
            Format = options.Format,
            TopN = options.WasBound(nameof(CliOptions.TopN)) ? options.TopN : defaultTopN,
            Severities = options.WasBound(nameof(CliOptions.Severities))
                ? Config.ParseSeverityList(options.Severities)
                : defaultSeverities.ToList()
        };
        if (choices.Severities.Count == 0)
            choices.Severities = ["FATAL", "SEVERE", "ERROR", "WARNING", "INFO"];

        if (options.Interactive && !options.WasBound(nameof(CliOptions.Organize)))
        {
            output.WriteLine();
            var ans = Cli.PromptDefault(
                "Organize report: [A] All  [S] Severity  [D] Driver  [Q] Quit",
                "A", input, output);
            choices.Organize = ans switch
            {
                var s when s.StartsWith('S') || s.StartsWith('s') => OrganizeMode.Severity,
                var s when s.StartsWith('D') || s.StartsWith('d') => OrganizeMode.Driver,
                var s when s.StartsWith('Q') || s.StartsWith('q') => OrganizeMode.All,
                _ => OrganizeMode.All
            };
            if (ans.StartsWith('Q') || ans.StartsWith('q'))
            {
                choices.Quit = true;
                return choices;
            }
        }

        if (choices.Organize == OrganizeMode.Severity
            && options.Interactive
            && !options.WasBound(nameof(CliOptions.Severities)))
        {
            output.WriteLine();
            output.WriteLine("Severities: 1=FATAL 2=SEVERE 3=ERROR 4=WARNING 5=INFO  (critical pack = 1,2,3)");
            var sevAns = Cli.PromptDefault("Select severities (e.g. 1,2,3 or FATAL,SEVERE)", "1,2,3", input, output);
            var picked = Config.ParseSeverityList(sevAns);
            if (picked.Count > 0) choices.Severities = picked;
            var topAns = Cli.PromptDefault("Top N per severity", choices.TopN.ToString(), input, output);
            if (int.TryParse(topAns, out var tn) && tn is >= 5 and <= 100)
                choices.TopN = tn;
        }

        if (choices.Organize == OrganizeMode.Driver)
        {
            var areaAll = ChartSeriesBuilder.AllAreaOn();
            var ranked = ApiBuilders.FilteredTopManagers(data, areaAll, 5000).ToList();
            if (options.WasBound(nameof(CliOptions.Driver)) && !string.IsNullOrWhiteSpace(options.Driver))
            {
                choices.Drivers = ResolveDriverTokens(options.Driver, ranked);
                if (choices.Drivers.Count == 0)
                    throw new InvalidOperationException($"No manager matched -Driver '{options.Driver}'.");
            }
            else if (options.Interactive)
            {
                choices.Drivers = SelectDriversInteractive(ranked, input, output);
            }
            else if (ranked.Count > 0)
            {
                var name = StrName(ranked[0]);
                choices.Drivers = [name];
                output.WriteLine($"Organize=Driver with no -Driver: using the busiest manager, {name}.");
            }
        }

        if (options.Interactive && !options.WasBound(nameof(CliOptions.Format)))
        {
            output.WriteLine();
            var ans = Cli.PromptDefault(
                "Report format: [T] Text  [H] HTML  [J] JSON  [A] All (text+html+json)",
                "A", input, output);
            choices.Format = ans switch
            {
                var s when s.StartsWith('H') || s.StartsWith('h') => ReportFormat.Html,
                var s when s.StartsWith('T') || s.StartsWith('t') => ReportFormat.Text,
                var s when s.StartsWith('J') || s.StartsWith('j') => ReportFormat.Json,
                _ => ReportFormat.All
            };
        }

        return choices;
    }

    public static List<string> SelectDriversInteractive(
        IReadOnlyList<Dictionary<string, object?>> ranked,
        TextReader? input = null,
        TextWriter? output = null)
    {
        output ??= Console.Out;
        input ??= Console.In;
        if (ranked.Count == 0) return [];

        var page = 0;
        const int pageSize = 10;
        while (true)
        {
            var pages = Math.Max(1, (int)Math.Ceiling(ranked.Count / (double)pageSize));
            if (page >= pages) page = 0;
            if (page < 0) page = 0;
            var start = page * pageSize;
            var sliceCount = Math.Min(pageSize, ranked.Count - start);

            output.WriteLine();
            output.WriteLine($"Drivers/managers (page {page + 1} of {pages}, by volume):");
            for (var i = 0; i < sliceCount; i++)
            {
                var row = ranked[start + i];
                var abs = start + i + 1;
                var count = row.TryGetValue("count", out var c) && c is not null ? Convert.ToInt32(c) : 0;
                output.WriteLine($"  {abs,2}. {count,8:N0}  {StrName(row)}");
            }

            var pick = Cli.PromptDefault(
                "[1-3,10] absolute ranks  [N]ext  [P]rev  Enter=1",
                "1", input, output);
            if (pick.StartsWith('N') || pick.StartsWith('n')) { page++; continue; }
            if (pick.StartsWith('P') || pick.StartsWith('p')) { if (page > 0) page--; continue; }

            try
            {
                var idxs = Cli.ParseManagerRange(pick, ranked.Count);
                return idxs.Select(i => StrName(ranked[i - 1])).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
            }
            catch (Exception ex)
            {
                output.WriteLine($"  {ex.Message}");
            }
        }
    }

    public static List<string> ResolveDriverTokens(string driverText, IReadOnlyList<Dictionary<string, object?>> ranked)
    {
        var drivers = new List<string>();
        foreach (var part in driverText.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var token = part.Trim();
            if (token.Length == 0) continue;
            if (int.TryParse(token, out var n) && n >= 1 && n <= ranked.Count)
            {
                drivers.Add(StrName(ranked[n - 1]));
                continue;
            }
            foreach (var m in ranked)
            {
                var name = StrName(m);
                if (name.Contains(token, StringComparison.OrdinalIgnoreCase))
                    drivers.Add(name);
            }
        }
        return drivers.Distinct(StringComparer.OrdinalIgnoreCase).ToList();
    }

    private static string StrName(Dictionary<string, object?> row) =>
        row.TryGetValue("name", out var v) && v is not null ? Convert.ToString(v) ?? "" : "";
}
