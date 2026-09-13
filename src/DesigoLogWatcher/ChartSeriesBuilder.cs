using System.Collections.Specialized;
using System.Globalization;
using System.Net;
using System.Text;

namespace DesigoLogWatcher;

/// <summary>
/// Port of Build-ChartSeries / Reduce-SeriesPoints / Build-HourlyObject / SVG chart helpers
/// from Watch-PvssLog.ps1.
/// </summary>
public static class ChartSeriesBuilder
{
    private static readonly string[] SevKeys = ["FATAL", "SEVERE", "ERROR", "WARNING", "INFO"];
    private static readonly string[] AreaKeys = ["SYS", "IMPL", "CTRL", "PARAM", "OTHER"];

    public enum ReduceAggregate { Max, MaxBac, Sum }

    public static Dictionary<string, bool> ParseSevFilter(NameValueCollection? q)
    {
        // Match Parse-QuerySevs: missing query → INFO off; present query → only listed on.
        var all = SevKeys.ToDictionary(s => s, _ => false, StringComparer.Ordinal);
        var raw = q?["severities"];
        if (string.IsNullOrWhiteSpace(raw))
        {
            foreach (var s in new[] { "FATAL", "SEVERE", "ERROR", "WARNING" })
                all[s] = true;
            return all;
        }
        foreach (var part in raw.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var p = part.ToUpperInvariant();
            if (all.ContainsKey(p)) all[p] = true;
        }
        return all;
    }

    public static Dictionary<string, bool> ParseAreaFilter(NameValueCollection? q)
    {
        var all = AreaKeys.ToDictionary(a => a, _ => false, StringComparer.Ordinal);
        var raw = q?["areas"];
        if (string.IsNullOrWhiteSpace(raw))
        {
            foreach (var a in AreaKeys) all[a] = true;
            return all;
        }
        foreach (var part in raw.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var p = part.ToUpperInvariant();
            if (all.ContainsKey(p)) all[p] = true;
        }
        return all;
    }

    public static Dictionary<string, bool> AllSevOn() =>
        SevKeys.ToDictionary(s => s, _ => true, StringComparer.Ordinal);

    /// <summary>UI / pulse default: INFO off.</summary>
    public static Dictionary<string, bool> DefaultSevFilter() =>
        SevKeys.ToDictionary(s => s, s => s != "INFO", StringComparer.Ordinal);

    public static Dictionary<string, bool> AllAreaOn() =>
        AreaKeys.ToDictionary(a => a, _ => true, StringComparer.Ordinal);

    public static Dictionary<string, bool> SevFilterFromList(IEnumerable<string> list)
    {
        var set = new HashSet<string>(list, StringComparer.OrdinalIgnoreCase);
        return SevKeys.ToDictionary(s => s, s => set.Contains(s), StringComparer.Ordinal);
    }

    public static Dictionary<string, bool> AreaFilterFromList(IEnumerable<string> list)
    {
        var set = new HashSet<string>(list, StringComparer.OrdinalIgnoreCase);
        return AreaKeys.ToDictionary(a => a, a => set.Contains(a), StringComparer.Ordinal);
    }

    public static bool AreaFilterAllOn(IReadOnlyDictionary<string, bool> areaFilter) =>
        AreaKeys.All(a => areaFilter.TryGetValue(a, out var on) && on);

    public static IEnumerable<string> EnabledAreas(IReadOnlyDictionary<string, bool> areaFilter) =>
        AreaKeys.Where(a => areaFilter.TryGetValue(a, out var on) && on);

    public static string GetGranularity(string? firstTs, string? lastTs, int minuteBucketCount)
    {
        var dtFirst = TryParseLogTs(firstTs);
        var dtLast = TryParseLogTs(lastTs);
        if (dtFirst is DateTime f && dtLast is DateTime l && l >= f)
        {
            var hours = (l - f).TotalHours;
            if (hours <= 6) return "minute";
            if (hours <= 14 * 24) return "hour";
            return "day";
        }
        if (minuteBucketCount > 2000) return "day";
        if (minuteBucketCount > 400) return "hour";
        return "minute";
    }

    public static DateTime? TryParseLogTs(string? ts)
    {
        if (string.IsNullOrWhiteSpace(ts)) return null;
        var formats = new[]
        {
            "yyyy.MM.dd HH:mm:ss.fff", "yyyy.MM.dd HH:mm:ss", "yyyy.MM.dd HH:mm", "yyyy.MM.dd"
        };
        if (DateTime.TryParseExact(ts.Trim(), formats, CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeLocal | DateTimeStyles.AllowWhiteSpaces, out var dt))
            return dt;
        return null;
    }

