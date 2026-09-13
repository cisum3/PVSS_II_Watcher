using System.Net;
using System.Text;
using System.Text.Json;

namespace DesigoLogWatcher;

/// <summary>
/// 127.0.0.1 HttpListener, static ui\, /api/* from docs/INVENTORY-V0.5.md §3.
/// </summary>
public sealed class HttpServer : IDisposable
{
    private readonly string _uiRoot;
    private readonly Func<WatchSession> _session;
    private HttpListener? _listener;
    private CancellationTokenSource? _cts;
    private Task? _loop;

    public string? ListeningUrl { get; private set; }
    public int BoundPort { get; private set; }

    public HttpServer(string uiRoot, Func<WatchSession> session)
    {
        _uiRoot = uiRoot;
        _session = session;
    }

    public void Start(int preferredPort, int maxTries = 40)
    {
        if (maxTries < 1) maxTries = 1;
        Exception? last = null;
        for (var p = preferredPort; p < preferredPort + maxTries; p++)
        {
            var listener = new HttpListener();
            var prefix = $"http://127.0.0.1:{p}/";
            listener.Prefixes.Add(prefix);
            try
            {
                listener.Start();
                _listener = listener;
                BoundPort = p;
                ListeningUrl = prefix;
                _cts = new CancellationTokenSource();
                _loop = Task.Run(() => ListenLoop(_cts.Token));
                return;
            }
            catch (Exception ex)
            {
                last = ex;
                try { listener.Close(); } catch { /* ignore */ }
            }
        }
        throw new InvalidOperationException($"Could not bind 127.0.0.1 ports {preferredPort}..{preferredPort + maxTries - 1}", last);
    }

    public void Dispose()
    {
        try { _cts?.Cancel(); } catch { /* ignore */ }
        try { _listener?.Stop(); } catch { /* ignore */ }
        try { _listener?.Close(); } catch { /* ignore */ }
        _listener = null;
    }

    private async Task ListenLoop(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested && _listener is { IsListening: true })
        {
            HttpListenerContext ctx;
            try
            {
                ctx = await _listener.GetContextAsync().WaitAsync(ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException) { break; }
            catch (HttpListenerException) { break; }
            catch (ObjectDisposedException) { break; }

            _ = Task.Run(() =>
            {
                try { HandleRequest(ctx); }
                catch (Exception ex)
                {
                    try { WriteStatus(ctx, 500, ex.Message); } catch { /* ignore */ }
                }
            }, ct);
        }
    }

    private void HandleRequest(HttpListenerContext ctx)
    {
        var req = ctx.Request;
        var path = Uri.UnescapeDataString(req.Url?.AbsolutePath ?? "/");
        if (path.StartsWith("/api/", StringComparison.OrdinalIgnoreCase))
        {
            HandleApi(ctx, path.TrimEnd('/'));
            return;
        }
        if (path is "/" or "")
            path = "/index.html";
        var rel = path.TrimStart('/').Replace('/', Path.DirectorySeparatorChar);
        if (rel.Contains("..", StringComparison.Ordinal))
        {
            WriteStatus(ctx, 400, "Invalid path");
            return;
        }
        var full = Path.GetFullPath(Path.Combine(_uiRoot, rel));
        var uiFull = Path.GetFullPath(_uiRoot);
        if (!full.StartsWith(uiFull, StringComparison.OrdinalIgnoreCase))
        {
            WriteStatus(ctx, 400, "Invalid path");
            return;
        }
        if (!File.Exists(full))
        {
            WriteStatus(ctx, 404, "Not found");
            return;
        }
        WriteFile(ctx, full);
    }

