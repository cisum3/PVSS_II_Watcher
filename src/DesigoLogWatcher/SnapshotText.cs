using System.Globalization;
using System.Text;

namespace DesigoLogWatcher;

/// <summary>Plain-text snapshot report (Convert-SnapshotToText port).</summary>
public static class SnapshotText
{
    public static string Render(Dictionary<string, object?> snap, string author = "Cisum")
    {
        var meta = Dict(snap, "meta");
        var win = Dict(snap, "window");
        var opt = Dict(snap, "options");
        var inc = GetSections(opt);
        var sb = new StringBuilder(64_000);
        void W(string t = "") => sb.AppendLine(t);

        W("================================================================================");
        W(" PVSS / WinCC OA Log Analysis Report");
        W("================================================================================");
        W($"Tool      : {Str(meta, "tool")} v{Str(meta, "version")} by {author}");
        W($"Generated : {Str(meta, "generated")}");
        W($"Log file  : {Str(meta, "logPath")}");
        var len = meta.TryGetValue("fileLength", out var fl) && fl is not null ? Convert.ToInt64(fl) : 0L;
        W(string.Create(CultureInfo.InvariantCulture, $"Size      : {len / (1024.0 * 1024.0):N2} MB"));
        W(string.Create(CultureInfo.InvariantCulture,
            $"Lines     : {Int(meta, "parsedLines"):N0} analyzed (WinCC OA header, in window)"));
        W($"Time span : {Str(win, "first")}  -->  {Str(win, "last")}");
        W("");

        W("--- Options used ---");
        W($" Organize      : {Str(opt, "organize")}");
        W($" Severities    : {string.Join(", ", Arr(opt, "severities"))}");
        W($" Areas         : {string.Join(", ", Arr(opt, "areas"))}");
        if (Arr(opt, "drivers") is { Length: > 0 } drivers)
            W($" Drivers       : {string.Join(", ", drivers)}");
        W(string.Create(CultureInfo.InvariantCulture, $" TopN          : {Int(opt, "topN")}"));
        W(string.Create(CultureInfo.InvariantCulture, $" Sample/patt   : {Int(opt, "samplePerPattern")}"));
        var timeMode = Str(opt, "window") == "entire"
            ? "entire file"
            : string.Create(CultureInfo.InvariantCulture, $"last {Int(opt, "lastMinutes"):N0} minutes");
        W($" Time mode     : {timeMode}");
        W($" Format        : {Str(opt, "format")}");
        W("");

        W("--- Findings ---");
        foreach (var f in StringList(snap, "findings"))
            W($" * {f}");
        W("");

        W("--- Severity counts ---");
        var sev = IntDict(snap, "severityCounts");
        foreach (var s in new[] { "FATAL", "SEVERE", "ERROR", "WARNING", "INFO" })
            W(string.Create(CultureInfo.InvariantCulture, $" {sev.GetValueOrDefault(s),8:N0}  {s}"));
        W("");

        W("--- Area counts ---");
        var areas = IntDict(snap, "areaCounts");
        foreach (var a in new[] { "SYS", "IMPL", "CTRL", "PARAM", "OTHER" })
            W(string.Create(CultureInfo.InvariantCulture, $" {areas.GetValueOrDefault(a),8:N0}  {a}"));
        W("");

        if (inc.ModuleHeadlines)
        {
            var mh = Dict(snap, "moduleHeadlines");
            var bacH = Dict(mh, "bacnet");
            var cnsH = Dict(mh, "cns");
            var cohoH = Dict(mh, "coho");
            var apoH = Dict(mh, "apogee");
            W("--- Module headlines ---");
            W(string.Create(CultureInfo.InvariantCulture,
                $" BACnet : Failed={Int(bacH, "failed"):N0} OK={Int(bacH, "ok"):N0} endedFailed={Int(bacH, "endedFailed"):N0} endedOK={Int(bacH, "endedOk"):N0} flappers={Int(bacH, "flappers"):N0} objectList={Int(bacH, "objectList"):N0} CollectTrend={Int(bacH, "collectTrend"):N0} ({Int(bacH, "collectTrendProps"):N0} props) TimeSync={Int(bacH, "timeSync"):N0} ({Int(bacH, "timeSyncProps"):N0} props)"));
            W(string.Create(CultureInfo.InvariantCulture,
                $" CNS    : ResolveNodes={Int(cnsH, "resolveNodes"):N0} ReducedFunction={Int(cnsH, "reducedFunction"):N0} TryRenewSession={Int(cnsH, "tryRenew"):N0}"));
            W(string.Create(CultureInfo.InvariantCulture, $" CoHo   : stuck/drop={Int(cohoH, "stuck"):N0}"));
            W(string.Create(CultureInfo.InvariantCulture,
                $" Apogee : events={Int(apoH, "events"):N0} UpdatePoints={Int(apoH, "updatePoints"):N0} | Drv overflow={Int(apoH, "trendOverflow"):N0} seq={Int(apoH, "trendSeq"):N0} AlertID={Int(apoH, "alertId"):N0} getData={Int(apoH, "getDataFail"):N0}"));
            W("");
        }

        var pl = Dict(snap, "projectLifecycle");
        W("--- Project restarts (pmon) ---");
        W(" Each row is one cycle: up -> shutdown -> stopped -> next up. Uptime = up to shutdown; stop = shutdown to stopped; downtime = stopped to next up (blank when still down). START_MODE counted only (too frequent to list).");
        if (pl.Count > 0)
        {
            var cycles = Rows(pl, "cycles");
            var capped = Bool(pl, "capped") ? "  (events capped at 200)" : "";
            W(string.Create(CultureInfo.InvariantCulture,
                $"  up={Int(pl, "up"):N0}  stopped={Int(pl, "stopped"):N0}  shutdown={Int(pl, "shutdown"):N0}  START_MODE={Int(pl, "startMode"):N0}  cycles={cycles.Count:N0}{capped}"));
            if (cycles.Count > 0)
            {
                W(" | Up | Shutdown | Uptime | Stopped | Stop | Downtime | Note |");
                foreach (var c in cycles)
                {
                    var note = new List<string>();
                    if (Bool(c, "upImplied")) note.Add("up implied (window start)");
                    if (Bool(c, "stillUp")) note.Add("still up");
                    if (Bool(c, "stillDown")) note.Add("still down");
                    W($" | {Str(c, "up")} | {NullDash(Str(c, "shutdown"))} | {Str(c, "uptime")} | {NullDash(Str(c, "stopped"))} | {Str(c, "stopDuration")} | {Str(c, "downtime")} | {string.Join("; ", note)} |");
                }
            }
            else W("   (none listed)");
        }
        W("");

        var mhz = Dict(snap, "managerHealth");
        W("--- Manager health (pmon) ---");
        W(" Start/stop = Manager Start PROJ / Manager Stop. Restarts = Detected stopped manager. Blocking = no heartbeat (busy/overloaded).");
        var tot = Dict(mhz, "totals");
        if (tot.Count > 0)
        {
            W(string.Create(CultureInfo.InvariantCulture,
                $"  Starts={Int(tot, "starts"):N0}  Stops={Int(tot, "stops"):N0}  Auto-restarts={Int(tot, "restarts"):N0}  Blocking={Int(tot, "blocking"):N0}  Unblocked={Int(tot, "unblocked"):N0}  Driver-ready={Int(mhz, "driverReady"):N0}"));
            W("  Per-manager (top 25 by activity):");
            W(string.Create(CultureInfo.InvariantCulture,
                $"   {"Manager",-40} {"Starts",7} {"Stops",7} {"Restart",8} {"Blocking",9} {"Unblock",9}"));
            foreach (var r in Rows(mhz, "managers"))
            {
                W(string.Create(CultureInfo.InvariantCulture,
                    $"   {Str(r, "name"),-40} {Int(r, "starts"),7:N0} {Int(r, "stops"),7:N0} {Int(r, "restarts"),8:N0} {Int(r, "blocking"),9:N0} {Int(r, "unblocked"),9:N0}"));
            }
        }
        W("");

        if (inc.Managers)
        {
            var mgrs = Rows(snap, "topManagers");
            W(string.Create(CultureInfo.InvariantCulture, $"--- Top {mgrs.Count} components (managers) ---"));
            foreach (var m in mgrs)
                W(string.Create(CultureInfo.InvariantCulture, $" {Int(m, "count"),8:N0}  {Str(m, "name")}"));
            W("");
        }

        if (inc.Perf)
        {
            W("--- Performance-related keyword categories ---");
            var pc = Rows(Dict(snap, "perf"), "perfCategories");
            if (pc.Count == 0) W(" (none matched)");
            else
                foreach (var row in pc)
                    W(string.Create(CultureInfo.InvariantCulture, $" {Int(row, "count"),8:N0}  {Str(row, "name")}"));
            W("");
        }

        if (inc.Hourly)
        {
            var hr = Dict(snap, "hourly");
            if (Bool(hr, "truncated"))
            {
                W("--- Hourly volume (most recent 24 hours) ---");
                W(string.Create(CultureInfo.InvariantCulture,
                    $" Hours in analyzed window: {Int(hr, "hourCount"):N0} (showing most recent 24 + top 10 busiest)"));
            }
            else
            {
                W("--- Hourly volume (all parsed / SEVERE / WARNING) ---");
                W(string.Create(CultureInfo.InvariantCulture,
                    $" Hours in analyzed window: {Int(hr, "hourCount"):N0}"));
            }
            W(string.Create(CultureInfo.InvariantCulture,
                $" {"Hour",-16} {"All",10} {"SEVERE",10} {"WARNING",10}"));
            foreach (var r in Rows(hr, "rows"))
                W(string.Create(CultureInfo.InvariantCulture,
                    $" {Str(r, "hour"),-16} {Int(r, "total"),10:N0} {Int(r, "severe"),10:N0} {Int(r, "warning"),10:N0}"));
            if (Bool(hr, "truncated"))
            {
                W("");
                W("--- Busiest hours (top 10 by total lines) ---");
                W(string.Create(CultureInfo.InvariantCulture,
                    $" {"Hour",-16} {"All",10} {"SEVERE",10} {"WARNING",10}"));
                foreach (var r in Rows(hr, "busiest"))
                    W(string.Create(CultureInfo.InvariantCulture,
                        $" {Str(r, "hour"),-16} {Int(r, "total"),10:N0} {Int(r, "severe"),10:N0} {Int(r, "warning"),10:N0}"));
            }
            W("");
        }

        if (inc.Bacnet) AppendBacnet(W, Dict(snap, "bacnet"), Int(opt, "bacFlapMin") is var flap and > 0 ? flap : 3);
        if (inc.Cns) AppendCns(W, Dict(snap, "cns"), Int(opt, "topN"));
        if (inc.Coho) AppendCoho(W, Dict(snap, "coho"));
        if (inc.Apogee) AppendApogee(W, Dict(snap, "apogee"));

        if (inc.Detections)
        {
            foreach (var g in Rows(snap, "detections"))
            {
                var rules = Rows(g, "rules");
                W($"--- Detections: {Str(g, "group")} ---");
                W(string.Create(CultureInfo.InvariantCulture,
                    $" {Int(g, "total"):N0} line(s) across {rules.Count:N0} rule(s)"));
                foreach (var r in rules)
                    AppendDetectionRule(W, r);
                W("");
            }
        }

        if (inc.DriverDeepDive)
        {
            W("--- Driver deep-dive ---");
            foreach (var dd in Rows(snap, "driverDeepDive"))
            {
                W("");
                W($"=== {Str(dd, "name")} ===");
                W(string.Create(CultureInfo.InvariantCulture, $" Total lines: {Int(dd, "count"):N0}"));
                W(" Severity mix:");
                var sevs = IntDict(dd, "severities");
                foreach (var s in new[] { "FATAL", "SEVERE", "ERROR", "WARNING", "INFO" })
                    W(string.Create(CultureInfo.InvariantCulture, $"  {sevs.GetValueOrDefault(s),8:N0}  {s}"));
                var bySev = Dict(dd, "patternsBySeverity");
                foreach (var s in new[] { "FATAL", "SEVERE", "ERROR", "WARNING" })
                {
                    W($" Patterns - {s} (top {Int(opt, "topN")}):");
                    var list = Rows(bySev, s);
                    if (list.Count == 0) { W("  (none)"); continue; }
                    AppendPatternBlock(W, list, "  ");
                }
            }
            W("");
        }

        if (inc.SeverityPatterns)
        {
            W("--- Top patterns by severity ---");
            var bySev = Dict(snap, "patternsBySeverity");
            foreach (var s in new[] { "FATAL", "SEVERE", "ERROR", "WARNING" })
            {
                var list = Rows(bySev, s);
                W("");
                W($" {s} (top {Int(opt, "topN")}):");
                if (list.Count == 0) { W("   (none)"); continue; }
                AppendPatternBlock(W, list, "  ");
            }
            W("");
        }

        var perf = Dict(snap, "perf");
        W("--- Notes ---");
        W(" Project restart events are capped at 200; manager health lists the top 25 managers.");
        W(string.Create(CultureInfo.InvariantCulture,
            $" Parsed lines: {Int(meta, "parsedLines"):N0}   Unparsed / skipped: {Int(perf, "unparsedLines"):N0}"));
        W("");
        W($"Report from live Watch state (no re-scan). Watch v{Str(meta, "version")} - tool by {author}.");
        return sb.ToString();
    }