    public static Dictionary<string, object?> Build(
        AnalysisState data,
        IReadOnlyDictionary<string, bool>? sevFilter = null,
        IReadOnlyDictionary<string, bool>? areaFilter = null)
    {
        sevFilter ??= AllSevOn();
        areaFilter ??= AllAreaOn();

        var gran = GetGranularity(data.FirstTs, data.LastTs, data.ByMinute.Count);
        if (gran == "minute" && data.ByMinute.Count > 400) gran = "hour";

        var acc = new Dictionary<string, MinuteBucket>(StringComparer.Ordinal);
        var useAreaSplit = !AreaFilterAllOn(areaFilter);
        var enabled = EnabledAreas(areaFilter).ToArray();

        if (useAreaSplit && data.ByMinuteByArea.Count > 0)
        {
            foreach (var (src, byArea) in data.ByMinuteByArea)
            {
                var key = TruncateKey(src, gran);
                if (!acc.TryGetValue(key, out var dst))
                    acc[key] = dst = new MinuteBucket();
                foreach (var a in enabled)
                {
                    if (!byArea.TryGetValue(a, out var v)) continue;
                    dst.AddFrom(v);
                }
            }
        }
        else
        {
            foreach (var (src, v) in data.ByMinute)
            {
                var key = TruncateKey(src, gran);
                if (!acc.TryGetValue(key, out var dst))
                    acc[key] = dst = new MinuteBucket();
                dst.AddFrom(v);
            }
        }

        var rows = acc.OrderBy(kv => kv.Key, StringComparer.Ordinal)
            .Select(kv => RowFromBucket(kv.Key, kv.Value, sevFilter))
            .ToArray();

        return new Dictionary<string, object?>
        {
            ["granularity"] = gran,
            ["byMinute"] = rows,
            ["projectUp"] = data.ProjectUp,
            ["projectStopped"] = data.ProjectStopped
        };
    }

    public static Dictionary<string, object?> BuildHourly(
        AnalysisState data,
        IReadOnlyDictionary<string, bool>? areaFilter = null)
    {
        areaFilter ??= AllAreaOn();
        var acc = new Dictionary<string, (int Total, int Severe, int Warning)>(StringComparer.Ordinal);
        var useAreaSplit = !AreaFilterAllOn(areaFilter);
        var enabled = EnabledAreas(areaFilter).ToArray();

        void AddBucket(string src, MinuteBucket v)
        {
            var key = src.Length >= 13 ? src[..13] : src;
            acc.TryGetValue(key, out var cur);
            var total = cur.Total + v.Fatal + v.Severe + v.Error + v.Warning + v.Info;
            var severe = cur.Severe + v.Fatal + v.Severe + v.Error;
            var warning = cur.Warning + v.Warning;
            acc[key] = (total, severe, warning);
        }

        if (useAreaSplit && data.ByMinuteByArea.Count > 0)
        {
            foreach (var (src, byArea) in data.ByMinuteByArea)
            {
                foreach (var a in enabled)
                {
                    if (!byArea.TryGetValue(a, out var v)) continue;
                    AddBucket(src, v);
                }
            }
        }
        else
        {
            foreach (var (src, v) in data.ByMinute)
                AddBucket(src, v);
        }

        var keys = acc.Keys.OrderBy(k => k, StringComparer.Ordinal).ToArray();
        var hourCount = keys.Length;
        var truncated = hourCount > 25;
        var shown = truncated ? keys.TakeLast(24).ToArray() : keys;
        var rows = shown.Select(k => new Dictionary<string, object?>
        {
            ["hour"] = k,
            ["total"] = acc[k].Total,
            ["severe"] = acc[k].Severe,
            ["warning"] = acc[k].Warning
        }).ToArray();

        object[] busiest = [];
        if (truncated)
        {
            busiest = acc.OrderByDescending(kv => kv.Value.Total)
                .ThenBy(kv => kv.Key, StringComparer.Ordinal)
                .Take(10)
                .Select(kv => (object)new Dictionary<string, object?>
                {
                    ["hour"] = kv.Key,
                    ["total"] = kv.Value.Total,
                    ["severe"] = kv.Value.Severe,
                    ["warning"] = kv.Value.Warning
                }).ToArray();
        }

        return new Dictionary<string, object?>
        {
            ["hourCount"] = hourCount,
            ["truncated"] = truncated,
            ["rows"] = rows,
            ["busiest"] = busiest
        };
    }