    private void HandleApi(HttpListenerContext ctx, string path)
    {
        var session = _session();
        var method = ctx.Request.HttpMethod;

        if (path == "/api/health" && method == "GET")
        {
            WriteJson(ctx, session.BuildHealth(BoundPort, ListeningUrl ?? ""));
            return;
        }
        if (path == "/api/pulse" && method == "GET")
        {
            WriteJson(ctx, session.BuildPulse(ctx.Request.QueryString));
            return;
        }
        if (path == "/api/section" && method == "GET")
        {
            var name = ctx.Request.QueryString["name"];
            if (string.IsNullOrWhiteSpace(name))
            {
                WriteStatus(ctx, 400, "name required");
                return;
            }
            WriteJson(ctx, session.BuildSection(name, ctx.Request.QueryString));
            return;
        }
        if (path == "/api/manager" && method == "GET")
        {
            var name = ctx.Request.QueryString["name"];
            if (string.IsNullOrWhiteSpace(name))
            {
                WriteStatus(ctx, 400, "name required");
                return;
            }
            WriteJson(ctx, session.BuildManager(name, ctx.Request.QueryString));
            return;
        }
        if (path == "/api/snapshot" && method == "GET")
        {
            session.HandleSnapshot(ctx);
            return;
        }
        if (path == "/api/logPath" && method == "POST")
        {
            session.HandleLogPath(ctx);
            return;
        }
        if (path == "/api/control" && method == "POST")
        {
            session.HandleControl(ctx);
            return;
        }
        WriteStatus(ctx, 404, "Not found");
    }

    internal static void WriteJson(HttpListenerContext ctx, object obj, int code = 200)
    {
        var json = JsonSerializer.Serialize(obj);
        var bytes = Encoding.UTF8.GetBytes(json);
        ctx.Response.StatusCode = code;
        ctx.Response.ContentType = "application/json; charset=utf-8";
        ctx.Response.ContentLength64 = bytes.Length;
        ctx.Response.OutputStream.Write(bytes, 0, bytes.Length);
        ctx.Response.Close();
    }

    internal static void WriteStatus(HttpListenerContext ctx, int code, string message)
    {
        var bytes = Encoding.UTF8.GetBytes(message);
        ctx.Response.StatusCode = code;
        ctx.Response.ContentType = "text/plain; charset=utf-8";
        ctx.Response.ContentLength64 = bytes.Length;
        ctx.Response.OutputStream.Write(bytes, 0, bytes.Length);
        ctx.Response.Close();
    }

    internal static void WriteFile(HttpListenerContext ctx, string filePath)
    {
        var bytes = File.ReadAllBytes(filePath);
        ctx.Response.StatusCode = 200;
        ctx.Response.ContentType = Mime(filePath);
        ctx.Response.ContentLength64 = bytes.Length;
        ctx.Response.OutputStream.Write(bytes, 0, bytes.Length);
        ctx.Response.Close();
    }

    internal static void WriteDownload(HttpListenerContext ctx, byte[] bytes, string contentType, string fileName)
    {
        ctx.Response.StatusCode = 200;
        ctx.Response.ContentType = contentType;
        ctx.Response.Headers["Content-Disposition"] = $"attachment; filename=\"{fileName}\"";
        ctx.Response.ContentLength64 = bytes.Length;
        ctx.Response.OutputStream.Write(bytes, 0, bytes.Length);
        ctx.Response.Close();
    }

    private static string Mime(string path) => Path.GetExtension(path).ToLowerInvariant() switch
    {
        ".html" => "text/html; charset=utf-8",
        ".js" => "application/javascript; charset=utf-8",
        ".css" => "text/css; charset=utf-8",
        ".json" => "application/json; charset=utf-8",
        ".svg" => "image/svg+xml",
        ".png" => "image/png",
        ".ico" => "image/x-icon",
        _ => "application/octet-stream"
    };
}

/// <summary>Dashboard session state: catch-up slices, live tail, restart/reload.</summary>
public sealed class WatchSession : IDisposable
{
    private readonly object _gate = new();
    private CancellationTokenSource? _workerCts;
    private Task? _worker;
    private LogParser? _parser;
    private int _workerEpoch;

    public Config Config { get; }
    public AnalysisState Data { get; private set; } = new();
    public RuleEngine Rules { get; } = new();
    public string LogPath { get; set; } = "";
    public string PrefillPath { get; set; } = "";
    public bool WindowEntire { get; set; }
    public int LastMinutes { get; set; } = 60;
    public int Generation { get; private set; }
    public bool Loading { get; set; }
    public bool Paused { get; set; }
    public bool TailRunning { get; set; }
    public bool Rotated { get; set; }
    public int LoadProgressPct { get; set; }
    public string LoadMessage { get; set; } = "";
    public string? LastError { get; set; }
    public long FileLength { get; set; }