    private static void AppendBacnet(Action<string> W, Dictionary<string, object?> bac, int bacFlapMin)
    {
        W("--- BACnet module ---");
        if (bac.Count == 0) { W(" (no BACnet data)"); W(""); return; }
        W(" Device status (INFO)");
        W(string.Create(CultureInfo.InvariantCulture,
            $"  Failed transitions : {Int(bac, "failed"):N0}  (unique devices: {Int(bac, "failedDevices"):N0})"));
        W(string.Create(CultureInfo.InvariantCulture,
            $"  OK transitions     : {Int(bac, "ok"):N0}  (unique devices: {Int(bac, "okDevices"):N0})"));
        W(string.Create(CultureInfo.InvariantCulture,
            $"  Last-known status  : ended Failed={Int(bac, "endedFailed"):N0}  ended OK={Int(bac, "endedOk"):N0}  (devices seen in window)"));
        W(string.Create(CultureInfo.InvariantCulture,
            $"  Flapping (>= {bacFlapMin} Failed/OK changes): {Int(bac, "flappers"):N0} devices"));
        var act = Rows(bac, "activity");
        if (act.Count > 0)
        {
            W("");
            W("  Device status activity (top 20 by Failed transitions):");
            W("   rank   Failed     OK  flips  device");
            var rank = 0;
            foreach (var r in act)
            {
                rank++;
                W(string.Create(CultureInfo.InvariantCulture,
                    $"   {rank,4}  {Int(r, "failed"),6:N0}  {Int(r, "ok"),6:N0}  {Int(r, "flips"),5:N0}  {Str(r, "device")}"));
            }
        }
        W("");
        W("  Devices that ended Failed (last-known in window, top 20):");
        var ended = Rows(bac, "endedFailedList");
        if (ended.Count == 0) W("   (none)");
        else
        {
            W("   rank   Failed     OK  flips  device");
            var rank = 0;
            foreach (var r in ended)
            {
                rank++;
                W(string.Create(CultureInfo.InvariantCulture,
                    $"   {rank,4}  {Int(r, "failed"),6:N0}  {Int(r, "ok"),6:N0}  {Int(r, "flips"),5:N0}  {Str(r, "device")}"));
            }
        }
        W("");
        W(" Object list (WARNING)");
        W(string.Create(CultureInfo.InvariantCulture,
            $"  Events            : {Int(bac, "objectList"):N0}  (unique devices: {Int(bac, "objectListDevices"):N0})"));
        var objTop = Rows(bac, "objectListTop");
        if (objTop.Count > 0)
        {
            W("  Top devices by object-list warnings:");
            var rank = 0;
            foreach (var r in objTop)
            {
                rank++;
                W(string.Create(CultureInfo.InvariantCulture,
                    $"   {rank,2}. {Int(r, "count"),8:N0}  device {Str(r, "device")}"));
            }
        }
        foreach (var (label, nKey, propsKey, codesKey, topKey) in new[]
                 {
                     (" BACnetCollectTrend (driver trend-collection command failures; often CoHo / Log_Enable)",
                         "collectTrend", "collectTrendProps", "collectTrendCodes", "collectTrendTop"),
                     (" BACnetTimeSync (driver time-sync command failures; often CoHo / Local_Time)",
                         "timeSync", "timeSyncProps", "timeSyncCodes", "timeSyncTop")
                 })
        {
            W("");
            W(label);
            W(string.Create(CultureInfo.InvariantCulture,
                $"  Events             : {Int(bac, nKey):N0}  (unique properties: {Int(bac, propsKey):N0})"));
            var codes = Rows(bac, codesKey);
            if (codes.Count > 0)
            {
                W("  Error codes:");
                foreach (var c in codes)
                    W(string.Create(CultureInfo.InvariantCulture,
                        $"    {Str(c, "code"),8}  {Int(c, "count"):N0}"));
            }
            var top = Rows(bac, topKey);
            if (top.Count > 0)
            {
                W("  Top properties:");
                var rank = 0;
                foreach (var c in top)
                {
                    rank++;
                    W(string.Create(CultureInfo.InvariantCulture,
                        $"   {rank,4}  {Int(c, "count"),6:N0}  {Str(c, "property")}"));
                }
            }
        }
        W("");
    }

