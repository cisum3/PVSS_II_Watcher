using System.Globalization;
using System.Net;
using System.Text;

namespace DesigoLogWatcher;

/// <summary>Siemens-themed HTML snapshot report (Convert-SnapshotToHtml port).</summary>
public static class SnapshotHtml
{
    private const string Css = """
:root {
  --siemens-petrol: #009999;
  --siemens-snow: #ffffff;
  --siemens-stone: #879baa;
  --siemens-sand: #aaaa96;
  --bg-deep: #0f1923;
  --bg-panel: #15202b;
  --bg-elevated: #1c2834;
  --border: rgba(135, 155, 170, 0.35);
  --text: #ffffff;
  --text-muted: #879baa;
  --text-meta: #aaaa96;
  --sev-fatal: #e00000;
  --sev-severe: #c000a0;
  --sev-error: #b00040;
  --sev-warning: #e07000;
  --sev-info: #008000;
  --font: "Segoe UI", "Candara", "Calibri", sans-serif;
  --mono: "Cascadia Mono", "Consolas", monospace;
  --chrome-h: 5.5rem;
}
* { box-sizing: border-box; }
html { scroll-padding-top: calc(var(--chrome-h) + 0.5rem); }
body {
  margin: 0;
  font-family: var(--font);
  color: var(--text);
  background: var(--bg-deep);
  line-height: 1.45;
}
header.chrome {
  position: sticky;
  top: 0;
  z-index: 5;
  background: var(--bg-panel);
  border-bottom: 1px solid var(--border);
  padding: 0.65rem 1.25rem 0.55rem;
}
.brand { color: var(--siemens-petrol); font-weight: 700; font-size: 1.05rem; letter-spacing: 0.02em; }
.meta { color: var(--text-meta); font-size: 0.88rem; }
.muted { color: var(--text-muted); }
nav.jump {
  display: flex;
  flex-wrap: wrap;
  gap: 0.2rem 0.15rem;
  margin-top: 0.45rem;
}
nav.jump a {
  color: var(--text);
  text-decoration: none;
  font-size: 0.8rem;
  padding: 0.2rem 0.45rem;
  border-radius: 2px;
  border: 1px solid transparent;
}
nav.jump a:hover {
  color: var(--siemens-petrol);
  background: var(--bg-elevated);
  border-color: var(--border);
}
.intro { padding: 0.85rem 1.25rem 0; max-width: 72rem; }
main { padding: 0.5rem 1.25rem 2.5rem; max-width: 72rem; }
h1 { font-size: 1.05rem; margin: 0.15rem 0 0.2rem; font-weight: 600; }
h2 {
  font-size: 1rem;
  color: var(--siemens-petrol);
  margin: 1.35rem 0 0.55rem;
  padding-bottom: 0.25rem;
  border-bottom: 1px solid var(--border);
}
h3 { font-size: 0.92rem; margin: 0.85rem 0 0.4rem; }
.findings { margin: 0.5rem 0 1rem; padding-left: 1.1rem; }
.findings li { margin: 0.25rem 0; }
.kpi-row {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(7rem, 1fr));
  gap: 0.5rem;
  margin: 0.75rem 0 1rem;
}
.kpi {
  background: var(--bg-panel);
  border: 1px solid var(--border);
  border-radius: 2px;
  padding: 0.55rem 0.65rem;
}
.kpi .label { font-size: 0.75rem; letter-spacing: 0.04em; color: var(--text-muted); }
.kpi .value { font-size: 1.25rem; font-variant-numeric: tabular-nums; font-weight: 600; }
.kpi[data-sev="FATAL"] .value { color: #ffb0b0; }
.kpi[data-sev="SEVERE"] .value { color: #f0a0e0; }
.kpi[data-sev="ERROR"] .value { color: #f0a0c0; }
.kpi[data-sev="WARNING"] .value { color: #ffd0a0; }
.kpi[data-sev="INFO"] .value { color: #90d090; }
table.data {
  width: 100%;
  border-collapse: collapse;
  font-size: 0.86rem;
  font-variant-numeric: tabular-nums;
  margin: 0.35rem 0 0.85rem;
}
table.data th, table.data td {
  text-align: left;
  padding: 0.35rem 0.45rem;
  border-bottom: 1px solid var(--border);
  vertical-align: top;
}
table.data th {
  color: var(--text-muted);
  background: var(--bg-elevated);
  font-weight: 600;
}
.badge {
  display: inline-block;
  margin-left: 0.5rem;
  padding: 0.05rem 0.4rem;
  border: 1px solid var(--border);
  border-radius: 2px;
  font-size: 0.72rem;
  font-weight: 600;
  letter-spacing: 0.02em;
  vertical-align: middle;
  color: var(--text-muted);
  white-space: nowrap;
}
.badge.over { border-color: var(--sev-warning); color: #ffd0a0; }
h4 { font-size: 0.9rem; margin: 0.75rem 0 0.35rem; font-weight: 600; }
table.data.kv { width: auto; min-width: 22rem; max-width: 100%; }
table.data.kv th:first-child, table.data.kv td:first-child {
  width: 1%;
  white-space: nowrap;
  text-align: right;
  padding-right: 0.9rem;
}
.kind-up { color: #90d090; }
.kind-shutdown { color: #ffd0a0; }
.kind-stopped { color: #ffb0b0; }
.mono { font-family: var(--mono); font-size: 0.8rem; word-break: break-word; }
.card {
  background: var(--bg-panel);
  border: 1px solid var(--border);
  border-radius: 2px;
  padding: 0.65rem 0.75rem;
  margin: 0.5rem 0;
}
footer { margin-top: 2rem; color: var(--text-meta); font-size: 0.8rem; }
.chart-svg { width: 100%; max-width: 48rem; height: auto; display: block; margin: 0.35rem 0 0.25rem; border: 1px solid var(--border); border-radius: 2px; }
.legend { font-size: 0.8rem; color: var(--text-muted); margin: 0.2rem 0 0.85rem; }
.legend span { margin-right: 0.9rem; white-space: nowrap; }
.swatch { display: inline-block; width: 0.65rem; height: 0.65rem; margin-right: 0.28rem; vertical-align: middle; border-radius: 1px; }
@media (max-width: 640px) {
  nav.jump a { font-size: 0.75rem; padding: 0.18rem 0.35rem; }
}
""";