    public WatchSession(Config config)
    {
        Config = config;
        PrefillPath = config.Effective.LogPath;
        WindowEntire = config.Effective.DefaultWindowEntire;
        LastMinutes = config.Effective.DefaultWindowMinutes;
    }

    public void Dispose() => StopWorker(waitMs: 3000);

    public void BumpGeneration() => Generation++;

    public object BuildHealth(int boundPort, string listeningUrl)
    {
        lock (_gate)
        {
            return new Dictionary<string, object?>
            {
                ["ok"] = true,
                ["version"] = Program.Version,
                ["author"] = "Cisum",
                ["logPath"] = LogPath,
                ["prefillPath"] = PrefillPath,
                ["listeningUrl"] = listeningUrl,
                ["port"] = boundPort,
                ["preferredPort"] = Config.Effective.PreferredPort,
                ["refreshSeconds"] = Config.Effective.RefreshSeconds,
                ["defaults"] = new Dictionary<string, object?>
                {
                    ["lastMinutes"] = LastMinutes,
                    ["windowEntire"] = WindowEntire,
                    ["severities"] = Config.Effective.DefaultSeverities.ToArray(),
                    ["areas"] = Config.Effective.DefaultAreas.ToArray(),
                    ["topN"] = Config.Effective.TopN
                },
                ["tailRunning"] = TailRunning,
                ["paused"] = Paused,
                ["loading"] = Loading,
                ["loadProgressPct"] = LoadProgressPct,
                ["loadMessage"] = LoadMessage,
                ["fileLength"] = FileLength,
                ["lastError"] = LastError,
                ["generation"] = Generation
            };
        }
    }

