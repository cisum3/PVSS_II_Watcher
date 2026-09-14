using System.Globalization;
using System.Text;

namespace DesigoLogWatcher;

public enum ReportFormat
{
    Text,
    Html,
    Both,
    Json
}

public enum OrganizeMode
{
    All,
    Severity,
    Driver
}

/// <summary>Normalized analysis window after CLI precedence rules.</summary>
public sealed class TimeWindow
{
    public bool EntireLog { get; init; }
    public DateTime? Start { get; init; }
    public DateTime? End { get; init; }
    public int? LastMinutes { get; init; }
    public int? LastHours { get; init; }
}

/// <summary>All Watch 0.4.0 CLI switches (param block lines 13–45).</summary>
public sealed class CliOptions
{
    public string LogPath { get; set; } = "";
    public int Port { get; set; } = 8787;
    public int LastMinutes { get; set; } = 60;
    public int RefreshSeconds { get; set; } = 3;
    public bool NoBrowser { get; set; }
    public bool NoPause { get; set; }
    public int TopN { get; set; } = 10;
    /// <summary>CLI ValidateRange 0–5 (config file allows 1–20).</summary>
    public int SamplePerPattern { get; set; } = 1;
    public int SampleMaxChars { get; set; } = 500;
    public bool Report { get; set; }
    public string OutPath { get; set; } = "";
    public ReportFormat Format { get; set; } = ReportFormat.Both;
    public OrganizeMode Organize { get; set; } = OrganizeMode.All;
    public string Severities { get; set; } = "";
    public string Areas { get; set; } = "";
    public string Driver { get; set; } = "";
    public bool Entire { get; set; }
    public string From { get; set; } = "";
    public string To { get; set; } = "";
    public int LastHours { get; set; }
    public bool Interactive { get; set; }
    public bool Help { get; set; }

    // Bound-tracking: which switches were explicitly provided (CLI > config).
    public HashSet<string> Bound { get; } = new(StringComparer.OrdinalIgnoreCase);

    public bool WasBound(string name) => Bound.Contains(name);

    public CliConfigOverrides ToConfigOverrides() => new()
    {
        Port = WasBound(nameof(Port)) ? Port : null,
        LastMinutes = WasBound(nameof(LastMinutes)) ? LastMinutes : null,
        RefreshSeconds = WasBound(nameof(RefreshSeconds)) ? RefreshSeconds : null,
        TopN = WasBound(nameof(TopN)) ? TopN : null,
        SamplePerPattern = WasBound(nameof(SamplePerPattern)) ? SamplePerPattern : null,
        SampleMaxChars = WasBound(nameof(SampleMaxChars)) ? SampleMaxChars : null,
        NoBrowser = WasBound(nameof(NoBrowser)) ? NoBrowser : null,
        Entire = WasBound(nameof(Entire)) ? Entire : null,
        LogPath = WasBound(nameof(LogPath)) && !string.IsNullOrWhiteSpace(LogPath) ? LogPath : null,
        Severities = WasBound(nameof(Severities)) ? Severities : null,
        Areas = WasBound(nameof(Areas)) ? Areas : null
    };
}

