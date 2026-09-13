namespace DesigoLogWatcher;

/// <summary>
/// Dashboard/report payload helpers: filtered counts, patterns, managers, detections
/// (parity with Watch-PvssLog.ps1 Get-Filtered* / Build-DetectionsObject / Build-ManagerObject).
/// </summary>
public static class ApiBuilders
{
    private static readonly string[] SevKeys = ["FATAL", "SEVERE", "ERROR", "WARNING", "INFO"];
    private static readonly string[] PatternSevs = ["FATAL", "SEVERE", "ERROR", "WARNING"];
    private static readonly HashSet<string> CuratedGroups = new(StringComparer.Ordinal)
        { "BACnet", "CNS", "CoHo", "Apogee" };
    private static readonly Dictionary<string, double> SevWeight = new(StringComparer.Ordinal)
    {
        ["FATAL"] = 4.0, ["SEVERE"] = 3.0, ["ERROR"] = 2.0, ["WARNING"] = 1.0, ["INFO"] = 0.25
    };
    private const int RuleMinSpanSec = 60;

    public static Dictionary<string, int> FilteredSeverityCounts(
        AnalysisState data, IReadOnlyDictionary<string, bool> areaFilter)
    {
        var sevCounts = SevKeys.ToDictionary(s => s, _ => 0, StringComparer.Ordinal);
        if (ChartSeriesBuilder.AreaFilterAllOn(areaFilter))
        {
            foreach (var s in SevKeys)
                if (data.Severity.TryGetValue(s, out var n)) sevCounts[s] = n;
            return sevCounts;
        }
        foreach (var a in ChartSeriesBuilder.EnabledAreas(areaFilter))
        {
            if (!data.SeverityByArea.TryGetValue(a, out var map)) continue;
            foreach (var s in SevKeys)
                if (map.TryGetValue(s, out var n)) sevCounts[s] += n;
        }
        return sevCounts;
    }

    public static List<Dictionary<string, object?>> FilteredTopManagers(
        AnalysisState data, IReadOnlyDictionary<string, bool> areaFilter, int n)
    {
        IEnumerable<KeyValuePair<string, int>> source;
        if (ChartSeriesBuilder.AreaFilterAllOn(areaFilter))
        {
            source = data.Components;
        }
        else
        {
            var acc = new Dictionary<string, int>(StringComparer.Ordinal);
            foreach (var a in ChartSeriesBuilder.EnabledAreas(areaFilter))
            {
                if (!data.ComponentsByArea.TryGetValue(a, out var map)) continue;
                foreach (var (k, v) in map)
                    acc[k] = acc.GetValueOrDefault(k) + v;
            }
            source = acc;
        }

        return source.OrderByDescending(kv => kv.Value).Take(n)
            .Select(kv => new Dictionary<string, object?>
            {
                ["name"] = kv.Key,
                ["count"] = kv.Value,
                ["severities"] = CompSevMap(data, kv.Key)
            }).ToList();
    }

    public static Dictionary<string, int> CompSevMap(AnalysisState data, string comp)
    {
        var m = SevKeys.ToDictionary(s => s, _ => 0, StringComparer.Ordinal);
        if (data.CompSev.TryGetValue(comp, out var cs))
            foreach (var kv in cs) m[kv.Key] = kv.Value;
        return m;
    }

    public static Dictionary<string, object?> FilteredPatternsBySeverity(
        AnalysisState data,
        IReadOnlyDictionary<string, bool> sevFilter,
        IReadOnlyDictionary<string, bool> areaFilter,
        int topN)
    {
        var result = new Dictionary<string, object?>();
        foreach (var s in PatternSevs)
        {
            if (!sevFilter.TryGetValue(s, out var on) || !on)
            {
                result[s] = Array.Empty<object>();
                continue;
            }
            result[s] = FilteredTopPatterns(data, s, areaFilter, topN).ToArray();
        }
        return result;
    }