    public static string Render(Dictionary<string, object?> snap, string author = "Cisum")
    {
        var meta = Dict(snap, "meta");
        var win = Dict(snap, "window");
        var opt = Dict(snap, "options");
        var inc = GetSections(opt);
        var sb = new StringBuilder(64_000);
        var winMode = Str(win, "mode");
        var winLabel = winMode == "entire"
            ? "Entire file"
            : string.Create(CultureInfo.InvariantCulture, $"Last {Int(win, "lastMinutes")} minutes of file");
        var span = (!string.IsNullOrEmpty(Str(win, "first")) || !string.IsNullOrEmpty(Str(win, "last")))
            ? $"{Str(win, "first")}  ->  {Str(win, "last")}" : "";
        var sevOn = Arr(meta, "severities") is { Length: > 0 } sArr ? string.Join(", ", sArr) : "(none)";
        var areaOn = Arr(meta, "areas") is { Length: > 0 } aArr ? string.Join(", ", aArr) : "SYS, IMPL, CTRL, PARAM, OTHER";

        sb.AppendLine("<!DOCTYPE html>");
        sb.AppendLine("<html lang=\"en\"><head><meta charset=\"utf-8\" />");
        sb.AppendLine("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />");
        sb.AppendLine("<title>PVSS Log Watch Snapshot</title>");
        sb.AppendLine("<style>");
        sb.AppendLine(Css);
        sb.AppendLine("</style></head><body>");
        sb.AppendLine("<header class=\"chrome\">");
        sb.AppendLine("<div class=\"brand\">PVSS Log Watch</div>");
        sb.AppendLine($"<h1>Snapshot report <span class=\"meta\">v{E(Str(meta, "version"))}</span></h1>");
        sb.AppendLine("<nav class=\"jump\" aria-label=\"Report sections\">");
        foreach (var (href, label, on) in new (string, string, bool)[]
                 {
                     ("#options", "Options", true), ("#findings", "Findings", true),
                     ("#severity", "Severity", true), ("#charts", "Charts", true),
                     ("#hourly", "Hourly", inc.Hourly), ("#project", "Project restarts", true),
                     ("#mgr-health", "Manager health", true), ("#managers", "Top managers", inc.Managers),
                     ("#patterns", "Patterns", inc.SeverityPatterns),
                     ("#headlines", "Module headlines", inc.ModuleHeadlines),
                     ("#bacnet", "BACnet", inc.Bacnet), ("#cns", "CNS", inc.Cns),
                     ("#coho", "CoHo", inc.Coho), ("#apogee", "Apogee", inc.Apogee),
                     ("#detections", "Detections", inc.Detections), ("#perf", "Perf", inc.Perf)
                 })
        {
            if (on) sb.AppendLine($"<a href=\"{href}\">{label}</a>");
        }
        sb.AppendLine("</nav></header>");

        sb.AppendLine("<div class=\"intro\">");
        sb.AppendLine($"<p class=\"meta\">Generated {E(Str(meta, "generated"))}</p>");
        sb.AppendLine($"<p class=\"meta\">Log: <span class=\"mono\">{E(Str(meta, "logPath"))}</span></p>");
        sb.AppendLine($"<p class=\"meta\">{E(winLabel)}  &middot;  {E(span)}</p>");
        sb.AppendLine($"<p class=\"meta\">Severity filters: {E(sevOn)}  &middot;  Area filters: {E(areaOn)}</p>");
        sb.AppendLine(CultureInfo.InvariantCulture,
            $"<p class=\"meta\">Parsed lines: {Int(meta, "parsedLines"):N0}  &middot;  gen {Int(meta, "generation")}</p>");
        sb.AppendLine("<p class=\"meta\">Module pages (BACnet/CNS/&hellip;) show all areas; area filter applies to charts, patterns, managers, and severity KPIs.</p>");
        sb.AppendLine("</div><main>");

        // Options
        sb.AppendLine("<section id=\"options\"><h2>Options used</h2><div class=\"card\">");
        sb.AppendLine("<table class=\"data\"><thead><tr><th>Option</th><th>Value</th></tr></thead><tbody>");
        var winTxt = Str(opt, "window") == "entire"
            ? "entire file"
            : string.Create(CultureInfo.InvariantCulture, $"last {Int(opt, "lastMinutes"):N0} minutes");
        foreach (var (k, v) in new (string, string)[]
                 {
                     ("Organize", Str(opt, "organize")),
                     ("Severities", string.Join(", ", Arr(opt, "severities"))),
                     ("Areas", string.Join(", ", Arr(opt, "areas"))),
                     ("Drivers", Arr(opt, "drivers") is { Length: > 0 } d ? string.Join(", ", d) : "(none)"),
                     ("TopN", Int(opt, "topN").ToString(CultureInfo.InvariantCulture)),
                     ("Sample/pattern", Int(opt, "samplePerPattern").ToString(CultureInfo.InvariantCulture)),
                     ("Time window", winTxt),
                     ("Format", Str(opt, "format"))
                 })
            sb.AppendLine($"<tr><td>{E(k)}</td><td class=\"mono\">{E(v)}</td></tr>");
        sb.AppendLine("</tbody></table></div></section>");

        // Findings
        sb.AppendLine("<section id=\"findings\"><h2>Findings</h2><ul class=\"findings\">");
        var findings = snap.TryGetValue("findings", out var fObj) && fObj is List<string> fl ? fl : [];
        if (findings.Count == 0) sb.AppendLine("<li class=\"muted\">No findings.</li>");
        else foreach (var f in findings) sb.AppendLine($"<li>{E(f)}</li>");
        sb.AppendLine("</ul></section>");

        // Severity KPIs
        var sevCounts = snap.TryGetValue("severityCounts", out var sevObj) ? AsObjDict(sevObj) : [];
        sb.AppendLine("<section id=\"severity\"><h2>Severity counts</h2><div class=\"kpi-row\">");
        foreach (var s in new[] { "FATAL", "SEVERE", "ERROR", "WARNING", "INFO" })
            sb.AppendLine(CultureInfo.InvariantCulture,
                $"<div class=\"kpi\" data-sev=\"{s}\"><div class=\"label\">{s}</div><div class=\"value\">{Int(sevCounts, s):N0}</div></div>");
        sb.AppendLine("</div></section>");

        // Charts
        var series = Dict(snap, "series");
        var gran = Str(series, "granularity");
        if (string.IsNullOrEmpty(gran)) gran = "minute";
        sb.AppendLine($"<section id=\"charts\"><h2>Activity charts (by {E(gran)})</h2>");
        var points = Rows(series, "byMinute");
        if (points.Count == 0)
            sb.AppendLine("<p class=\"muted\">No series points in window.</p>");
        else
        {
            var (buckets, peakVol, peakVolN, peakBac, peakBacN) = ChartSeriesBuilder.PeakSummary(points);
            sb.AppendLine(CultureInfo.InvariantCulture,
                $"<p class=\"meta\">{buckets:N0} {E(gran)} buckets in series. Charts are peak-preserving downsamples (not every bucket drawn).</p>");
            if (peakVol is not null && peakVolN > 0)
                sb.AppendLine(CultureInfo.InvariantCulture,
                    $"<p class=\"meta\">Peak message volume: <strong>{peakVolN:N0}</strong> at <span class=\"mono\">{E(Str(peakVol, "t"))}</span> (FATAL {ChartSeriesBuilder.Int(peakVol, "FATAL")}, SEVERE {ChartSeriesBuilder.Int(peakVol, "SEVERE")}, ERROR {ChartSeriesBuilder.Int(peakVol, "ERROR")}, WARNING {ChartSeriesBuilder.Int(peakVol, "WARNING")}, INFO {ChartSeriesBuilder.Int(peakVol, "INFO")}).</p>");
            if (peakBac is not null && peakBacN > 0)
                sb.AppendLine(CultureInfo.InvariantCulture,
                    $"<p class=\"meta\">Peak BACnet Failed: <strong>{peakBacN:N0}</strong> at <span class=\"mono\">{E(Str(peakBac, "t"))}</span> (OK in that bucket: {ChartSeriesBuilder.Int(peakBac, "bacOk"):N0}).</p>");
            sb.AppendLine("<div class=\"card\"><h3>Message volume</h3>");
            sb.AppendLine("<div class=\"legend\"><span><span class=\"swatch\" style=\"background:#e00000\"></span>FATAL</span><span><span class=\"swatch\" style=\"background:#c000a0\"></span>SEVERE</span><span><span class=\"swatch\" style=\"background:#b00040\"></span>ERROR</span><span><span class=\"swatch\" style=\"background:#e07000\"></span>WARNING</span><span><span class=\"swatch\" style=\"background:#008000\"></span>INFO</span><span><span class=\"swatch\" style=\"background:#e0a000\"></span>project up</span></div>");
            sb.AppendLine(ChartSeriesBuilder.BuildVolumeSvg(points, gran));
            sb.AppendLine("<p class=\"meta\">Dashed amber line = project up / restart (pmon).</p></div>");
            sb.AppendLine("<div class=\"card\"><h3>BACnet Failed / OK</h3>");
            sb.AppendLine("<div class=\"legend\"><span><span class=\"swatch\" style=\"background:#c000a0\"></span>Failed</span><span><span class=\"swatch\" style=\"background:#008000\"></span>OK</span><span><span class=\"swatch\" style=\"background:#e0a000\"></span>project up</span></div>");
            sb.AppendLine(ChartSeriesBuilder.BuildBacnetSvg(points, gran));
            sb.AppendLine("</div>");
        }
        sb.AppendLine("</section>");

        if (inc.Hourly) AppendHourly(sb, Dict(snap, "hourly"));
        AppendProject(sb, Dict(snap, "projectLifecycle"));
        AppendManagerHealth(sb, Dict(snap, "managerHealth"));
        if (inc.Managers) AppendTopManagers(sb, snap);
        if (inc.SeverityPatterns) AppendPatterns(sb, Dict(snap, "patternsBySeverity"));
        if (inc.ModuleHeadlines) AppendHeadlines(sb, Dict(snap, "moduleHeadlines"));
        if (inc.Bacnet) AppendBacnet(sb, Dict(snap, "bacnet"));
        if (inc.Cns) AppendCns(sb, Dict(snap, "cns"));
        if (inc.Coho) AppendCoho(sb, Dict(snap, "coho"));
        if (inc.Apogee) AppendApogee(sb, Dict(snap, "apogee"));
        if (inc.Detections) AppendDetections(sb, snap);
        if (inc.Perf) AppendPerf(sb, Dict(snap, "perf"));

        sb.AppendLine(CultureInfo.InvariantCulture,
            $"<footer>Snapshot from live Watch state (no re-scan). Watch v{E(Str(meta, "version"))} &middot; tool by {E(author)}.</footer>");
        sb.AppendLine("</main></body></html>");
        return sb.ToString();
    }