    public object BuildPulse(System.Collections.Specialized.NameValueCollection query)
    {
        lock (_gate)
        {
            var sevFilter = ChartSeriesBuilder.ParseSevFilter(query);
            var areaFilter = ChartSeriesBuilder.ParseAreaFilter(query);
            var builder = new SnapshotBuilder(Data, Rules, Config.Effective.TopN, Config.Effective.BacFlapMin);
            var findings = Loading ? new List<string>() : builder.BuildFindings();

            var sevCounts = ApiBuilders.FilteredSeverityCounts(Data, areaFilter);
            // KPIs are area-filtered only (PS Get-FilteredSeverityCounts); sev chips gate charts/patterns.

            var areaCounts = new Dictionary<string, int>();
            foreach (var a in new[] { "SYS", "IMPL", "CTRL", "PARAM", "OTHER" })
                areaCounts[a] = Data.AreaCounts.GetValueOrDefault(a);

            Dictionary<string, object?> series;
            object[] topManagers;
            if (Loading)
            {
                series = new Dictionary<string, object?> { ["granularity"] = "minute", ["byMinute"] = Array.Empty<object>() };
                topManagers = [];
            }
            else
            {
                series = ChartSeriesBuilder.Build(Data, sevFilter, areaFilter);
                topManagers = ApiBuilders.FilteredTopManagers(Data, areaFilter, 20)
                    .Select(m => (object)m).ToArray();
            }

            var endedFailed = Data.BacLastStatus.Count(kv => kv.Value == "Failed");
            var endedOk = Data.BacLastStatus.Count(kv => kv.Value == "OK");
            var flappers = Data.BacFlipByDevice.Count(kv => kv.Value >= Config.Effective.BacFlapMin);
            var headlines = new Dictionary<string, object?>
            {
                ["bacnet"] = new Dictionary<string, object?>
                {
                    ["failed"] = Data.BacFailed, ["ok"] = Data.BacOk,
                    ["endedFailed"] = Loading ? 0 : endedFailed, ["endedOk"] = Loading ? 0 : endedOk,
                    ["flappers"] = Loading ? 0 : flappers, ["objectList"] = Data.BacObjectList,
                    ["collectTrend"] = Data.BacCollectTrend, ["timeSync"] = Data.BacTimeSync,
                    ["collectTrendProps"] = Data.BacCollectTrendByProp.Count,
                    ["timeSyncProps"] = Data.BacTimeSyncByProp.Count
                },
                ["cns"] = new Dictionary<string, object?>
                {
                    ["resolveNodes"] = RuleEngine.GetRuleCount(Data, "cns.resolveNodes"),
                    ["reducedFunction"] = RuleEngine.GetRuleCount(Data, "cns.reducedFunction"),
                    ["tryRenew"] = RuleEngine.GetRuleCount(Data, "cns.tryRenew"),
                    ["icns"] = RuleEngine.GetRuleCount(Data, "cns.icns")
                },
                ["coho"] = new Dictionary<string, object?> { ["stuck"] = Data.CohoStuck },
                ["apogee"] = new Dictionary<string, object?>
                {
                    ["events"] = Data.ApogeeEvents,
                    ["updatePoints"] = Data.ApogeeUpdatePoints,
                    ["drvLines"] = Data.ApogeeDrvLines,
                    ["trendOverflow"] = RuleEngine.GetRuleCount(Data, "apogeeDrv.trendOverflow"),
                    ["trendSeq"] = RuleEngine.GetRuleCount(Data, "apogeeDrv.trendSeq"),
                    ["alertId"] = RuleEngine.GetRuleCount(Data, "apogeeDrv.alertId"),
                    ["getDataFail"] = RuleEngine.GetRuleCount(Data, "apogeeDrv.getDataFail")
                }
            };

            return new Dictionary<string, object?>
            {
                ["generation"] = Generation,
                ["window"] = new Dictionary<string, object?>
                {
                    ["mode"] = WindowEntire ? "entire" : "minutes",
                    ["lastMinutes"] = WindowEntire ? 0 : LastMinutes,
                    ["first"] = Data.FirstTs,
                    ["last"] = Data.LastTs
                },
                ["loading"] = Loading,
                ["loadProgressPct"] = LoadProgressPct,
                ["loadMessage"] = LoadMessage,
                ["paused"] = Paused,
                ["tailRunning"] = TailRunning,
                ["rotated"] = Rotated,
                ["lastError"] = LastError,
                ["logPath"] = LogPath,
                ["fileLength"] = FileLength,
                ["findings"] = findings,
                ["severityCounts"] = sevCounts,
                ["areaCounts"] = areaCounts,
                ["moduleHeadlines"] = headlines,
                ["topManagers"] = topManagers,
                ["series"] = series,
                ["projectLifecycle"] = Loading
                    ? new Dictionary<string, object?>
                    {
                        ["up"] = Data.ProjectUp,
                        ["stopped"] = Data.ProjectStopped,
                        ["shutdown"] = Data.ProjectShutdown,
                        ["startMode"] = Data.ProjectStartMode,
                        ["cycles"] = Array.Empty<object>(),
                        ["capped"] = false
                    }
                    : ApiBuilders.BuildProjectLifecycle(Data, areaFilter)
            };
        }
    }