    public static List<Dictionary<string, object?>> FilteredTopPatterns(
        AnalysisState data, string sev, IReadOnlyDictionary<string, bool> areaFilter, int n)
    {
        if (ChartSeriesBuilder.AreaFilterAllOn(areaFilter))
        {
            if (!data.PatternsBySev.TryGetValue(sev, out var map)) return [];
            return TopPatterns(map,
                data.PatternSampleBySev.GetValueOrDefault(sev),
                data.PatternTimeBySev.GetValueOrDefault(sev), n);
        }

        var count = new Dictionary<string, int>(StringComparer.Ordinal);
        var sample = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        var time = new Dictionary<string, PatternTimeBounds>(StringComparer.Ordinal);
        foreach (var a in ChartSeriesBuilder.EnabledAreas(areaFilter))
        {
            if (!data.PatternsByArea.TryGetValue(a, out var bySev)) continue;
            if (!bySev.TryGetValue(sev, out var cm)) continue;
            var sm = data.PatternSampleByArea.GetValueOrDefault(a)?.GetValueOrDefault(sev);
            var tm = data.PatternTimeByArea.GetValueOrDefault(a)?.GetValueOrDefault(sev);
            foreach (var (k, v) in cm)
            {
                count[k] = count.GetValueOrDefault(k) + v;
                if (sm is not null && sm.TryGetValue(k, out var samples))
                {
                    if (!sample.TryGetValue(k, out var list))
                        sample[k] = list = new List<string>();
                    foreach (var s in samples)
                    {
                        if (list.Count >= 5) break;
                        list.Add(s);
                    }
                }
                if (tm is not null && tm.TryGetValue(k, out var bounds))
                {
                    if (!time.TryGetValue(k, out var cur))
                        time[k] = bounds;
                    else
                    {
                        var first = string.CompareOrdinal(bounds.First, cur.First) < 0 ? bounds.First : cur.First;
                        var last = string.CompareOrdinal(bounds.Last, cur.Last) > 0 ? bounds.Last : cur.Last;
                        time[k] = new PatternTimeBounds(first, last);
                    }
                }
            }
        }
        return TopPatterns(count, sample, time, n);
    }

    public static List<Dictionary<string, object?>> TopPatterns(
        IReadOnlyDictionary<string, int>? countMap,
        IReadOnlyDictionary<string, List<string>>? sampleMap,
        IReadOnlyDictionary<string, PatternTimeBounds>? timeMap,
        int n)
    {
        if (countMap is null || countMap.Count == 0) return [];
        return countMap.OrderByDescending(kv => kv.Value).Take(n)
            .Select(kv =>
            {
                string? first = null, last = null;
                if (timeMap is not null && timeMap.TryGetValue(kv.Key, out var t))
                {
                    first = t.First;
                    last = t.Last;
                }
                var samples = sampleMap is not null && sampleMap.TryGetValue(kv.Key, out var s)
                    ? s.ToArray() : Array.Empty<string>();
                return new Dictionary<string, object?>
                {
                    ["pattern"] = kv.Key,
                    ["count"] = kv.Value,
                    ["first"] = first,
                    ["last"] = last,
                    ["samples"] = samples
                };
            }).ToList();
    }

