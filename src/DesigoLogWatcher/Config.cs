using System.Collections.ObjectModel;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace DesigoLogWatcher;

/// <summary>
/// watch-config.txt load / validate / self-correct / CLI merge / LogPath write-back.
/// Behavioral port of Read-WatchConfig, Set-WatchConfigKeys, Apply-WatchConfig
/// (Watch-PvssLog.ps1; see docs/INVENTORY-V0.5.md §2).
/// </summary>
public sealed class WatchConfig
{
    public int PreferredPort { get; set; } = 8787;
    public int MaxPortTries { get; set; } = 40;
    public int RefreshSeconds { get; set; } = 3;
    public bool OpenBrowser { get; set; } = true;
    public string Browser { get; set; } = "default";
    public int DefaultWindowMinutes { get; set; } = 60;
    public bool DefaultWindowEntire { get; set; }
    public List<string> DefaultSeverities { get; set; } = ["FATAL", "SEVERE", "ERROR", "WARNING"];
    public List<string> DefaultAreas { get; set; } = ["SYS", "IMPL", "CTRL", "PARAM", "OTHER"];
    public int TopN { get; set; } = 10;
    /// <summary>Config-file range is 1–20; CLI param ValidateRange is 0–5 — preserve both at merge.</summary>
    public int SamplePerPattern { get; set; } = 1;
    public int SampleMaxChars { get; set; } = 500;
    public int BacFlapMin { get; set; } = 3;
    public string LogPath { get; set; } = "";

    public static WatchConfig CreateDefaults() => new();
}

/// <summary>CLI-bound overrides; only properties that were explicitly provided are set.</summary>
public sealed class CliConfigOverrides
{
    public int? Port { get; init; }
    public int? LastMinutes { get; init; }
    public int? RefreshSeconds { get; init; }
    public int? TopN { get; init; }
    public int? SamplePerPattern { get; init; }
    public int? SampleMaxChars { get; init; }
    public bool? NoBrowser { get; init; }
    public bool? Entire { get; init; }
    public string? LogPath { get; init; }
    public string? Severities { get; init; }
    public string? Areas { get; init; }
}

public sealed class ConfigLoadResult
{
    public required WatchConfig Config { get; init; }
    public IReadOnlyList<string> Warnings { get; init; } = Array.Empty<string>();
    public IReadOnlyDictionary<string, string> Corrections { get; init; } =
        new ReadOnlyDictionary<string, string>(new Dictionary<string, string>());
    public IReadOnlyList<string> RuntimeChanges { get; init; } = Array.Empty<string>();
    public IReadOnlyList<string> RuntimeSkipped { get; init; } = Array.Empty<string>();
}

public enum WatchRunMode
{
    Dashboard,
    Report
}

/// <summary>
/// Owns the config file path and runtime merge state (CLI overrides survive reloads).
/// </summary>
public sealed class Config
{
    private static readonly HashSet<string> KnownKeys = new(StringComparer.Ordinal)
    {
        "PreferredPort", "MaxPortTries", "RefreshSeconds", "OpenBrowser", "Browser",
        "DefaultWindowMinutes", "DefaultWindowEntire", "DefaultSeverities", "DefaultAreas",
        "TopN", "SamplePerPattern", "SampleMaxChars", "BacFlapMin", "LogPath"
    };

    private static readonly string[] SeverityOrder = ["FATAL", "SEVERE", "ERROR", "WARNING", "INFO"];
    private static readonly string[] AreaOrder = ["SYS", "IMPL", "CTRL", "PARAM", "OTHER"];
    private static readonly Regex KeyLineRe = new(@"^\s*(?<k>[^=]+?)\s*=", RegexOptions.Compiled);

    private readonly string _configPath;
    private readonly Action<string>? _warn;
    private CliConfigOverrides? _cli;
    private WatchConfig _effective = WatchConfig.CreateDefaults();
    private int _boundPort;

    public Config(string configPath, Action<string>? warn = null)
    {
        _configPath = configPath;
        _warn = warn;
    }

    public string ConfigPath => _configPath;
    public WatchConfig Effective => _effective;
    public WatchRunMode Mode { get; set; } = WatchRunMode.Dashboard;

    /// <summary>Port the listener actually bound (startup-only; not overwritten on Reload).</summary>
    public int BoundPort
    {
        get => _boundPort;
        set => _boundPort = value;
    }