    public object BuildSection(string name, System.Collections.Specialized.NameValueCollection query)
    {
        lock (_gate)
        {
            var sevFilter = ChartSeriesBuilder.ParseSevFilter(query);
            var areaFilter = ChartSeriesBuilder.ParseAreaFilter(query);
            var topN = Config.Effective.TopN;
            var flap = Config.Effective.BacFlapMin;
            return name.ToLowerInvariant() switch
            {
                "patterns" => new Dictionary<string, object?>
                {
                    ["generation"] = Generation,
                    ["patternsBySeverity"] = ApiBuilders.FilteredPatternsBySeverity(Data, sevFilter, areaFilter, topN)
                },
                "managers" => new Dictionary<string, object?>
                {
                    ["generation"] = Generation,
                    ["managers"] = ApiBuilders.FilteredTopManagers(Data, areaFilter, 5000).ToArray()
                },
                "detections" => new Dictionary<string, object?>
                {
                    ["generation"] = Generation,
                    ["detections"] = ApiBuilders.BuildDetectionsObject(Data, Rules.Rules, topN)
                },
                "perf" => new Dictionary<string, object?>
                {
                    ["generation"] = Generation,
                    ["perfCategories"] = Data.PerfCats.OrderByDescending(kv => kv.Value)
                        .Select(kv => new Dictionary<string, object?> { ["name"] = kv.Key, ["count"] = kv.Value }).ToArray(),
                    ["unparsedLines"] = Data.UnparsedLines,
                    ["parsedLines"] = Data.ParsedLines
                },
                "cns" => new Dictionary<string, object?>
                {
                    ["generation"] = Generation,
                    ["cns"] = ApiBuilders.BuildCnsSection(Data, topN)
                },
                "coho" => new Dictionary<string, object?>
                {
                    ["generation"] = Generation,
                    ["coho"] = ApiBuilders.BuildCohoSection(Data, topN)
                },
                "bacnet" => new Dictionary<string, object?>
                {
                    ["generation"] = Generation,
                    ["bacnet"] = ApiBuilders.BuildBacnetSection(Data, flap, topN)
                },
                "apogee" => new Dictionary<string, object?>
                {
                    ["generation"] = Generation,
                    ["apogee"] = ApiBuilders.BuildApogeeSection(Data, topN)
                },
                _ => new Dictionary<string, object?> { ["generation"] = Generation, ["error"] = $"Unknown section: {name}" }
            };
        }
    }

    public object BuildManager(string name, System.Collections.Specialized.NameValueCollection query)
    {
        lock (_gate)
        {
            var sevFilter = ChartSeriesBuilder.ParseSevFilter(query);
            var areaFilter = ChartSeriesBuilder.ParseAreaFilter(query);
            return ApiBuilders.BuildManagerPayload(Data, name, sevFilter, Config.Effective.TopN, Generation, areaFilter);
        }
    }

    public void HandleLogPath(HttpListenerContext ctx)
    {
        try
        {
            using var reader = new StreamReader(ctx.Request.InputStream, ctx.Request.ContentEncoding);
            var body = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(reader.ReadToEnd())
                       ?? throw new InvalidOperationException("Invalid JSON body");
            if (!body.TryGetValue("path", out var pathEl))
                throw new InvalidOperationException("path required");
            var p = pathEl.GetString() ?? "";
            p = LogParser.AssertLogPathUsable(p);

            lock (_gate)
            {
                PrefillPath = p;
                Config.WriteLogPath(p);
                if (body.TryGetValue("window", out var w) && w.GetString() == "entire")
                    WindowEntire = true;
                else if (body.TryGetValue("lastMinutes", out var lm) && lm.TryGetInt32(out var minutes) && minutes > 0)
                {
                    WindowEntire = false;
                    LastMinutes = minutes;
                }
            }
            RunCatchUpAsync(p);
            HttpServer.WriteJson(ctx, new Dictionary<string, object?> { ["ok"] = true, ["logPath"] = p, ["generation"] = Generation });
        }
        catch (Exception ex)
        {
            LastError = ex.Message;
            HttpServer.WriteStatus(ctx, 400, ex.Message);
        }
    }

