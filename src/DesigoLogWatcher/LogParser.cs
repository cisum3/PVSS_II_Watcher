using System.Buffers;
using System.Text;
using System.Text.RegularExpressions;

namespace DesigoLogWatcher;

/// <summary>
/// Streaming log read, discovery, windows, catch-up/tail primitives.
/// Port of Open-LogStream / Resolve-LogPath / Find-WindowStartPosition / catch-up
/// (Watch-PvssLog.ps1; docs/INVENTORY-V0.5.md §6).
/// </summary>
public sealed class LogParser : IDisposable
{
    // Same header as $script:LineRe — component, timestamp, area, severity.
    private static readonly Regex LineHeaderRe = new(
        @"^([^,]+),\s*(\d{4}\.\d{2}\.\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+),\s*([^,]+),\s*([^,\s]+)",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private FileStream? _stream;
    private StreamReader? _reader;
    private string _partialLine = "";

    public string? Path { get; private set; }
    public long FilePos { get; private set; }
    public long FileLength { get; private set; }
    public bool IsOpen => _stream is not null;

    /// <summary>Open read-only with share so Desigo/WinCC can keep appending.</summary>
    public void Open(string path, long position = 0L)
    {
        Close();
        var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 1024 * 1024, FileOptions.SequentialScan);
        if (position > 0 && position <= fs.Length)
            fs.Seek(position, SeekOrigin.Begin);
        _stream = fs;
        _reader = new StreamReader(fs, Encoding.UTF8, detectEncodingFromByteOrderMarks: true, bufferSize: 1024 * 1024, leaveOpen: true);
        Path = path;
        FilePos = fs.Position;
        FileLength = fs.Length;
        _partialLine = "";
    }

    public void Close()
    {
        try { _reader?.Dispose(); } catch { /* ignore */ }
        try { _stream?.Dispose(); } catch { /* ignore */ }
        _reader = null;
        _stream = null;
        Path = null;
        FilePos = 0;
        FileLength = 0;
        _partialLine = "";
    }

    public void Dispose() => Close();

    public void RefreshLength()
    {
        if (_stream is null) return;
        FileLength = _stream.Length;
        FilePos = _stream.Position;
    }

    /// <summary>
    /// Read next complete line. Returns false at EOF (may leave a partial line buffered for tail).
    /// </summary>
    public bool TryReadLine(out string line)
    {
        line = "";
        if (_reader is null || _stream is null)
            return false;

        while (true)
        {
            var chunk = _reader.ReadLine();
            FilePos = _stream.Position;
            FileLength = _stream.Length;
            if (chunk is null)
            {
                // EOF: keep partial for next tail append.
                return false;
            }

            if (_partialLine.Length > 0)
            {
                line = _partialLine + chunk;
                _partialLine = "";
            }
            else
            {
                line = chunk;
            }

            return true;
        }
    }

    /// <summary>Enumerate all currently available complete lines from the open stream.</summary>
    public IEnumerable<string> ReadAvailableLines()
    {
        while (TryReadLine(out var line))
            yield return line;
    }

    public static bool TryParseHeader(ReadOnlySpan<char> line, out LogHeader header)
    {
        header = default;
        // Fast path: require at least "a, 2000.01.01 00:00:00.0, b, C"
        if (line.Length < 28)
            return false;

        var m = LineHeaderRe.Match(line.ToString());
        if (!m.Success)
            return false;

        header = new LogHeader(
            Component: m.Groups[1].Value.Trim(),
            Timestamp: m.Groups[2].Value,
            AreaRaw: m.Groups[3].Value.Trim(),
            Severity: NormalizeSeverity(m.Groups[4].Value.Trim()));
        return true;
    }

    public static string NormalizeSeverity(string sev)
    {
        var s = sev.ToUpperInvariant();
        return s == "WARN" ? "WARNING" : s;
    }

