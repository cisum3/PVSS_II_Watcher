using System.Text.RegularExpressions;

namespace DesigoLogWatcher;

/// <summary>
/// Port of Build-LifecycleRows / Build-ProjectLifecycleObject / Format-DurationLabel
/// from Watch-PvssLog.ps1.
/// </summary>
public static class LifecycleBuilder
{
    public static Dictionary<string, object?> BuildLifecycleRows(AnalysisState data, string matchPattern = ".")
    {
        Regex re;
        try { re = new Regex(matchPattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant); }
        catch { re = new Regex(".", RegexOptions.CultureInvariant); }

        var keys = new HashSet<string>(StringComparer.Ordinal);
        void AddKeys(Dictionary<string, int> map)
        {
            foreach (var k in map.Keys)
                if (re.IsMatch(k)) keys.Add(k);
        }
        AddKeys(data.MgrStartByComp);
        AddKeys(data.MgrStopByComp);
        AddKeys(data.PmonRestartByComp);
        AddKeys(data.BlockingByComp);
        AddKeys(data.UnblockingByComp);

        var rows = keys
            .Select(name => new Dictionary<string, object?>
            {
                ["name"] = name,
                ["starts"] = data.MgrStartByComp.GetValueOrDefault(name),
                ["stops"] = data.MgrStopByComp.GetValueOrDefault(name),
                ["restarts"] = data.PmonRestartByComp.GetValueOrDefault(name),
                ["blocking"] = data.BlockingByComp.GetValueOrDefault(name),
                ["unblocked"] = data.UnblockingByComp.GetValueOrDefault(name)
            })
            .OrderByDescending(r =>
                Convert.ToInt32(r["blocking"]) + Convert.ToInt32(r["restarts"]) +
                Convert.ToInt32(r["starts"]) + Convert.ToInt32(r["stops"]))
            .ThenBy(r => (string)r["name"]!, StringComparer.Ordinal)
            .ToList();

        var tot = new Dictionary<string, object?>
        {
            ["starts"] = 0, ["stops"] = 0, ["restarts"] = 0, ["blocking"] = 0, ["unblocked"] = 0
        };
        foreach (var r in rows)
        {
            tot["starts"] = Convert.ToInt32(tot["starts"]) + Convert.ToInt32(r["starts"]);
            tot["stops"] = Convert.ToInt32(tot["stops"]) + Convert.ToInt32(r["stops"]);
            tot["restarts"] = Convert.ToInt32(tot["restarts"]) + Convert.ToInt32(r["restarts"]);
            tot["blocking"] = Convert.ToInt32(tot["blocking"]) + Convert.ToInt32(r["blocking"]);
            tot["unblocked"] = Convert.ToInt32(tot["unblocked"]) + Convert.ToInt32(r["unblocked"]);
        }

        return new Dictionary<string, object?>
        {
            ["totals"] = tot,
            ["managers"] = rows.ToArray()
        };
    }

    public static Dictionary<string, object?> BuildProjectLifecycle(
        AnalysisState data,
        IEnumerable<ProjectRestartEvent>? events = null,
        string? windowFirst = null,
        string? windowLast = null)
    {
        var evs = (events ?? data.ProjectRestartEvents)
            .Select(e => new Dictionary<string, object?>
            {
                ["t"] = e.T,
                ["kind"] = e.Kind,
                ["area"] = e.Area
            })
            .ToList();
        var cycles = BuildProjectLifecycleCycles(evs, windowFirst ?? data.FirstTs, windowLast ?? data.LastTs);
        var retained = data.ProjectRestartEvents.Count > 0 ? data.ProjectRestartEvents.Count : evs.Count;
        return new Dictionary<string, object?>
        {
            ["up"] = data.ProjectUp,
            ["stopped"] = data.ProjectStopped,
            ["shutdown"] = data.ProjectShutdown,
            ["startMode"] = data.ProjectStartMode,
            ["cycles"] = cycles,
            ["capped"] = (data.ProjectUp + data.ProjectStopped + data.ProjectShutdown) > retained
        };
    }