    private static void AppendCns(Action<string> W, Dictionary<string, object?> cns, int topN)
    {
        W("--- CNS module (thin) ---");
        W(string.Create(CultureInfo.InvariantCulture, $"  ResolveNodes     : {Int(cns, "resolveNodes"):N0}"));
        W(string.Create(CultureInfo.InvariantCulture, $"  ReducedFunction  : {Int(cns, "reducedFunction"):N0}"));
        W(string.Create(CultureInfo.InvariantCulture, $"  ICns             : {Int(cns, "icns"):N0}"));
        W(string.Create(CultureInfo.InvariantCulture, $"  TryRenewSession  : {Int(cns, "tryRenew"):N0}"));
        W(string.Create(CultureInfo.InvariantCulture, $"  Top CNS-related patterns (top {topN}):"));
        var pats = Rows(cns, "patterns");
        AppendPatternBlock(W, pats, "  ");
        if (pats.Count == 0) W("  (none)");
        W("");
    }

    private static void AppendCoho(Action<string> W, Dictionary<string, object?> coho)
    {
        W("--- CoHo module (thin) ---");
        W(string.Create(CultureInfo.InvariantCulture, $"  Stuck/drop messages : {Int(coho, "stuck"):N0}"));
        if (!string.IsNullOrEmpty(Str(coho, "sample")))
            W($"  Example             : {Str(coho, "sample")}");
        W("  Top stuck names:");
        var rank = 0;
        foreach (var n in Rows(coho, "topNames"))
        {
            rank++;
            W(string.Create(CultureInfo.InvariantCulture,
                $"   {rank,2}. {Int(n, "count"),8:N0}  {Str(n, "name")}"));
        }
        if (rank == 0) W("   (none parsed)");
        W("");
    }