    private static void AppendHourly(StringBuilder sb, Dictionary<string, object?> hr)
    {
        sb.AppendLine("<section id=\"hourly\"><h2>Hourly volume</h2><div class=\"card\">");
        if (Int(hr, "hourCount") > 0)
        {
            if (Bool(hr, "truncated"))
            {
                sb.AppendLine(CultureInfo.InvariantCulture,
                    $"<p class=\"meta\">Hours in analyzed window: {Int(hr, "hourCount"):N0} (showing most recent 24 + top 10 busiest)</p>");
                AppendHourlyTable(sb, Rows(hr, "rows"));
                sb.AppendLine("<h3>Busiest hours (top 10 by total lines)</h3>");
                AppendHourlyTable(sb, Rows(hr, "busiest"));
            }
            else
            {
                sb.AppendLine(CultureInfo.InvariantCulture,
                    $"<p class=\"meta\">Hours in analyzed window: {Int(hr, "hourCount"):N0}</p>");
                AppendHourlyTable(sb, Rows(hr, "rows"));
            }
        }
        else sb.AppendLine("<p class=\"muted\">No hourly data.</p>");
        sb.AppendLine("</div></section>");
    }

    private static void AppendHourlyTable(StringBuilder sb, List<Dictionary<string, object?>> rows)
    {
        sb.AppendLine("<table class=\"data\"><thead><tr><th>Hour</th><th>All</th><th>SEVERE</th><th>WARNING</th></tr></thead><tbody>");
        foreach (var r in rows)
            sb.AppendLine(CultureInfo.InvariantCulture,
                $"<tr><td class=\"mono\">{E(Str(r, "hour"))}</td><td>{Int(r, "total"):N0}</td><td>{Int(r, "severe"):N0}</td><td>{Int(r, "warning"):N0}</td></tr>");
        sb.AppendLine("</tbody></table>");
    }