    public void HandleControl(HttpListenerContext ctx)
    {
        try
        {
            using var reader = new StreamReader(ctx.Request.InputStream, ctx.Request.ContentEncoding);
            var body = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(reader.ReadToEnd())
                       ?? throw new InvalidOperationException("Invalid JSON body");
            var action = body.TryGetValue("action", out var a) ? a.GetString() ?? "" : "";
            switch (action)
            {
                case "pause":
                    lock (_gate) { Paused = true; BumpGeneration(); }
                    break;
                case "resume":
                    lock (_gate) { Paused = false; BumpGeneration(); }
                    break;
                case "restart":
                    StopWorker(waitMs: 2000);
                    lock (_gate)
                    {
                        Loading = false; TailRunning = false; Paused = false; Rotated = false;
                        LoadMessage = ""; LoadProgressPct = 0; LastError = null;
                        LogPath = "";
                        Data = new AnalysisState();
                        try
                        {
                            var reload = Config.ReloadRuntime();
                            PrefillPath = Config.Effective.LogPath;
                            LastMinutes = Config.Effective.DefaultWindowMinutes;
                            WindowEntire = Config.Effective.DefaultWindowEntire;
                            foreach (var c in reload.RuntimeChanges)
                                Console.WriteLine($"Config reload  {c}");
                        }
                        catch (Exception ex)
                        {
                            Console.WriteLine($"Config reload failed: {ex.Message}");
                        }
                        BumpGeneration();
                    }
                    break;
                case "setWindow":
                {
                    string? path;
                    lock (_gate)
                    {
                        var wantEntire = body.TryGetValue("window", out var win) && win.GetString() == "entire";
                        WindowEntire = wantEntire;
                        if (!wantEntire && body.TryGetValue("lastMinutes", out var lm) && lm.TryGetInt32(out var minutes))
                            LastMinutes = Math.Max(1, minutes);
                        path = LogPath;
                    }
                    if (!string.IsNullOrEmpty(path))
                        RunCatchUpAsync(path);
                    break;
                }
                case "note":
                    break;
                default:
                    throw new InvalidOperationException($"Unknown action: {action}");
            }
            HttpServer.WriteJson(ctx, new Dictionary<string, object?> { ["ok"] = true, ["generation"] = Generation });
        }
        catch (Exception ex)
        {
            HttpServer.WriteStatus(ctx, 400, ex.Message);
        }
    }

    public void HandleSnapshot(HttpListenerContext ctx)
    {
        try
        {
            lock (_gate)
            {
                if (string.IsNullOrEmpty(LogPath))
                {
                    HttpServer.WriteStatus(ctx, 400, "Start a session before taking a snapshot.");
                    return;
                }
                if (Loading)
                {
                    HttpServer.WriteStatus(ctx, 409, "Catch-up still running. Wait until loading finishes, then snapshot.");
                    return;
                }
                var fmt = (ctx.Request.QueryString["format"] ?? "html").ToLowerInvariant();
                var reportFmt = fmt == "text" ? ReportFormat.Text : ReportFormat.Html;
                var sevFilter = ChartSeriesBuilder.ParseSevFilter(ctx.Request.QueryString);
                var areaFilter = ChartSeriesBuilder.ParseAreaFilter(ctx.Request.QueryString);
                var sevList = sevFilter.Where(kv => kv.Value).Select(kv => kv.Key).ToArray();
                var areaList = areaFilter.Where(kv => kv.Value).Select(kv => kv.Key).ToArray();
                var builder = new SnapshotBuilder(Data, Rules, Config.Effective.TopN, Config.Effective.BacFlapMin);
                var snap = builder.BuildSnapshot(
                    LogPath, FileLength, Program.Version,
                    format: reportFmt,
                    windowEntire: WindowEntire, lastMinutes: LastMinutes,
                    severities: sevList, areas: areaList);
                var writer = new ReportWriter();
                var stamp = DateTime.Now.ToString("yyyyMMdd_HHmmss");
                if (fmt == "json")
                {
                    var bytes = Encoding.UTF8.GetBytes(writer.ToJson(snap));
                    HttpServer.WriteDownload(ctx, bytes, "application/json; charset=utf-8", $"PVSS_Log_Watch_Snapshot_{stamp}.json");
                }
                else if (fmt == "text")
                {
                    var bytes = Encoding.UTF8.GetBytes(writer.ToText(snap));
                    HttpServer.WriteDownload(ctx, bytes, "text/plain; charset=utf-8", $"PVSS_Log_Watch_Snapshot_{stamp}.txt");
                }
                else
                {
                    var bytes = Encoding.UTF8.GetBytes(writer.ToHtml(snap));
                    HttpServer.WriteDownload(ctx, bytes, "text/html; charset=utf-8", $"PVSS_Log_Watch_Snapshot_{stamp}.html");
                }
            }
        }
        catch (Exception ex)
        {
            HttpServer.WriteStatus(ctx, 500, ex.Message);
        }
    }