/// <summary>
/// PowerShell-style CLI parser (-LogPath value, -Report switch). Hand parser preferred for
/// exact switch name parity with Watch-PvssLog.ps1.
/// </summary>
public sealed class Cli
{
    public static string HelpText { get; } = """
        DesigoLogWatcher — PVSS_II.log triage (0.5.0 C# host)

        Usage:
          DesigoLogWatcher.exe [options]              Dashboard mode (default)
          DesigoLogWatcher.exe -Report [options]      Batch report mode

        Common:
          -LogPath <path>         Explicit PVSS_II.log (else auto-discover)
          -TopN <5-100>           Pattern table depth (default 10)
          -Entire                 Whole-file window
          -LastMinutes <n>        Relative window (dashboard default 60)
          -LastHours <0-8760>     Relative hours (report); wins over -From/-To
          -From / -To <stamp>     Absolute bounds (date-only -To = end of day)
          -Severities <list>      FATAL,SEVERE,ERROR,WARNING,INFO (or 1-5)
          -Areas <list>           SYS,IMPL,CTRL,PARAM,OTHER (or 1-5)
          -NoPause                Do not wait for Enter on report exit

        Dashboard:
          -Port <1-65535>         Preferred listen port (127.0.0.1)
          -RefreshSeconds <1-60>  Pulse cadence
          -NoBrowser              Do not open a browser
          -SamplePerPattern <0-5> Samples kept per pattern (CLI; config allows 1-20)
          -SampleMaxChars <100-2000>

        Report:
          -Report                 Batch scan → write → exit (no port)
          -OutPath <path>         Output stem (default: <log>.analysis)
          -Format Text|Html|Json|Both  (default Both)
          -Organize All|Severity|Driver
          -Driver <name|n>        Driver filter / list position
          -Interactive            Enter-defaulted prompts (manager ranges: 1-3,10)

        Relative windows (-Entire / -LastHours / -LastMinutes) override -From/-To.
        """;

    public CliOptions Parse(string[] args)
    {
        var o = new CliOptions();
        for (var i = 0; i < args.Length; i++)
        {
            var a = args[i];
            if (a is "-h" or "--help" or "/?" or "-Help")
            {
                o.Help = true;
                o.Bound.Add("Help");
                continue;
            }

            if (!a.StartsWith('-') && !a.StartsWith('/'))
                throw new ArgumentException($"Unexpected argument '{a}'. Options start with -.");

            var name = a.TrimStart('-', '/');
            switch (name.ToLowerInvariant())
            {
                case "logpath":
                    o.LogPath = NeedValue(args, ref i, name); o.Bound.Add(nameof(CliOptions.LogPath)); break;
                case "port":
                    o.Port = ParseInt(NeedValue(args, ref i, name), 1, 65535, name); o.Bound.Add(nameof(CliOptions.Port)); break;
                case "lastminutes":
                    o.LastMinutes = ParseInt(NeedValue(args, ref i, name), 1, 525600, name); o.Bound.Add(nameof(CliOptions.LastMinutes)); break;
                case "refreshseconds":
                    o.RefreshSeconds = ParseInt(NeedValue(args, ref i, name), 1, 60, name); o.Bound.Add(nameof(CliOptions.RefreshSeconds)); break;
                case "nobrowser":
                    o.NoBrowser = true; o.Bound.Add(nameof(CliOptions.NoBrowser)); break;
                case "nopause":
                    o.NoPause = true; o.Bound.Add(nameof(CliOptions.NoPause)); break;
                case "topn":
                    o.TopN = ParseInt(NeedValue(args, ref i, name), 5, 100, name); o.Bound.Add(nameof(CliOptions.TopN)); break;
                case "sampleperpattern":
                    o.SamplePerPattern = ParseInt(NeedValue(args, ref i, name), 0, 5, name); o.Bound.Add(nameof(CliOptions.SamplePerPattern)); break;
                case "samplemaxchars":
                    o.SampleMaxChars = ParseInt(NeedValue(args, ref i, name), 100, 2000, name); o.Bound.Add(nameof(CliOptions.SampleMaxChars)); break;
                case "report":
                    o.Report = true; o.Bound.Add(nameof(CliOptions.Report)); break;
                case "outpath":
                    o.OutPath = NeedValue(args, ref i, name); o.Bound.Add(nameof(CliOptions.OutPath)); break;
                case "format":
                    o.Format = ParseEnumFormat(NeedValue(args, ref i, name)); o.Bound.Add(nameof(CliOptions.Format)); break;
                case "organize":
                    o.Organize = ParseEnumOrganize(NeedValue(args, ref i, name)); o.Bound.Add(nameof(CliOptions.Organize)); break;
                case "severities":
                    o.Severities = NeedValue(args, ref i, name); o.Bound.Add(nameof(CliOptions.Severities)); break;
                case "areas":
                    o.Areas = NeedValue(args, ref i, name); o.Bound.Add(nameof(CliOptions.Areas)); break;
                case "driver":
                    o.Driver = NeedValue(args, ref i, name); o.Bound.Add(nameof(CliOptions.Driver)); break;
                case "entire":
                    o.Entire = true; o.Bound.Add(nameof(CliOptions.Entire)); break;
                case "from":
                    o.From = NeedValue(args, ref i, name); o.Bound.Add(nameof(CliOptions.From)); break;
                case "to":
                    o.To = NeedValue(args, ref i, name); o.Bound.Add(nameof(CliOptions.To)); break;
                case "lasthours":
                    o.LastHours = ParseInt(NeedValue(args, ref i, name), 0, 8760, name); o.Bound.Add(nameof(CliOptions.LastHours)); break;
                case "interactive":
                    o.Interactive = true; o.Bound.Add(nameof(CliOptions.Interactive)); break;
                default:
                    throw new ArgumentException($"Unknown switch -{name}. Use -Help for options.");
            }
        }

        return o;
    }

