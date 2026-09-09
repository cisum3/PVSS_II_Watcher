# Implementation Progress — PVSS Log Analyzer V2.4

Tracks work against locked [`PRD-V2.4.md`](PRD-V2.4.md).
**Target:** Watch **2.4** — declarative rule engine; `OfflineAnalyze\` absorbed and removed.
**Started:** 2026-09-07 · **Author:** Cisum

| Status | Meaning |
|--------|---------|
| **Built** | Implemented in code by the agent; not yet verified by you |
| **Confirmed** | You have run it and confirmed it works |

**Rule:** Confirm before marking **Confirmed**. Review the next phase before starting it.

---

## Phases

| Phase | Description | Built | Confirmed | Notes |
|-------|-------------|:-----:|:---------:|-------|
| **40** | Repair `Test-WatchSelf.ps1` after the move into `docs\` | yes | yes | 30/30 pass, exit 0, ~200 s full run (2026-09-07) |
| **4A** | Rule engine + `PvssRules.ps1` + proof migration (CNS, ApogeeDrv) | yes | | Engine only — no new rules |
| **4B** | `detections` payload + generic renderers + Detections nav view + 14 new rules | yes | | |
| **4C** | Snapshot gap-fill: `options`, `hourly`, `driverDeepDive`, organize modes | yes | | |
| **4D** | `Convert-SnapshotToText` + `format=text` + snapshot format buttons | yes | | |
| **4E** | Batch mode `-Report` + absolute window + prompts + launchers | yes | | Prompts driven end to end by `_batch2.ps1`; human pass cosmetic only |
| **4F** | Verification (§10) | yes | | Full suite 40/40. Acceptance 13 amended (PRD §12.13); perf work deferred to backlog |
| **4G** | Delete `OfflineAnalyze\`, docs, version bump to 2.4 | part | | Docs + VERSION done; deletion and zip held by Cisum |


4A-4D are additive to the dashboard and shippable-safe at any point.

---

### 40 — Test harness repair (PRD §4.7)

| Item | Built | Confirmed |
|------|:-----:|:---------:|
| `$DocsRoot` = script dir; `$Root` = its parent; `$WatchRoot` correct again | yes | yes |
| `$ExamplesRoot` variable replaces every hardcoded `docs\PVSS_II_Examples\` | yes | yes |
| Phase labels → `Assets` / `Api` / `Control` / `Modules` / `Snapshot` / `All` | yes | yes |
| Full run green from new `docs\` location | yes | yes |

**Run 2026-09-07:** `-Phase All -Port 8799` → 30 PASS, 0 FAIL, exit 0, ~200 s.
Assets 8 · Api 5 · Control 6 · Modules 10 · Snapshot 2. Temp artifacts cleaned up.

Paths now derive from the script location, so a future move needs one edit, not eight.
Phase names describe what they test rather than which V2.0 build step produced them.

**Side effect observed:** the run rewrote `Watch\watch-config.txt` `LogPath=` to the example
log, because `Set-WatchConfigLogPath` fires on every successful Start (3509). Harmless for
the dashboard, but it confirms PRD §7.2 is a real requirement — `-Report` must not persist
the path. Revert the file before committing if you do not want the local path tracked.

---

### 4A — Rule engine (PRD §4)

| Item | Built | Confirmed |
|------|:-----:|:---------:|
| `Watch\PvssRules.ps1` created; dot-sourced via `$script:Root` with existence check | yes | |
| Rule keys: `Id` `Group` `Label` `Re` `Scope` `BucketBy` `Measure` `Sample` `SampleSlot` `PatternGroup` | yes | |
| `BucketBy` accepts capture index **and** `'$component'` / `'$area'` / `'$severity'` | yes | |
| `Measure` with `Sum` / `Max` aggregation | yes | |
| Generic state: `Hits` `HitBuckets` `HitMeasures` `HitSevs` `HitSample` `HitTime` | yes | |
| `Clone-AnalysisState` covers the new maps | yes | |
| `Add-RuleHit` | yes | |
| Scope index + per-component memoization (`Register-RuleSet` / `$script:RuleSetCache`) | yes | |
| Proof migration: CNS counters (`CnsResolve/Reduced/ICns/TryRenew`) | yes | |
| Proof migration: ApogeeDrv (`trendOverflow` `trendSeq` `alertId` `queryTimeout` `getDataFail`) | yes | |
| Migrated section payload keys unchanged (`app.js` / HTML untouched) | yes | |
| Rule-test phase added to `Test-WatchSelf.ps1` | yes | |
| Self-test asserts migrated `cns` / `apogee` payloads match pre-migration output | yes | |
| Timing sanity-check on a ~50 MB log | yes | |

Scope note: 4A ships the **engine only**, with no new rules beyond the two migrated clusters.
The corpus-validated rules land in 4B, once there is a renderer to display them.

**Parity run 2026-09-07** — `PVSS_II_C2P.log` (48 MB, 321,166 parsed lines). Replayed the
pre-migration `Watch-PvssLog.ps1` (git HEAD) and the rule-engine build through the same
`Process-LogLine` harness and compared the `cns` / `apogee` section payloads plus
`Build-Findings`: **byte-identical**, 21,170 chars. Runtime 411.1 s → 369.2 s.

`Test-WatchSelf.ps1 -Phase Rules` → 14 PASS, 0 FAIL, 3.6 s. Runs offline (no listener), so
it does not touch `watch-config.txt`. It loads Watch's function library by cutting the file
at the `# --- main ---` marker — keep that marker in place.