    private static void AppendProject(StringBuilder sb, Dictionary<string, object?> pl)
    {
        sb.AppendLine("<section id=\"project\"><h2>Project restarts (pmon)</h2>");
        sb.AppendLine("<p class=\"meta\">Each row is one cycle: up &rarr; shutdown &rarr; stopped &rarr; next up. Uptime = up to shutdown; stop = shutdown to stopped; downtime = stopped to next up. START_MODE counted only (too frequent to list).</p>");
        var cycles = Rows(pl, "cycles");
        var capNote = Bool(pl, "capped") ? " (events capped at 200)" : "";
        sb.AppendLine(CultureInfo.InvariantCulture,
            $"<p class=\"meta\">up={Int(pl, "up"):N0}  &middot;  stopped={Int(pl, "stopped"):N0}  &middot;  shutdown={Int(pl, "shutdown"):N0}  &middot;  START_MODE={Int(pl, "startMode"):N0}  &middot;  cycles={cycles.Count:N0}{E(capNote)}</p>");
        if (Int(pl, "up") + Int(pl, "stopped") + Int(pl, "shutdown") == 0)
            sb.AppendLine("<p class=\"muted\">No project up / stop / shutdown events in this window.</p>");
        else if (cycles.Count == 0)
            sb.AppendLine("<p class=\"muted\">No project lifecycle data.</p>");
        else
        {
            sb.AppendLine("<table class=\"data\"><thead><tr><th>Up</th><th>Shutdown</th><th>Uptime</th><th>Stopped</th><th>Stop</th><th>Downtime</th><th>Note</th></tr></thead><tbody>");
            foreach (var c in cycles)
            {
                var upLabel = Str(c, "up");
                if (Bool(c, "upImplied") && upLabel.Length > 0) upLabel += " (window start)";
                var note = "";
                if (Bool(c, "stillUp") && !string.IsNullOrEmpty(Str(c, "nextUp"))) note = "no shutdown before next up";
                else if (Bool(c, "stillUp")) note = "still up";
                else if (Bool(c, "stillDown")) note = "still down";
                else if (string.IsNullOrEmpty(Str(c, "shutdown")) && !string.IsNullOrEmpty(Str(c, "stopped"))) note = "no shutdown line";
                sb.AppendLine(CultureInfo.InvariantCulture,
                    $"<tr><td class=\"mono kind-up\">{E(upLabel)}</td><td class=\"mono kind-shutdown\">{E(Str(c, "shutdown"))}</td><td>{E(Str(c, "uptime"))}</td><td class=\"mono kind-stopped\">{E(Str(c, "stopped"))}</td><td>{E(Str(c, "stopDuration"))}</td><td>{E(Str(c, "downtime"))}</td><td class=\"meta\">{E(note)}</td></tr>");
            }
            sb.AppendLine("</tbody></table>");
        }
        sb.AppendLine("</section>");
    }

    private static void AppendManagerHealth(StringBuilder sb, Dictionary<string, object?> mh)
    {
        sb.AppendLine("<section id=\"mgr-health\"><h2>Manager health (pmon)</h2>");
        sb.AppendLine("<p class=\"meta\">Start/stop = Manager Start PROJ / Manager Stop. Restarts = Detected stopped manager. Blocking = no heartbeat.</p>");
        var t = Dict(mh, "totals");
        sb.AppendLine(CultureInfo.InvariantCulture,
            $"<p>Starts: <strong>{Int(t, "starts"):N0}</strong>  &middot;  Stops: <strong>{Int(t, "stops"):N0}</strong>  &middot;  Auto-restarts: <strong>{Int(t, "restarts"):N0}</strong>  &middot;  Blocking: <strong>{Int(t, "blocking"):N0}</strong>  &middot;  Unblocked: <strong>{Int(t, "unblocked"):N0}</strong>  &middot;  Driver-ready: <strong>{Int(mh, "driverReady"):N0}</strong></p>");
        var sample = Str(mh, "blockingSample");
        if (!string.IsNullOrEmpty(sample)) sb.AppendLine($"<p class=\"meta mono\">{E(sample)}</p>");
        var unblock = Str(mh, "unblockingSample");
        if (!string.IsNullOrEmpty(unblock)) sb.AppendLine($"<p class=\"meta mono\">{E(unblock)}</p>");
        var rows = Rows(mh, "managers");
        if (rows.Count > 0)
        {
            sb.AppendLine("<table class=\"data\"><thead><tr><th>Manager</th><th>Starts</th><th>Stops</th><th>Restarts</th><th>Blocking</th><th>Unblocked</th></tr></thead><tbody>");
            foreach (var r in rows)
                sb.AppendLine(CultureInfo.InvariantCulture,
                    $"<tr><td class=\"mono\">{E(Str(r, "name"))}</td><td>{Int(r, "starts"):N0}</td><td>{Int(r, "stops"):N0}</td><td>{Int(r, "restarts"):N0}</td><td>{Int(r, "blocking"):N0}</td><td>{Int(r, "unblocked"):N0}</td></tr>");
            sb.AppendLine("</tbody></table>");
        }
        else sb.AppendLine("<p class=\"muted\">No per-manager start/stop/blocking activity.</p>");
        sb.AppendLine("</section>");
    }

    private static void AppendTopManagers(StringBuilder sb, Dictionary<string, object?> snap)
    {
        sb.AppendLine("<section id=\"managers\"><h2>Top managers</h2>");
        var mgrs = Rows(snap, "topManagers");
        var byName = Rows(snap, "managers").Where(m => m.ContainsKey("name"))
            .ToDictionary(m => Str(m, "name"), m => m, StringComparer.Ordinal);
        if (mgrs.Count == 0) sb.AppendLine("<p class=\"muted\">No managers.</p>");
        else
        {
            sb.AppendLine("<table class=\"data\"><thead><tr><th>Count</th><th>FATAL</th><th>SEVERE</th><th>ERROR</th><th>WARNING</th><th>INFO</th><th>Manager</th></tr></thead><tbody>");
            foreach (var m in mgrs)
            {
                var name = Str(m, "name");
                var sev = byName.TryGetValue(name, out var full) ? Dict(full, "severities") : [];
                sb.AppendLine(CultureInfo.InvariantCulture,
                    $"<tr><td>{Int(m, "count"):N0}</td><td>{Int(sev, "FATAL"):N0}</td><td>{Int(sev, "SEVERE"):N0}</td><td>{Int(sev, "ERROR"):N0}</td><td>{Int(sev, "WARNING"):N0}</td><td>{Int(sev, "INFO"):N0}</td><td class=\"mono\">{E(name)}</td></tr>");
            }
            sb.AppendLine("</tbody></table>");
        }
        sb.AppendLine("</section>");
    }