    private static void AppendApogee(Action<string> W, Dictionary<string, object?> apo)
    {
        W("--- Apogee module ---");
        W(" CoHo.Apogee* / Orch.Apogee* (orchestration / ApogeeBACnet path)");
        W(string.Create(CultureInfo.InvariantCulture, $"  Events              : {Int(apo, "events"):N0}"));
        W(string.Create(CultureInfo.InvariantCulture, $"  UpdatePoints        : {Int(apo, "updatePoints"):N0}"));
        W(string.Create(CultureInfo.InvariantCulture, $"  Trace repetitions   : {Int(apo, "repetition"):N0}"));
        if (Int(apo, "other") > 0)
            W(string.Create(CultureInfo.InvariantCulture, $"  Other               : {Int(apo, "other"):N0}"));
        W(string.Create(CultureInfo.InvariantCulture, $"  Unique PPCL programs: {Int(apo, "uniquePpcl"):N0}"));
        if (!string.IsNullOrEmpty(Str(apo, "sample")))
            W($"  Example             : {Str(apo, "sample")}");
        W("  Top PPCL programs by UpdatePoints:");
        var rank = 0;
        foreach (var p in Rows(apo, "topPpcl"))
        {
            rank++;
            W(string.Create(CultureInfo.InvariantCulture,
                $"   {rank,2}. {Int(p, "count"),8:N0}  {Str(p, "name")}"));
        }
        if (rank == 0) W("   (none parsed)");
        W("");
        W(" WCCOAApogeeDrv (native Apogee driver)");
        W(string.Create(CultureInfo.InvariantCulture, $"  Driver lines        : {Int(apo, "drvLines"):N0}"));
        W(string.Create(CultureInfo.InvariantCulture,
            $"  Trend buffer overflow: {Int(apo, "trendOverflow"):N0}  (unique devices: {Int(apo, "trendDevices"):N0}, unique trends: {Int(apo, "trendNames"):N0})"));
        W(string.Create(CultureInfo.InvariantCulture,
            $"  Sequence-gap lines  : {Int(apo, "trendSeq"):N0}  (Last sequence number... companion warnings)"));
        W(string.Create(CultureInfo.InvariantCulture, $"  AlertID issues      : {Int(apo, "alertId"):N0}"));
        W(string.Create(CultureInfo.InvariantCulture, $"  Query timeouts      : {Int(apo, "queryTimeout"):N0}"));
        W(string.Create(CultureInfo.InvariantCulture,
            $"  Get-data failures   : {Int(apo, "getDataFail"):N0}  (unique devices: {Int(apo, "getDataDevices"):N0})"));
        if (!string.IsNullOrEmpty(Str(apo, "trendSample")))
            W($"  Trend example       : {Str(apo, "trendSample")}");
        if (!string.IsNullOrEmpty(Str(apo, "alertSample")))
            W($"  AlertID example     : {Str(apo, "alertSample")}");
        if (!string.IsNullOrEmpty(Str(apo, "timeoutSample")))
            W($"  Timeout example     : {Str(apo, "timeoutSample")}");
        if (!string.IsNullOrEmpty(Str(apo, "getDataSample")))
            W($"  Get-data example    : {Str(apo, "getDataSample")}");
        foreach (var (h, key, nameKey) in new[]
                 {
                     ("  Top devices by trend overflow:", "topTrendDevices", "device"),
                     ("  Top trends by overflow:", "topTrends", "trend"),
                     ("  Top devices by get-data failure:", "topGetDataDevices", "device")
                 })
        {
            var rows = Rows(apo, key);
            if (rows.Count == 0) continue;
            W(h);
            rank = 0;
            foreach (var r in rows)
            {
                rank++;
                W(string.Create(CultureInfo.InvariantCulture,
                    $"   {rank,4}  {Int(r, "count"),6:N0}  {Str(r, nameKey)}"));
            }
        }
        W("");
    }