    /// <summary>
    /// Relative windows (-Entire / -LastHours / -LastMinutes) win over -From/-To.
    /// When nothing is specified: report mode defaults to Entire; dashboard-style defaults to LastMinutes.
    /// </summary>
    public static TimeWindow ResolveWindow(CliOptions o, DateTime? logEndLocal = null, bool defaultEntire = false)
    {
        if (o.Entire)
            return new TimeWindow { EntireLog = true };

        var relativeHours = o.WasBound(nameof(CliOptions.LastHours)) && o.LastHours > 0;
        var relativeMinutes = o.WasBound(nameof(CliOptions.LastMinutes));
        if (relativeHours)
        {
            var end = logEndLocal ?? DateTime.Now;
            return new TimeWindow
            {
                LastHours = o.LastHours,
                End = end,
                Start = end.AddHours(-o.LastHours)
            };
        }

        if (relativeMinutes)
            return new TimeWindow { LastMinutes = o.LastMinutes };

        if (!string.IsNullOrWhiteSpace(o.From) || !string.IsNullOrWhiteSpace(o.To))
        {
            DateTime? start = string.IsNullOrWhiteSpace(o.From) ? null : ConvertWindowBound(o.From, isTo: false);
            DateTime? end = string.IsNullOrWhiteSpace(o.To) ? null : ConvertWindowBound(o.To, isTo: true);
            return new TimeWindow { Start = start, End = end };
        }

        if (defaultEntire)
            return new TimeWindow { EntireLog = true };

        // Dashboard-style default when nothing else specified.
        return new TimeWindow { LastMinutes = o.LastMinutes };
    }

    /// <summary>
    /// §2.1: manager pick ranges like "1-3,10" → distinct sorted 1-based indices.
    /// </summary>
    public static List<int> ParseManagerRange(string text, int maxInclusive)
    {
        if (string.IsNullOrWhiteSpace(text))
            throw new ArgumentException("Manager pick is empty.");
        if (maxInclusive < 1)
            throw new ArgumentException("Manager list is empty.");

        var set = new SortedSet<int>();
        foreach (var part in text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var token = part.Trim();
            var dash = token.IndexOf('-');
            if (dash > 0 && dash < token.Length - 1 && !token.StartsWith('-'))
            {
                var left = token[..dash].Trim();
                var right = token[(dash + 1)..].Trim();
                if (!int.TryParse(left, NumberStyles.Integer, CultureInfo.InvariantCulture, out var a) ||
                    !int.TryParse(right, NumberStyles.Integer, CultureInfo.InvariantCulture, out var b))
                    throw new ArgumentException($"Invalid manager range '{token}'. Use e.g. 1-3,10.");
                if (a > b)
                    throw new ArgumentException($"Invalid manager range '{token}' (start > end).");
                for (var n = a; n <= b; n++)
                {
                    if (n < 1 || n > maxInclusive)
                        throw new ArgumentException($"Manager index {n} out of range 1..{maxInclusive}.");
                    set.Add(n);
                }
            }
            else
            {
                if (!int.TryParse(token, NumberStyles.Integer, CultureInfo.InvariantCulture, out var n))
                    throw new ArgumentException($"Invalid manager pick '{token}'. Use e.g. 1-3,10.");
                if (n < 1 || n > maxInclusive)
                    throw new ArgumentException($"Manager index {n} out of range 1..{maxInclusive}.");
                set.Add(n);
            }
        }

        if (set.Count == 0)
            throw new ArgumentException("No manager indices selected.");
        return set.ToList();
    }