    /// <summary>
    /// Discovery order from Resolve-LogPath: explicit → PVSS_II.log → .bak → newest PVSS_II*.log*.
    /// Search dirs: watchRoot, parent(watchRoot), cwd.
    /// </summary>
    public static string ResolveLogPath(string? explicitPath, string watchRoot, string? currentDirectory = null)
    {
        if (!string.IsNullOrWhiteSpace(explicitPath))
            return AssertLogPathUsable(explicitPath.Trim());

        var cwd = currentDirectory ?? Environment.CurrentDirectory;
        var parent = Directory.GetParent(watchRoot)?.FullName;
        var searchDirs = new List<string>();
        foreach (var d in new[] { watchRoot, parent, cwd })
        {
            if (!string.IsNullOrWhiteSpace(d) && !searchDirs.Contains(d, StringComparer.OrdinalIgnoreCase))
                searchDirs.Add(d!);
        }

        foreach (var name in new[] { "PVSS_II.log", "PVSS_II.log.bak" })
        {
            foreach (var dir in searchDirs)
            {
                var cand = System.IO.Path.Combine(dir, name);
                if (File.Exists(cand))
                    return AssertLogPathUsable(cand);
            }
        }

        FileInfo? newest = null;
        foreach (var dir in searchDirs)
        {
            if (!Directory.Exists(dir)) continue;
            foreach (var pattern in new[] { "PVSS_II*.log", "PVSS_II*.log.bak" })
            {
                foreach (var fi in new DirectoryInfo(dir).EnumerateFiles(pattern))
                {
                    if (newest is null || fi.LastWriteTime > newest.LastWriteTime)
                        newest = fi;
                }
            }
        }

        if (newest is not null)
            return AssertLogPathUsable(newest.FullName);

        var hint = string.Join(Environment.NewLine, searchDirs.Select(d => "  - " + d));
        throw new FileNotFoundException(
            $"Log file not found. Looked for PVSS_II.log, PVSS_II.log.bak, PVSS_II*.log and PVSS_II*.log.bak in:{Environment.NewLine}{hint}{Environment.NewLine}Pass -LogPath explicitly.");
    }

    public static string AssertLogPathUsable(string path)
    {
        if (!File.Exists(path))
            throw new FileNotFoundException($"Log path not found: {path}");
        // Prove share-safe open.
        using var test = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        return System.IO.Path.GetFullPath(path);
    }

    /// <summary>
    /// Compare log timestamp prefix (yyyy.MM.dd HH:mm:ss) lexicographically — same as PS cutoff string compare.
    /// </summary>
    public static bool IsBeforeCutoff(string timestamp, string cutoffCompare19)
    {
        if (timestamp.Length < 19 || cutoffCompare19.Length < 19)
            return false;
        return timestamp.AsSpan(0, 19).SequenceCompareTo(cutoffCompare19.AsSpan(0, 19)) < 0;
    }

    public static bool IsAfterUpper(string timestamp, string upperCompare19)
    {
        if (timestamp.Length < 19 || upperCompare19.Length < 19)
            return false;
        return timestamp.AsSpan(0, 19).SequenceCompareTo(upperCompare19.AsSpan(0, 19)) > 0;
    }

    public static string ToCompareStamp(DateTime dt) =>
        dt.ToString("yyyy.MM.dd HH:mm:ss", System.Globalization.CultureInfo.InvariantCulture);

    public readonly record struct ProbeTimestamps(DateTime? First, DateTime? Last, long SeekPos);

    /// <summary>Probe first/last parsed timestamps in a byte range (PS Get-ProbeTimestamps).</summary>
    public static ProbeTimestamps GetProbeTimestamps(string path, long seekPos, long maxBytes = 1_048_576L)
    {
        using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 64 * 1024);
        var len = fs.Length;
        if (seekPos < 0) seekPos = 0;
        if (seekPos >= len) return new ProbeTimestamps(null, null, seekPos);
        var toRead = (int)Math.Min(maxBytes, len - seekPos);
        fs.Position = seekPos;
        var buf = new byte[toRead];
        var n = fs.Read(buf, 0, toRead);
        if (n <= 0) return new ProbeTimestamps(null, null, seekPos);
        var text = Encoding.UTF8.GetString(buf, 0, n);
        if (seekPos > 0)
        {
            var cut = text.IndexOfAny(['\n', '\r']);
            if (cut < 0) return new ProbeTimestamps(null, null, seekPos);
            if (cut + 1 < text.Length && text[cut] == '\r' && text[cut + 1] == '\n')
                text = text[(cut + 2)..];
            else
                text = text[(cut + 1)..];
        }