    private static void AppendDetectionRule(Action<string> W, Dictionary<string, object?> r)
    {
        W("");
        W($" === {Str(r, "label")} ===");
        var measures = AsObjDict(r.TryGetValue("measures", out var mObj) ? mObj : null);
        if (measures.Count > 0)
        {
            foreach (var mk in measures.Keys.OrderBy(k => k, StringComparer.Ordinal))
                W(string.Create(CultureInfo.InvariantCulture,
                    $"   {mk,-14}: {Convert.ToInt64(measures[mk]):N0}"));
            W(string.Create(CultureInfo.InvariantCulture, $"   {"lines",-14}: {Int(r, "count"):N0}"));
        }
        else
            W(string.Create(CultureInfo.InvariantCulture, $"   {"lines",-14}: {Int(r, "count"):N0}"));

        var sevs = AsObjDict(r.TryGetValue("severities", out var sObj) ? sObj : null);
        if (sevs.Count > 0)
        {
            var sp = sevs.Select(kv =>
                string.Create(CultureInfo.InvariantCulture, $"{kv.Key}={Convert.ToInt32(kv.Value):N0}"));
            W($"   {"severities",-14}: {string.Join(" ", sp)}");
        }
        var span = LifecycleBuilder.FormatDurationLabel(
            Convert.ToDouble(r.TryGetValue("spanSec", out var ss) && ss is not null ? ss : 0));
        W($"   {"window",-14}: {Str(r, "first")}  -->  {Str(r, "last")}  ({span})");
        var overLbl = FormatRuleOverLabel(r);
        if (overLbl is not null)
        {
            var over = Convert.ToDouble(r.TryGetValue("over", out var o) && o is not null ? o : 0);
            var exceeded = over >= 1 ? " EXCEEDED" : "";
            W(string.Create(CultureInfo.InvariantCulture,
                $"   {"threshold",-14}: {Int(r, "findingAt"):N0} line(s) - {overLbl}{exceeded}"));
        }
        W($"   {"rule",-14}: {Str(r, "id")}");
        if (!string.IsNullOrEmpty(Str(r, "sample")))
            W($"   {"example",-14}: {Str(r, "sample")}");
        var buckets = AsObjDict(r.TryGetValue("buckets", out var bObj) ? bObj : null);
        foreach (var bn in buckets.Keys.OrderBy(k => k, StringComparer.Ordinal))
        {
            var b = AsObjDict(buckets[bn]);
            var top = Rows(b, "top");
            if (top.Count == 0) continue;
            if (Int(b, "distinct") == 1 && top.Count == 1)
            {
                W($"   {bn,-14}: all from {Str(top[0], "value")}");
                continue;
            }
            var capped = Bool(b, "capped") ? ", capped" : "";
            W(string.Create(CultureInfo.InvariantCulture,
                $"   By {bn} ({Int(b, "distinct"):N0} distinct{capped}):"));
            var rank = 0;
            foreach (var x in top)
            {
                rank++;
                W(string.Create(CultureInfo.InvariantCulture,
                    $"    {rank,3}. {Int(x, "count"),8:N0}  {Str(x, "value")}"));
            }
        }
    }