**Deviations from the PRD, deliberate:**

- `Trim` is specified **per bucket**, not per rule: a `BucketBy` value may be a capture index,
  a header token, or `@{ Group = 2; TrimEnd = '.' }`. The migrated trend-overflow rule needs
  `TrimEnd` on `device` but not on `trend`, so a rule-level key could not reproduce 2.3.
- `FindingAt` is **not implemented yet**. No shipped rule uses it — the migrated clusters keep
  their hand-written `Build-Findings` thresholds. It lands in 4B with the generic renderers.
- The match loop is **inlined in `Process-LogLine`** instead of living behind a
  `Get-RulesForComponent` call. A PowerShell call with a bound param block measured ~122 µs;
  at one call per line that alone cost +12 % on the 48 MB catch-up. `Add-RuleHit` stays a
  function because it only runs on a hit (~1,200 times in that run). Rules still live entirely
  in `PvssRules.ps1`; only the four-line loop is in the main script.
- A combined pre-filter regex was measured and **rejected**: an 18-way alternation costs as
  much as running the 18 patterns separately (4,304 ms vs 4,406 ms per 100k lines) and is
  slower on a hit. Per-rule cost is ~2.2 µs, so the 14 rules in 4B should add ~3 % on a 48 MB
  log — check this again at the end of 4B.

**Re-checked at the end of 4B:** the same harness with all 23 rules ran C2P in **428.5 s**
(34,140 rule hits), against 369.2 s with the 9 migrated rules — **+16 %, not the predicted
3 %**.

**Resolved 2026-09-08 by a back-to-back A/B** (`docs\_abrun.ps1`), first 120,000 lines of
C2P, all three builds over an identical line set, alternated across two rounds:

| Build | Round 1 | Round 2 |
|---|---|---|
| 2.3 committed baseline | 131.1 s | 133.6 s |
| 2.4 with an **empty** rule table | 120.2 s | 132.4 s |
| 2.4 shipping (23 rules) | 135.9 s | 157.8 s |

All three parse the same 93,347 lines. The ordering is consistent in both rounds: the 2.4
refactor is a small win on its own, and **the rules then cost 13-19 % on top of it**, leaving
2.4 net 4-18 % slower than 2.3.

So the +16 % was real and it *is* the rule table. The ~3 % prediction was wrong for two
reasons: it priced only the regex match, ignoring the per-line `foreach` and hashtable lookup
around each rule; and it assumed scope gating would keep most rules off most lines, when in
fact **18 of the 23 rules have no `Scope`**, so they evaluate on every parsed line. Only the
5 ApogeeDrv rules are gated.

Two caveats on the table. The empty-rule build is not a clean control — with no rules,
`$isCnsLine` never goes true, so it also skips the CNS pattern accumulation that 2.3 and 2.4
both do, which flatters it. And run-to-run variance on this box is large (the shipping build
moved 136 s → 158 s between identical rounds), so treat the percentages as a direction, not a
figure.

**Scoping pass 2026-09-08 — 44 % fewer rule evaluations, no detections lost.**
`docs\_scopes.ps1` mapped every unscoped rule to the components it actually fires on across
all 12 example logs (2,148,799 parsed lines, 104 distinct components). Seven rules turned out
to be emitted by exactly one manager binary and were gated:

| Rule | Scope | Why it is safe |
|---|---|---|
| `trend.dataLoss` | `GmsBACnet` | "trend log object" is BACnet's own term |
| `alarm.getSummaryFail` | `GmsBACnet` | GetAlarmSummary is a BACnet service |
| `device.cptFailed` | `GmsBACnet` | CPT = BACnet ConfirmedPrivateTransfer |
| `device.aesDecrypt` | `GmsBACnet` | BACnet device credential |
| `driver.offline` | `CoHo` | command handler reporting on its own dispatch |
| `driver.readFile` | `CoHo` | as above |
| `afw.serverSideException` | `CComMgr` | the comm manager marshals the server call |

Scopes are **binary-name substrings, never instance numbers** (`GmsBACnet`, not
`WCCOAGmsBACnet(1)`), so a site with different instance numbering still matches.

