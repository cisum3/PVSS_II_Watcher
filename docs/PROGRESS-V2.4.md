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
| **4A** | Rule engine + `PvssRules.ps1` + proof migration (CNS, ApogeeDrv) | | | Engine only — no new rules |
| **4B** | `detections` payload + generic renderers + Detections nav view + 14 new rules | | | |
| **4C** | Snapshot gap-fill: `options`, `hourly`, `driverDeepDive`, organize modes | | | |
| **4D** | `Convert-SnapshotToText` + `format=text` + snapshot format buttons | | | |
| **4E** | Batch mode `-Report` + absolute window + prompts + launchers | | | |
| **4F** | Verification (§10) | | | Gate for 4G |
| **4G** | Delete `OfflineAnalyze\`, docs, version bump to 2.4 | | | **Irreversible** |

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
| `Watch\PvssRules.ps1` created; dot-sourced via `$script:Root` with existence check | | |
| Rule keys: `Id` `Group` `Label` `Re` `Scope` `BucketBy` `Measure` `Sample` `FindingAt` `Trim` | | |
| `BucketBy` accepts capture index **and** `'$component'` / `'$area'` / `'$severity'` | | |
| `Measure` with `Sum` / `Max` aggregation | | |
| Generic state: `Hits` `HitBuckets` `HitMeasures` `HitSevs` `HitSample` `HitTime` | | |
| `Clone-AnalysisState` covers the new maps | | |
| `Add-RuleHit` | | |
| `Get-RulesForComponent` + scope index + per-component memoization | | |
| Proof migration: CNS counters (`CnsResolve/Reduced/ICns/TryRenew`) | | |
| Proof migration: ApogeeDrv (`trendOverflow` `trendSeq` `alertId` `queryTimeout` `getDataFail`) | | |
| Migrated section payload keys unchanged (`app.js` / HTML untouched) | | |
| Rule-test phase added to `Test-WatchSelf.ps1` | | |
| Self-test asserts migrated `cns` / `apogee` payloads match pre-migration output | | |
| Timing sanity-check on a ~50 MB log | | |

Scope note: 4A ships the **engine only**, with no new rules beyond the two migrated clusters.
The corpus-validated rules land in 4B, once there is a renderer to display them.

---

### 4B — Detections rendering + new rules (PRD §6.2, §4.1.1)

| Item | Built | Confirmed |
|------|:-----:|:---------:|
| `detections` snapshot key (group → rules → count/severities/measures/buckets) | | |
| `$script:CuratedGroups` exclusion | | |
| Zero-hit rules omitted | | |
| HTML section (reuses `Add-SnapCountNameTable`) | | |
| Detections nav view in `ui\app.js` + `index.html` | | |
| Measure-carrying rules lead with the aggregate, not the line count | | |
| New rule row surfaces in HTML + dashboard with no renderer edits | | |

**Corpus-validated rules** (PRD §4.1.1) — added here so each is visible as it lands:

| Rule | Evidence | Built | Confirmed |
|------|----------|:-----:|:---------:|
| `Unexpected state, <subsystem>, <method>` (one row, `BucketBy` subsystem+method) | ~6,400 lines across 3 logs | | |
| `Repetition (#=N) of a former trace` (`$component` + `Measure`) | 13,238 lines / 9 managers (H1P) | | |
| `We counted N COVs` (`$component` + `Measure`) | 1,559 lines / 9 managers (H1P) | | |
| `Trend buffer data loss` — gap in 2.3, only *overflow* is caught | 1,849 (C2P) | | |
| `Last sequence number N is less than saved` — gap in 2.3, only *greater* is caught | 1,845 (C2P) | | |
| `The Driver returned Error Code N` | 6,869 (C2P) | | |
| `Command failed because Driver N is off` | 4,506 (C2P) | | |
| `Device N Read File returned error code N` | 3,458 (C2P) | | |
| `AlertID GMSBACNET_* is not known` | 3,090 (H1P) | | |
| `CPT failed: The BACnet device is failed` | 1,568 (H1P) | | |
| `AES decryption of password unsuccessful` | 1,008 (C2P) | | |
| `SERVER-SIDE exception: <Type>` | 1,193 (C1P) + 1,039 (H1P) | | |
| `Examining retained invocations` | 6,261 (C2P) | | |
| `GetAlarmSummary failed for device N` | 200 (C1P) | | |

---

### 4C — Snapshot gap-fill (PRD §6)

| Item | Built | Confirmed |
|------|:-----:|:---------:|
| `options` key (organize, severities, drivers, areas, TopN, window, format) | | |
| `hourly` key from `series.byMinute` rollup | | |
| Hourly presentation rule: full ≤25 hours, else last 24 + busiest 10 | | |
| `driverDeepDive` via `Build-ManagerObject` | | |
| Organize gating (All / Severity / Driver) at render time | | |
| Caps still disclosed (lifecycle 200, manager health 25) | | |

---

### 4D — Text renderer (PRD §8, §6.4)

| Item | Built | Confirmed |
|------|:-----:|:---------:|
| `Convert-SnapshotToText` | | |
| V1.3 format strings reproduced verbatim | | |
| Banner / `--- Section ---` / `=== Subsection ===` / restart pipe table | | |
| Detections rendered in text | | |
| `format=text` accepted at 3654-3669 | | |
| Snapshot button expands in place → `HTML` · `Text` · `JSON` | | |
| `Esc` / click-outside collapses without downloading | | |
| `downloadSnapshot(format)` takes the format as an argument | | |

---

### 4E — Batch mode (PRD §5, §7)

| Item | Built | Confirmed |
|------|:-----:|:---------:|
| `-Report` branch before `Start-Listener`; no port bind, no browser | | |
| Path validation extracted from the `/api/logPath` handler | | |
| `Resolve-LogPath` discovery (exact → `.bak` → newest `PVSS_II*`) | | |
| `$script:Sync` seeded so `meta` is populated | | |
| `perf.health.port` / `url` emitted as empty strings | | |
| `ConvertFrom-UserTimestamp` + `Convert-WindowBound` (operator input) | | |
| `-From` / `-To` absolute window; date-only `-To` → end of day | | |
| Seek guards: `-From` ≤ first ts → byte 0; `-From` > last ts → fail fast | | |
| `-Entire` / `-LastHours` / `-LastMinutes` | | |
| New param block with `ValidateSet` / `ValidateRange` | | |
| Config precedence registered (`Severities`, `Areas`, `Entire`) | | |
| Batch run does **not** call `Set-WatchConfigLogPath` | | |
| Prompt 1 pre-scan: time window (`E` / `H` / `W`) | | |
| Prompt 2: organize (`A` / `S` / `D` / `Q`) | | |
| Prompt 3a: severities + TopN | | |
| Prompt 3b: paged manager picker | | |
| Prompt 4: format (`T` / `H` / `B`) | | |
| `Run-Report.cmd` | | |
| `Run-Report-Interactive.cmd` | | |

---

### 4F — Verification (PRD §10)

| Item | Built | Confirmed |
|------|:-----:|:---------:|
| §10.1 equivalence phase in `Test-WatchSelf.ps1` (batch ≡ dashboard snapshot) | | |
| HTML identical apart from `meta.generated` + two `perf.health` fields | | |
| Same for `format=text` and `format=json` | | |
| SVG charts byte-identical | | |
| Frozen 1.3 tagged before deletion | | |
| Cross-tool spot-check on 2-3 example logs, All + one of Severity/Driver | | |
| CNS + Apogee sections byte-identical vs 2.3 (proof-migration check) | | |
| Operator-input bound parsing accepts documented forms, rejects garbage | | |
| Batch runtime ≤ V1.3 on a ~50 MB log | | |

---

### 4G — Retire OfflineAnalyze (PRD §9)

| Item | Built | Confirmed |
|------|:-----:|:---------:|
| `Watch\OfflineAnalyze\` deleted | | |
| Root `readMe.txt` rewritten — one tool, two modes; no OfflineAnalyze mention | | |
| `CHANGELOG.txt` updated (operator-focused) | | |
| `Watch\VERSION.txt` → `2.4` | | |
| `BACKLOG.md` + `docs\README.txt` updated | | |
| Field zip built and smoke-tested | | |

---

## Open items / notes

- Rules must not anchor on the GMS version token — C1P renders
  `, N, GMSv5.1.0.0e,Orch.Alarm,...` while C2P/H1P render `, N, , GMSe,Orch.Alarm,...`.
  Anchor on the sub-area name instead.
- `ProjectRestartEvents` stays capped at 200 and `managerHealth` at 25; revisit only if the
  field asks for full-fidelity restart tables.
- Hand-written and staying that way: BACnet flip tracking, `Build-ProjectLifecycleCycles`,
  the Apogee orchestration trio (PRD §4.4).