    /// <summary>Parse raw key=value lines (PS Read-WatchConfig line loop).</summary>
    public static Dictionary<string, string> ParseRawLines(IEnumerable<string> lines, List<string>? warnings = null)
    {
        var map = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var raw in lines)
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith('#'))
                continue;

            var eq = line.IndexOf('=');
            if (eq < 1)
            {
                warnings?.Add($"Ignored malformed line (expected Key=Value): {line}");
                continue;
            }

            var key = line[..eq].Trim();
            var val = line[(eq + 1)..].Trim();
            if (key.Length == 0)
            {
                warnings?.Add($"Ignored malformed line (expected Key=Value): {line}");
                continue;
            }

            if (!KnownKeys.Contains(key))
            {
                warnings?.Add($"Unknown config key ignored: {key}");
                continue;
            }

            map[key] = val;
        }

        return map;
    }

    public ConfigLoadResult Load(CliConfigOverrides? cliOverrides = null, bool writeCorrections = true)
    {
        if (cliOverrides is not null)
            _cli = cliOverrides;

        var defaults = WatchConfig.CreateDefaults();
        var cfg = WatchConfig.CreateDefaults();
        var warnings = new List<string>();
        var corrections = new Dictionary<string, string>(StringComparer.Ordinal);

        if (!File.Exists(_configPath))
        {
            ApplyCliOverrides(cfg, _cli);
            _effective = cfg;
            return new ConfigLoadResult { Config = cfg, Warnings = warnings };
        }

        string[] lines;
        try
        {
            lines = File.ReadAllLines(_configPath, Encoding.UTF8);
        }
        catch (Exception ex)
        {
            warnings.Add($"Could not read config file; using built-in defaults: {_configPath} ({ex.Message})");
            ApplyCliOverrides(cfg, _cli);
            _effective = cfg;
            return new ConfigLoadResult { Config = cfg, Warnings = warnings };
        }

        var raw = ParseRawLines(lines, warnings);
        ApplyRawToConfig(raw, cfg, defaults, warnings, corrections);

        if (writeCorrections && corrections.Count > 0)
        {
            try
            {
                SetWatchConfigKeys(corrections);
            }
            catch (Exception ex)
            {
                warnings.Add($"Failed to write config corrections: {ex.Message}");
            }
        }

        ApplyCliOverrides(cfg, _cli);
        _effective = cfg;
        return new ConfigLoadResult
        {
            Config = cfg,
            Warnings = warnings,
            Corrections = new ReadOnlyDictionary<string, string>(corrections)
        };
    }

    /// <summary>
    /// Dashboard restart: re-read file, re-validate, re-apply CLI. Startup-only keys skipped.
    /// </summary>
    public ConfigLoadResult ReloadRuntime()
    {
        var before = SnapshotRuntime(_effective);
        var result = Load(_cli, writeCorrections: true);
        var after = SnapshotRuntime(result.Config);
        var changes = new List<string>();
        var skipped = new List<string>();

        foreach (var key in before.Keys)
        {
            if (!string.Equals(before[key], after[key], StringComparison.Ordinal))
            {
                var oldLabel = string.IsNullOrEmpty(before[key]) ? "(empty)" : before[key];
                var newLabel = string.IsNullOrEmpty(after[key]) ? "(empty)" : after[key];
                changes.Add($"{key}: {oldLabel} -> {newLabel}");
            }
        }

        if (_cli?.Port is null && result.Config.PreferredPort != BoundPort && BoundPort > 0)
        {
            skipped.Add($"PreferredPort={result.Config.PreferredPort} needs a host restart (still on {BoundPort})");
        }

        return new ConfigLoadResult
        {
            Config = result.Config,
            Warnings = result.Warnings,
            Corrections = result.Corrections,
            RuntimeChanges = changes,
            RuntimeSkipped = skipped
        };
    }

    /// <summary>
    /// Persist LogPath on dashboard Start only. Report mode is a no-op.
    /// </summary>
    public void WriteLogPath(string path)
    {
        if (Mode == WatchRunMode.Report)
            return;

        SetWatchConfigKeys(new Dictionary<string, string> { ["LogPath"] = path });
        _effective.LogPath = path;
    }

    /// <summary>Set-WatchConfigKeys equivalent — updates matching lines, preserves comments/order.</summary>
    public void SetWatchConfigKeys(IReadOnlyDictionary<string, string> updates)
    {
        if (updates.Count == 0)
            return;

        var lines = new List<string>();
        if (File.Exists(_configPath))
            lines.AddRange(File.ReadAllLines(_configPath, Encoding.UTF8));
        else
        {
            lines.Add("# Watch preferences (auto-created)");
            lines.Add("");
        }

        foreach (var (key, value) in updates)
        {
            var newLine = $"{key}={value}";
            var found = false;
            for (var i = 0; i < lines.Count; i++)
            {
                var m = KeyLineRe.Match(lines[i]);
                if (m.Success && string.Equals(m.Groups["k"].Value.Trim(), key, StringComparison.Ordinal))
                {
                    lines[i] = newLine;
                    found = true;
                    break;
                }
            }

            if (!found)
            {
                lines.Add("");
                lines.Add(newLine);
            }
        }

        File.WriteAllLines(_configPath, lines, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
    }

    public static string FormatValue(string key, object? value) => key switch
    {
        "OpenBrowser" or "DefaultWindowEntire" => value is true or "true" ? "true" : "false",
        "DefaultSeverities" or "DefaultAreas" when value is IEnumerable<string> seq =>
            string.Join(",", seq),
        _ => Convert.ToString(value, CultureInfo.InvariantCulture) ?? ""
    };

    public static bool? TryParseConfigBool(string text)
    {
        if (string.IsNullOrWhiteSpace(text))
            return null;
        return text.Trim().ToLowerInvariant() switch
        {
            "1" or "true" or "yes" or "on" => true,
            "0" or "false" or "no" or "off" => false,
            _ => null
        };
    }

    public static List<string> ParseSeverityList(string text)
    {
        var outList = new List<string>();
        foreach (var part in text.Split([',', ';', ' ', '\t'], StringSplitOptions.RemoveEmptyEntries))
        {
            var p = part.Trim().ToUpperInvariant();
            if (p == "WARN") p = "WARNING";
            if (p.Length == 1 && p[0] is >= '1' and <= '5')
                p = SeverityOrder[p[0] - '1'];
            if (SeverityOrder.Contains(p) && !outList.Contains(p))
                outList.Add(p);
        }
        return SeverityOrder.Where(outList.Contains).ToList();
    }

    public static List<string> ParseAreaList(string text)
    {
        var outList = new List<string>();
        foreach (var part in text.Split([',', ';', ' ', '\t'], StringSplitOptions.RemoveEmptyEntries))
        {
            var p = part.Trim().ToUpperInvariant();
            if (p.Length == 1 && p[0] is >= '1' and <= '5')
                p = AreaOrder[p[0] - '1'];
            if (AreaOrder.Contains(p) && !outList.Contains(p))
                outList.Add(p);
        }
        return AreaOrder.Where(outList.Contains).ToList();
    }

    private void ApplyRawToConfig(
        Dictionary<string, string> raw,
        WatchConfig cfg,
        WatchConfig defaults,
        List<string> warnings,
        Dictionary<string, string> corrections)
    {
        foreach (var (key, val) in raw)
        {
            switch (key)
            {
                case "PreferredPort":
                    if (TryParseInt(val, 1, 65535, out var port))
                        cfg.PreferredPort = port;
                    else
                        Correct(key, val, defaults.PreferredPort, $"PreferredPort='{val}' invalid (need integer 1-65535); reset to {defaults.PreferredPort}", cfg, defaults, warnings, corrections, v => cfg.PreferredPort = (int)v!);
                    break;
                case "MaxPortTries":
                    if (TryParseInt(val, 1, 200, out var tries))
                        cfg.MaxPortTries = tries;
                    else
                        Correct(key, val, defaults.MaxPortTries, $"MaxPortTries='{val}' invalid (need integer 1-200); reset to {defaults.MaxPortTries}", cfg, defaults, warnings, corrections, v => cfg.MaxPortTries = (int)v!);
                    break;
                case "RefreshSeconds":
                    if (TryParseInt(val, 1, 60, out var refresh))
                        cfg.RefreshSeconds = refresh;
                    else
                        Correct(key, val, defaults.RefreshSeconds, $"RefreshSeconds='{val}' invalid (need integer 1-60); reset to {defaults.RefreshSeconds}", cfg, defaults, warnings, corrections, v => cfg.RefreshSeconds = (int)v!);
                    break;
                case "OpenBrowser":
                {
                    var b = TryParseConfigBool(val);
                    if (b is not null)
                        cfg.OpenBrowser = b.Value;
                    else
                        Correct(key, val, defaults.OpenBrowser, $"OpenBrowser='{val}' invalid (need true|false); reset to {FormatValue("OpenBrowser", defaults.OpenBrowser)}", cfg, defaults, warnings, corrections, v => cfg.OpenBrowser = (bool)v!);
                    break;
                }
                case "Browser":
                    if (IsValidBrowser(val))
                        cfg.Browser = val.Trim();
                    else
                        Correct(key, val, defaults.Browser, $"Browser='{val}' invalid (default|chrome|msedge|existing .exe path); reset to {defaults.Browser}", cfg, defaults, warnings, corrections, v => cfg.Browser = (string)v!);
                    break;
                case "DefaultWindowMinutes":
                    if (TryParseInt(val, 1, 10080, out var mins))
                        cfg.DefaultWindowMinutes = mins;
                    else
                        Correct(key, val, defaults.DefaultWindowMinutes, $"DefaultWindowMinutes='{val}' invalid (need integer 1-10080); reset to {defaults.DefaultWindowMinutes}", cfg, defaults, warnings, corrections, v => cfg.DefaultWindowMinutes = (int)v!);
                    break;
                case "DefaultWindowEntire":
                {
                    var b = TryParseConfigBool(val);
                    if (b is not null)
                        cfg.DefaultWindowEntire = b.Value;
                    else
                        Correct(key, val, defaults.DefaultWindowEntire, $"DefaultWindowEntire='{val}' invalid (need true|false); reset to {FormatValue("DefaultWindowEntire", defaults.DefaultWindowEntire)}", cfg, defaults, warnings, corrections, v => cfg.DefaultWindowEntire = (bool)v!);
                    break;
                }
                case "DefaultSeverities":
                {
                    var parts = val.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                        .Select(p => p.ToUpperInvariant()).Where(p => p.Length > 0).ToList();
                    var good = new List<string>();
                    var bad = new List<string>();
                    foreach (var p in parts)
                    {
                        if (SeverityOrder.Contains(p))
                        {
                            if (!good.Contains(p)) good.Add(p);
                        }
                        else bad.Add(p);
                    }
                    if (good.Count > 0)
                    {
                        cfg.DefaultSeverities = SeverityOrder.Where(good.Contains).ToList();
                        if (bad.Count > 0)
                        {
                            warnings.Add($"DefaultSeverities dropped unknown token(s): {string.Join(",", bad)}; kept {string.Join(",", good)}");
                            corrections[key] = FormatValue(key, cfg.DefaultSeverities);
                            Warn(warnings[^1]);
                        }
                    }
                    else
                    {
                        Correct(key, val, defaults.DefaultSeverities, $"DefaultSeverities='{val}' invalid; reset to {string.Join(",", defaults.DefaultSeverities)}", cfg, defaults, warnings, corrections, v => cfg.DefaultSeverities = ((IEnumerable<string>)v!).ToList());
                    }
                    break;
                }
                case "DefaultAreas":
                {
                    var parts = val.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                        .Select(p => p.ToUpperInvariant()).Where(p => p.Length > 0).ToList();
                    var good = new List<string>();
                    var bad = new List<string>();
                    foreach (var p in parts)
                    {
                        if (AreaOrder.Contains(p))
                        {
                            if (!good.Contains(p)) good.Add(p);
                        }
                        else bad.Add(p);
                    }
                    if (good.Count > 0)
                    {
                        cfg.DefaultAreas = AreaOrder.Where(good.Contains).ToList();
                        if (bad.Count > 0)
                        {
                            warnings.Add($"DefaultAreas dropped unknown token(s): {string.Join(",", bad)}; kept {string.Join(",", good)}");
                            corrections[key] = FormatValue(key, cfg.DefaultAreas);
                            Warn(warnings[^1]);
                        }
                    }
                    else
                    {
                        Correct(key, val, defaults.DefaultAreas, $"DefaultAreas='{val}' invalid; reset to {string.Join(",", defaults.DefaultAreas)}", cfg, defaults, warnings, corrections, v => cfg.DefaultAreas = ((IEnumerable<string>)v!).ToList());
                    }
                    break;
                }
                case "TopN":
                    if (TryParseInt(val, 5, 100, out var topN))
                        cfg.TopN = topN;
                    else
                        Correct(key, val, defaults.TopN, $"TopN='{val}' invalid (need integer 5-100); reset to {defaults.TopN}", cfg, defaults, warnings, corrections, v => cfg.TopN = (int)v!);
                    break;
                case "SamplePerPattern":
                    if (TryParseInt(val, 1, 20, out var spp))
                        cfg.SamplePerPattern = spp;
                    else
                        Correct(key, val, defaults.SamplePerPattern, $"SamplePerPattern='{val}' invalid (need integer 1-20); reset to {defaults.SamplePerPattern}", cfg, defaults, warnings, corrections, v => cfg.SamplePerPattern = (int)v!);
                    break;
                case "SampleMaxChars":
                    if (TryParseInt(val, 100, 2000, out var smc))
                        cfg.SampleMaxChars = smc;
                    else
                        Correct(key, val, defaults.SampleMaxChars, $"SampleMaxChars='{val}' invalid (need integer 100-2000); reset to {defaults.SampleMaxChars}", cfg, defaults, warnings, corrections, v => cfg.SampleMaxChars = (int)v!);
                    break;
                case "BacFlapMin":
                    if (TryParseInt(val, 1, 50, out var flap))
                        cfg.BacFlapMin = flap;
                    else
                        Correct(key, val, defaults.BacFlapMin, $"BacFlapMin='{val}' invalid (need integer 1-50); reset to {defaults.BacFlapMin}", cfg, defaults, warnings, corrections, v => cfg.BacFlapMin = (int)v!);
                    break;
                case "LogPath":
                    cfg.LogPath = val;
                    break;
            }
        }
    }

    private void Correct(
        string key,
        string invalidVal,
        object defaultValue,
        string warning,
        WatchConfig cfg,
        WatchConfig defaults,
        List<string> warnings,
        Dictionary<string, string> corrections,
        Action<object> apply)
    {
        warnings.Add(warning);
        Warn(warning);
        apply(defaultValue);
        corrections[key] = FormatValue(key, defaultValue switch
        {
            IEnumerable<string> s when key is "DefaultSeverities" or "DefaultAreas" => s,
            _ => defaultValue
        });
        _ = cfg;
        _ = defaults;
        _ = invalidVal;
    }

    private static void ApplyCliOverrides(WatchConfig cfg, CliConfigOverrides? cli)
    {
        if (cli is null)
            return;

        if (cli.Port is int port)
            cfg.PreferredPort = port;
        if (cli.LastMinutes is int lm)
            cfg.DefaultWindowMinutes = lm;
        if (cli.RefreshSeconds is int rs)
            cfg.RefreshSeconds = Math.Clamp(rs, 1, 60);
        if (cli.TopN is int tn)
            cfg.TopN = tn;
        if (cli.SamplePerPattern is int spp)
            cfg.SamplePerPattern = spp; // CLI allows 0–5; do not clamp to config 1–20 here
        if (cli.SampleMaxChars is int smc)
            cfg.SampleMaxChars = Math.Clamp(smc, 100, 2000);
        if (cli.NoBrowser is true)
            cfg.OpenBrowser = false;
        else if (cli.NoBrowser is false)
            cfg.OpenBrowser = true;
        if (cli.Entire is bool entire)
            cfg.DefaultWindowEntire = entire;
        if (cli.LogPath is { Length: > 0 } lp)
            cfg.LogPath = lp.Trim();
        if (cli.Severities is { Length: > 0 } sev)
        {
            var list = ParseSeverityList(sev);
            if (list.Count > 0)
                cfg.DefaultSeverities = list;
        }
        if (cli.Areas is { Length: > 0 } areas)
        {
            var list = ParseAreaList(areas);
            if (list.Count > 0)
                cfg.DefaultAreas = list;
        }
    }

    private static Dictionary<string, string> SnapshotRuntime(WatchConfig c) => new(StringComparer.Ordinal)
    {
        ["RefreshSeconds"] = c.RefreshSeconds.ToString(CultureInfo.InvariantCulture),
        ["TopN"] = c.TopN.ToString(CultureInfo.InvariantCulture),
        ["SamplePerPattern"] = c.SamplePerPattern.ToString(CultureInfo.InvariantCulture),
        ["SampleMaxChars"] = c.SampleMaxChars.ToString(CultureInfo.InvariantCulture),
        ["BacFlapMin"] = c.BacFlapMin.ToString(CultureInfo.InvariantCulture),
        ["DefaultSeverities"] = string.Join(",", c.DefaultSeverities),
        ["DefaultAreas"] = string.Join(",", c.DefaultAreas),
        ["DefaultWindowMinutes"] = c.DefaultWindowMinutes.ToString(CultureInfo.InvariantCulture),
        ["DefaultWindowEntire"] = c.DefaultWindowEntire ? "True" : "False",
        ["LogPath"] = c.LogPath
    };

    private static bool TryParseInt(string text, int min, int max, out int value)
    {
        if (int.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out value) &&
            value >= min && value <= max)
            return true;
        value = 0;
        return false;
    }

    private static bool IsValidBrowser(string text)
    {
        if (string.IsNullOrWhiteSpace(text))
            return false;
        var t = text.Trim();
        var low = t.ToLowerInvariant();
        if (low is "default" or "chrome" or "msedge" or "edge")
            return true;
        return File.Exists(t);
    }

    private void Warn(string message) => _warn?.Invoke(message);
}