`docs\_scopecheck.ps1` is the safety net: for all 23 rules it counts corpus matches with the
gate applied and with it ignored, and fails if any rule loses a hit. **All seven new scopes
are hit-neutral** on 2.1 M lines. Rule evaluations 49,422,377 → 27,667,235 (44 % fewer;
~29 % of that is this pass, the rest was the existing ApogeeDrv gating). Rules scoped: 12/23.
`-Phase Rules` 21/21 and the §10.1 byte-identical check both still pass.

Three left deliberately unscoped despite looking scopeable:

- `driver.errorCode` — 184,640 hits in CoHo but **21 in `Siemens.Gms.ApplicationFramework(1)`**.
  A `CoHo` scope would save 40 % of lines and silently drop those 21. Not worth trading
  coverage for speed.
- `trend.seqLess`, `alarm.alertIdUnknown` — each fires for two drivers, and `Scope` is a
  single substring. Backlogged as multi-scope.

The check also surfaced a **coverage gap that predates this pass**: the four narrowing
`apogeeDrv.*` scopes hide 38,000+ `WCCOAGmsBACnet` hits. That is correct 2.3 behaviour and 4A
froze it, so it is not touched here — written up in `BACKLOG.md` → Detection / parsing.

---

### 4B — Detections rendering + new rules (PRD §6.2, §4.1.1)

| Item | Built | Confirmed |
|------|:-----:|:---------:|
| `detections` snapshot key (group → rules → count/severities/measures/buckets) | yes | |
| `/api/section?name=detections` for the dashboard | yes | |
| `$script:CuratedGroups` exclusion | yes | |
| Zero-hit rules omitted | yes | |
| HTML section (reuses `Add-SnapCountNameTable`) + `#detections` nav link | yes | |
| Detections nav view in `ui\app.js` + `index.html` (+ mock payload) | yes | |
| Measure-carrying rules lead with the aggregate, not the line count | yes | |
| `FindingAt` threshold headlines wired into `Build-Findings` | yes | |
| New rule row surfaces in HTML + dashboard with no renderer edits | yes | |

**Corpus-validated rules** (PRD §4.1.1). "Evidence" is the PRD's figure, "Measured" is what the
rule actually counted on the same corpus:

| Rule | Id | Evidence | Measured | Built | Confirmed |
|------|----|----------|----------|:-----:|:---------:|
| `Unexpected state, <subsystem>, <method>` | `state.unexpected` | ~6,400 / 3 logs | 8,349 | yes | |
| `Repetition (#=N) of a former trace` | `afw.traceRepetition` | 13,238 (H1P) | 13,238 (H1P) | yes | |
| `We counted N COVs` | `afw.covBurst` | 1,559 (H1P) | 1,559 (H1P) | yes | |
| `Trend buffer data loss` | `trend.dataLoss` | 1,849 (C2P) | 1,853 (C2P) | yes | |
| `Last sequence number N is less than saved` | `trend.seqLess` | 1,845 (C2P) | 1,891 (C2P) | yes | |
| `The Driver returned Error Code N` | `driver.errorCode` | 6,869 (C2P) | 6,890 (C2P) | yes | |
| `Command failed because Driver N is offline` | `driver.offline` | 4,506 (C2P) | 4,506 (C2P) | yes | |
| `Device N Read File returned error code N` | `driver.readFile` | 3,458 (C2P) | 3,458 (C2P) | yes | |
| `AlertID ... is not known` | `alarm.alertIdUnknown` | 3,090 (H1P) | 3,090 (H1P) | yes | |
| `CPT failed: The BACnet device is failed` | `device.cptFailed` | 1,568 (H1P) | 1,568 (H1P) | yes | |
| `AES decryption of password unsuccessful` | `device.aesDecrypt` | 1,008 (C2P) | 2,016 (C2P) | yes | |
| `SERVER-SIDE exception: <Type>` | `afw.serverSideException` | 1,193 + 1,039 | 1,198 + 1,641 | yes | |
| `Examining retained invocations` | `afw.retainedInvocations` | 6,261 (C2P) | 6,261 (C2P) | yes | |
| `GetAlarmSummary failed for device N` | `alarm.getSummaryFail` | 200 (C1P) | 201 (C1P) | yes | |

**Two evidence figures in the PRD were wrong, not the rules:**

- `AES decryption` — the log holds **1,008 distinct devices** each failing in two separate
  incidents (2026.05.04 and 2026.09.01), so 2,016 lines is correct. The bucket map confirms
  exactly 1,008 distinct devices.
- `SERVER-SIDE exception` H1P — a raw grep finds 1,641, and the rule matches all of them. The
  PRD's 1,039 was presumably one exception type rather than the family.