    private static void AppendPatternBlock(Action<string> W, List<Dictionary<string, object?>> rows, string indent)
    {
        var rank = 0;
        foreach (var row in rows)
        {
            rank++;
            W("");
            W(string.Create(CultureInfo.InvariantCulture, $"{indent} #{rank}  count={Int(row, "count"):N0}"));
            W($"{indent}     pattern: {Str(row, "pattern")}");
            if (!string.IsNullOrEmpty(Str(row, "first")))
                W($"{indent}     first  : {Str(row, "first")}");
            if (!string.IsNullOrEmpty(Str(row, "last")))
                W($"{indent}     last   : {Str(row, "last")}");
            foreach (var ex in Samples(row))
            {
                if (!string.IsNullOrEmpty(ex))
                    W($"{indent}     example: {ex}");
            }
        }
    }

    private static string? FormatRuleOverLabel(Dictionary<string, object?> rule)
    {
        var at = Int(rule, "findingAt");
        if (at <= 0) return null;
        var over = Convert.ToDouble(rule.TryGetValue("over", out var o) && o is not null ? o : 0);
        var n = over >= 10
            ? over.ToString("N0", CultureInfo.InvariantCulture)
            : over.ToString("N1", CultureInfo.InvariantCulture);
        return $"{n}x threshold";
    }