    public static List<Dictionary<string, object?>> ReduceSeriesPoints(
        IReadOnlyList<Dictionary<string, object?>> points,
        int maxBars = 60,
        ReduceAggregate aggregate = ReduceAggregate.Max)
    {
        if (points.Count <= maxBars || maxBars < 2)
            return points.ToList();

        var group = (int)Math.Ceiling(points.Count / (double)maxBars);
        if (group < 1) group = 1;
        var output = new List<Dictionary<string, object?>>();

        for (var i = 0; i < points.Count; i += group)
        {
            var end = Math.Min(i + group - 1, points.Count - 1);
            var chunk = points.Skip(i).Take(end - i + 1).ToList();
            if (aggregate is ReduceAggregate.Max or ReduceAggregate.MaxBac)
            {
                Dictionary<string, object?> best = chunk[0];
                var bestScore = -1;
                foreach (var row in chunk)
                {
                    var score = aggregate == ReduceAggregate.MaxBac
                        ? Int(row, "bacFailed") + Int(row, "bacOk")
                        : SevKeys.Sum(s => Int(row, s));
                    if (score > bestScore)
                    {
                        bestScore = score;
                        best = row;
                    }
                }
                var hadRestart = chunk.Any(r => Int(r, "projectRestart") > 0) ? 1 : 0;
                output.Add(new Dictionary<string, object?>
                {
                    ["t"] = best["t"]?.ToString() ?? "",
                    ["FATAL"] = Int(best, "FATAL"),
                    ["SEVERE"] = Int(best, "SEVERE"),
                    ["ERROR"] = Int(best, "ERROR"),
                    ["WARNING"] = Int(best, "WARNING"),
                    ["INFO"] = Int(best, "INFO"),
                    ["bacFailed"] = Int(best, "bacFailed"),
                    ["bacOk"] = Int(best, "bacOk"),
                    ["projectRestart"] = hadRestart
                });
                continue;
            }

            var mid = chunk[(chunk.Count - 1) / 2];
            var agg = new Dictionary<string, object?>
            {
                ["t"] = mid["t"]?.ToString() ?? "",
                ["FATAL"] = 0, ["SEVERE"] = 0, ["ERROR"] = 0, ["WARNING"] = 0, ["INFO"] = 0,
                ["bacFailed"] = 0, ["bacOk"] = 0, ["projectRestart"] = 0
            };
            foreach (var row in chunk)
            {
                foreach (var k in SevKeys.Concat(["bacFailed", "bacOk"]))
                    agg[k] = Int(agg, k) + Int(row, k);
                if (Int(row, "projectRestart") > 0) agg["projectRestart"] = 1;
            }
            output.Add(agg);
        }
        return output;
    }

    public static (int Buckets, Dictionary<string, object?>? PeakVol, int PeakVolN,
        Dictionary<string, object?>? PeakBac, int PeakBacN) PeakSummary(
        IReadOnlyList<Dictionary<string, object?>> points)
    {
        Dictionary<string, object?>? peakVol = null;
        var peakVolN = -1;
        Dictionary<string, object?>? peakBac = null;
        var peakBacN = -1;
        foreach (var row in points)
        {
            var vol = SevKeys.Sum(s => Int(row, s));
            if (vol > peakVolN) { peakVolN = vol; peakVol = row; }
            var bf = Int(row, "bacFailed");
            if (bf > peakBacN) { peakBacN = bf; peakBac = row; }
        }
        return (points.Count, peakVol, Math.Max(0, peakVolN), peakBac, Math.Max(0, peakBacN));
    }