    public static string PromptDefault(string promptText, string defaultValue, TextReader? input = null, TextWriter? output = null)
    {
        output ??= Console.Out;
        input ??= Console.In;
        output.WriteLine($"{promptText} [default: {defaultValue}]");
        var ans = input.ReadLine();
        return string.IsNullOrWhiteSpace(ans) ? defaultValue : ans.Trim();
    }

    public static DateTime ConvertWindowBound(string text, bool isTo)
    {
        var dt = ConvertFromUserTimestamp(text)
            ?? throw new ArgumentException($"Invalid bound '{text}'. Use e.g. '2026.09.04 09:00' or '2026.09.04'.");
        // Date-only -To = end of that calendar day (PS Convert-WindowBound).
        if (isTo && !System.Text.RegularExpressions.Regex.IsMatch(text, @"\d{1,2}:\d{2}"))
            dt = dt.Date.AddDays(1).AddMilliseconds(-1);
        return dt;
    }

    public static DateTime? ConvertFromUserTimestamp(string text)
    {
        if (string.IsNullOrWhiteSpace(text))
            return null;
        var t = text.Trim();
        string[] formats =
        [
            "yyyy.MM.dd HH:mm:ss.fff", "yyyy.MM.dd HH:mm:ss", "yyyy.MM.dd HH:mm", "yyyy.MM.dd",
            "yyyy-MM-dd HH:mm:ss.fff", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"
        ];
        foreach (var f in formats)
        {
            if (DateTime.TryParseExact(t, f, CultureInfo.InvariantCulture, DateTimeStyles.None, out var dt))
                return dt;
        }
        if (DateTime.TryParse(t, CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal, out var dt2))
            return dt2;
        return null;
    }

    private static string NeedValue(string[] args, ref int i, string name)
    {
        if (i + 1 >= args.Length || args[i + 1].StartsWith('-'))
            throw new ArgumentException($"-{name} requires a value.");
        i++;
        return args[i];
    }

    private static int ParseInt(string text, int min, int max, string name)
    {
        if (!int.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var n) || n < min || n > max)
            throw new ArgumentException($"-{name} must be an integer {min}-{max} (got '{text}').");
        return n;
    }

    private static ReportFormat ParseEnumFormat(string text) => text.Trim().ToLowerInvariant() switch
    {
        "text" => ReportFormat.Text,
        "html" => ReportFormat.Html,
        "json" => ReportFormat.Json,
        "both" => ReportFormat.Both,
        _ => throw new ArgumentException($"-Format must be Text, Html, Json, or Both (got '{text}').")
    };

    private static OrganizeMode ParseEnumOrganize(string text) => text.Trim().ToLowerInvariant() switch
    {
        "all" => OrganizeMode.All,
        "severity" => OrganizeMode.Severity,
        "driver" => OrganizeMode.Driver,
        _ => throw new ArgumentException($"-Organize must be All, Severity, or Driver (got '{text}').")
    };
}