    public static List<Dictionary<string, object?>> BuildProjectLifecycleCycles(
        IReadOnlyList<Dictionary<string, object?>> events,
        string? windowFirst,
        string? windowLast)
    {
        var evs = events
            .OrderBy(e => e["t"]?.ToString() ?? "", StringComparer.Ordinal)
            .ThenBy(e => e["kind"]?.ToString() ?? "", StringComparer.Ordinal)
            .ToList();
        if (evs.Count == 0) return [];

        var cycles = new List<Dictionary<string, object?>>();
        var upIdx = new List<int>();
        for (var i = 0; i < evs.Count; i++)
            if (string.Equals(evs[i]["kind"]?.ToString(), "up", StringComparison.Ordinal))
                upIdx.Add(i);

        var firstUp = upIdx.Count > 0 ? upIdx[0] : evs.Count;
        Dictionary<string, object?>? leadShutdown = null;
        Dictionary<string, object?>? leadStopped = null;
        for (var i = 0; i < firstUp; i++)
        {
            var k = evs[i]["kind"]?.ToString() ?? "";
            if (k == "shutdown" && leadShutdown is null) leadShutdown = evs[i];
            else if (k == "stopped" && leadStopped is null) leadStopped = evs[i];
        }
        if (leadShutdown is not null || leadStopped is not null)
        {
            var shutdownT = leadShutdown?["t"]?.ToString();
            var stoppedT = leadStopped?["t"]?.ToString();
            var nextUpT = upIdx.Count > 0 ? evs[upIdx[0]]["t"]?.ToString() : null;
            cycles.Add(CycleRow(windowFirst, upImplied: true, shutdownT, stoppedT, nextUpT, windowLast, stillUp: false));
        }

        for (var u = 0; u < upIdx.Count; u++)
        {
            var ui = upIdx[u];
            var upT = evs[ui]["t"]?.ToString();
            var end = (u + 1) < upIdx.Count ? upIdx[u + 1] : evs.Count;
            string? shutdownT = null;
            string? stoppedT = null;
            for (var j = ui + 1; j < end; j++)
            {
                var k = evs[j]["kind"]?.ToString() ?? "";
                if (k == "shutdown" && shutdownT is null) shutdownT = evs[j]["t"]?.ToString();
                else if (k == "stopped" && stoppedT is null) stoppedT = evs[j]["t"]?.ToString();
            }
            var nextUpT = (u + 1) < upIdx.Count ? evs[upIdx[u + 1]]["t"]?.ToString() : null;
            var stillUp = shutdownT is null;
            cycles.Add(CycleRow(upT, upImplied: false, shutdownT, stoppedT, nextUpT, windowLast, stillUp));
        }

        return cycles;
    }

    private static Dictionary<string, object?> CycleRow(
        string? upT, bool upImplied, string? shutdownT, string? stoppedT,
        string? nextUpT, string? windowLast, bool stillUp)
    {
        double? uptimeSec = null;
        if (shutdownT is not null)
            uptimeSec = DeltaSec(upT, shutdownT);
        else if (stillUp && nextUpT is null && windowLast is not null)
            uptimeSec = DeltaSec(upT, windowLast);

        double? stopSec = shutdownT is not null && stoppedT is not null
            ? DeltaSec(shutdownT, stoppedT) : null;
        double? downSec = stoppedT is not null && nextUpT is not null
            ? DeltaSec(stoppedT, nextUpT) : null;
        var stillDown = stoppedT is not null && nextUpT is null;

        return new Dictionary<string, object?>
        {
            ["up"] = upT,
            ["upImplied"] = upImplied,
            ["shutdown"] = shutdownT,
            ["stopped"] = stoppedT,
            ["nextUp"] = nextUpT,
            ["uptimeSec"] = uptimeSec,
            ["uptime"] = FormatDurationLabel(uptimeSec),
            ["stopSec"] = stopSec,
            ["stopDuration"] = FormatDurationLabel(stopSec),
            ["downtimeSec"] = downSec,
            ["downtime"] = FormatDurationLabel(downSec),
            ["stillUp"] = stillUp,
            ["stillDown"] = stillDown
        };
    }

    public static double? DeltaSec(string? fromTs, string? toTs)
    {
        var a = ChartSeriesBuilder.TryParseLogTs(fromTs);
        var b = ChartSeriesBuilder.TryParseLogTs(toTs);
        if (a is null || b is null) return null;
        return (b.Value - a.Value).TotalSeconds;
    }

    public static string FormatDurationLabel(double? seconds)
    {
        if (seconds is null) return "";
        var s = (int)Math.Round(seconds.Value);
        if (s < 0) return "";
        if (s < 60) return $"{s}s";
        var m = s / 60;
        var r = s % 60;
        if (m < 60) return r == 0 ? $"{m}m" : $"{m}m {r}s";
        var h = m / 60;
        var m2 = m % 60;
        if (h < 48) return m2 == 0 ? $"{h}h" : $"{h}h {m2}m";
        var d = h / 24;
        var h2 = h % 24;
        return h2 == 0 ? $"{d}d" : $"{d}d {h2}h";
    }

    public static List<Dictionary<string, object?>> RuleTopBucket(
        AnalysisState data, string id, string bucketName, string keyName, int n)
    {
        if (!data.HitBuckets.TryGetValue(id, out var idb) || !idb.TryGetValue(bucketName, out var map))
            return [];
        return map.OrderByDescending(kv => kv.Value)
            .ThenBy(kv => kv.Key, StringComparer.Ordinal)
            .Take(n)
            .Select(kv => new Dictionary<string, object?> { [keyName] = kv.Key, ["count"] = kv.Value })
            .ToList();
    }

    public static List<Dictionary<string, object?>> CountNameTop(
        IReadOnlyDictionary<string, int> map, string nameKey, int n) =>
        map.OrderByDescending(kv => kv.Value)
            .ThenBy(kv => kv.Key, StringComparer.Ordinal)
            .Take(n)
            .Select(kv => new Dictionary<string, object?> { [nameKey] = kv.Key, ["count"] = kv.Value })
            .ToList();
}