    private static void AppendPatterns(StringBuilder sb, Dictionary<string, object?> patterns)
    {
        sb.AppendLine("<section id=\"patterns\"><h2>Patterns by severity</h2>");
        foreach (var s in new[] { "FATAL", "SEVERE", "ERROR", "WARNING" })
        {
            var color = s switch
            {
                "FATAL" => "var(--sev-fatal)",
                "SEVERE" => "var(--sev-severe)",
                "ERROR" => "var(--sev-error)",
                _ => "var(--sev-warning)"
            };
            var list = Rows(patterns, s);
            sb.AppendLine($"<h3 style=\"color:{color}\">{s} <span class=\"meta\">({list.Count})</span></h3>");
            if (list.Count == 0) { sb.AppendLine("<p class=\"muted\">No patterns (filtered out or none in window).</p>"); continue; }
            AppendPatternTable(sb, list);
        }
        sb.AppendLine("</section>");
    }

    private static void AppendPatternTable(StringBuilder sb, List<Dictionary<string, object?>> rows)
    {
        sb.AppendLine("<table class=\"data\"><thead><tr><th>Count</th><th>First</th><th>Last</th><th>Pattern</th><th>Example</th></tr></thead><tbody>");
        foreach (var r in rows)
        {
            var sample = FirstSample(r);
            sb.AppendLine(CultureInfo.InvariantCulture,
                $"<tr><td>{Int(r, "count"):N0}</td><td class=\"meta\">{E(Str(r, "first"))}</td><td class=\"meta\">{E(Str(r, "last"))}</td><td class=\"mono\">{E(Str(r, "pattern"))}</td><td class=\"mono meta\">{E(sample)}</td></tr>");
        }
        sb.AppendLine("</tbody></table>");
    }

    private static string FirstSample(Dictionary<string, object?> r)
    {
        if (!r.TryGetValue("samples", out var sObj) || sObj is null) return "";
        if (sObj is string[] sa && sa.Length > 0) return sa[0];
        if (sObj is List<string> list && list.Count > 0) return list[0];
        if (sObj is object[] objs && objs.Length > 0) return Convert.ToString(objs[0]) ?? "";
        return "";
    }

    private static void AppendHeadlines(StringBuilder sb, Dictionary<string, object?> mh)
    {
        sb.AppendLine("<section id=\"headlines\"><h2>Module headlines</h2><div class=\"card\">");
        var bac = Dict(mh, "bacnet");
        var cns = Dict(mh, "cns");
        var coho = Dict(mh, "coho");
        var apo = Dict(mh, "apogee");
        sb.AppendLine(CultureInfo.InvariantCulture,
            $"<p>BACnet &mdash; Failed: <strong>{Int(bac, "failed"):N0}</strong> &middot; OK: <strong>{Int(bac, "ok"):N0}</strong> &middot; object list: <strong>{Int(bac, "objectList"):N0}</strong> &middot; CollectTrend: <strong>{Int(bac, "collectTrend"):N0}</strong> &middot; TimeSync: <strong>{Int(bac, "timeSync"):N0}</strong></p>");
        sb.AppendLine(CultureInfo.InvariantCulture,
            $"<p>CNS &mdash; ResolveNodes: <strong>{Int(cns, "resolveNodes"):N0}</strong> &middot; ReducedFunction: <strong>{Int(cns, "reducedFunction"):N0}</strong> &middot; TryRenewSession: <strong>{Int(cns, "tryRenew"):N0}</strong> &middot; ICns: <strong>{Int(cns, "icns"):N0}</strong></p>");
        sb.AppendLine(CultureInfo.InvariantCulture, $"<p>CoHo &mdash; stuck/drop: <strong>{Int(coho, "stuck"):N0}</strong></p>");
        sb.AppendLine(CultureInfo.InvariantCulture,
            $"<p>Apogee &mdash; events: <strong>{Int(apo, "events"):N0}</strong> &middot; UpdatePoints: <strong>{Int(apo, "updatePoints"):N0}</strong> &middot; driver lines: <strong>{Int(apo, "drvLines"):N0}</strong> &middot; trend overflow: <strong>{Int(apo, "trendOverflow"):N0}</strong> &middot; get-data fail: <strong>{Int(apo, "getDataFail"):N0}</strong></p>");
        sb.AppendLine("</div></section>");
    }

