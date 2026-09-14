using System.Text.RegularExpressions;

namespace DesigoLogWatcher;

public enum MeasureAgg
{
    Sum,
    Max
}

public sealed class BucketSpec
{
    /// <summary>Capture group index, or "$component" / "$area" / "$severity".</summary>
    public object Group { get; init; } = 1;
    public string? TrimEnd { get; init; }
}

public sealed class MeasureSpec
{
    public int Group { get; init; }
    public MeasureAgg Agg { get; init; } = MeasureAgg.Sum;
}

/// <summary>§9.2 gate: DevGate = 0.4 single-scope parity; ShipGate = §2.1 exceptions on.</summary>
public enum RuleGateMode
{
    DevGate,
    ShipGate
}

/// <summary>One row from PvssRules.ps1 (Scope and/or Scopes for §2.1 multi-scope).</summary>
public sealed class RuleDefinition
{
    public required string Id { get; init; }
    public required string Group { get; init; }
    public required string Label { get; init; }
    public required Regex Re { get; init; }
    /// <summary>Single component substring gate (0.4 Register-RuleSet).</summary>
    public string? Scope { get; init; }
    /// <summary>Multi-scope list; when set, replaces <see cref="Scope"/> for matching.</summary>
    public IReadOnlyList<string>? Scopes { get; init; }
    public Dictionary<string, BucketSpec>? BucketBy { get; init; }
    public Dictionary<string, MeasureSpec>? Measure { get; init; }
    public bool Sample { get; init; }
    public string? SampleSlot { get; init; }
    public string? PatternGroup { get; init; }
    public int? FindingAt { get; init; }

    public bool MatchesComponent(string comp)
    {
        if (Scopes is { Count: > 0 })
        {
            foreach (var s in Scopes)
            {
                if (comp.IndexOf(s, StringComparison.OrdinalIgnoreCase) >= 0)
                    return true;
            }
            return false;
        }

        if (Scope is not null)
            return comp.IndexOf(Scope, StringComparison.OrdinalIgnoreCase) >= 0;
        return true;
    }
}

/// <summary>
/// Data-driven rule engine (PvssRules.ps1 Add-RuleHit / Register-RuleSet).
/// Default rule table is ShipGate (§2.1); pass DevGate rules for 0.4 parity runs.
/// </summary>
public sealed class RuleEngine : IRuleHitSink
{
    public const int BucketCap = 2000;

    private readonly IReadOnlyList<RuleDefinition> _rules;
    private readonly Dictionary<string, RuleDefinition[]> _cache = new(StringComparer.Ordinal);

    public RuleEngine(IReadOnlyList<RuleDefinition>? rules = null)
    {
        _rules = rules ?? DesigoLogWatcher.Rules.RuleDefinitions.ForGate(RuleGateMode.ShipGate);
    }

    public RuleEngine(RuleGateMode gate)
        : this(DesigoLogWatcher.Rules.RuleDefinitions.ForGate(gate))
    {
    }

    public IReadOnlyList<RuleDefinition> Rules => _rules;

    public bool ApplyRules(AnalysisState data, string line, string comp, string area, string sev, string timestamp)
    {
        var set = GetRuleSet(comp);
        var cns = false;
        foreach (var rule in set)
        {
            var m = rule.Re.Match(line);
            if (!m.Success) continue;
            AddRuleHit(data, rule, m, line, comp, area, sev, timestamp);
            if (string.Equals(rule.PatternGroup, "Cns", StringComparison.OrdinalIgnoreCase))
                cns = true;
        }
        return cns;
    }

    public RuleDefinition[] GetRuleSet(string comp)
    {
        if (_cache.TryGetValue(comp, out var cached))
            return cached;

        var list = new List<RuleDefinition>();
        foreach (var r in _rules)
        {
            if (!r.MatchesComponent(comp))
                continue;
            list.Add(r);
        }
        var arr = list.ToArray();
        _cache[comp] = arr;
        return arr;
    }