    public static string BuildVolumeSvg(
        IReadOnlyList<Dictionary<string, object?>> points, string gran = "minute",
        int width = 840, int height = 200)
    {
        var rawN = points.Count;
        var pts = ReduceSeriesPoints(points, 56, ReduceAggregate.Max);
        if (pts.Count == 0) return "<p class=\"muted\">No volume series.</p>";

        const int padL = 40, padR = 12, padT = 12, padB = 32;
        var plotW = width - padL - padR;
        var plotH = height - padT - padB;
        var maxY = 1;
        foreach (var row in pts)
        {
            var v = SevKeys.Sum(s => Int(row, s));
            if (v > maxY) maxY = v;
        }
        var n = pts.Count;
        var slot = plotW / (double)n;
        var barW = Math.Max(2.5, slot * 0.88);
        var colors = new Dictionary<string, string>
        {
            ["FATAL"] = "#e00000", ["SEVERE"] = "#c000a0", ["ERROR"] = "#b00040",
            ["WARNING"] = "#e07000", ["INFO"] = "#008000"
        };

        var sb = new StringBuilder();
        sb.Append(CultureInfo.InvariantCulture,
            $"<svg class=\"chart-svg\" viewBox=\"0 0 {width} {height}\" role=\"img\" aria-label=\"Message volume by bucket\">");
        sb.Append("<rect x=\"0\" y=\"0\" width=\"100%\" height=\"100%\" fill=\"#1c2834\"/>");
        AppendAxes(sb, padL, padR, padT, padB, width, height, maxY, pts, gran);

        for (var i = 0; i < n; i++)
        {
            var row = pts[i];
            var x = padL + i * slot + (slot - barW) / 2.0;
            double yBase = padT + plotH;
            foreach (var s in SevKeys)
            {
                var c = Int(row, s);
                if (c <= 0) continue;
                var h = (c / (double)maxY) * plotH;
                if (h is > 0 and < 1.0) h = 1.0;
                yBase -= h;
                sb.Append(CultureInfo.InvariantCulture,
                    $"<rect x=\"{x:0.##}\" y=\"{yBase:0.##}\" width=\"{barW:0.##}\" height=\"{h:0.##}\" fill=\"{colors[s]}\"/>");
            }
        }
        for (var i = 0; i < n; i++)
        {
            if (Int(pts[i], "projectRestart") <= 0) continue;
            var x = padL + i * slot + slot / 2.0;
            sb.Append(CultureInfo.InvariantCulture,
                $"<line x1=\"{x:0.##}\" y1=\"{padT}\" x2=\"{x:0.##}\" y2=\"{padT + plotH}\" stroke=\"#e0a000\" stroke-width=\"2\" stroke-dasharray=\"4 3\" opacity=\"0.9\"/>");
        }
        if (rawN > pts.Count)
            sb.Append(CultureInfo.InvariantCulture,
                $"<text x=\"{width - padR}\" y=\"14\" fill=\"#879baa\" font-size=\"9\" text-anchor=\"end\">display {pts.Count}/{rawN} (peak-preserving)</text>");
        sb.Append("</svg>");
        return sb.ToString();
    }

    public static string BuildBacnetSvg(
        IReadOnlyList<Dictionary<string, object?>> points, string gran = "minute",
        int width = 840, int height = 200)
    {
        var rawN = points.Count;
        var pts = ReduceSeriesPoints(points, 120, ReduceAggregate.MaxBac);
        if (pts.Count == 0) return "<p class=\"muted\">No BACnet series.</p>";

        const int padL = 40, padR = 12, padT = 12, padB = 32;
        var plotW = width - padL - padR;
        var plotH = height - padT - padB;
        var maxY = 1;
        foreach (var row in pts)
        {
            var v = Math.Max(Int(row, "bacFailed"), Int(row, "bacOk"));
            if (v > maxY) maxY = v;
        }
        var n = pts.Count;
        var slot = plotW / (double)n;
        var sb = new StringBuilder();
        sb.Append(CultureInfo.InvariantCulture,
            $"<svg class=\"chart-svg\" viewBox=\"0 0 {width} {height}\" role=\"img\" aria-label=\"BACnet Failed and OK by bucket\">");
        sb.Append("<rect x=\"0\" y=\"0\" width=\"100%\" height=\"100%\" fill=\"#1c2834\"/>");
        AppendAxes(sb, padL, padR, padT, padB, width, height, maxY, pts, gran);

        var failPts = new List<string>(n);
        var okPts = new List<string>(n);
        for (var i = 0; i < n; i++)
        {
            var row = pts[i];
            var x = padL + i * slot + slot / 2.0;
            var yf = padT + plotH - (Int(row, "bacFailed") / (double)maxY) * plotH;
            var yo = padT + plotH - (Int(row, "bacOk") / (double)maxY) * plotH;
            failPts.Add(string.Create(CultureInfo.InvariantCulture, $"{x:0.##},{yf:0.##}"));
            okPts.Add(string.Create(CultureInfo.InvariantCulture, $"{x:0.##},{yo:0.##}"));
        }
        // Match dashboard: Failed drawn last (on top). OK underneath.
        sb.Append(CultureInfo.InvariantCulture,
            $"<polyline fill=\"none\" stroke=\"#008000\" stroke-width=\"2\" stroke-linejoin=\"round\" stroke-linecap=\"round\" points=\"{string.Join(' ', okPts)}\"/>");
        sb.Append(CultureInfo.InvariantCulture,
            $"<polyline fill=\"none\" stroke=\"#c000a0\" stroke-width=\"2\" stroke-linejoin=\"round\" stroke-linecap=\"round\" points=\"{string.Join(' ', failPts)}\"/>");
        for (var i = 0; i < n; i++)
        {
            if (Int(pts[i], "projectRestart") <= 0) continue;
            var x = padL + i * slot + slot / 2.0;
            sb.Append(CultureInfo.InvariantCulture,
                $"<line x1=\"{x:0.##}\" y1=\"{padT}\" x2=\"{x:0.##}\" y2=\"{padT + plotH}\" stroke=\"#e0a000\" stroke-width=\"2\" stroke-dasharray=\"4 3\" opacity=\"0.9\"/>");
        }
        if (rawN > pts.Count)
            sb.Append(CultureInfo.InvariantCulture,
                $"<text x=\"{width - padR}\" y=\"14\" fill=\"#879baa\" font-size=\"9\" text-anchor=\"end\">display {pts.Count}/{rawN} (peak-preserving)</text>");
        sb.Append("</svg>");
        return sb.ToString();
    }