    private static void AppendBacnet(StringBuilder sb, Dictionary<string, object?> bac)
    {
        sb.AppendLine("<section id=\"bacnet\"><h2>BACnet</h2><div class=\"card\">");
        sb.AppendLine(CultureInfo.InvariantCulture,
            $"<p>Failed: <strong>{Int(bac, "failed"):N0}</strong> ({Int(bac, "failedDevices"):N0} devices) &middot; OK: <strong>{Int(bac, "ok"):N0}</strong> ({Int(bac, "okDevices"):N0} devices) &middot; ended Failed: <strong>{Int(bac, "endedFailed"):N0}</strong> &middot; ended OK: <strong>{Int(bac, "endedOk"):N0}</strong> &middot; flappers: <strong>{Int(bac, "flappers"):N0}</strong></p>");
        sb.AppendLine(CultureInfo.InvariantCulture,
            $"<p>Object-list: <strong>{Int(bac, "objectList"):N0}</strong> ({Int(bac, "objectListDevices"):N0} devices) &middot; CollectTrend: <strong>{Int(bac, "collectTrend"):N0}</strong> ({Int(bac, "collectTrendProps"):N0} properties) &middot; TimeSync: <strong>{Int(bac, "timeSync"):N0}</strong> ({Int(bac, "timeSyncProps"):N0} properties)</p>");
        if (!string.IsNullOrEmpty(Str(bac, "failedSample")))
            sb.AppendLine($"<p class=\"muted mono\">Failed example: {E(Str(bac, "failedSample"))}</p>");
        if (!string.IsNullOrEmpty(Str(bac, "okSample")))
            sb.AppendLine($"<p class=\"muted mono\">OK example: {E(Str(bac, "okSample"))}</p>");
        var activity = Rows(bac, "activity");
        if (activity.Count > 0)
        {
            sb.AppendLine("<h3>Device status activity</h3><table class=\"data\"><thead><tr><th>Device</th><th>Failed</th><th>OK</th><th>Flips</th><th>Last</th></tr></thead><tbody>");
            foreach (var row in activity)
                sb.AppendLine(CultureInfo.InvariantCulture,
                    $"<tr><td class=\"mono\">{E(Str(row, "device"))}</td><td>{Int(row, "failed"):N0}</td><td>{Int(row, "ok"):N0}</td><td>{Int(row, "flips"):N0}</td><td>{E(Str(row, "last"))}</td></tr>");
            sb.AppendLine("</tbody></table>");
        }
        var ended = Rows(bac, "endedFailedList");
        if (ended.Count > 0)
        {
            sb.AppendLine("<h3>Devices that ended Failed</h3><table class=\"data\"><thead><tr><th>Device</th><th>Failed</th><th>OK</th><th>Flips</th></tr></thead><tbody>");
            foreach (var row in ended)
                sb.AppendLine(CultureInfo.InvariantCulture,
                    $"<tr><td class=\"mono\">{E(Str(row, "device"))}</td><td>{Int(row, "failed"):N0}</td><td>{Int(row, "ok"):N0}</td><td>{Int(row, "flips"):N0}</td></tr>");
            sb.AppendLine("</tbody></table>");
        }
        if (!string.IsNullOrEmpty(Str(bac, "objectListSample")))
            sb.AppendLine($"<p class=\"muted mono\">Object-list example: {E(Str(bac, "objectListSample"))}</p>");
        AppendCountName(sb, Rows(bac, "objectListTop"), "device", "Device", "Top object-list devices");
        if (Int(bac, "collectTrend") > 0 || Rows(bac, "collectTrendCodes").Count > 0)
        {
            sb.AppendLine("<h3>BACnetCollectTrend</h3>");
            if (!string.IsNullOrEmpty(Str(bac, "collectTrendSample")))
                sb.AppendLine($"<p class=\"muted mono\">{E(Str(bac, "collectTrendSample"))}</p>");
            if (Rows(bac, "collectTrendCodes").Count > 0)
            {
                sb.AppendLine("<p class=\"meta\">Error codes</p>");
                AppendCountName(sb, Rows(bac, "collectTrendCodes"), "code", "Code", "");
            }
            if (Rows(bac, "collectTrendTop").Count > 0)
            {
                sb.AppendLine("<p class=\"meta\">Top properties</p>");
                AppendCountName(sb, Rows(bac, "collectTrendTop"), "property", "Property", "");
            }
        }
        if (Int(bac, "timeSync") > 0 || Rows(bac, "timeSyncCodes").Count > 0)
        {
            sb.AppendLine("<h3>BACnetTimeSync</h3>");
            if (!string.IsNullOrEmpty(Str(bac, "timeSyncSample")))
                sb.AppendLine($"<p class=\"muted mono\">{E(Str(bac, "timeSyncSample"))}</p>");
            if (Rows(bac, "timeSyncCodes").Count > 0)
            {
                sb.AppendLine("<p class=\"meta\">Error codes</p>");
                AppendCountName(sb, Rows(bac, "timeSyncCodes"), "code", "Code", "");
            }
            if (Rows(bac, "timeSyncTop").Count > 0)
            {
                sb.AppendLine("<p class=\"meta\">Top properties</p>");
                AppendCountName(sb, Rows(bac, "timeSyncTop"), "property", "Property", "");
            }
        }
        AppendLifecycleTable(sb, Dict(bac, "lifecycle"), "BACnet manager health");
        sb.AppendLine("</div></section>");
    }

    private static void AppendCns(StringBuilder sb, Dictionary<string, object?> cns)
    {
        sb.AppendLine("<section id=\"cns\"><h2>CNS</h2><div class=\"card\">");
        sb.AppendLine(CultureInfo.InvariantCulture,
            $"<p>ResolveNodes: <strong>{Int(cns, "resolveNodes"):N0}</strong> &middot; ReducedFunction: <strong>{Int(cns, "reducedFunction"):N0}</strong> &middot; ICns: <strong>{Int(cns, "icns"):N0}</strong> &middot; TryRenewSession: <strong>{Int(cns, "tryRenew"):N0}</strong></p>");
        var pats = Rows(cns, "patterns");
        if (pats.Count > 0) { sb.AppendLine("<h3>CNS patterns</h3>"); AppendPatternTable(sb, pats); }
        AppendLifecycleTable(sb, Dict(cns, "lifecycle"), "CNS-related manager health");
        sb.AppendLine("</div></section>");
    }

    private static void AppendCoho(StringBuilder sb, Dictionary<string, object?> coho)
    {
        sb.AppendLine("<section id=\"coho\"><h2>CoHo</h2><div class=\"card\">");
        sb.AppendLine(CultureInfo.InvariantCulture, $"<p>Stuck/drop: <strong>{Int(coho, "stuck"):N0}</strong></p>");
        if (!string.IsNullOrEmpty(Str(coho, "sample")))
            sb.AppendLine($"<p class=\"mono meta\">{E(Str(coho, "sample"))}</p>");
        AppendCountName(sb, Rows(coho, "topNames"), "name", "Name", "Top stuck names");
        AppendLifecycleTable(sb, Dict(coho, "lifecycle"), "CoHo manager health");
        sb.AppendLine("</div></section>");
    }