    /// <summary>Kick off sliced catch-up + live tail on a background worker (non-blocking).</summary>
    public void RunCatchUpAsync(string path)
    {
        StopWorker(waitMs: 2000);
        var epoch = Interlocked.Increment(ref _workerEpoch);
        lock (_gate)
        {
            LogPath = path;
            Loading = true;
            LoadProgressPct = 0;
            var mode = WindowEntire ? "Loading entire file" : $"Loading last {LastMinutes} minutes";
            LoadMessage = $"{mode}... 0%";
            TailRunning = false;
            Rotated = false;
            LastError = null;
            Data = new AnalysisState();
            BumpGeneration();
        }

        var cts = new CancellationTokenSource();
        _workerCts = cts;
        _worker = Task.Run(() => WorkerLoop(path, epoch, cts.Token));
    }

    /// <summary>Wait for background catch-up to finish (tests / sync callers).</summary>
    public void RunCatchUpUnlocked(string path)
    {
        RunCatchUpAsync(path);
        var deadline = DateTime.UtcNow.AddMinutes(10);
        while (DateTime.UtcNow < deadline)
        {
            lock (_gate)
            {
                if (!Loading && (TailRunning || LastError is not null))
                    return;
            }
            Thread.Sleep(20);
        }
        throw new TimeoutException("Catch-up did not finish in time.");
    }

    private void StopWorker(int waitMs)
    {
        var cts = _workerCts;
        var worker = _worker;
        try { cts?.Cancel(); } catch { /* ignore */ }
        if (worker is not null && !worker.IsCompleted)
        {
            try { worker.Wait(waitMs); } catch { /* ignore */ }
        }
        lock (_gate)
        {
            try { _parser?.Dispose(); } catch { /* ignore */ }
            _parser = null;
        }
        try { cts?.Dispose(); } catch { /* ignore */ }
        if (ReferenceEquals(_workerCts, cts))
        {
            _workerCts = null;
            _worker = null;
        }
    }