    private static void AppendAxes(
        StringBuilder sb, int padL, int padR, int padT, int padB,
        int width, int height, int maxY,
        IReadOnlyList<Dictionary<string, object?>> points, string gran)
    {
        var plotW = width - padL - padR;
        var plotH = height - padT - padB;
        var n = points.Count;
        foreach (var frac in new[] { 0.0, 0.5, 1.0 })
        {
            var y = padT + plotH * (1.0 - frac);
            var val = (int)Math.Round(maxY * frac);
            sb.Append(CultureInfo.InvariantCulture,
                $"<line x1=\"{padL}\" y1=\"{y:0.##}\" x2=\"{width - padR}\" y2=\"{y:0.##}\" stroke=\"rgba(135,155,170,0.25)\" stroke-width=\"1\"/>");
            sb.Append(CultureInfo.InvariantCulture,
                $"<text x=\"{padL - 4}\" y=\"{y:0.##}\" fill=\"#879baa\" font-size=\"10\" text-anchor=\"end\" dominant-baseline=\"middle\">{val}</text>");
        }
        if (n < 1) return;
        var slot = plotW / (double)n;
        var labelIdx = new List<int> { 0 };
        if (n > 2) labelIdx.Add((n - 1) / 2);
        if (n > 1) labelIdx.Add(n - 1);
        foreach (var i in labelIdx.Distinct())
        {
            var x = padL + i * slot + slot / 2.0;
            var label = WebUtility.HtmlEncode(FormatAxisLabel(points[i]["t"]?.ToString() ?? "", gran));
            var anchor = "middle";
            if (i == 0) { anchor = "start"; x = padL; }
            else if (i == n - 1) { anchor = "end"; x = width - padR; }
            sb.Append(CultureInfo.InvariantCulture,
                $"<text x=\"{x:0.##}\" y=\"{height - 10}\" fill=\"#aaaa96\" font-size=\"10\" text-anchor=\"{anchor}\">{label}</text>");
        }
    }

    public static string FormatAxisLabel(string t, string gran)
    {
        if (string.IsNullOrWhiteSpace(t)) return "";
        if (t.Contains("..", StringComparison.Ordinal))
            t = t.Split([".."], 2, StringSplitOptions.None)[0];
        return gran switch
        {
            "day" => t.Length >= 10 ? t[..10] : t,
            "hour" => t.Length >= 13 ? t.Substring(5, Math.Min(8, t.Length - 5)) : t,
            _ => t.Length >= 16 ? t.Substring(5, 11) : t
        };
    }

    private static string TruncateKey(string src, string gran) => gran switch
    {
        "day" => src.Length >= 10 ? src[..10] : src,
        "hour" => src.Length >= 13 ? src[..13] : src,
        _ => src
    };

    private static Dictionary<string, object?> RowFromBucket(
        string key, MinuteBucket v, IReadOnlyDictionary<string, bool> sevFilter)
    {
        var row = new Dictionary<string, object?>
        {
            ["t"] = key,
            ["bacFailed"] = v.BacFailed,
            ["bacOk"] = v.BacOk,
            ["projectRestart"] = v.ProjectRestart
        };
        foreach (var s in SevKeys)
            row[s] = sevFilter.TryGetValue(s, out var on) && on ? v.Get(s) : 0;
        return row;
    }

    public static int Int(Dictionary<string, object?> row, string key) =>
        row.TryGetValue(key, out var v) && v is not null ? Convert.ToInt32(v) : 0;
}