    private sealed record Sections(
        bool Bacnet, bool Cns, bool Coho, bool Apogee, bool ModuleHeadlines,
        bool SeverityPatterns, bool Managers, bool Perf, bool Hourly, bool Detections,
        bool DriverDeepDive);

    private static Sections GetSections(Dictionary<string, object?> opt)
    {
        var organize = Str(opt, "organize");
        var bacnet = true; var cns = true; var coho = true; var apogee = true;
        var headlines = false; var patterns = true; var full = true; var driver = false;
        if (string.Equals(organize, "Severity", StringComparison.OrdinalIgnoreCase))
        {
            bacnet = cns = coho = apogee = false;
            headlines = true;
            full = false;
        }
        else if (string.Equals(organize, "Driver", StringComparison.OrdinalIgnoreCase))
        {
            full = false;
            patterns = false;
            driver = true;
            bacnet = cns = coho = apogee = false;
            foreach (var name in Arr(opt, "drivers"))
            {
                if (name.Contains("BACnet", StringComparison.OrdinalIgnoreCase)) bacnet = true;
                if (name.Contains("ApplicationFramework", StringComparison.OrdinalIgnoreCase)
                    || name.Contains("ICns", StringComparison.OrdinalIgnoreCase)) cns = true;
                if (name.Contains("CoHo", StringComparison.OrdinalIgnoreCase))
                { coho = true; apogee = true; bacnet = true; }
                if (name.Contains("Apogee", StringComparison.OrdinalIgnoreCase)) apogee = true;
            }
        }
        return new Sections(bacnet, cns, coho, apogee, headlines, patterns,
            full || driver, full, full,
            !string.Equals(organize, "Severity", StringComparison.OrdinalIgnoreCase),
            driver);
    }