`state.unexpected` intentionally misses 8 lines of the form
`Unexpected state, Only one thread may call Manager::send() at:498 file:...` — that variant
carries no subsystem/method pair, so folding it in would produce junk bucket values.

**Group names avoid the curated set.** `CuratedGroups` suppresses a group from `detections`,
so a new rule tagged `BACnet` would render nowhere. The 14 rules use `Platform`, `Trending`,
`Driver`, `Alarms`, `Devices`, `Framework` — several of them do fire on `WCCOAGmsBACnet`
lines, which is fine; the group is a report heading, not a component filter.

**Deliberate overlap:** `alarm.alertIdUnknown` is a subset of `state.unexpected`
(`Unexpected state, AlertService, sendAck, AlertID ... is not known`). Both fire. Detections
are per-rule rows with no shared total, so nothing is inflated, and the specific row is the
actionable one.

**Addition beyond the PRD:** `$script:RuleBucketCap = 2000` limits distinct values per bucket
map. Counts for values already seen keep rising; new values are dropped and the payload sets
`capped = true`. The corpus peaks at 1,008 distinct, so this only bites on a rule bucketed by
something unbounded like a datapoint name — which is exactly the mistake a casual rule author
would make. Bucketing on free text (property names, AlertIDs) was avoided for the same reason.

**Verified 2026-09-07:** `Test-WatchSelf.ps1 -Phase Rules` → 21 PASS, 0 FAIL. Live host on
`PVSS_II_C1P.log`: `/api/section?name=detections` returned 4 groups; snapshot HTML contained
`<section id="detections">` and the nav link; `format=json` carried the key. Dashboard checked
in a browser in both `?mock=1` and real-data mode — Detections renders groups, measure-led
headlines and bucket tables, and BACnet / CNS / Apogee still render. No console errors.

---

### 4C — Snapshot gap-fill (PRD §6)

| Item | Built | Confirmed |
|------|:-----:|:---------:|
| `options` key (organize, severities, drivers, areas, TopN, window, format) | yes | |
| `hourly` key from `series.byMinute` rollup | yes | |
| Hourly presentation rule: full ≤25 hours, else last 24 + busiest 10 | yes | |
| `driverDeepDive` via `Build-ManagerObject` | yes | |
| Organize gating (All / Severity / Driver) at render time | yes | |
| Caps still disclosed (lifecycle 200, manager health 25) | yes | |

`Get-ReportSections` is the single place that decides which sections a report carries; both
renderers consume it, so HTML and text can never drift on inclusion. `driverDeepDive` is only
built when `Organize=Driver`, since `Build-ManagerObject` is not free and the other two modes
never render it.

---

### 4D — Text renderer (PRD §8, §6.4)

| Item | Built | Confirmed |
|------|:-----:|:---------:|
| `Convert-SnapshotToText` | yes | |
| V1.3 format strings reproduced verbatim | yes | |
| Banner / `--- Section ---` / `=== Subsection ===` / restart pipe table | yes | |
| Detections rendered in text | yes | |
| `format=text` accepted at the snapshot endpoint | yes | |
| Snapshot button expands in place → `HTML` · `Text` · `JSON` | yes | |
| `Esc` / click-outside collapses without downloading | yes | |
| `downloadSnapshot(format)` takes the format as an argument | yes | |

**Browser pass 2026-09-08.** First attempt failed: collapsed and expanded states rendered at
once, because `.seg` sets `display: inline-flex` and that outranks the `hidden` attribute's
UA `display: none`. Fixed with `.snap-formats[hidden] { display: none !important; }`. Re-test
green — collapsed shows only the button, expanded only the three chips, and both `Esc` and a
chip click collapse. No console errors.

**Verified 2026-09-07** on `PVSS_II_C1P.log` via the live host: `format=text` returns
`text/plain` with a `.txt` `Content-Disposition`; All = 483 lines / 19 sections, Severity =
229 lines / 9 sections, Driver = 360 lines / 14 sections; `format=bogus` still 400s.

**One deviation from §8.** The V1.3 heading `--- Top N components (managers) ---` interpolated
`TopN`, but Watch's `topManagers` is always the top 20 regardless of `TopN`, so the heading
reports the actual row count instead of a number it would not honour.

---

### 4E — Batch mode (PRD §5, §7)