    private static void AppendApogee(StringBuilder sb, Dictionary<string, object?> apo)
    {
        sb.AppendLine("<section id=\"apogee\"><h2>Apogee</h2><div class=\"card\">");
        if (Int(apo, "events") + Int(apo, "drvLines") + Int(apo, "trendOverflow") + Int(apo, "alertId") + Int(apo, "getDataFail") > 0)
        {
            sb.AppendLine("<h3>CoHo / Orch Apogee</h3>");
            var other = Int(apo, "other") > 0
                ? string.Create(CultureInfo.InvariantCulture, $" &middot; Other: <strong>{Int(apo, "other"):N0}</strong>")
                : "";
            sb.AppendLine(CultureInfo.InvariantCulture,
                $"<p>Events: <strong>{Int(apo, "events"):N0}</strong> &middot; UpdatePoints: <strong>{Int(apo, "updatePoints"):N0}</strong> &middot; Trace repetitions: <strong>{Int(apo, "repetition"):N0}</strong>{other} &middot; unique PPCL: <strong>{Int(apo, "uniquePpcl"):N0}</strong></p>");
            if (!string.IsNullOrEmpty(Str(apo, "sample")))
                sb.AppendLine($"<p class=\"muted mono\">{E(Str(apo, "sample"))}</p>");
            var topPpcl = Rows(apo, "topPpcl");
            if (topPpcl.Count > 0)
            {
                sb.AppendLine("<p class=\"meta\">Top PPCL programs by UpdatePoints</p>");
                AppendCountName(sb, topPpcl, "name", "PPCL", "");
            }
            sb.AppendLine("<h3>WCCOAApogeeDrv</h3>");
            sb.AppendLine(CultureInfo.InvariantCulture,
                $"<p>Driver lines: <strong>{Int(apo, "drvLines"):N0}</strong> &middot; trend overflow: <strong>{Int(apo, "trendOverflow"):N0}</strong> ({Int(apo, "trendDevices"):N0} devices, {Int(apo, "trendNames"):N0} trends) &middot; sequence gaps: <strong>{Int(apo, "trendSeq"):N0}</strong></p>");
            sb.AppendLine(CultureInfo.InvariantCulture,
                $"<p>AlertID: <strong>{Int(apo, "alertId"):N0}</strong> &middot; query timeout: <strong>{Int(apo, "queryTimeout"):N0}</strong> &middot; get-data fail: <strong>{Int(apo, "getDataFail"):N0}</strong> ({Int(apo, "getDataDevices"):N0} devices)</p>");
            if (!string.IsNullOrEmpty(Str(apo, "trendSample")))
                sb.AppendLine($"<p class=\"muted mono\">Trend example: {E(Str(apo, "trendSample"))}</p>");
            if (!string.IsNullOrEmpty(Str(apo, "alertSample")))
                sb.AppendLine($"<p class=\"muted mono\">AlertID example: {E(Str(apo, "alertSample"))}</p>");
            if (!string.IsNullOrEmpty(Str(apo, "timeoutSample")))
                sb.AppendLine($"<p class=\"muted mono\">Timeout example: {E(Str(apo, "timeoutSample"))}</p>");
            if (!string.IsNullOrEmpty(Str(apo, "getDataSample")))
                sb.AppendLine($"<p class=\"muted mono\">Get-data example: {E(Str(apo, "getDataSample"))}</p>");
            AppendCountName(sb, Rows(apo, "topTrendDevices"), "device", "Device", "Top devices by trend overflow");
            AppendCountName(sb, Rows(apo, "topTrends"), "trend", "Trend", "Top trends by overflow");
            AppendCountName(sb, Rows(apo, "topGetDataDevices"), "device", "Device", "Top devices by get-data failure");
        }
        else sb.AppendLine("<p class=\"muted\">No Apogee data.</p>");
        AppendLifecycleTable(sb, Dict(apo, "lifecycle"), "ApogeeDrv manager health");
        sb.AppendLine("</div></section>");
    }

    private static void AppendLifecycleTable(StringBuilder sb, Dictionary<string, object?> life, string title)
    {
        var rows = Rows(life, "managers");
        if (rows.Count == 0) return;
        sb.AppendLine($"<h3>{E(title)}</h3><table class=\"data\"><thead><tr><th>Manager</th><th>Starts</th><th>Stops</th><th>Restarts</th><th>Blocking</th><th>Unblocked</th></tr></thead><tbody>");
        foreach (var r in rows)
            sb.AppendLine(CultureInfo.InvariantCulture,
                $"<tr><td class=\"mono\">{E(Str(r, "name"))}</td><td>{Int(r, "starts"):N0}</td><td>{Int(r, "stops"):N0}</td><td>{Int(r, "restarts"):N0}</td><td>{Int(r, "blocking"):N0}</td><td>{Int(r, "unblocked"):N0}</td></tr>");
        sb.AppendLine("</tbody></table>");
    }

    private static void AppendDetections(StringBuilder sb, Dictionary<string, object?> snap)
    {
        sb.AppendLine("<section id=\"detections\"><h2>Detections</h2><div class=\"card\">");
        var groups = snap.TryGetValue("detections", out var d) && d is List<Dictionary<string, object?>> list
            ? list
            : Rows(snap, "detections");
        if (groups.Count == 0) sb.AppendLine("<p class=\"muted\">No rule detections in this window.</p>");
        else
        {
            foreach (var g in groups)
            {
                sb.AppendLine(CultureInfo.InvariantCulture,
                    $"<h3>{E(Str(g, "group"))} <span class=\"meta\">({Int(g, "total"):N0} lines)</span></h3>");
                foreach (var r in Rows(g, "rules"))
                    AppendDetectionRule(sb, r);
            }
        }
        sb.AppendLine("</div></section>");
    }