    public static Dictionary<string, object?> BuildManagerPayload(
        AnalysisState data, string mgrName,
        IReadOnlyDictionary<string, bool> sevFilter,
        int topN, int generation,
        IReadOnlyDictionary<string, bool>? areaFilter = null)
    {
        areaFilter ??= ChartSeriesBuilder.AllAreaOn();
        var p = new Dictionary<string, object?>();
        foreach (var s in PatternSevs)
        {
            if (!(sevFilter.TryGetValue(s, out var on) && on))
            {
                p[s] = Array.Empty<object>();
                continue;
            }

            if (ChartSeriesBuilder.AreaFilterAllOn(areaFilter))
            {
                if (data.CompPatterns.TryGetValue(mgrName, out var bySev) && bySev.TryGetValue(s, out var map))
                {
                    p[s] = TopPatterns(map,
                        data.CompPatternSamples.GetValueOrDefault(mgrName)?.GetValueOrDefault(s),
                        data.CompPatternTimes.GetValueOrDefault(mgrName)?.GetValueOrDefault(s),
                        topN).ToArray();
                }
                else p[s] = Array.Empty<object>();
                continue;
            }

            var count = new Dictionary<string, int>(StringComparer.Ordinal);
            var sample = new Dictionary<string, List<string>>(StringComparer.Ordinal);
            var time = new Dictionary<string, PatternTimeBounds>(StringComparer.Ordinal);
            if (data.CompPatternsByArea.TryGetValue(mgrName, out var byArea))
            {
                foreach (var a in ChartSeriesBuilder.EnabledAreas(areaFilter))
                {
                    if (!byArea.TryGetValue(a, out var bySev) || !bySev.TryGetValue(s, out var cm)) continue;
                    var sm = data.CompPatternSamplesByArea.GetValueOrDefault(mgrName)?.GetValueOrDefault(a)?.GetValueOrDefault(s);
                    var tm = data.CompPatternTimesByArea.GetValueOrDefault(mgrName)?.GetValueOrDefault(a)?.GetValueOrDefault(s);
                    foreach (var (k, v) in cm)
                    {
                        count[k] = count.GetValueOrDefault(k) + v;
                        if (sm is not null && sm.TryGetValue(k, out var samples))
                        {
                            if (!sample.TryGetValue(k, out var list))
                                sample[k] = list = new List<string>();
                            foreach (var samp in samples)
                            {
                                if (list.Count >= 5) break;
                                list.Add(samp);
                            }
                        }
                        if (tm is not null && tm.TryGetValue(k, out var bounds))
                        {
                            if (!time.TryGetValue(k, out var cur))
                                time[k] = bounds;
                            else
                                time[k] = new PatternTimeBounds(
                                    string.CompareOrdinal(bounds.First, cur.First) < 0 ? bounds.First : cur.First,
                                    string.CompareOrdinal(bounds.Last, cur.Last) > 0 ? bounds.Last : cur.Last);
                        }
                    }
                }
            }
            p[s] = TopPatterns(count, sample, time, topN).ToArray();
        }

        var key = AnalysisState.NormalizeManagerKey(mgrName);
        var lifePat = "^" + System.Text.RegularExpressions.Regex.Escape(key) + "$";
        var countTotal = ChartSeriesBuilder.AreaFilterAllOn(areaFilter)
            ? data.Components.GetValueOrDefault(mgrName)
            : ChartSeriesBuilder.EnabledAreas(areaFilter)
                .Sum(a => data.ComponentsByArea.GetValueOrDefault(a)?.GetValueOrDefault(mgrName) ?? 0);
        return new Dictionary<string, object?>
        {
            ["generation"] = generation,
            ["name"] = mgrName,
            ["count"] = countTotal,
            ["severities"] = CompSevMap(data, mgrName),
            ["patternsBySeverity"] = p,
            ["lifecycle"] = LifecycleBuilder.BuildLifecycleRows(data, lifePat)
        };
    }

