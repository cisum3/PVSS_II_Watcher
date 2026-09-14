using System.Text.RegularExpressions;

namespace DesigoLogWatcher.Rules;

/// <summary>Shipping rule table (ported from 0.4 PvssRules.ps1 plus BACnetDrv / multi-scope).</summary>
internal static class RuleDefinitions
{
    private static readonly RegexOptions Rx = RegexOptions.Compiled | RegexOptions.CultureInvariant;

    public static IReadOnlyList<RuleDefinition> All { get; } =
    [
        // --- CNS ---
        new()
        {
            Id = "cns.resolveNodes", Group = "CNS", Label = "ResolveNodes",
            Re = new Regex("ResolveNodes", Rx), PatternGroup = "Cns"
        },
        new()
        {
            Id = "cns.reducedFunction", Group = "CNS", Label = "ReducedFunction",
            Re = new Regex("ReducedFunction", Rx), PatternGroup = "Cns"
        },
        new()
        {
            Id = "cns.icns", Group = "CNS", Label = "ICns",
            Re = new Regex(@"(?i)\bICns\b|ICns\.", Rx), PatternGroup = "Cns"
        },
        new()
        {
            Id = "cns.tryRenew", Group = "CNS", Label = "TryRenewSession",
            Re = new Regex("TryRenewSession", Rx), PatternGroup = "Cns"
        },

        // --- ApogeeDrv (do not widen Scope to BACnet) ---
        new()
        {
            Id = "apogeeDrv.trendOverflow", Group = "Apogee", Label = "Trend buffer overflow",
            Scope = "ApogeeDrv",
            Re = new Regex(@"(?i)Trend buffer overflow for trend\s+(.+?)\s+in device\s+(.+?)\.?\s*$", Rx),
            BucketBy = new Dictionary<string, BucketSpec>
            {
                ["trend"] = new() { Group = 1 },
                ["device"] = new() { Group = 2, TrimEnd = "." }
            },
            Sample = true, SampleSlot = "apogeeDrv.trend"
        },
        new()
        {
            Id = "apogeeDrv.trendSeq", Group = "Apogee", Label = "Trend sequence gap",
            Scope = "ApogeeDrv",
            Re = new Regex(@"(?i)Last sequence number\s+\d+\s+is greater than saved", Rx),
            Sample = true, SampleSlot = "apogeeDrv.trend"
        },
        new()
        {
            Id = "apogeeDrv.alertId", Group = "Apogee", Label = "AlertID issue",
            Scope = "ApogeeDrv",
            Re = new Regex(@"AlertID\s+\S+", Rx),
            Sample = true
        },
        new()
        {
            Id = "apogeeDrv.queryTimeout", Group = "Apogee", Label = "Query timeout",
            Scope = "ApogeeDrv",
            Re = new Regex(@"(?i)pending answer run into timeout", Rx),
            Sample = true
        },
        new()
        {
            Id = "apogeeDrv.getDataFail", Group = "Apogee", Label = "Failed to get data",
            Scope = "ApogeeDrv",
            Re = new Regex(@"(?i)Failed to get data for object\s+(.+?)\s+on device\s+([^,]+)", Rx),
            BucketBy = new Dictionary<string, BucketSpec> { ["device"] = new() { Group = 2 } },
            Sample = true
        },

        // --- Platform ---
        new()
        {
            Id = "state.unexpected", Group = "Platform", Label = "Unexpected state",
            Re = new Regex(@"Unexpected state,\s*([^,]+?)\s*,\s*([^,]+?)\s*,", Rx),
            BucketBy = new Dictionary<string, BucketSpec>
            {
                ["subsystem"] = new() { Group = 1 },
                ["method"] = new() { Group = 2 }
            },
            Sample = true, FindingAt = 500
        },

        // --- Trending ---
        new()
        {
            Id = "trend.dataLoss", Group = "Trending", Label = "Trend buffer data loss",
            Scope = "GmsBACnet",
            Re = new Regex(@"(?i)Trend buffer data loss for trend log object\s+(\S+)\s+in device\s+(\d+)", Rx),
            BucketBy = new Dictionary<string, BucketSpec> { ["device"] = new() { Group = 2 } },
            Sample = true, FindingAt = 100
        },
        new()
        {
            Id = "trend.seqLess", Group = "Trending", Label = "Sequence number lower than saved",
            Scopes = ["GmsBACnet", "ApogeeDrv"],
            Re = new Regex(@"(?i)Last sequence number\s+\d+\s+is less than saved", Rx),
            BucketBy = new Dictionary<string, BucketSpec> { ["manager"] = new() { Group = "$component" } },
            Sample = true, FindingAt = 100
        },

        // --- Driver ---
        new()
        {
            Id = "driver.errorCode", Group = "Driver", Label = "Driver returned error code",
            Re = new Regex(@"(?i)The Driver returned Error Code\s+(\d+)", Rx),
            BucketBy = new Dictionary<string, BucketSpec>
            {
                ["code"] = new() { Group = 1 },
                ["manager"] = new() { Group = "$component" }
            },
            Sample = true, FindingAt = 250
        },
        new()
        {
            Id = "driver.offline", Group = "Driver", Label = "Command failed - driver offline",
            Scope = "CoHo",
            Re = new Regex(@"(?i)Command failed because Driver\s+(\d+)\s+is offline", Rx),
            BucketBy = new Dictionary<string, BucketSpec> { ["driver"] = new() { Group = 1 } },
            Sample = true, FindingAt = 250
        },
        new()
        {
            Id = "driver.readFile", Group = "Driver", Label = "Read File returned error code",
            Scope = "CoHo",
            Re = new Regex(@"(?i)Device\s+(\d+)\s+Read File returned error code\s+(\d+)", Rx),
            BucketBy = new Dictionary<string, BucketSpec>
            {
                ["device"] = new() { Group = 1 },
                ["code"] = new() { Group = 2 }
            },
            Sample = true, FindingAt = 250
        },

        // --- Alarms ---
        new()
        {
            Id = "alarm.alertIdUnknown", Group = "Alarms", Label = "AlertID not known",
            Re = new Regex(@"(?i)AlertID\s+\S+\s+is not known", Rx),
            BucketBy = new Dictionary<string, BucketSpec> { ["manager"] = new() { Group = "$component" } },
            Sample = true, FindingAt = 250
        },
        new()
        {
            Id = "alarm.getSummaryFail", Group = "Alarms", Label = "GetAlarmSummary failed",
            Scope = "GmsBACnet",
            Re = new Regex(@"(?i)GetAlarmSummary failed for device\s+(\d+)", Rx),
            BucketBy = new Dictionary<string, BucketSpec> { ["device"] = new() { Group = 1 } },
            Sample = true, FindingAt = 100
        },

        // --- Devices ---
        new()
        {
            Id = "device.cptFailed", Group = "Devices", Label = "CPT failed - device failed",
            Scope = "GmsBACnet",
            Re = new Regex(@"(?i)CPT failed:.*?Dev\s*=\s*(\d+)", Rx),
            BucketBy = new Dictionary<string, BucketSpec> { ["device"] = new() { Group = 1 } },
            Sample = true, FindingAt = 100
        },
        new()
        {
            Id = "device.aesDecrypt", Group = "Devices", Label = "AES password decryption failed",
            Scope = "GmsBACnet",
            Re = new Regex(@"(?i)Device\s+(\d+):\s*AES decryption of password unsuccessful", Rx),
            BucketBy = new Dictionary<string, BucketSpec> { ["device"] = new() { Group = 1 } },
            Sample = true, FindingAt = 100
        },

        // --- Framework ---
        new()
        {
            Id = "afw.traceRepetition", Group = "Framework", Label = "Repeated trace",
            Re = new Regex(@"(?:,([^,]*),,\d{2}:\d{2}:\d{2}\.\d+,\^\d+:)?Repetition \(#=(\d+)\) of a former trace", Rx),
            BucketBy = new Dictionary<string, BucketSpec>
            {
                ["manager"] = new() { Group = "$component" },
                ["subArea"] = new() { Group = 1 }
            },
            Measure = new Dictionary<string, MeasureSpec>
            {
                ["repeats"] = new() { Group = 2, Agg = MeasureAgg.Sum },
                ["worstRun"] = new() { Group = 2, Agg = MeasureAgg.Max }
            },
            Sample = true, FindingAt = 500
        },
        new()
        {
            Id = "afw.covBurst", Group = "Framework", Label = "COV burst",
            Re = new Regex(@"(?:,([^,]*),,\d{2}:\d{2}:\d{2}\.\d+,\^\d+:)?We counted\s+(\d+)\s+COVs over the last", Rx),
            BucketBy = new Dictionary<string, BucketSpec>
            {
                ["manager"] = new() { Group = "$component" },
                ["subArea"] = new() { Group = 1 }
            },
            Measure = new Dictionary<string, MeasureSpec>
            {
                ["covs"] = new() { Group = 2, Agg = MeasureAgg.Sum },
                ["worstBurst"] = new() { Group = 2, Agg = MeasureAgg.Max }
            },
            Sample = true, FindingAt = 250
        },
        new()
        {
            Id = "afw.serverSideException", Group = "Framework", Label = "SERVER-SIDE exception",
            Scope = "CComMgr",
            Re = new Regex(@"SERVER-SIDE exception:\s*([A-Za-z0-9_.]+)", Rx),
            BucketBy = new Dictionary<string, BucketSpec>
            {
                ["exception"] = new() { Group = 1 },
                ["manager"] = new() { Group = "$component" }
            },
            Sample = true, FindingAt = 100
        },
        new()
        {
            Id = "afw.retainedInvocations", Group = "Framework", Label = "Examining retained invocations",
            Re = new Regex(@"(?i)Examining retained invocations", Rx),
            BucketBy = new Dictionary<string, BucketSpec> { ["manager"] = new() { Group = "$component" } },
            Sample = true, FindingAt = 500
        },

        // --- BACnetDrv (Apogee-shaped; BACnet "trend log object" wording) ---
        new()
        {
            Id = "bacnetDrv.trendOverflow", Group = "BACnetDrv", Label = "Trend buffer overflow",
            Scope = "GmsBACnet",
            Re = new Regex(
                @"(?i)Trend buffer overflow for trend(?:\s+log object)?\s+(.+?)\s+in device\s+(.+?)\.?\s*$", Rx),
            BucketBy = new Dictionary<string, BucketSpec>
            {
                ["trend"] = new() { Group = 1 },
                ["device"] = new() { Group = 2, TrimEnd = "." }
            },
            Sample = true, SampleSlot = "bacnetDrv.trend", FindingAt = 100
        },
        new()
        {
            Id = "bacnetDrv.trendSeq", Group = "BACnetDrv", Label = "Trend sequence gap",
            Scope = "GmsBACnet",
            Re = new Regex(@"(?i)Last sequence number\s+\d+\s+is greater than saved", Rx),
            Sample = true, SampleSlot = "bacnetDrv.trend", FindingAt = 100
        },
        new()
        {
            Id = "bacnetDrv.alertId", Group = "BACnetDrv", Label = "AlertID issue",
            Scope = "GmsBACnet",
            Re = new Regex(@"AlertID\s+\S+", Rx),
            Sample = true, FindingAt = 100
        },
        new()
        {
            Id = "bacnetDrv.queryTimeout", Group = "BACnetDrv", Label = "Query timeout",
            Scope = "GmsBACnet",
            Re = new Regex(@"(?i)pending answer run into timeout", Rx),
            Sample = true, FindingAt = 100
        },
        new()
        {
            Id = "bacnetDrv.getDataFail", Group = "BACnetDrv", Label = "Failed to get data",
            Scope = "GmsBACnet",
            Re = new Regex(@"(?i)Failed to get data for object\s+(.+?)\s+on device\s+([^,]+)", Rx),
            BucketBy = new Dictionary<string, BucketSpec> { ["device"] = new() { Group = 2 } },
            Sample = true, FindingAt = 100
        },
    ];
}
