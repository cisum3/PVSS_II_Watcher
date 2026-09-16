# PRD: PVSS Log Analyzer V0.4 — rule engine + Watch absorbs OfflineAnalyze

**Product:** `Watch-PvssLog.ps1` / `Run-Watch.cmd` (+ new `Run-Report.cmd`)
**Status:** **Shipped 2026-09-12** (reviewed 2026-09-07, Cisum)
**Date:** 2026-09-07
**Supersedes:** the "shared parser library" plan in [`BACKLOG.md`](../BACKLOG.md) (see §2)
**Ships as:** Watch **0.4.0** — `OfflineAnalyze\` is **removed** from the package
**Build tracker:** [`PROGRESS-V0.4.md`](PROGRESS-V0.4.md) (also archived)

**Primary goal:** make "this log line means this" cheap to add — one rule row instead of
edits in nine places.

**Secondary goal:** stop maintaining that logic twice. Watch gains a text renderer and a
batch mode, `OfflineAnalyze\` is deleted, and Watch's copy becomes the only copy.

---

## 1. Problem

### 1.1 Adding a detection is expensive

Adding one rule today means editing the same concept in up to nine places spread across
3,600 lines. Tracing `ApogeeTrendOverflow` through `Watch-PvssLog.ps1`:

| Line(s) | What |
|---|---|
| 648 | regex declaration |
| 604, 609, 610 | counter + two bucket maps in `New-EmptyState` |
| 1098-1112 | detection block in `Process-LogLine` |
| 1699-1701 | findings threshold |
| 2188, 2249 | module headline, built twice |
| 2390, 2410-2416 | section payload |
| 3336-3345 | `Convert-SnapshotToHtml` |
| `ui/app.js` 985, 1012, 1020, 1025-1027 | dashboard card |

`CnsTryRenew` is the same story in eight places (590, 1051, 1694, 2184, 2245, 2362, 3283,
plus `app.js` 938 and 949) for what is conceptually "count this line."

Adding the text renderer in this release would make it *worse* by one more place. That is
the problem this PRD leads with.

### 1.2 Everything is written twice

`Normalize-Message`, `Get-PerfCategory`, `Add-Pattern`, `Format-DurationLabel`,
`Get-LogTimestampDeltaSec`, `Build-ProjectLifecycleCycles`, the header regex, and the
perf-category rule table are duplicated near-verbatim between `Watch-PvssLog.ps1` and
`Analyze-PvssLog.ps1`. Watch is already the more capable of the two — it has an area
dimension, BACnet flip tracking, and pre-compiled regexes that OfflineAnalyze lacks. What
Watch lacks is only the *output* half: a text report and a way to run without a browser.

---

## 2. Relationship to the backlog plan

`BACKLOG.md` scoped V0.4 as a three-layer shared parser library consumed by both tools,
with the note that "OfflineAnalyze becomes an additional tool inside Watch."

This PRD reaches the same endpoint by deleting the second consumer instead of building a
library for it, and replaces the "extract the functions" idea with something that actually
serves §1.1 — dot-sourcing a file relocates code but does not reduce touch points.

| Backlog layer | Fate |
|---|---|
| 1. Rules + helpers | **Replaced** by the declarative rule engine (§4) |
| 2. Line classify | **Replaced** by the generic rule loop (§4.3) |
| 3. Shared accumulator state | **Dropped as moot** — one tool means one accumulator |
| Dev-only rule test harness over `PVSS_II_Examples\` | **Kept** — now trivial, since a rule is data |
| Standalone flat-zip option for `OfflineAnalyze\` | **Retired**, as the backlog already called for |

---

## 3. Design principles

1. **A rule is data, not code.** Adding a detection is one row in a table plus one line in
   the test harness. Everything downstream — counting, bucketing, samples, findings, text,
   HTML, dashboard — is generic.
2. **Additive, not a rewrite.** The rule engine runs alongside the existing hand-written
   detections. Curated module cards keep working untouched. Migration is opportunistic.
3. **Object first.** Text and HTML are two renderers over one `Build-SnapshotObject`
   result — never text-scraped into HTML the way `Convert-AnalysisReportToHtml` does today.
4. **No new analysis path.** Batch mode drives the existing `Begin-CatchUp` /
   `Step-CatchUp` loop synchronously. It does not re-implement scanning.
5. **The dashboard is the interactive mode.** Console prompts stay minimal (§7.3); anything
   needing exploration belongs in the browser, where it re-filters without a rescan.
6. Unchanged from V2: PS 5.1, no installs, localhost only, log opened read-only.

---

## 4. Rule engine

### 4.1 Rule shape

Rules live in `Watch\PvssRules.ps1`, dot-sourced from `Watch-PvssLog.ps1` (§4.6).

```powershell
$script:PvssRules = @(
    @{ Id = 'cns.tryRenew'; Group = 'CNS'; Label = 'TryRenewSession'
       Re = [regex]'...'
       FindingAt = 5 }

    @{ Id = 'apogee.trendOverflow'; Group = 'Apogee'; Label = 'Trend buffer overflow'
       Scope = 'ApogeeDrv'
       Re = [regex]'(?i)Trend buffer overflow for trend\s+(.+?)\s+in device\s+(.+?)\.?\s*$'
       BucketBy = @{ trend = 1; device = 2 }
       Sample = $true
       FindingAt = 50 }

    @{ Id = 'afw.traceRepetition'; Group = 'Framework'; Label = 'Repeated trace'
       Re = [regex]'Repetition \(#=(\d+)\) of a former trace'
       BucketBy = @{ manager = '$component'; subArea = 2 }
       Measure  = @{ repeats = @{ Group = 1; Agg = 'Sum' } }
       Sample = $true
       FindingAt = 500 }

\)
```

| Key | Required | Meaning |
|---|---|---|
| `Id` | yes | Stable key: `group.name`. Used in state maps, payload keys, and tests. |
| `Group` | yes | Renders as a section heading; groups rules in reports and the UI. |
| `Label` | yes | Human text in reports. |
| `Re` | yes | Pre-compiled `[regex]`. |
| `Scope` | no | Component substring gate (`BACnet`, `ApogeeDrv`, `CoHo`). Absent = all lines. |
| `BucketBy` | no | `bucketName -> capture group index`, **or** a header token: `'$component'`, `'$area'`, `'$severity'`. Produces top-N breakdown tables. |
| `Measure` | no | `name -> @{ Group = <capture index>; Agg = 'Sum'\|'Max' }`. Aggregates a captured number alongside the hit count. |
| `Sample` | no | Keep the first matching line. |
| `FindingAt` | no | Emit a findings headline at this count. Simple threshold only. |
| `Trim` | no | Per-bucket cleanup, e.g. `TrimEnd('.')`. |

Both `BucketBy` header tokens and `Measure` were added after validating the schema against
`PVSS_II_Examples\` — see §4.1.1.

### 4.1.1 Schema validation against the example corpus

Checked against `PVSS_II_C1P.log` (17.9k parsed), `PVSS_II_C2P.log` (321k, includes 2,827
FATAL) and `PVSS_II_H1P.log` (143k). Roughly a dozen high-volume undetected patterns are
expressible as plain rows — `GetAlarmSummary failed for device N`, `Trend buffer data loss`
(the existing regex only catches *overflow*), `Last sequence number N is less than saved`
(only *greater than* is caught), `Device N Read File returned error code N`, `The Driver
returned Error Code N`, `CPT failed: The BACnet device is failed`, `AES decryption of
password unsuccessful`, `AlertID ... is not known`, `Examining retained invocations`, and
`SERVER-SIDE exception: <Type>`.

One row collapses a whole family: `Unexpected state, <subsystem>, <method>, <detail>` with
`BucketBy = @{ subsystem = 1; method = 2 }` covers `RequestHandler/SendAnswer` (2,199),
`AlertService/sendAck` (3,090), `AlertHistory/commitUpdate` (1,002), and
`DrvManager/gotAlertConfigAnswer` — about 6,400 lines across the three logs.

Two patterns did **not** fit the original schema, and both are top-tier signals:

- **`Repetition (#=N) of a former trace`** — 13,238 lines across **9 distinct managers** in
  H1P, the largest non-INFO signal in that log. The useful breakdown is *which manager is
  repeating*, and the manager is the header component field, not a capture group. Today
  `ReApogeeRep` only sees these inside the Apogee gate, so nearly all of them go uncounted.
  Drives the `'$component'` token.
- **`We counted N COVs over the last N.N seconds`** — 1,559 lines across 9 managers in H1P.
  Same component-bucketing need, plus the payload *is* the number: counting lines says 1,559
  where the actual COV total is orders of magnitude higher. Drives `Measure`.

`Repetition (#=N)` needs both — the `#=N` is a repeat count, so line counts understate it the
same way. Sub-area strings (`Orch.Alarm`, `EngineeringConsoleSnapIn`, `Orch.Globalization`)
are embedded in the message and capture normally, so they need no schema support.

### 4.2 Generic state

Four maps in `New-EmptyState` replace per-rule named fields:

```powershell
Hits        = @{}   # ruleId -> count
HitBuckets  = @{}   # ruleId -> bucketName -> value -> count
HitMeasures = @{}   # ruleId -> measureName -> aggregated number
HitSevs     = @{}   # ruleId -> severity -> count
HitSample   = @{}   # ruleId -> first matching line
HitTime     = @{}   # ruleId -> @{ First; Last }
```

`HitSevs` exists because severity varies within a rule — the `Unexpected state` family
appears as WARNING in some subsystems and SEVERE in others — and the mix is worth showing
without splitting one concept into several rules.

`Clone-AnalysisState` must cover these (verify it clones generically rather than by named
field, or extend it).

### 4.3 Generic classify

One loop in `Process-LogLine` replaces every hand-written detection block:

```powershell
foreach ($r in (Get-RulesForComponent $comp)) {
    $m = $r.Re.Match($Line)
    if ($m.Success) { Add-RuleHit -Data $Data -Rule $r -Match $m -Line $Line -Timestamp $ts }
}
```

**Performance.** `Scope` makes this parity by construction. Today each line pays ~3
`IndexOf` calls on the component (BACnet 971, CoHo 1058, ApogeeDrv 1096) and then only the
regexes inside the matching gate; a scope-indexed loop pays the same.

`Get-RulesForComponent` **memoizes by component name**. Names repeat enormously — a few
dozen managers across a million lines — so after first sight the per-line cost is one
hashtable lookup, below today's cost.

The one accepted regression: short-circuit `elseif` chains (`trendOverflow` / `trendSeq` at
1098-1116) currently skip the second test when the first matches, where a flat loop
evaluates both. One extra regex on a subset of lines.

Time a ~50 MB log in 4A as a sanity-check.

### 4.4 What stays hand-written

The rule table covers "match, count, bucket, sample." Three things in the current code
legitimately fall outside it and are **not** migrated:

- **BACnet flip tracking** (998-1004) — stateful across lines; remembers each device's
  previous status and counts transitions.
- **`Build-ProjectLifecycleCycles`** — pairs up/shutdown/stopped events into cycles with
  durations.
- **Apogee orchestration trio** (1080-1092) — `UpdatePoints` / `Repetition` / `Other` is
  first-match-wins with a catch-all, which the flat rule loop does not express.

Composite findings that interpolate several values (1699-1701) also stay hand-written;
`FindingAt` only covers simple count thresholds.

This boundary is expected to stay. The rule engine is not trying to absorb everything.

### 4.5 Proof migration

To prove the engine on real rules without touching the risky parts, migrate two clusters
in 4A:

- **CNS counters** — `CnsResolve`, `CnsReduced`, `CnsICns`, `CnsTryRenew` (1047-1051). Pure
  counters, no captures.
- **ApogeeDrv rules** — `trendOverflow` (2 buckets + sample), `trendSeq`, `alertId`,
  `queryTimeout` (samples), `getDataFail` (1 bucket + sample), lines 1096-1135. Chosen
  deliberately: the driver side has no exclusive-group problem, unlike the orchestration
  side. `ApogeeDrvLines` is a scope line-count, not a rule — leave it hand-written.

**Contract: payload keys do not change.** The `cns` and `apogee` section payloads keep
emitting `resolveNodes`, `tryRenew`, `trendOverflow`, `topTrendDevices` and the rest, only
now sourced from `Hits` / `HitBuckets`. `app.js`, `Convert-SnapshotToHtml`, and the
findings text are untouched, so the spot-check in §10 should show byte-identical output for
these sections. That is the proof.

### 4.6 Dot-sourcing mechanics

`PvssRules.ps1` is dot-sourced, not imported as a module — no manifest, no install path, no
export list, and the launchers' existing `-ExecutionPolicy Bypass` already covers it.
Dot-sourcing creates no new scope, so `function script:` and `$script:` inside the file
bind to `Watch-PvssLog.ps1`'s scope exactly as they do today.

Use the existing `$script:Root` rather than a relative path, which would resolve against the
working directory:

```powershell
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path   # line 26, existing
. (Join-Path $script:Root 'PvssRules.ps1')
```

The dot-source goes after `Set-StrictMode` and before any call site, with an existence
check and a clear error the way `Run-Watch.cmd` already guards `Watch-PvssLog.ps1`.

### 4.7 Test harness

Rule tests fold into the existing `docs\Test-WatchSelf.ps1` as a new phase rather than
shipping a second test script — one entry point. The phase dot-sources `PvssRules.ps1` and
asserts each rule against expected-match and expected-no-match sample lines drawn from
`PVSS_II_Examples\`.

Adding a detection is then: one row in `$script:PvssRules`, one line in the harness. Field
feedback of the form "this line isn't detected" becomes a two-line change.

**`Test-WatchSelf.ps1` needs repair first.** It was moved from the package root into
`docs\` and its path logic was not adjusted: line 14-15 computes
`$Root = Split-Path -Parent $MyInvocation.MyCommand.Path` then `Join-Path $Root 'Watch'`,
which now resolves to `docs\Watch`. The example-log paths break identically, becoming
`docs\docs\PVSS_II_Examples\...`. It is non-functional as it stands. Fix `$Root` to climb
one level, and rename the phase labels off `2A`-`2E` — those were V2.0 build phases and no
longer mean anything.

---

## 5. Architecture — batch mode

```text
Run-Watch.cmd              → dashboard (unchanged)
Run-Report.cmd             → batch report, no listener, no browser
Run-Report-Interactive.cmd → batch report + 2 prompts (organize, format)
  └─ Watch-PvssLog.ps1 -Report ...
       ├─ Resolve-LogPath (auto-discovery, ported from OfflineAnalyze)
       ├─ Begin-CatchUp / Step-CatchUp   ← existing, driven synchronously
       ├─ Build-SnapshotObject           ← existing, gap-filled per §6
       ├─ Convert-SnapshotToText         ← NEW
       ├─ Convert-SnapshotToHtml         ← existing
       └─ write file(s), exit
```

### 5.1 Batch entry point

A branch inserted **before** `Start-Listener` in `# --- main ---`. When `-Report` is present
the script never binds a port, never opens a browser, and exits with the report's status
code.

```text
1. Resolve log path (-LogPath, else Resolve-LogPath discovery)
2. Seed $script:Sync: LogPath, FileLength, window mode, Generation
3. Begin-CatchUp; loop Step-CatchUp until CatchUpActive is false
   (Update-LoadProgress already writes console progress)
4. Build severity/area filter hashtables from CSV switches
5. Build-SnapshotObject → render → write file(s)
6. exit 0 / exit 1
```

Two frictions to handle:

- `Build-SnapshotObject` and the `Build-*Object` family read `$script:Sync` globals directly
  rather than taking parameters. Batch mode must seed them or `meta` carries zeros.
- `perf.health` reports `port` and `url`, meaningless offline. Emit them as **empty strings**
  and keep the keys, so the equivalence check in §10.1 compares two known lines rather than
  differing structures.

### 5.2 Path validation

Log-path validation currently lives inline in the `POST /api/logPath` handler. Extract it to
a function so the handler and batch mode share one implementation.

### 5.3 Time window

Watch's window model is entire-or-last-N-minutes anchored to the newest timestamp in the
file, resolved by a backward byte-seek (`Find-WindowStartPosition`). OfflineAnalyze supports
absolute `-From` / `-To`. **This is the one genuine capability gap.**

| Switch | Behavior |
|---|---|
| `-Entire` | Parse from start of file (equivalent to `window=entire`) |
| `-LastMinutes N` | Existing rolling window, file-end anchored |
| `-LastHours N` | Sugar for `-LastMinutes (N*60)`; wins over `-From`/`-To`, as in V1.3 |
| `-From` / `-To` | **New.** Absolute bounds, `yyyy.MM.dd HH:mm[:ss]`. Date-only `-To` widens to end of day. |

`-From`/`-To` reuse the backward-seek to locate the `-From` offset, then stop parsing at
`-To` rather than EOF. Default in batch mode: `-Entire` (matching OfflineAnalyze, **not**
Watch's 60m dashboard default).

#### 5.3.1 Seek strategy — reuse, do not replace

`Find-WindowStartPosition` (1272-1309) is already a bounded doubling search rather than a
linear backward read: the chunk doubles from 256 KB (capped at 32 MB), but each iteration
probes at most 2 MB via `Get-ProbeTimestamps`. Worst case is ~8 iterations reading ~12 MB
total regardless of target depth; the common case exits in 1-3 iterations under 2 MB. Against
a ~50 s full parse of a 50 MB log that is a few seconds at absolute worst, and effectively
nothing in normal use.

Correctness comes from **over-inclusion**: the search lands at or before the true cutoff, and
`Step-CatchUp` filters precisely afterward using `LoadEnforce` / `LoadCutoff` (1402-1404,
1455-1465), counting discards in `LoadSkipped`.

Two guards are worth adding, and nothing else:

- `-From` at or before the file's first timestamp → return 0 without probing. The first
  header costs a few hundred bytes to read.
- `-From` after the file's last timestamp → empty window; fail fast with a clear message.

### 5.4 Timestamp parsing — operator input vs log lines

These are two separate concerns that OfflineAnalyze happens to serve with one function.
Keeping them separate in Watch avoids porting complexity that is not needed.

**Log lines — no change required.** `$script:LineRe` constrains group 2 to
`\d{4}\.\d{2}\.\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+`: dotted date, mandatory fractional seconds. A
line in any other shape never matches the header and never reaches a timestamp parser, so
only `yyyy.MM.dd HH:mm:ss.fff` is ever reachable. Watch's single-format
`ConvertFrom-LogTimestamp` (508-519) is fed exclusively from that group — at 1252, 1898-1899
and 2018-2019 — and is sufficient as-is. Six of OfflineAnalyze's seven `TryParseExact`
formats are unreachable from log text.

*(A log whose timestamps genuinely lacked fractional seconds would fail at the header regex
and count as unparsed. That behavior is identical in both tools today and is out of scope
here.)*

**Operator input — new to Watch.** `-From` / `-To` and the `[W]` interactive prompt accept
loose human input, which is what OfflineAnalyze's wider format list is actually for. Watch
has no equivalent because it has no absolute-window support yet.

Port `Convert-LogTimestamp` and `Convert-WindowBound` (144-177, 320-335) as an **input**
parser, named to keep the roles distinct — `ConvertFrom-UserTimestamp` alongside the existing
`ConvertFrom-LogTimestamp`. It carries the seven exact formats, the lenient `TryParse`
fallback, and the date-only `-To` widening to end of day. `Convert-WindowBound` also backs
the prompt's re-ask-until-parseable loop (491).

---

## 6. Snapshot gap-fill

Watch's snapshot object already covers most of the OfflineAnalyze report:

| OfflineAnalyze section | Watch snapshot source | Work |
|---|---|---|
| Banner (tool/generated/log/size/lines/span/runtime) | `meta`, `window` | render only |
| `--- Options used ---` | — | **new key** `options` |
| `--- Findings ---` | `findings` | render only |
| `--- Severity counts ---` | `severityCounts` | render only |
| `--- Module headlines ---` | `moduleHeadlines` | render only |
| `--- Project restarts (pmon) ---` | `projectLifecycle` | render only |
| `--- Manager health (pmon) ---` | `managerHealth` | render only |
| `--- Top N components ---` | `managers` | render only |
| `--- Performance-related keyword categories ---` | `perf.perfCategories` | render only |
| `--- BACnet / CNS / CoHo / Apogee module ---` | `bacnet` / `cns` / `coho` / `apogee` | render only |
| `--- Hourly volume ---` / `--- Busiest hours ---` | `series.byMinute` | **new key** `hourly` |
| `--- Driver deep-dive ---` | `Build-ManagerObject` (exists, not in snapshot) | **include** when Organize=Driver |
| `--- Top patterns by severity ---` | `patternsBySeverity` | render only |
| *(none — new in 0.4.0)* | `Hits` / `HitBuckets` | **new key** `detections` (§6.2) |

Additions:

1. **`options`** — organize mode, severities, drivers, areas, TopN, SamplePerPattern, time
   window, format. Populated from the resolved parameter set.
2. **`hourly`** — `{ hour -> { total, severe, warning } }`. Watch keeps minute buckets only;
   `Build-ChartSeries` already rolls up by string truncation. Preserve V1.3's presentation
   rule: full table at ≤25 hours, otherwise last 24 hours plus a busiest-10 table.
3. **`driverDeepDive`** — array of `Build-ManagerObject` results for the selected drivers.
4. **`detections`** — §6.2.

Two existing caps carry over unchanged and stay disclosed in the report footer:
`projectLifecycle` events capped at 200, `managerHealth` at top 25 managers.

### 6.2 Generic detections rendering

`detections` is built by walking `$script:PvssRules` grouped by `Group`:

```text
detections: [ { group, rules: [ { id, label, count, first, last, sample,
                                   severities: { SEV: count },
                                   measures:   { name: number },
                                   buckets:    { name: [ {value, count} ] } } ] } ]
```

Where a rule carries a `Measure`, renderers lead with the aggregate rather than the hit
count — "42,110 repeats across 1,204 lines" reads correctly where "1,204" alone would
understate the signal by an order of magnitude.

Rules with zero hits are omitted. Three renderers consume it, all generic:

- **Text** (`Convert-SnapshotToText`) — a `--- Detections: <Group> ---` section per group,
  label/count rows, top-N bucket tables.
- **HTML** (`Convert-SnapshotToHtml`) — matching section, reusing the existing
  `Add-SnapCountNameTable` helper.
- **Dashboard** (`ui/app.js`) — a new **Detections** nav view rendering the same payload.

Result: a rule row surfaces in all three with **zero renderer edits**. Curated module cards
(BACnet, CNS, CoHo, Apogee) are unaffected and keep their hand-tuned layouts; a rule is
promoted into a curated card only if it earns the attention.

Groups that already have a curated card are excluded from `detections` so nothing reports
twice:

```powershell
$script:CuratedGroups = @('BACnet', 'CNS', 'CoHo', 'Apogee')
```

Retiring a curated card deletes one entry; when the last card goes, the array goes.

### 6.3 Organize modes

`-Organize All|Severity|Driver` gates which sections render, matching V1.3's eight inclusion
flags. Severity mode swaps the four full module sections for the condensed `moduleHeadlines`
block and drops components / perf categories / hourly volume. Driver mode replaces the
severity-pattern section with the deep-dive and re-enables modules heuristically from the
chosen driver names. `detections` renders in All and Driver modes.

Organize is a **render-time** concern — it never changes what gets scanned, so one snapshot
object can produce any mode.

### 6.4 Snapshot format selection in the dashboard

Today the Snapshot button always downloads HTML: `index.html` has a single `#btnSnapshot`,
and `app.js` line 331 hardcodes `format=html`. JSON is reachable only by hand-editing the
URL. With text arriving in 0.4.0 there are three formats, so the choice belongs in the UI.

**Expand in place.** Clicking Snapshot replaces the button with three buttons occupying the
same slot — `HTML` · `Text` · `JSON`. Clicking one starts that download and collapses back
to the single button. `Esc` or a click outside collapses without downloading.

This adds no persistent chrome, which matters because the sticky bar already carries the
path, Pause/Resume/Restart, window presets, severity chips, area chips, and the status line.
A format selector sitting there permanently would occupy space for a control used once a
session, and exporting is a deliberate act where a second click costs nothing.

`downloadSnapshot(format)` takes the format as an argument instead of hardcoding the
literal, and the fallback filename extension follows it. The server already dispatches on
`format`; the only host change is accepting `text` at `Watch-PvssLog.ps1` 3654-3669, which
currently 400s on anything but `html` or `json`.

---

## 7. CLI surface

### 7.1 New parameters on `Watch-PvssLog.ps1`

```text
-Report                          # batch mode: no listener, no browser, write + exit
-OutPath "C:\path\report.txt"    # default <logname>.analysis.<ext> next to the log
-Format Text|Html|Both           # default Both in batch mode
-Organize All|Severity|Driver    # default All
-Severities FATAL,SEVERE,ERROR   # default FATAL,SEVERE,ERROR,WARNING
-Areas SYS,IMPL,CTRL,PARAM,OTHER # default all five  (Watch-only; Offline had no areas)
-Driver "1" | "WCCOAbacnet"      # index or name substring; comma list allowed
-Entire                          # whole file (default in batch mode)
-From "2026.09.04 09:00"         # new absolute lower bound
-To   "2026.09.04 12:00"         # new absolute upper bound
-LastHours 6                     # sugar over -LastMinutes; overrides -From/-To
-Interactive                     # enable the two prompts (§7.3)
```

Existing `-LogPath`, `-TopN`, `-SamplePerPattern`, `-SampleMaxChars`, `-LastMinutes`,
`-NoPause` are reused as-is. `-Port`, `-NoBrowser`, `-RefreshSeconds` are ignored under
`-Report`.

Add `ValidateSet` / `ValidateRange` to the new parameters, matching OfflineAnalyze's stricter
param block — Watch's current block has no validation at all.

### 7.2 Config precedence

`$script:CliOverrides` snapshots `$PSBoundParameters.Keys` and `Apply-WatchConfig` skips any
config key passed on the command line. **Every new parameter shadowing a config key must be
registered in that flow** (`Severities`→`DefaultSeverities`, `Areas`→`DefaultAreas`,
`Entire`→`DefaultWindowEntire`) or it will be silently overwritten on a dashboard Restart.

`-Report` must **not** trigger `Set-WatchConfigLogPath` — a batch run should not rewrite the
operator's saved dashboard path.

### 7.3 Interactive prompts

Active under `-Interactive`. Every prompt accepts Enter for its default. A prompt is skipped
when the corresponding switch was supplied explicitly — passing `-From`/`-To` bypasses the
window menu, passing `-Organize` bypasses the organize menu, and so on.

| Order | Prompt | Options | Default |
|---|---|---|---|
| 1 (pre-scan) | Time window | `[E]ntire` / `[H]` last N hours / `[W]` absolute From/To | `E` |
| 2 (post-scan) | Organize | `[A]ll` / `[S]everity` / `[D]river` / `[Q]uit` | `A` |
| 3a (Severity only) | Severities, then Top N | names or `1`-`5`, comma/space separated | `FATAL,SEVERE,ERROR`; TopN `10` |
| 3b (Driver only) | Manager picker | `1`-`10`, comma list, `N`ext, `P`rev | `#1` on current page |
| 4 (pre-write) | Format | `[T]ext` / `[H]TML` / `[B]oth` | `B` |

**Prompt 1 must run before the scan.** The window sets the backward byte-seek offset in
`Find-WindowStartPosition`, so unlike organize and format it cannot be deferred. `H`
sub-prompts for an hour count (default 6, range 1-8760); `W` prompts for each bound
separately, re-prompting until parseable, and accepts empty for an open end. Before the menu,
print the log path, size, and the peeked time span so the operator can choose meaningfully.

**Prompt 3b** pages the ranked manager list 10 per page, showing name and line count, and
wraps to the first page past the end. The list comes from the existing
`Build-SectionObject -Name managers` payload, which already returns every manager ranked by
volume (`-N 5000`) — the picker is console I/O over data the snapshot already carries.

**Quit** at prompt 2 skips report writing and exits 0; the scan has already completed by that
point, so the console summary still prints.

### 7.4 Launchers

Both at package root, mirroring the retired `Run-Analyze*.cmd` pair — same `cd /d "%~dp0"`,
`-NoProfile -ExecutionPolicy Bypass -File`, `%*` forwarding, `%ERRORLEVEL%` capture, `pause`,
`exit /b` structure.

| File | Invocation |
|---|---|
| `Run-Report.cmd` | `-Report -Format Html -NoPause %*` |
| `Run-Report-Interactive.cmd` | `-Report -Interactive -NoPause %*` |

`Run-Watch.cmd` is unchanged and still forwards `%*`, so `-Report` is reachable through it.

---

## 8. Text renderer

`Convert-SnapshotToText -Snap $snap` returns a string, a sibling of
`Convert-SnapshotToHtml` reading the same object.

Reproduce V1.3's format strings verbatim so the spot-check in §10 is meaningful:

| Purpose | Format |
|---|---|
| count + label rows | `' {0,8:N0}  {1}'` |
| manager health rows | `'   {0,-40} {1,7} {2,7} {3,8} {4,9} {5,9}'` |
| BACnet device activity | `'   {0,4}  {1,6:N0}  {2,6:N0}  {3,5:N0}  {4,-7} {5}'` |
| ranked count/name | `'   {0,2}. {1,8:N0}  {2}'` |
| rank/count/key | `'   {0,4}  {1,6:N0}  {2}'` |
| hourly table | `' {0,-16} {1,10} {2,10} {3,10}'` |
| pattern block | `' #{0}  count={1:N0}'` + `pattern:` / `first  :` / `last   :` / `example:` |

Separators stay `'=' x 80` banners, `--- Section ---`, `=== Subsection ===`, and the one pipe
table for project restarts.

**`Convert-AnalysisReportToHtml` and `Format-ReportSectionBodyHtml` are not ported.** Those
455 lines exist only because OfflineAnalyze had no object to render from; Watch does. The
235-line CSS here-string inside them is a copy of Watch's own theme. Deleting them is a net
line reduction and removes the marker-sniffing coupling between formats.

---

## 9. Package layout after 0.4.0

```text
PvssLogAnalyze\
  Run-Watch.cmd
  Run-Report.cmd                ← new
  Run-Report-Interactive.cmd    ← new
  readMe.txt                    ← rewritten: one tool, two modes
  CHANGELOG.txt
  Watch\
    VERSION.txt                 → 0.4.0
    Watch-PvssLog.ps1
    PvssRules.ps1               ← new, dot-sourced rule table
    watch-config.txt
    ui\
  (OfflineAnalyze\ deleted — frozen 1.3 under docs\archive\OfflineAnalyze\)
docs\                           ← dev only, not in field zips
  BACKLOG.md, archive\ (incl. this PRD + PROGRESS-V0.4.md), PVSS_II_Examples\
  Test-WatchSelf.ps1            ← repaired + new rule/text/batch phases (§4.7)
```

Root `readMe.txt` is rewritten to describe one tool with two modes: the live dashboard via
`Run-Watch.cmd`, and one-shot reports via `Run-Report.cmd`. `CHANGELOG.txt` records the
removal of `OfflineAnalyze\`, operator-focused.

---

## 10. Verification

The tool has two users and is pre-1.0, so the cross-tool comparison is a spot-check. The
*internal* consistency check in §10.1 is exact and automatable, and is the stronger signal.

### 10.1 Batch HTML ≡ dashboard snapshot HTML (primary check)

Both paths call the same `Build-SnapshotObject` then `Convert-SnapshotToHtml`, so on a
**static** log with matched window and filters the two files should be byte-identical apart
from a known allowlist.

The SVG charts are included in that claim: `Build-ChartSeries` derives granularity from the
span, and the downsampling helpers (2542-2832) are pure functions of the point list, so
identical points produce identical path data. Hash-ordering is not a hazard either — both
runs insert in the same sequence from the same file, so enumeration and sort results agree
even though PS 5.1's `Sort-Object` is not stable.

**Allowed differences, and nothing else:**

- `meta.generated` — wall-clock timestamp
- `perf.health.port` and `perf.health.url` — populated in dashboard mode, empty under
  `-Report` (§5.1)

This runs as a `Test-WatchSelf.ps1` phase: start the host, load a fixed example log, fetch
`/api/snapshot?format=html`, run batch mode over the same log with matched switches, and
diff with the allowlist filtered out. Must be run against a static file — a live tailing
dashboard keeps advancing and will not match.

The same comparison applies to `format=text` and `format=json`.

### 10.2 Cross-tool spot-check against frozen 1.3

1. Tag the frozen `Analyze-PvssLog.ps1` 1.3 as reference before deleting it.
2. Run reference and new batch mode against **two or three representative logs** from
   `PVSS_II_Examples\`, covering All and one of Severity/Driver.
3. Diff the text. Expected differences: tool/version banner, generated timestamp, runtime
   line, and sections Watch legitimately adds (areas, detections).
4. **Stricter check on the §4.5 proof migration:** the `cns` and `apogee` sections must be
   byte-identical, since their payload contract did not change. A diff there is a real bug.
5. Operator-input bound parsing per §5.4 — `-From`/`-To` accept `yyyy.MM.dd HH:mm:ss`,
   `yyyy.MM.dd HH:mm`, `yyyy.MM.dd`, the `yyyy-MM-dd` equivalents, and reject garbage with a
   usable message. Date-only `-To` covers through end of day.
6. Rule-engine timing sanity-check per §4.3 — informational, not a gate.

---

## 11. Build phases

| Phase | Deliverable |
|---|---|
| **40** | Repair `Test-WatchSelf.ps1` after the move into `docs\` (§4.7): fix `$Root`, rename `2A`-`2E` phase labels. Prerequisite for everything else being verifiable. |
| **4A** | `PvssRules.ps1` + rule shape + generic state + `Add-RuleHit` + scope index with per-component memoization. Migrate CNS counters and ApogeeDrv rules (§4.5), payload keys unchanged. Rule-test phase in `Test-WatchSelf.ps1`. Timing sanity-check. |
| **4B** | `detections` snapshot key + `CuratedGroups` filter + generic HTML section + Detections view in `app.js`. A new rule row now surfaces with zero renderer edits. |
| **4C** | Snapshot gap-fill: `options`, `hourly`, `driverDeepDive`; organize-mode gating. Verify via `/api/snapshot?format=json`. |
| **4D** | `Convert-SnapshotToText` (including detections); accept `format=text` at 3654-3669; expand-in-place format buttons on Snapshot (§6.4). Text is now testable from the dashboard before batch mode exists. |
| **4E** | Batch mode: `-Report` branch, path-validation extraction, `Resolve-LogPath`, absolute `-From`/`-To`, new param block + config precedence, full V1.3 prompt set (§7.3), both launchers. |
| **4F** | Verification per §10 — the §10.1 equivalence check lands as a `Test-WatchSelf.ps1` phase. |
| **4G** | Delete `OfflineAnalyze\`; rewrite root `readMe.txt` (no OfflineAnalyze mention); `CHANGELOG.txt`; `VERSION.txt` → 0.4.0; update `BACKLOG.md` + `docs/README.md`. |

4A through 4D only add to the dashboard and are shippable-safe at any point. The
irreversible step is 4G, gated on 4F.

---

## 12. Acceptance

1. Adding a detection is one row in `$script:PvssRules` plus one line in
   `Test-PvssRules.ps1`, and it appears in the text report, the HTML report, and the
   dashboard with no other edits.
2. Rule-engine scan performance on a ~50 MB log is within noise of 0.3.0.
3. CNS and ApogeeDrv sections render byte-identically to 0.3.0 after the proof migration.
4. BACnet flip tracking, project lifecycle cycles, and the Apogee orchestration trio still
   work, hand-written and unmigrated.
5. A rule in a curated group reports once, not twice.
6. **Batch HTML and dashboard snapshot HTML on a static log with matched window and filters
   differ only in `meta.generated`, the two `perf.health` fields, and the `gen N` session
   counter — SVG charts included.** Same for text and JSON. (`gen` added to the allowlist
   2026-09-08: it counts catch-ups in the emitting process, so a restarted dashboard runs
   ahead of a fresh batch run. Same category as `perf.health`.)
7. `Run-Report.cmd` produces an HTML report on a double-click with no browser and no port
   bind, and exits non-zero on failure.
8. `Run-Report-Interactive.cmd` reproduces the full V1.3 prompt flow: time window, organize,
   severity + TopN, paged driver picker, format — all Enter-defaulted.
9. Text and HTML render from the same `Build-SnapshotObject` result; no text scraping.
10. All 16 V1.3 report sections are reproducible, gated correctly by all three organize modes.
11. `-From` / `-To` / `-LastHours` / `-Entire` / `-LastMinutes` all scope the report.
12. Log auto-discovery finds `PVSS_II.log`, then `.bak`, then newest `PVSS_II*`.
13. ~~Batch runtime ≤ V1.3 on a ~50 MB log.~~ **Amended 2026-09-08 → batch runtime is within
    noise of a 0.3.0 dashboard entire-file load on the same machine.** The original wording
    assumed the two tools do comparable per-line work; they do not, since Watch also builds
    the per-minute series, the severity/component-by-area matrices, per-component pattern
    maps and BACnet device tracking. Measured 2.2x V1.3 and not closable without a
    `Process-LogLine` refactor, which is deferred to the backlog. See `PROGRESS-V0.4.md` 4F.
14. A batch run does not modify `watch-config.txt`.
15. The dashboard Snapshot control offers HTML / Text / JSON; behavior is otherwise unchanged.
16. `Test-WatchSelf.ps1` runs green from its new `docs\` location.
17. `OfflineAnalyze\` is gone, and `readMe.txt` does not mention it.

---

## 13. Review checklist

- [x] §4.1 rule keys — validated against the example corpus; `$component` bucket tokens and
      `Measure` added as a result (§4.1.1)
- [x] §4.4 hand-written boundary accepted (flips, lifecycle, Apogee trio)
- [x] §4.5 proof-migration targets agreed (CNS counters + ApogeeDrv)
- [x] §7.1 parameter names and defaults agreed (`-Report` as the mode switch)
- [x] §7.4 launcher names agreed — `Run-Report.cmd` / `Run-Report-Interactive.cmd`
- [x] §5.3 absolute `-From`/`-To` approach accepted; seek strategy settled in §5.3.1
- [x] Status → **Locked / ready to build** → [`PROGRESS-V0.4.md`](PROGRESS-V0.4.md) created
- [x] Shipped 2026-09-12 as Watch 0.4.0; this file + tracker archived under `docs\archive\`