    /// <summary>Grouped detections for /api/section?name=detections and snapshot HTML.</summary>
    public static List<Dictionary<string, object?>> BuildDetectionsObject(
        AnalysisState data, IReadOnlyList<RuleDefinition> rules, int topN)
    {
        var order = new List<string>();
        var byGroup = new Dictionary<string, List<Dictionary<string, object?>>>(StringComparer.Ordinal);

        foreach (var r in rules)
        {
            if (CuratedGroups.Contains(r.Group)) continue;
            var id = r.Id;
            var count = RuleEngine.GetRuleCount(data, id);
            if (count <= 0) continue;

            var sevs = new Dictionary<string, object?>(StringComparer.Ordinal);
            if (data.HitSevs.TryGetValue(id, out var sm))
            {
                foreach (var s in SevKeys)
                    if (sm.TryGetValue(s, out var n)) sevs[s] = n;
                foreach (var k in sm.Keys.OrderBy(x => x, StringComparer.Ordinal))
                    if (!sevs.ContainsKey(k)) sevs[k] = sm[k];
            }

            var measures = new Dictionary<string, object?>(StringComparer.Ordinal);
            if (data.HitMeasures.TryGetValue(id, out var mm))
                foreach (var k in mm.Keys.OrderBy(x => x, StringComparer.Ordinal))
                    measures[k] = mm[k];

            var buckets = new Dictionary<string, object?>(StringComparer.Ordinal);
            if (data.HitBuckets.TryGetValue(id, out var idb))
            {
                foreach (var bname in idb.Keys.OrderBy(x => x, StringComparer.Ordinal))
                {
                    var map = idb[bname];
                    buckets[bname] = new Dictionary<string, object?>
                    {
                        ["distinct"] = map.Count,
                        ["capped"] = map.Count >= RuleEngine.BucketCap,
                        ["top"] = map.OrderByDescending(kv => kv.Value)
                            .ThenBy(kv => kv.Key, StringComparer.Ordinal)
                            .Take(topN)
                            .Select(kv => new Dictionary<string, object?>
                            {
                                ["value"] = kv.Key,
                                ["count"] = kv.Value
                            }).ToArray()
                    };
                }
            }

            data.HitTime.TryGetValue(id, out var t);
            var spanSec = (double)RuleMinSpanSec;
            if (!string.IsNullOrEmpty(t.First) && !string.IsNullOrEmpty(t.Last))
            {
                var a = ChartSeriesBuilder.TryParseLogTs(t.First);
                var b = ChartSeriesBuilder.TryParseLogTs(t.Last);
                if (a is DateTime da && b is DateTime db && db > da)
                    spanSec = Math.Max(RuleMinSpanSec, (db - da).TotalSeconds);
            }
            var rate = count / spanSec * 3600.0;

            var sevW = 1.0;
            if (sevs.Count > 0)
            {
                double wsum = 0; var n = 0;
                foreach (var (k, v) in sevs)
                {
                    var w = SevWeight.GetValueOrDefault(k, 1.0);
                    var c = Convert.ToInt32(v);
                    wsum += w * c;
                    n += c;
                }
                if (n > 0) sevW = wsum / n;
            }

            var findingAt = r.FindingAt ?? 0;
            var slot = string.IsNullOrEmpty(r.SampleSlot) ? id : r.SampleSlot!;
            var row = new Dictionary<string, object?>
            {
                ["id"] = id,
                ["label"] = r.Label,
                ["count"] = count,
                ["first"] = string.IsNullOrEmpty(t.First) ? null : t.First,
                ["last"] = string.IsNullOrEmpty(t.Last) ? null : t.Last,
                ["findingAt"] = findingAt,
                ["over"] = findingAt > 0 ? Math.Round(count / (double)findingAt, 2) : 0,
                ["spanSec"] = (int)Math.Round(spanSec),
                ["rate"] = Math.Round(rate, 1),
                ["score"] = Math.Round(rate * sevW, 1),
                ["sample"] = RuleEngine.GetRuleSample(data, slot),
                ["severities"] = sevs,
                ["measures"] = measures,
                ["buckets"] = buckets
            };

            if (!byGroup.TryGetValue(r.Group, out var list))
            {
                byGroup[r.Group] = list = new List<Dictionary<string, object?>>();
                order.Add(r.Group);
            }
            list.Add(row);
        }

        var groups = new List<Dictionary<string, object?>>();
        foreach (var g in order)
        {
            var rows = byGroup[g]
                .OrderByDescending(r => Convert.ToDouble(r["score"]))
                .ThenBy(r => (string)r["id"]!, StringComparer.Ordinal)
                .ToList();
            var total = rows.Sum(r => Convert.ToInt32(r["count"]));
            var top = rows.Count > 0 ? rows.Max(r => Convert.ToDouble(r["score"])) : 0.0;
            groups.Add(new Dictionary<string, object?>
            {
                ["group"] = g,
                ["total"] = total,
                ["score"] = top,
                ["rules"] = rows
            });
        }

        return groups
            .OrderByDescending(g => Convert.ToDouble(g["score"]))
            .ThenBy(g => (string)g["group"]!, StringComparer.Ordinal)
            .ToList();
    }

    /// <summary>Filter project restart events by area, then build cycle object (pulse/snapshot).</summary>
    public static Dictionary<string, object?> BuildProjectLifecycle(
        AnalysisState data, IReadOnlyDictionary<string, bool>? areaFilter = null)
    {
        IEnumerable<ProjectRestartEvent> events = data.ProjectRestartEvents;
        if (areaFilter is not null && !ChartSeriesBuilder.AreaFilterAllOn(areaFilter))
        {
            events = data.ProjectRestartEvents.Where(e =>
            {
                var a = string.IsNullOrEmpty(e.Area) ? "SYS" : e.Area;
                return areaFilter.TryGetValue(a, out var on) && on;
            });
        }
        return LifecycleBuilder.BuildProjectLifecycle(data, events, data.FirstTs, data.LastTs);
    }