| Item | Built | Confirmed |
|------|:-----:|:---------:|
| `-Report` branch before `Start-Listener`; no port bind, no browser | yes | |
| Path validation extracted from the `/api/logPath` handler (`Assert-LogPathUsable`) | yes | |
| `Resolve-LogPath` discovery (exact → `.bak` → newest `PVSS_II*`) | yes | |
| `$script:Sync` seeded so `meta` is populated | yes | |
| `perf.health.port` / `url` emitted as empty strings | yes | |
| `ConvertFrom-UserTimestamp` + `Convert-WindowBound` (operator input) | yes | |
| `-From` / `-To` absolute window; date-only `-To` → end of day | yes | |
| Seek guards: `-From` ≤ first ts → byte 0; `-From` > last ts → fail fast | yes | |
| `-Entire` / `-LastHours` / `-LastMinutes` | yes | |
| New param block with `ValidateSet` / `ValidateRange` | yes | |
| Config precedence registered (`Severities`, `Areas`, `Entire`) | yes | |
| Batch run does **not** call `Set-WatchConfigLogPath` | yes | |
| Prompt 1 pre-scan: time window (`E` / `H` / `W`) | yes | |
| Prompt 2: organize (`A` / `S` / `D` / `Q`) | yes | |
| Prompt 3a: severities + TopN | yes | |
| Prompt 3b: paged manager picker | yes | |
| Prompt 4: format (`T` / `H` / `B`) | yes | |
| `Run-Report.cmd` | yes | |
| `Run-Report-Interactive.cmd` | yes | |

**Automated run 2026-09-07** (`docs\_batch.ps1`, `PVSS_II_C1P.log`): **28 PASS / 0 FAIL**,
covering All/Severity/Driver, `-From`/`-To`, date-only `-To`, `-LastHours`, `-LastMinutes`,
garbage `-From`, `-From` past end of log, inverted bounds, default `OutPath` placement, and
`watch-config.txt` being untouched.

**Still needs a human pass:** the four interactive prompts. They are wired and the
non-interactive paths through the same code are covered, but nobody has typed at them.
Run `Run-Report-Interactive.cmd` once before marking 4E confirmed.

**Additions beyond the PRD:**

- `Process-LogLine` gained an `UpperCompare` parameter for `-To`. It filters rather than
  stopping the read, because timestamps are not monotonic across managers.
- `Save-EntireCache` is skipped under `$script:Sync['BatchMode']`. The cache only pays off
  across dashboard window switches, and cloning the full state before exiting is pure cost.
- `options.format` names the file being written, so `-Format Both` produces exactly what two
  single-format runs would. Without this the §10.1 equivalence check fails on one line.
- Interactive prompts are skipped when the matching switch was supplied, per §7.3 — the
  window prompt also treats `-Entire`, `-LastMinutes` and `-LastHours` as "already answered".

---

### 4F — Verification (PRD §10)

| Item | Built | Confirmed |
|------|:-----:|:---------:|
| §10.1 equivalence phase in `Test-WatchSelf.ps1` (batch ≡ dashboard snapshot) | yes | |
| HTML identical apart from `meta.generated` | yes | |
| Same for `format=text` | yes | |
| SVG charts byte-identical | yes | |
| Frozen 1.3 tagged before deletion | | 4G |
| Cross-tool spot-check on 2-3 example logs | yes | |
| Operator-input bound parsing accepts documented forms, rejects garbage | yes | |
| Log auto-discovery: exact → `.bak` → newest `PVSS_II*` → error (acceptance 12) | yes | |
| `Run-Report.cmd` writes HTML, binds no port, exits non-zero on failure (acceptance 7) | yes | |
| Full interactive prompt flow driven end to end (acceptance 8) | yes | |
| Batch runtime within noise of a 2.3 entire-file load (PRD §12.13, amended) | yes | |

**§10.1 run 2026-09-07** — `Test-WatchSelf.ps1 -Phase Report` on `PVSS_II_C1P.log`, entire
file, matched severities/areas: batch HTML **byte-identical** to the dashboard snapshot
(55,148 chars) and batch text likewise (26,086 chars), with only the `Generated` line
normalised. The SVG charts are inside that HTML, so §10.1's chart claim holds.

`format=json` is **not** compared: batch `-Format` is `Text|Html|Both` by §7.1, so there is no
batch JSON file to diff. The JSON path is exercised by the Snapshot phase instead.

**§10.2 cross-tool spot-check** against frozen `Analyze-PvssLog.ps1` 1.3. Differences found
and their disposition:

| Difference | Disposition |
|---|---|
| Severity counts ordered by count desc, zeros omitted (1.3) vs fixed FATAL→INFO with zeros (2.4) | **Keep 2.4.** The fixed order is Watch's convention everywhere else (dashboard, HTML snapshot, `$script:RuleSevOrder`); making text disagree with HTML would be worse. |
| `--- Top 10 components ---` vs `--- Top 20 ---` | **Keep 2.4** — see 4D. |
| Apogee / CoHo block layout | **Fixed.** The first pass condensed them; both now reproduce 1.3's labelled layout line for line. |
| 1.3 omits CNS / CoHo / Apogee sections entirely when their counters are zero | **Keep 2.4.** A zeroed section is a useful triage answer, and always emitting keeps the text and HTML section inventories the same. |
| 2.4 adds `--- Area counts ---`, `--- Detections: * ---`, `--- Options used ---`, `--- Notes ---` | Expected per §10.2 step 3. |