    private void WorkerLoop(string path, int epoch, CancellationToken ct)
    {
        LogParser? parser = null;
        try
        {
            parser = new LogParser();
            parser.Open(path);

            while (!ct.IsCancellationRequested)
            {
                string? cutoff;
                string modeLabel;
                int samplePerPattern, sampleMaxChars;
                long startPos = 0;
                lock (_gate)
                {
                    if (epoch != _workerEpoch) return;
                    _parser = parser;
                    FileLength = parser.FileLength;
                    samplePerPattern = Config.Effective.SamplePerPattern;
                    sampleMaxChars = Config.Effective.SampleMaxChars;
                    Loading = true;
                    TailRunning = false;
                    LoadProgressPct = 0;
                    if (WindowEntire)
                    {
                        cutoff = null;
                        modeLabel = "Loading entire file";
                        startPos = 0;
                    }
                    else
                    {
                        try
                        {
                            var (cutDt, anchor, usedWall) = LogParser.ResolveLastNCutoff(path, LastMinutes);
                            cutoff = LogParser.ToCompareStamp(cutDt);
                            startPos = LogParser.FindWindowStartPosition(path, cutDt);
                            modeLabel = $"Loading last {LastMinutes} minutes";
                            Console.WriteLine(usedWall
                                ? $"[{DateTime.Now:HH:mm:ss}] No EOF timestamp found; wall-clock cutoff {cutDt:yyyy.MM.dd HH:mm:ss}"
                                : $"[{DateTime.Now:HH:mm:ss}] Window anchored to file end {anchor:yyyy.MM.dd HH:mm:ss}; cutoff {cutDt:yyyy.MM.dd HH:mm:ss}");
                        }
                        catch (Exception ex)
                        {
                            LastError = ex.Message;
                            Loading = false;
                            LoadMessage = "";
                            LoadProgressPct = 0;
                            BumpGeneration();
                            Console.WriteLine($"[{DateTime.Now:HH:mm:ss}] {ex.Message}");
                            return;
                        }
                    }
                    LoadMessage = $"{modeLabel}... 0%";
                }

                var progress = parser.BeginCatchUp(startPos);
                var lastLogPct = -1;
                var sw = System.Diagnostics.Stopwatch.StartNew();

                while (!ct.IsCancellationRequested)
                {
                    var slice = System.Diagnostics.Stopwatch.StartNew();
                    var n = 0;
                    var eof = false;
                    lock (_gate)
                    {
                        if (epoch != _workerEpoch) return;
                        while (n < 100_000 && slice.ElapsedMilliseconds < 200)
                        {
                            if (!parser.TryReadLine(out var line))
                            {
                                eof = true;
                                break;
                            }
                            progress.Lines++;
                            progress.CurrentPos = parser.FilePos;
                            Data.ProcessLine(line,
                                samplePerPattern: samplePerPattern,
                                sampleMaxChars: sampleMaxChars,
                                enforceCutoff: cutoff is not null,
                                cutoffCompare: cutoff,
                                rules: Rules);
                            n++;
                        }

                        var pct = (int)Math.Round(progress.Percent);
                        if (!eof && pct > 99) pct = 99;
                        pct = Math.Clamp(pct, 0, 100);
                        LoadProgressPct = pct;
                        LoadMessage = $"{modeLabel}... {pct}%";
                        FileLength = parser.FileLength;

                        if (pct >= lastLogPct + 10 || sw.ElapsedMilliseconds >= 3000)
                        {
                            lastLogPct = pct;
                            sw.Restart();
                            Console.WriteLine($"Catch-up ... {pct}%  scanned={progress.Lines:N0}  parsed={Data.ParsedLines:N0}");
                        }
                    }

                    if (eof) break;
                    Thread.Sleep(0);
                }

                if (ct.IsCancellationRequested) return;

                lock (_gate)
                {
                    if (epoch != _workerEpoch) return;
                    FileLength = parser.FileLength;
                    LoadProgressPct = 100;
                    LoadMessage = "";
                    Loading = false;
                    TailRunning = true;
                    BumpGeneration();
                    Console.WriteLine($"Catch-up done. Parsed {Data.ParsedLines:N0} lines. Tailing…");
                }

                // Live tail until cancel, missing file, or rotation requiring full restart
                var restartCatchUp = false;
                while (!ct.IsCancellationRequested)
                {
                    bool paused;
                    lock (_gate)
                    {
                        if (epoch != _workerEpoch) return;
                        paused = Paused;
                    }
                    if (paused)
                    {
                        Thread.Sleep(50);
                        continue;
                    }

                    lock (_gate)
                    {
                        if (epoch != _workerEpoch) return;
                        if (!File.Exists(path))
                        {
                            LastError = "Log file is missing.";
                            TailRunning = false;
                            BumpGeneration();
                            return;
                        }

                        if (parser.DetectTruncationAndReseek())
                        {
                            Rotated = true;
                            Data = new AnalysisState();
                            restartCatchUp = true;
                            Console.WriteLine("Log truncated/rotated — restarting catch-up.");
                            break;
                        }

                        parser.ReseekIfGrew();
                        var changed = false;
                        foreach (var line in parser.ReadAvailableLines())
                        {
                            Data.ProcessLine(line,
                                samplePerPattern: samplePerPattern,
                                sampleMaxChars: sampleMaxChars,
                                enforceCutoff: false,
                                rules: Rules);
                            changed = true;
                        }
                        FileLength = parser.FileLength;
                        if (changed) BumpGeneration();
                    }

                    if (restartCatchUp) break;
                    Thread.Sleep(50);
                }

                if (!restartCatchUp || ct.IsCancellationRequested) return;
                // loop outer while to re-run catch-up after rotation
            }
        }
        catch (Exception ex)
        {
            lock (_gate)
            {
                if (epoch != _workerEpoch) return;
                Loading = false;
                TailRunning = false;
                LastError = ex.Message;
                LoadMessage = ex.Message;
                BumpGeneration();
            }
            Console.WriteLine($"Catch-up/tail FAILED  {ex.Message}");
        }
        finally
        {
            lock (_gate)
            {
                if (epoch == _workerEpoch)
                {
                    // Keep open while still tailing; StopWorker disposes on cancel/restart.
                    if (ct.IsCancellationRequested || !TailRunning)
                    {
                        try { parser?.Dispose(); } catch { /* ignore */ }
                        if (ReferenceEquals(_parser, parser)) _parser = null;
                    }
                }
                else
                {
                    try { parser?.Dispose(); } catch { /* ignore */ }
                }
            }
        }
    }
}