    public static Dictionary<string, object?> BuildBacnetSection(AnalysisState data, int bacFlapMin, int topN)
    {
        var endedFailed = data.BacLastStatus.Count(kv => kv.Value == "Failed");
        var endedOk = data.BacLastStatus.Count(kv => kv.Value == "OK");
        var flappers = data.BacFlipByDevice.Count(kv => kv.Value >= bacFlapMin);
        var activity = data.BacFailedByDevice.OrderByDescending(kv => kv.Value).Take(20)
            .Select(kv =>
            {
                var id = kv.Key;
                return new Dictionary<string, object?>
                {
                    ["device"] = id,
                    ["failed"] = kv.Value,
                    ["ok"] = data.BacOkByDevice.GetValueOrDefault(id),
                    ["flips"] = data.BacFlipByDevice.GetValueOrDefault(id),
                    ["last"] = data.BacLastStatus.GetValueOrDefault(id, "?")
                };
            }).ToArray();
        var endedList = data.BacLastStatus
            .Where(kv => kv.Value == "Failed")
            .Select(kv =>
            {
                var id = kv.Key;
                return new Dictionary<string, object?>
                {
                    ["device"] = id,
                    ["failed"] = data.BacFailedByDevice.GetValueOrDefault(id),
                    ["ok"] = data.BacOkByDevice.GetValueOrDefault(id),
                    ["flips"] = data.BacFlipByDevice.GetValueOrDefault(id)
                };
            })
            .OrderByDescending(r => Convert.ToInt32(r["failed"]))
            .Take(20)
            .ToArray();
        return new Dictionary<string, object?>
        {
            ["failed"] = data.BacFailed,
            ["ok"] = data.BacOk,
            ["endedFailed"] = endedFailed,
            ["endedOk"] = endedOk,
            ["flappers"] = flappers,
            ["objectList"] = data.BacObjectList,
            ["failedDevices"] = data.BacFailedByDevice.Count,
            ["okDevices"] = data.BacOkByDevice.Count,
            ["objectListDevices"] = data.BacObjectListByDevice.Count,
            ["collectTrend"] = data.BacCollectTrend,
            ["timeSync"] = data.BacTimeSync,
            ["collectTrendProps"] = data.BacCollectTrendByProp.Count,
            ["timeSyncProps"] = data.BacTimeSyncByProp.Count,
            ["collectTrendSample"] = data.BacCollectTrendSample,
            ["timeSyncSample"] = data.BacTimeSyncSample,
            ["collectTrendCodes"] = data.BacCollectTrendByCode.OrderByDescending(kv => kv.Value).Take(10)
                .Select(kv => new Dictionary<string, object?> { ["code"] = kv.Key, ["count"] = kv.Value }).ToArray(),
            ["collectTrendTop"] = data.BacCollectTrendByProp.OrderByDescending(kv => kv.Value).Take(20)
                .Select(kv => new Dictionary<string, object?> { ["property"] = kv.Key, ["count"] = kv.Value }).ToArray(),
            ["timeSyncCodes"] = data.BacTimeSyncByCode.OrderByDescending(kv => kv.Value).Take(10)
                .Select(kv => new Dictionary<string, object?> { ["code"] = kv.Key, ["count"] = kv.Value }).ToArray(),
            ["timeSyncTop"] = data.BacTimeSyncByProp.OrderByDescending(kv => kv.Value).Take(20)
                .Select(kv => new Dictionary<string, object?> { ["property"] = kv.Key, ["count"] = kv.Value }).ToArray(),
            ["failedSample"] = data.BacFailedSample,
            ["okSample"] = data.BacOkSample,
            ["objectListSample"] = data.BacObjectListSample,
            ["activity"] = activity,
            ["endedFailedList"] = endedList,
            ["objectListTop"] = data.BacObjectListByDevice.OrderByDescending(kv => kv.Value).Take(20)
                .Select(kv => new Dictionary<string, object?> { ["device"] = kv.Key, ["count"] = kv.Value }).ToArray(),
            ["lifecycle"] = LifecycleBuilder.BuildLifecycleRows(data, "(?i)GmsBACnet|WCCOAGmsBACnet")
        };
    }