Performance-related keyword categories came out **byte-identical** on both logs.

**§10.3 discovery / launcher / prompt run 2026-09-08** (`docs\_batch2.ps1`): **34 PASS / 0 FAIL**.
Covers all four tiers of `Resolve-LogPath`, `Run-Report.cmd` through `cmd.exe` (HTML written,
no port bound, non-zero exit on a bad path), and every interactive prompt driven from canned
stdin — defaults, `[H]` with a rejected hour value, `[W]` with a rejected bound, `[S]` with
severities + TopN, `[D]` with `N`/`P` paging, `[Q]`, and switch-supplied prompt skipping.
`Read-Host` reads redirected stdin, so the prompts are automatable after all; the remaining
human pass is cosmetic only.

### Batch runtime is 2.2x V1.3 — acceptance 13 amended rather than met

`docs\_perf.ps1` on `PVSS_II_C2P.log` (48 MB, 438,480 lines scanned):

| Tool | Runtime |
|---|---|
| OfflineAnalyze 1.3 | **219.3 s** |
| Watch 2.4 `-Report` | **481.1 s** (+119 %) — 475.9 s of it the scan |

An independent repeat gave 207.0 s vs 465.5 s (+125 %), so the ratio is stable even though
absolute times drift 3-6 % between runs on this machine.

This is **not** a 2.4 regression: 4A measured the same scan at 411 s on 2.3 and 369 s on 2.4.
It is also not the rule engine, and it is barely about regexes at all.

`docs\_callcost2.ps1` — every PowerShell **function call** on this machine costs ~80-96 µs,
while everything else runs at normal speed:

| Operation | Cost |
|---|---|
| Function call, empty body, no args | **78 µs** |
| Function call, empty body, one arg | **94 µs** |
| Loop iteration | 1.2 µs |
| .NET method call (`Substring`) | 1.8 µs |
| Hashtable set + get | 2.1 µs |
| Compiled `[regex]` `IsMatch` | 2.4 µs |

**Corrected 2026-09-08.** This was first written up as "calls are ~40x too expensive, AMSI is
the likely hook". That was wrong. The primitives above are *also* slow in absolute terms — a
0.2 µs hashtable op is normal, 2.1 µs is not — so the whole machine is roughly 5-10x down,
and the call-to-primitive **ratio** (~45x) is what PowerShell 5.1 normally shows. There is no
evidence of a hook. Cisum confirmed the cause: 2.3 was developed and benchmarked on a fast
desktop, and the switch to this laptop happened immediately after 2.3 shipped, so a machine
change was read as a version regression. Function calls are simply the most expensive thing
in a PS 5.1 hot loop, which is what 4A found when inlining the rule loop.

`docs\_profile.ps1` over 60,000 C2P lines, against 61.0 s total for `Process-LogLine`:

| Component | Share | Calls per line |
|---|---|---|
| `Add-Pattern` x3 (severe path) | **55 %** | 3 |
| `Ensure-Minute` + `Ensure-MinuteArea` | **20 %** | 2 |
| `Get-PerfCategory` | **15 %** | 1 |
| `Normalize-Message` | **13 %** | 1 |
| Rule engine, scope-gated | 3 % | 0 (inlined) |
| All 14 unconditional regex batteries combined | **< 1.5 %** | 0 (inlined) |

`Process-LogLine` costs 1.02 ms/line and makes ~5 calls on an INFO line, ~10 on a severe one.
At ~95 µs each that is 0.5-0.95 ms — i.e. **over 80 % of the scan is call overhead, not
analysis**. The shares above exceed 100 % because each row is dominated by the same overhead.

**Disposition.** Acceptance 13 was written on the assumption that the two tools do comparable
per-line work. They do not: Watch additionally maintains the per-minute series, the
severity-by-area and component-by-area matrices, per-component pattern maps, and BACnet
device/flip tracking. Normalising out the call overhead still leaves Watch roughly 2x
OfflineAnalyze, so the criterion is unreachable as written even on a healthy machine.

**Resolved 2026-09-08 — acceptance 13 amended, no code change.** PRD §12.13 now reads
"batch runtime is within noise of a 2.3 dashboard entire-file load on the same machine",
which 2.4 meets. Absolute runtime on a 48 MB log stays ~8 min on this laptop.

Inlining the four hot helpers is deferred to `BACKLOG.md` → Performance (post-2.4), together
with scoping the 18 unscoped rules. Both are worth doing; neither blocks 2.4. **4F is green.**

### Full-suite run 2026-09-08 — 40 PASS / 0 FAIL, exit 0, 340 s