    public static void AddRuleHit(
        AnalysisState data, RuleDefinition rule, Match match,
        string line, string comp, string area, string sev, string timestamp)
    {
        var id = rule.Id;
        data.Hits.TryGetValue(id, out var hc);
        data.Hits[id] = hc + 1;

        if (!data.HitSevs.TryGetValue(id, out var sm))
            data.HitSevs[id] = sm = new Dictionary<string, int>(StringComparer.Ordinal);
        sm.TryGetValue(sev, out var sc);
        sm[sev] = sc + 1;

        if (data.HitTime.TryGetValue(id, out var ht))
            data.HitTime[id] = new PatternTimeBounds(ht.First, timestamp);
        else
            data.HitTime[id] = new PatternTimeBounds(timestamp, timestamp);

        if (rule.Sample)
        {
            var slot = string.IsNullOrEmpty(rule.SampleSlot) ? id : rule.SampleSlot!;
            if (!data.HitSample.ContainsKey(slot) || string.IsNullOrEmpty(data.HitSample[slot]))
                data.HitSample[slot] = line;
        }

        if (rule.BucketBy is { Count: > 0 } bb)
        {
            if (!data.HitBuckets.TryGetValue(id, out var idb))
                data.HitBuckets[id] = idb = new Dictionary<string, Dictionary<string, int>>(StringComparer.Ordinal);

            foreach (var (bname, spec) in bb)
            {
                var val = GetBucketValue(spec, match, comp, area, sev);
                if (val is null) continue;
                if (!idb.TryGetValue(bname, out var bm))
                    idb[bname] = bm = new Dictionary<string, int>(StringComparer.Ordinal);
                if (bm.TryGetValue(val, out var vc))
                    bm[val] = vc + 1;
                else if (bm.Count < BucketCap)
                    bm[val] = 1;
            }
        }

        if (rule.Measure is { Count: > 0 } mm)
        {
            if (!data.HitMeasures.TryGetValue(id, out var idm))
                data.HitMeasures[id] = idm = new Dictionary<string, long>(StringComparer.Ordinal);

            foreach (var (mname, spec) in mm)
            {
                if (match.Groups.Count <= spec.Group) continue;
                var g = match.Groups[spec.Group];
                if (!g.Success) continue;
                if (!double.TryParse(g.Value, System.Globalization.NumberStyles.Float,
                        System.Globalization.CultureInfo.InvariantCulture, out var num))
                    continue;
                var asLong = (long)num;
                if (!idm.TryGetValue(mname, out var cur))
                    idm[mname] = asLong;
                else if (spec.Agg == MeasureAgg.Max)
                {
                    if (asLong > cur) idm[mname] = asLong;
                }
                else
                    idm[mname] = cur + asLong;
            }
        }
    }

    public static int GetRuleCount(AnalysisState data, string id) =>
        data.Hits.TryGetValue(id, out var n) ? n : 0;

    public static string? GetRuleSample(AnalysisState data, string id) =>
        data.HitSample.TryGetValue(id, out var s) ? s : null;

    public static int GetRuleBucketCount(AnalysisState data, string id, string name)
    {
        if (!data.HitBuckets.TryGetValue(id, out var idb)) return 0;
        return idb.TryGetValue(name, out var bm) ? bm.Count : 0;
    }

    private static string? GetBucketValue(BucketSpec spec, Match match, string comp, string area, string sev)
    {
        string? val = null;
        if (spec.Group is string s)
        {
            val = s switch
            {
                "$component" => comp,
                "$area" => area,
                "$severity" => sev,
                _ => null
            };
        }
        else
        {
            var gi = Convert.ToInt32(spec.Group);
            if (match.Groups.Count > gi)
            {
                var g = match.Groups[gi];
                if (g.Success) val = g.Value.Trim();
            }
        }

        if (string.IsNullOrWhiteSpace(val)) return null;
        if (!string.IsNullOrEmpty(spec.TrimEnd))
            val = val.TrimEnd(spec.TrimEnd.ToCharArray());
        return string.IsNullOrWhiteSpace(val) ? null : val;
    }
}