        DateTime? first = null;
        DateTime? last = null;
        foreach (var line in text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            if (!TryParseHeader(line, out var hdr)) continue;
            var dt = ChartSeriesBuilder.TryParseLogTs(hdr.Timestamp);
            if (dt is null) continue;
            first ??= dt;
            last = dt;
        }
        return new ProbeTimestamps(first, last, seekPos);
    }

    /// <summary>Newest timestamp near EOF (PS Get-LogFileEndTimestamp). Null if none found.</summary>
    public static DateTime? GetLogFileEndTimestamp(string path)
    {
        var len = new FileInfo(path).Length;
        if (len <= 0) return null;
        var seek = Math.Max(0L, len - 1_048_576L);
        return GetProbeTimestamps(path, seek).Last;
    }

    /// <summary>
    /// Relative last-N cutoff anchored to newest log timestamp (wall clock only as fallback).
    /// </summary>
    public static (DateTime Cutoff, DateTime Anchor, bool UsedWallClock) ResolveLastNCutoff(string path, int lastMinutes)
    {
        var end = GetLogFileEndTimestamp(path);
        if (end is DateTime anchor)
            return (anchor.AddMinutes(-lastMinutes), anchor, false);
        var wall = DateTime.Now;
        return (wall.AddMinutes(-lastMinutes), wall, true);
    }

    /// <summary>Byte start for last-N window (PS Find-WindowStartPosition). Throws if log ends before cutoff.</summary>
    public static long FindWindowStartPosition(string path, DateTime cutoff)
    {
        var len = new FileInfo(path).Length;
        if (len <= 0) return 0L;

        var head = GetProbeTimestamps(path, 0, Math.Min(len, 65_536L));
        if (head.First is DateTime hf && hf >= cutoff)
            return 0L;

        var tail = GetLogFileEndTimestamp(path);
        if (tail is DateTime tl && tl < cutoff)
            throw new InvalidOperationException(
                $"Empty window: the log ends at {tl:yyyy.MM.dd HH:mm:ss}, before the requested start {cutoff:yyyy.MM.dd HH:mm:ss}.");

        long chunk = 262_144; // 256 KB
        var maxChunk = Math.Min(len, 32L * 1024 * 1024);
        var startPos = Math.Max(0L, len - chunk);
        for (var guard = 0; guard < 40; guard++)
        {
            var probe = GetProbeTimestamps(path, startPos, Math.Min(chunk, 2L * 1024 * 1024));
            if (probe.First is null)
            {
                if (startPos == 0) return 0L;
                chunk = Math.Min(maxChunk, chunk * 2);
                startPos = Math.Max(0L, len - chunk);
                continue;
            }
            if (probe.First <= cutoff || startPos == 0)
                return startPos;
            chunk = Math.Min(maxChunk, chunk * 2);
            var next = Math.Max(0L, len - chunk);
            if (next == startPos) return 0L;
            startPos = next;
        }
        return startPos;
    }

    /// <summary>Catch-up progress helper (bytes in window).</summary>
    public sealed class CatchUpProgress
    {
        public long StartPos { get; init; }
        public long SpanBytes { get; init; } = 1;
        public long CurrentPos { get; set; }
        public int Lines { get; set; }
        public int Skipped { get; set; }
        public double Percent => SpanBytes <= 0 ? 100 : Math.Min(100, 100.0 * (CurrentPos - StartPos) / SpanBytes);
    }

    public CatchUpProgress BeginCatchUp(long startPos)
    {
        RefreshLength();
        var span = Math.Max(1, FileLength - startPos);
        if (FilePos != startPos && _stream is not null)
        {
            _stream.Seek(startPos, SeekOrigin.Begin);
            _reader = new StreamReader(_stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true, bufferSize: 1024 * 1024, leaveOpen: true);
            FilePos = startPos;
            _partialLine = "";
        }
        return new CatchUpProgress { StartPos = startPos, SpanBytes = span, CurrentPos = startPos };
    }

    /// <summary>
    /// Detect truncation/rotation: file shorter than last position → reopen from 0.
    /// </summary>
    public bool DetectTruncationAndReseek()
    {
        if (_stream is null) return false;
        var len = _stream.Length;
        if (len < FilePos)
        {
            Open(Path!, 0);
            return true;
        }
        FileLength = len;
        return false;
    }

    /// <summary>
    /// After EOF, StreamReader may not observe newly appended bytes until we reseek.
    /// Returns true if the file grew and the reader was repositioned.
    /// </summary>
    public bool ReseekIfGrew()
    {
        if (_stream is null || Path is null) return false;
        var len = _stream.Length;
        if (len <= FilePos) { FileLength = len; return false; }
        var pos = FilePos;
        _stream.Seek(pos, SeekOrigin.Begin);
        _reader = new StreamReader(_stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true, bufferSize: 1024 * 1024, leaveOpen: true);
        FilePos = pos;
        FileLength = len;
        return true;
    }
}

public readonly record struct LogHeader(string Component, string Timestamp, string AreaRaw, string Severity);