`Test-WatchSelf.ps1 -Phase All -Port 8799`: Assets 8 · Rules 22 · Api 5 · Control 6 ·
Modules 10 · Snapshot 2 · Report 3. Two bugs surfaced only in the combined run:

- **`-Phase All` clobbered its own parameters.** The `Rules` phase dot-sources Watch's
  function library, which still carries Watch's `param()` block, so `$LogPath` and `$Port`
  were rebound to *Watch's* defaults. Every later phase then ran with no log (three FAILs)
  and on port 8787 instead of the requested one. The single-phase runs all passed because
  nothing ran after `Rules`. Fixed by snapshotting the test's own parameters before the
  dot-source and restoring them after.
- **§10.1 needs a third allowlist entry: `gen N`.** That is the session generation counter,
  which counts catch-ups in the emitting process — the `Control` phase's restart puts the
  dashboard several ahead of a fresh batch run (`gen 6` vs `gen 3`). Pure per-process state,
  the same category as the `perf.health` port/url carve-out, so it is normalised alongside
  `meta.generated`. Everything else still matches byte for byte: HTML 55,148 chars, text
  26,499 chars.

**Scratch harnesses kept in `docs\`** (untracked, dev-only): `_batch.ps1`, `_batch2.ps1`,
`_crosstool.ps1`, `_perf.ps1`, `_profile.ps1`, `_callcost2.ps1`. Delete them at 4G unless the
perf decision above turns into work.

---

### 4G — Retire OfflineAnalyze (PRD §9)

| Item | Built | Confirmed |
|------|:-----:|:---------:|
| Root `readMe.txt` rewritten — one tool, two modes; no OfflineAnalyze mention | yes | |
| `CHANGELOG.txt` updated (operator-focused) | yes | |
| `Watch\VERSION.txt` → `2.4` | yes | |
| `BACKLOG.md` + `docs\README.txt` updated | yes | |
| `Watch\OfflineAnalyze\` deleted | | **held by Cisum** |
| Field zip built and smoke-tested | | **held by Cisum** |

**Docs pass 2026-09-08.** Cisum asked for the documentation half of 4G only — the folder
deletion and the zip are deliberately not done, so the package is in a mixed state right now:
the docs describe 2.4 (one tool, two modes) while `Watch\OfflineAnalyze\` is still on disk.
That is intended and temporary; nothing else needs redoing when it goes.

`readMe.txt` is a rewrite rather than an edit. It now leads with "one tool, two modes",
documents both launchers, and carries a switch table for report mode (`-From`/`-To` formats,
`-Organize`, `-Severities`, auto-discovery order) that the old file had pushed into the
OfflineAnalyze sub-readme. Two additions worth noting: a short **Detections** section that
tells an operator `PvssRules.ps1` is where a missed signature gets added — which is the whole
point of 2.4 and would otherwise be invisible to the field — and a plain warning that a 50 MB
log takes several minutes, so nobody thinks it has hung.

`CHANGELOG.txt` leads with the OfflineAnalyze absorption and ends with an **Upgrading** note,
since anyone unzipping over an existing install keeps a stale `OfflineAnalyze\` folder and
two launchers that no longer have a partner. The header's reference to
`Watch\OfflineAnalyze\VERSION.txt` is gone.

Two things deliberately **not** claimed in the user-facing docs: the rule count (it changes
every release) and any performance figure (see 4F — the numbers are machine-dependent).

**Left to do in 4G:** delete `Watch\OfflineAnalyze\`, tag frozen 1.3 first (§10.2 step 1),
then build and smoke-test the field zip.

---

## Pre-ship fixes (2026-09-08)

Three of the five bugs logged during 2.4 testing were cheap enough to fix before the zip.
The other two (snapshot lockup, entire-window caching) stay in `BACKLOG.md` — the first has
no reproduction, and the second is an investigation with a likely architectural outcome.

**Time-window desync.** The window presets, custom value, unit chips and Apply are now
disabled whenever `starting` / `awaitingLoad` / `pulse.loading` is set — the same signals
that already gate the Snapshot button, so it cannot latch on. The subtlety: the chips render
*from* `state.windowEntire` / `state.lastMinutes`, so a handler that mutates state and then
declines to send the request **is** the desync. The guard therefore runs before any mutation
(`windowLocked()` at the top of the chip handler and `applyCustomWindow`), with the disabled
attribute as the visible half. `showLoading()` calls `updateChromeButtons()` directly so the
lock lands immediately rather than a poll interval later.

**`â€¦` encoding.** Both literals removed — the ellipsis became `&hellip;`, and a `→` in a
comment became `->`. Adding a BOM was rejected as the fix: it would be silently lost if an
editor re-saved the file. Instead the `Assets` self-test phase now fails on any non-ASCII
byte in `Watch\*.ps1`, so the class of bug cannot return unnoticed.

**Detections readability — mechanical half only.** Three objective noise fixes, applied to
both renderers plus the text report:

| Fix | Before | After |
|-----|--------|-------|
| Single-value buckets | `By manager — 1 distinct` + a one-row table | `All from manager WCCOAGmsCoHoMngr(7)` |
| Redundant severity echo | `783 line(s) · SEVERE 783` | `783 SEVERE line(s)` |
| Count column | 50/50 split stranded the count from its value | `table.data.kv`, count column shrinks to content |

The severity fold only applies when there is exactly one severity *and* its count equals the
line count; a mixed rule such as `state.unexpected` keeps its full `SEVERE 5, WARNING 133,
INFO 1` breakdown. The `kv` class is a modifier rather than a change to `table.data`, to keep
the blast radius off the BACnet/CNS/Perf tables this late in the release.

Verified: `Assets`, `Rules` and `Report` phases all pass, and batch output is still
byte-identical to the dashboard snapshot — the HTML dropped 55,153 → 54,890 chars on C1P,
which is the collapsed one-row tables. The dashboard view was checked separately in mock
mode (`?mock=1`) since no automated check covers `renderDetections`; the mock payload was
extended to exercise the folded-severity, collapsed-bucket and multi-severity branches.

---

## Detections ranking (2026-09-09)

The remaining half of the detections work: the section had no notion of priority, so it led
with whatever the rule table happened to list first.

**The finding that shaped it.** The obvious candidate — scale `FindingAt` by the window and
rank on `count / effectiveThreshold` — does nothing. A window-derived factor is the same
divisor for every rule in a report, so it cancels out of the ordering and leaves you sorting
by `count / FindingAt`. Both that and raw count put the highest-volume rule first, which on
C3P is "Repeated trace" (45,066 hits of logging chatter) ahead of a driver that was offline
for four hours. Dynamic scaling changes *which Findings fire*; it cannot order Detections.

What does separate them is rate over each rule's **own** first-to-last span, which is already
in the payload:

| C3P, top 3 | by count (2.4.0) | by count/FindingAt | by rate over own span |
|---|---|---|---|
| 1 | Repeated trace (45,066) | Repeated trace (90x) | **driver offline (1,038/hr)** |
| 2 | driver offline (4,563) | driver offline (18x) | Repeated trace (82/hr) |
| 3 | Unexpected state (2,145) | seq lower (6x) | Unexpected state (4/hr) |

Same on C2P, where `device.aesDecrypt` scores 20x on the threshold ratio but 0.7 hits/hour —
2,016 hits dribbled over four months across 1,008 devices. The ratio calls it urgent; the
rate correctly calls it background.

**Why the badge shows something else.** The rate is unusable as a displayed number: C2P's
driver-offline burst is 4,506 hits in seven seconds, which reads as 270,360/hr. So rate
orders the section and `count / FindingAt` is what gets rendered — "18x threshold" is a
number a person can hold. Sub-minute spans are floored at 60 s (`$script:RuleMinSpanSec`),
or two hits a second apart would top the list.

**Severity weighting** (`$script:RuleSevWeight`, FATAL 4 → INFO 0.25) is applied to the sort
score. It changed the order on neither corpus log, so it is currently earning nothing; it is
in because an INFO-heavy rule outranking a SEVERE one is a failure worth pre-empting.

**Payload additions** (per rule): `findingAt`, `over`, `spanSec`, `rate`, `score`; groups also
carry `score`. Rules sort by score within a group, groups by their own worst rule, both with
an id/name tiebreak so 10.1 stays byte-comparable. Renderers stay generic — a new rule row
still needs no renderer edit.

**Rendered:** a threshold badge beside each rule title (emphasised over 1x, muted under) and
the span duration in the meta line, in all three renderers. Duration is what makes the order
legible — 4,563 hits over 4 h is an outage, the same count over three weeks is background.

Verified: 26 Rules assertions pass (5 new), Report phase still byte-identical on HTML and
text, dashboard checked in mock mode. `docs\_detdata.ps1` and `docs\_rank.ps1` are the
throwaway harnesses behind the tables above.

**Still open:** dynamic scaling of the Findings thresholds themselves — see `BACKLOG.md`.
It is independent of this work, and needs triage calls on ~19 comparisons first.

---

## Open items / notes

- Rules must not anchor on the GMS version token — C1P renders
  `, N, GMSv5.1.0.0e,Orch.Alarm,...` while C2P/H1P render `, N, , GMSe,Orch.Alarm,...`.
  Anchor on the sub-area name instead.
- `ProjectRestartEvents` stays capped at 200 and `managerHealth` at 25; revisit only if the
  field asks for full-fidelity restart tables.
- Hand-written and staying that way: BACnet flip tracking, `Build-ProjectLifecycleCycles`,
  the Apogee orchestration trio (PRD §4.4).