    public static Dictionary<string, object?> BuildCnsSection(AnalysisState data, int topN) =>
        new()
        {
            ["resolveNodes"] = RuleEngine.GetRuleCount(data, "cns.resolveNodes"),
            ["reducedFunction"] = RuleEngine.GetRuleCount(data, "cns.reducedFunction"),
            ["icns"] = RuleEngine.GetRuleCount(data, "cns.icns"),
            ["tryRenew"] = RuleEngine.GetRuleCount(data, "cns.tryRenew"),
            ["patterns"] = TopPatterns(data.CnsPatterns, data.CnsPatternSamples, data.CnsPatternTimes, topN).ToArray(),
            ["lifecycle"] = LifecycleBuilder.BuildLifecycleRows(data, "(?i)ApplicationFramework|ICns")
        };

    public static Dictionary<string, object?> BuildCohoSection(AnalysisState data, int topN) =>
        new()
        {
            ["stuck"] = data.CohoStuck,
            ["sample"] = data.CohoSample,
            ["topNames"] = data.CohoStuckNames.OrderByDescending(kv => kv.Value).Take(topN)
                .Select(kv => new Dictionary<string, object?> { ["name"] = kv.Key, ["count"] = kv.Value }).ToArray(),
            ["lifecycle"] = LifecycleBuilder.BuildLifecycleRows(data, "(?i)CoHo|GmsCoHo"),
            ["blockingSample"] = data.BlockingSample,
            ["unblockingSample"] = data.UnblockingSample
        };

    public static Dictionary<string, object?> BuildApogeeSection(AnalysisState data, int topN) =>
        new()
        {
            ["events"] = data.ApogeeEvents,
            ["updatePoints"] = data.ApogeeUpdatePoints,
            ["repetition"] = data.ApogeeRepetition,
            ["other"] = data.ApogeeOther,
            ["uniquePpcl"] = data.ApogeePpcl.Count,
            ["sample"] = data.ApogeeSample,
            ["topPpcl"] = data.ApogeePpcl.OrderByDescending(kv => kv.Value).Take(topN)
                .Select(kv => new Dictionary<string, object?> { ["name"] = kv.Key, ["count"] = kv.Value }).ToArray(),
            ["drvLines"] = data.ApogeeDrvLines,
            ["trendOverflow"] = RuleEngine.GetRuleCount(data, "apogeeDrv.trendOverflow"),
            ["trendSeq"] = RuleEngine.GetRuleCount(data, "apogeeDrv.trendSeq"),
            ["alertId"] = RuleEngine.GetRuleCount(data, "apogeeDrv.alertId"),
            ["queryTimeout"] = RuleEngine.GetRuleCount(data, "apogeeDrv.queryTimeout"),
            ["getDataFail"] = RuleEngine.GetRuleCount(data, "apogeeDrv.getDataFail"),
            ["trendDevices"] = RuleEngine.GetRuleBucketCount(data, "apogeeDrv.trendOverflow", "device"),
            ["trendNames"] = RuleEngine.GetRuleBucketCount(data, "apogeeDrv.trendOverflow", "trend"),
            ["getDataDevices"] = RuleEngine.GetRuleBucketCount(data, "apogeeDrv.getDataFail", "device"),
            ["trendSample"] = RuleEngine.GetRuleSample(data, "apogeeDrv.trend"),
            ["alertSample"] = RuleEngine.GetRuleSample(data, "apogeeDrv.alertId"),
            ["timeoutSample"] = RuleEngine.GetRuleSample(data, "apogeeDrv.queryTimeout"),
            ["getDataSample"] = RuleEngine.GetRuleSample(data, "apogeeDrv.getDataFail"),
            ["topTrendDevices"] = LifecycleBuilder.RuleTopBucket(data, "apogeeDrv.trendOverflow", "device", "device", 20).ToArray(),
            ["topTrends"] = LifecycleBuilder.RuleTopBucket(data, "apogeeDrv.trendOverflow", "trend", "trend", 20).ToArray(),
            ["topGetDataDevices"] = LifecycleBuilder.RuleTopBucket(data, "apogeeDrv.getDataFail", "device", "device", 20).ToArray(),
            ["lifecycle"] = LifecycleBuilder.BuildLifecycleRows(data, "(?i)ApogeeDrv")
        };
}