    private static void AppendDetectionRule(StringBuilder sb, Dictionary<string, object?> r)
    {
        var sevs = AsObjDict(r.TryGetValue("severities", out var sevObj) ? sevObj : null);
        var sevWord = "";
        var sevTxt = "";
        if (sevs.Count == 1)
        {
            var only = sevs.First();
            if (Convert.ToInt32(only.Value) == Int(r, "count"))
                sevWord = E(only.Key) + " ";
        }
        else if (sevs.Count > 1)
        {
            var parts = sevs.Select(kv =>
                string.Create(CultureInfo.InvariantCulture, $"{E(kv.Key)} {Convert.ToInt32(kv.Value):N0}"));
            sevTxt = " &middot; " + string.Join(", ", parts);
        }

        var measures = AsObjDict(r.TryGetValue("measures", out var mObj) ? mObj : null);
        string head;
        if (measures.Count > 0)
        {
            var parts = measures.Select(kv =>
                string.Create(CultureInfo.InvariantCulture, $"{E(kv.Key)}: <strong>{Convert.ToInt64(kv.Value):N0}</strong>"));
            head = string.Join(" &middot; ", parts) +
                   string.Create(CultureInfo.InvariantCulture, $" &middot; over {Int(r, "count"):N0} {sevWord}line(s)");
        }
        else
            head = string.Create(CultureInfo.InvariantCulture, $"<strong>{Int(r, "count"):N0}</strong> {sevWord}line(s)");

        sb.AppendLine($"<h4>{E(Str(r, "label"))}{RuleBadgeHtml(r)}</h4>");
        sb.AppendLine($"<p>{head}{sevTxt}</p>");
        if (!string.IsNullOrEmpty(Str(r, "first")))
        {
            var span = LifecycleBuilder.FormatDurationLabel(Convert.ToDouble(r.TryGetValue("spanSec", out var ss) && ss is not null ? ss : 0));
            sb.AppendLine(CultureInfo.InvariantCulture,
                $"<p class=\"meta\">{E(Str(r, "first"))} &rarr; {E(Str(r, "last"))} &middot; {E(span)} &middot; rule <span class=\"mono\">{E(Str(r, "id"))}</span></p>");
        }
        if (!string.IsNullOrEmpty(Str(r, "sample")))
            sb.AppendLine($"<p class=\"muted mono\">{E(Str(r, "sample"))}</p>");

        var buckets = AsObjDict(r.TryGetValue("buckets", out var bObj) ? bObj : null);
        foreach (var (bname, bval) in buckets)
        {
            var b = AsObjDict(bval);
            var top = Rows(b, "top");
            if (top.Count == 0) continue;
            if (Int(b, "distinct") == 1 && top.Count == 1)
            {
                sb.AppendLine($"<p class=\"meta\">All from {E(bname)} <span class=\"mono\">{E(Str(top[0], "value"))}</span></p>");
                continue;
            }
            var capped = Bool(b, "capped") ? " (capped)" : "";
            sb.AppendLine(CultureInfo.InvariantCulture,
                $"<p class=\"meta\">By {E(bname)} &mdash; {Int(b, "distinct"):N0} distinct{E(capped)}</p>");
            AppendCountName(sb, top, "value", bname, "", cssClass: "data kv");
        }
    }

    private static string RuleBadgeHtml(Dictionary<string, object?> r)
    {
        var at = Int(r, "findingAt");
        if (at <= 0) return "";
        var over = Convert.ToDouble(r.TryGetValue("over", out var o) && o is not null ? o : 0);
        var n = over >= 10
            ? over.ToString("N0", CultureInfo.InvariantCulture)
            : over.ToString("N1", CultureInfo.InvariantCulture);
        var cls = over >= 1 ? "badge over" : "badge";
        return string.Create(CultureInfo.InvariantCulture,
            $" <span class=\"{cls}\" title=\"Raises a finding at {at:N0} line(s)\">{n}&times; threshold</span>");
    }

    private static void AppendPerf(StringBuilder sb, Dictionary<string, object?> perf)
    {
        sb.AppendLine("<section id=\"perf\"><h2>Perf / parse notes</h2><div class=\"card\">");
        var cats = Rows(perf, "perfCategories");
        if (cats.Count > 0)
        {
            sb.AppendLine("<table class=\"data\"><thead><tr><th>Count</th><th>Category</th></tr></thead><tbody>");
            foreach (var row in cats)
                sb.AppendLine(CultureInfo.InvariantCulture,
                    $"<tr><td>{Int(row, "count"):N0}</td><td>{E(Str(row, "name"))}</td></tr>");
            sb.AppendLine("</tbody></table>");
        }
        sb.AppendLine(CultureInfo.InvariantCulture,
            $"<p class=\"meta\">Unparsed / skipped lines: {Int(perf, "unparsedLines"):N0}</p>");
        sb.AppendLine("</div></section>");
    }

    private static void AppendCountName(StringBuilder sb, List<Dictionary<string, object?>> rows,
        string nameKey, string nameHeader, string title, string cssClass = "data")
    {
        if (rows.Count == 0) return;
        if (!string.IsNullOrEmpty(title)) sb.AppendLine($"<h3>{E(title)}</h3>");
        sb.AppendLine($"<table class=\"{E(cssClass)}\"><thead><tr><th>Count</th><th>{E(nameHeader)}</th></tr></thead><tbody>");
        foreach (var row in rows)
            sb.AppendLine(CultureInfo.InvariantCulture,
                $"<tr><td>{Int(row, "count"):N0}</td><td class=\"mono\">{E(Str(row, nameKey))}</td></tr>");
        sb.AppendLine("</tbody></table>");
    }

    private sealed record Sections(
        bool Bacnet, bool Cns, bool Coho, bool Apogee, bool ModuleHeadlines,
        bool SeverityPatterns, bool Managers, bool Perf, bool Hourly, bool Detections);

    private static Sections GetSections(Dictionary<string, object?> opt)
    {
        var organize = Str(opt, "organize");
        var bacnet = true; var cns = true; var coho = true; var apogee = true;
        var headlines = false; var patterns = true; var full = true;
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
            bacnet = cns = coho = apogee = false;
        }
        return new Sections(bacnet, cns, coho, apogee, headlines, patterns,
            full, full, full, !string.Equals(organize, "Severity", StringComparison.OrdinalIgnoreCase));
    }

    private static string E(string? s) => WebUtility.HtmlEncode(s ?? "");

    /// <summary>Coerce nested dictionaries that may be string→int/long/object.</summary>
    private static Dictionary<string, object?> AsObjDict(object? v)
    {
        if (v is Dictionary<string, object?> d) return d;
        if (v is Dictionary<string, int> di)
        {
            var o = new Dictionary<string, object?>(StringComparer.Ordinal);
            foreach (var kv in di) o[kv.Key] = kv.Value;
            return o;
        }
        if (v is Dictionary<string, long> dl)
        {
            var o = new Dictionary<string, object?>(StringComparer.Ordinal);
            foreach (var kv in dl) o[kv.Key] = kv.Value;
            return o;
        }
        if (v is System.Collections.IDictionary idict)
        {
            var o = new Dictionary<string, object?>(StringComparer.Ordinal);
            foreach (System.Collections.DictionaryEntry e in idict)
            {
                if (e.Key is string k) o[k] = e.Value;
            }
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
        if (v is object[] objs)
            return objs.OfType<Dictionary<string, object?>>().ToList();
        return [];
    }
}