    private static string NullDash(string s) => string.IsNullOrEmpty(s) ? "" : s;

    private static Dictionary<string, object?> AsObjDict(object? v)
    {
        if (v is Dictionary<string, object?> d) return d;
        if (v is Dictionary<string, int> di)
        {
            var o = new Dictionary<string, object?>(StringComparer.Ordinal);
            foreach (var kv in di) o[kv.Key] = kv.Value;
            return o;
        }
        if (v is System.Collections.IDictionary idict)
        {
            var o = new Dictionary<string, object?>(StringComparer.Ordinal);
            foreach (System.Collections.DictionaryEntry e in idict)
                if (e.Key is string k) o[k] = e.Value;
            return o;
        }
        return [];
    }

    private static Dictionary<string, object?> Dict(Dictionary<string, object?> parent, string key) =>
        parent.TryGetValue(key, out var v) ? AsObjDict(v) : [];

    private static string Str(Dictionary<string, object?> d, string key) =>
        d.TryGetValue(key, out var v) && v is not null ? Convert.ToString(v) ?? "" : "";
    private static int Int(Dictionary<string, object?> d, string key) =>
        d.TryGetValue(key, out var v) && v is not null ? Convert.ToInt32(v) : 0;
    private static bool Bool(Dictionary<string, object?> d, string key) =>
        d.TryGetValue(key, out var v) && v is not null && Convert.ToBoolean(v);
    private static string[] Arr(Dictionary<string, object?> d, string key) =>
        d.TryGetValue(key, out var v) && v is string[] a ? a : [];

    private static List<Dictionary<string, object?>> Rows(Dictionary<string, object?> d, string key)
    {
        if (!d.TryGetValue(key, out var v) || v is null) return [];
        if (v is List<Dictionary<string, object?>> list) return list;
        if (v is Dictionary<string, object?>[] arr) return arr.ToList();
        if (v is object[] objs) return objs.OfType<Dictionary<string, object?>>().ToList();
        return [];
    }

    private static List<string> StringList(Dictionary<string, object?> d, string key)
    {
        if (!d.TryGetValue(key, out var v) || v is null) return [];
        if (v is List<string> ls) return ls;
        if (v is string[] sa) return sa.ToList();
        if (v is object[] oa) return oa.Select(o => Convert.ToString(o) ?? "").ToList();
        return [];
    }

    private static Dictionary<string, int> IntDict(Dictionary<string, object?> parent, string key)
    {
        if (!parent.TryGetValue(key, out var v) || v is null) return new(StringComparer.Ordinal);
        if (v is Dictionary<string, int> di) return di;
        var d = AsObjDict(v);
        var o = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var kv in d)
            if (kv.Value is not null) o[kv.Key] = Convert.ToInt32(kv.Value);
        return o;
    }

    private static IEnumerable<string> Samples(Dictionary<string, object?> row)
    {
        if (!row.TryGetValue("samples", out var v) || v is null) yield break;
        if (v is string[] sa) { foreach (var s in sa) yield return s; yield break; }
        if (v is List<string> ls) { foreach (var s in ls) yield return s; yield break; }
        if (v is object[] oa) { foreach (var o in oa) yield return Convert.ToString(o) ?? ""; }
    }
}
