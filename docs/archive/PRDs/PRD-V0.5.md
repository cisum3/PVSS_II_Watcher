# PRD: PVSS Log Analyzer V0.5 — C# high-performance runtime

**Product:** Siemens Desigo CC `PVSS_II.log` triage toolkit (`Run-Watch.cmd` / `Run-Report*.cmd`)
**Status:** **Pre-finalized** (may tweak after any residual 0.4.x field notes; not yet locked)
**Date:** 2026-09-12
**Author:** Cisum
**Depends on / baseline:** Watch **0.4.0** (shipped). **0.5.0 is a direct port** of that
baseline to C# (same behavior), with **only** the intentional exceptions in §2.1.
**Ships as:** Watch **0.5.0** — PowerShell host replaced by a single-file .NET console exe
**Build tracker:** _(create [`PROGRESS-V0.5.md`](PROGRESS-V0.5.md) when this PRD is locked)_
**TFM:** **net10.0-windows** (confirmed)

**Primary goal:** cut ~50 MB entire-file parse time from minutes (PowerShell 5.1) to
**sub-second or low seconds**, as a **direct behavioral port of 0.4.0** plus the §2.1
exceptions.

**Secondary goal:** keep the field package feel unchanged — same `.cmd` launchers, same
`watch-config.txt`, same `ui\`, same switches, same reports and dashboard behavior —
while the runtime under `Watch\` becomes a zero-install, self-contained Windows binary.

---

## 1. Problem

### 1.1 PowerShell is the bottleneck

0.4.0 acceptance amended batch runtime to “within noise of a 0.3.0 dashboard entire-file
load.” On a typical laptop that is still **~8 minutes for a ~50 MB log**, dominated by
PowerShell **per-line function-call overhead** in `Process-LogLine` (and helpers such as
`Add-Pattern`, `Ensure-Minute*`, `Get-PerfCategory`, `Normalize-Message`). Backlog items to
inline those helpers are partial mitigations; they do not change the language ceiling.

Operators and developers need triage that finishes in the time it takes to open a browser
tab — not a coffee break.

### 1.2 What must not change

Rewriting the engine must not force field re-training or a second tool:

| Surface | Constraint |
|---|---|
| Launchers | `Run-Watch.cmd`, `Run-Report.cmd`, `Run-Report-Interactive.cmd` keep working |
| CLI | Same switch names and semantics (§6) |
| Config | `Watch\watch-config.txt` key set, validation, self-correction, `LogPath` update rules |
| Rules intent | All 0.4.x detection signatures and ranking behavior |
| UI | Existing `Watch\ui\` assets and `/api/*` contracts the dashboard already uses |
| Modes | Dashboard (localhost `HttpListener`) and Report (scan → write → exit, no port) |
| Safety | Log opened read-only with share for writer; bind `127.0.0.1` only in dashboard mode |

---

## 2. Relationship to the backlog / scope delta

### 2.1 What 0.5.0 is

**Direct port of Watch 0.4.0** to a net10 single-file C# host: same CLI, config, UI assets,
API contracts, report/dashboard modes, and analysis meaning — **except** the following
intentional upgrades (documented deltas vs 0.4.0 snapshots):

| Exception | Notes |
|---|---|
| **Multi-scope rules** | `Scope` as string or list; enable for dual-driver rules (§4.5, §9.2) |
| **BACnet-scoped rules** | New BACnet rules for the four Apogee-shaped families; do **not** widen Apogee scopes |
| **Interactive manager pick ranges** | Prompt accepts `1-3,10` style ranges when porting `-Interactive` |

**Entire-window cache:** not a behavior change to “must match 0.4.0 cache.” Follow §4.6 —
defer until measured; optional late add. That decision stands.

Everything else from the former **0.4.1** list (Detections UI leftovers, catch-up % feel,
Detections dual-render, etc.) is **out of 0.5.0** → **0.5.1**.

### 2.2 Other backlog fate

| Backlog item | Fate |
|---|---|
| Inline hot helpers in `Process-LogLine` (PS) | **Superseded** by C# |
| Absolute dashboard From/To, chart ladder, Findings scaling, startup plume, Blazor | **Later** (Ideas) |
| PowerShell 0.4.1 patch release | **Cancelled** — do not implement in PS first |

---

## 3. Design principles

1. **Direct port first.** Match 0.4.0 unless §2.1 explicitly allows a delta. Use the §9.2
   byte-identical **dev gate** (single-scope, no BACnet extras) before enabling the
   exceptions; ship with those deltas documented — fail only on *unexpected* diffs.
2. **Zero install.** Field machines get a **single-file self-contained** `win-x64` publish.
   No separate .NET runtime install, no PowerShell host dependency for the analyzer.
3. **Additive package shape.** Operators still unzip / copy a folder. Launchers call the
   new exe instead of `powershell.exe -File Watch-PvssLog.ps1`.
4. **A rule remains data.** Port `PvssRules.ps1` into a structured table (C# records and/or
   a checked-in data file) consumed by one generic engine — not a one-off `if` tree per
   signature. Adding a detection stays “one row + one test.”
5. **UI stays static files.** No Blazor rewrite in 0.5.0. `HttpListener` (or equivalent
   embedded listener) serves `ui\` and the existing `/api/*` routes.
6. **Live-log safe I/O.** Open with `FileAccess.Read` + `FileShare.ReadWrite` so Desigo CC /
   WinCC OA can keep appending.
7. **Low allocation on the hot path.** Prefer `ReadOnlySpan<char>`, compiled regexes,
   reuse buffers; avoid per-line LINQ and unnecessary string copies.

---

## 4. Target architecture

### 4.1 Source vs field layout

**Development** lives under `src\`; **publish** lands the runtime payload in `Watch\`
(field zip shape unchanged for operators).

```text
src\
  DesigoLogWatcher\
    DesigoLogWatcher.csproj     ← publish settings (§6)
    Program.cs                  ← entry: mode select, CLI, interactive prompts
    Config.cs                   ← watch-config.txt load / validate / rewrite
    LogParser.cs                ← line parse, windows, catch-up, tail
    RuleEngine.cs               ← rule table + hit / bucket / measure / samples
    AnalysisState.cs            ← accumulators (patterns, modules, lifecycle, …)
    SnapshotBuilder.cs          ← Build-SnapshotObject equivalent
    ReportWriter.cs             ← HTML / text / JSON renderers
    HttpServer.cs               ← 127.0.0.1 listener, static ui\, /api/*
    Cli.cs                      ← argument parsing + interactive prompts
    Rules\                      ← ported rule definitions (see §4.5)

Watch\                          ← field / published payload (not a second source tree)
  DesigoLogWatcher.exe          ← single-file publish output
  VERSION.txt                   → 0.5.0
  watch-config.txt
  ui\                           ← dashboard assets (copied or content-linked at publish)
  (Watch-PvssLog.ps1 removed from field package after cutover)
```

**Exe name (preferred):** `DesigoLogWatcher.exe` — matches product wording (Desigo CC
`PVSS_II` logs). Repo/GitHub may stay `PVSS_II_Watcher`; the binary name is what operators
see. Alternate `PVSS_IIWatcher.exe` is more cryptic and easy to mistype.

### 4.2 Dual-mode execution

**Dashboard mode** (default; today’s `Run-Watch.cmd` path):

- Bind `HttpListener` on `127.0.0.1` (preferred port + fallback tries from config/CLI).
- Serve `ui\` statically; implement existing API surface (`/api/health`, `/api/pulse`,
  `/api/section`, `/api/manager`, `/api/snapshot`, start/pause/restart, etc. — inventory
  from current `Watch-PvssLog.ps1` during phase 5A).
- Catch-up with progress %; then tail new bytes.
- Restart re-reads `watch-config.txt` for the same keys PowerShell Restart applies today.

**Report mode** (`-Report` / `Run-Report*.cmd`):

- Resolve log path (auto-discovery order unchanged).
- Apply window (`-Entire` / `-LastHours` / `-LastMinutes` / `-From` / `-To`).
- Run detections + snapshot build.
- Write `.analysis.html` / `.analysis.txt` (and JSON if requested) per `-Format`.
- **No** browser open, **no** port bind, **no** `LogPath` write-back to config.
- Exit non-zero on failure; respect `-NoPause` / pause-on-exit behavior of today’s cmds.

### 4.3 File processing & memory

- Stream the file; do **not** require loading the entire log as one string.
- Use efficient line enumeration or buffered reads compatible with concurrent appends.
- Timestamp / header parse on spans where practical; allocate strings when they must enter
  long-lived maps (pattern keys, device ids).
- Compiled `Regex` for rules and header patterns; reuse instances for the process lifetime.
- **Entire-window cache (dashboard):** **deferred decision** — see §4.6. Do not build it
  until late phases have real cold-parse numbers.

### 4.4 Configuration

Port `watch-config.txt` behavior:

- Parse `key=value`, ignore comments/blank lines.
- Validate ranges; on invalid value: reject, print to host console, rewrite default
  (self-correcting).
- CLI overrides file when both present (same precedence as today).
- Dashboard Start updates `LogPath`; report mode does not.

### 4.5 Rule detection

- Port every shipping rule from `PvssRules.ps1` (Ids, Groups, Labels, Scope, patterns,
  BucketBy, Measure, Sample, FindingAt, ranking inputs).
- Prefer a **data-driven** engine (`RuleDefinition` + `RuleEngine`) so curated module cards
  and generic Detections stay one pipeline.
- Hand-written analysis that remained outside the rule table in 0.4 (BACnet flips, project
  lifecycle cycles, Apogee orchestration trio, Findings builders, etc.) must be ported
  explicitly — inventory in phase 5A against `Watch-PvssLog.ps1`.
- Multi-scope, BACnet-scoped families, and manager pick ranges: **in 0.5.0** per §2.1.
  Prove byte-identical vs 0.4.0 **first** (single-scope, no new BACnet rules), then enable
  the exceptions and accept documented report deltas (§9.2).

### 4.6 Entire-window cache (deferred)

Today’s cache clones analysis state after an Entire catch-up so leaving Entire and returning
can avoid a full re-parse (batch mode already skips it). PowerShell’s deep clone is expensive
and blocks the host until it finishes (`Finish-CatchUp` → `Save-EntireCache`).

**0.5.0 approach:** ship the C# dashboard **without** Entire-cache first. After report and
dashboard paths are working, measure cold Entire parse on the ~50 MB corpus (§9.1).

| Measured cold Entire (typical) | Action |
|---|---|
| Already feels instant (e.g. **&lt; ~0.5–1 s**) | **Skip cache** for 0.5.0; revisit only if field complains about re-parse on window flips |
| Still noticeable on return to Entire (e.g. **multi-second**) | Implement cache late (phase **5H** / post-perf): same invalidation triggers as today; **serve results first, then cache** (optional “Caching results…”) |

Do not spend early phases on cache. Do not assume “C# is fast ⇒ never cache” without numbers.

---

## 5. CLI parameter support

Support all existing switches with the same names and meaning:

| Switch | Notes |
|---|---|
| `-LogPath` | Explicit log; else auto-discover |
| `-OutPath` | Report output path |
| `-Format` | `Text` \| `Html` \| `Both` (and dashboard snapshot JSON as today) |
| `-Organize` | `All` \| `Severity` \| `Driver` |
| `-Severities` | Comma list |
| `-Areas` | Comma list |
| `-Driver` | Name substring or list position |
| `-TopN` | Pattern table depth |
| `-Entire` | Whole file |
| `-LastHours` / `-LastMinutes` | Relative window; win over `-From`/`-To` |
| `-From` / `-To` | Absolute bounds; date-only `-To` = end of that day |
| `-Interactive` | Report prompts (Enter-defaulted) |
| `-NoPause` | Do not wait for keypress on exit |
| `-Report` | Batch/report mode |
| Dashboard-only | Port, browser, refresh, sample depths, etc. — same as current host |

Interactive manager pick **must** support **range syntax** (`1-3,10`) — §2.1 exception.

Argument parsing may use `System.CommandLine` or a small hand parser — either is fine if
behavior matches and help text stays operator-usable.

---

## 6. Build & release

### 6.1 Project settings

`.csproj` configured for single-file self-contained Windows deployment (adjust TFM only if
review explicitly picks .NET 9):

```xml
<PropertyGroup>
  <OutputType>Exe</OutputType>
  <TargetFramework>net10.0-windows</TargetFramework>
  <ImplicitUsings>enable</ImplicitUsings>
  <Nullable>enable</Nullable>
  <PublishSingleFile>true</PublishSingleFile>
  <SelfContained>true</SelfContained>
  <RuntimeIdentifier>win-x64</RuntimeIdentifier>
  <IncludeNativeLibrariesForSelfExtract>true</IncludeNativeLibrariesForSelfExtract>
</PropertyGroup>
```

**Decision (confirmed):** **net10.0-windows** (LTS through 2028-11-14). Windows OS matrix
matches net8/net9 for client and Server targets we care about.

### 6.2 Publish recipe

Document in `docs\` (dev-only) and briefly in `CHANGELOG` / `readMe` if operators ever
rebuild:

```text
dotnet publish src\DesigoLogWatcher\DesigoLogWatcher.csproj -c Release -o Watch\
```

(Exact `-o` / content-copy for `ui\` settled in 5A.) Field zip contains the published exe +
`ui\` + `watch-config.txt` + `VERSION.txt` + root launchers/docs — **not** `src\`.
Default field package: **runtime payload only**.

### 6.3 Launcher changes

`Run-Watch.cmd` / `Run-Report*.cmd` invoke `Watch\DesigoLogWatcher.exe` with the same
forwarded args they pass today (replace `powershell -File ...Watch-PvssLog.ps1`).

---

## 7. Package layout after 0.5.0

```text
PvssLogAnalyze\                   (repo / field zip root)
  Run-Watch.cmd
  Run-Report.cmd
  Run-Report-Interactive.cmd
  readMe.txt                      ← note C# runtime / no PowerShell required
  CHANGELOG.txt
  README.md                       ← GitHub only (export-ignore)
  Watch\
    DesigoLogWatcher.exe
    VERSION.txt                   → 0.5.0
    watch-config.txt
    ui\
  src\DesigoLogWatcher\           ← development only (export-ignore / omit from field zip)
docs\                             ← PRD-V0.5.md, PROGRESS-V0.5.md, tests, archive\
```

---

## 8. Non-goals (0.5.0)

- Rewriting the dashboard in Blazor / SPA framework
- Cross-platform (Linux/macOS) hosts
- Changing detection *meaning* beyond the §2.1 exceptions (multi-scope, BACnet-scoped
  families)
- Findings window-scaling, startup-plume tagging, absolute dashboard From/To, chart ladder,
  Blazor/SPA dashboard, Detections UI polish, catch-up % tuning, dual-render unify
  (→ **0.5.1** or later Ideas)
- Requiring a machine-wide .NET install
- Entire-window cache as a day-one requirement (deferred to measured need — §4.6)

---

## 9. Verification

### 9.1 Performance (informational — not a ship blocker)

On the same machine / same ~50 MB static corpus log used for 0.4 timing notes, record
PowerShell 0.4.0 baseline vs C# in `PROGRESS-V0.5.md`.

| Metric | Aspiration (not a hard fail) |
|---|---|
| Report mode entire-file scan + HTML write | **&lt; 5 s** nice; **&lt; 1 s** stretch on a warm disk |

Any large drop from the ~8 minute PS baseline is already a successful rewrite. There is **no
hard ceiling** that fails the release — use the numbers to decide hotspots and whether
Entire-cache is worth building (§4.6).

### 9.2 Parity gate (primary)

Against **0.4.0** on static logs:

**Executable checklist (pass/fail rows):** [`PROGRESS-V0.5.md`](PROGRESS-V0.5.md) § “§9.2 verification checklist”.  
Keep gate *rules* here; keep run results and tick-boxes in PROGRESS.

**Ship includes the §2.1 exceptions** (multi-scope, BACnet-scoped rules, manager ranges).
Byte-identical vs 0.4.0 is a **development checkpoint**, not the 0.5.0 release bar.

1. **Snapshot HTML / text / JSON:**
   - **Dev gate (pure port):** rule table matching 0.4.0 single-scope semantics (no new
     BACnet rules, multi-scope off) — snapshots byte-identical aside from the allowlist
     (`meta.generated`, tool/version banner, `perf.health` port/url, `gen`, documented
     formatting normals including accepted `N0` thousand separators). Proves the C# engine/renderers did not drift.
   - **Ship gate (§2.1 on):** expect **known** count/section diffs vs 0.4.0 for multi-scope
     and new BACnet rules. Record those deltas in PROGRESS. **Fail only on unexpected
     diffs** — do not fail the release for expected non-identical reports.
2. **Dashboard APIs:** contract tests — same keys and types for pulse/section/manager/health
   on a fixed fixture.
3. **Rules phase:** fixture expectations for 0.4.x-equivalent Ids under the dev gate; updated
   expectations for multi-scope-enabled rules at ship.
4. **Launchers:** double-click / cmd forwarding; report mode binds no port; dashboard binds
   localhost only.
5. **Config:** invalid keys self-correct; report does not write `LogPath`; dashboard Start
   does.

### 9.3 Corpus

Reuse `docs\PVSS_II_Examples\` / site logs already used for 0.4. Spot-check CNS / Apogee /
BACnet sections and Detections ranking order on at least two representative files.

---

## 10. Build phases

| Phase | Deliverable |
|---|---|
| **5A** | **Inventory + scaffold.** List every `/api/*` route and method the current host exposes (plus static `ui\` paths), CLI switches, config keys, hand-written vs rule-table analysis. Confirm exe name / `src\` layout. Scaffold `DesigoLogWatcher.csproj` + empty `Program.cs`. The API list is the **checklist for 5F** — without it, HttpServer “done” is undefined. |
| **5B** | `Config.cs` + CLI parse + report-mode skeleton (open log shared-read, line loop, exit codes) |
| **5C** | Header parse + analysis state + pattern/module/lifecycle ports sufficient for a minimal snapshot JSON |
| **5D** | `RuleEngine` + full rule table port (still single-scope like 0.4.0) + Findings/Detections on fixtures |
| **5E** | `ReportWriter` HTML/text/JSON — **dev gate:** §9.2 byte-identical vs 0.4.0 (allowlist only) |
| **5E.1** | Enable §2.1 exceptions (multi-scope + BACnet-scoped rules); record expected snapshot deltas; manager range prompts if not already in 5B — **ship gate** |
| **5F** | `HttpServer` + static `ui\` + **all routes from the 5A inventory**; catch-up % + tail; Restart config reload. **Depends on 5A’s inventory** (and usually on 5C–5E so APIs have real state to serve). |
| **5G** | Launchers, `VERSION` 0.5.0, `readMe`/`CHANGELOG`, publish recipe, field-zip smoke; retire PS host from field package |
| **5H** | Measure perf on ~50 MB log; document in PROGRESS; optional hotspots; **decide Entire-cache** per §4.6 and implement only if warranted |

5B–5E can be developed and tested without the UI. **5A is not optional busywork** — it
defines what 5F must implement. 5G is the irreversible field-package switch. 5H is
measurement + optional cache, not a fail gate.

**0.5.1** (not 0.5.0): Detections UI leftovers, catch-up % feel, Detections dual-render, and
any cache UX polish beyond §4.6’s late optional add.

---

## 11. Acceptance

1. Field package runs dashboard and report modes **without PowerShell** and **without** a
   separate .NET runtime install (single-file self-contained `win-x64`).
2. All listed CLI switches (§5) behave as in 0.4.x.
3. `watch-config.txt` validation / self-correction / `LogPath` rules match 0.4.x.
4. Every 0.4.0 detection Id still fires; counts match 0.4.0 on fixtures at the **dev gate**;
   at ship, counts match **documented §2.1 expectations** (multi-scope + BACnet-scoped rules).
5. Report mode writes analysis output and exits with **no** port and **no** browser.
6. Dashboard serves existing `ui\` and preserves operator workflows (window, chips, modules,
   detections, snapshot formats). HttpServer covers the **5A API inventory**.
7. Log open uses read + `FileShare.ReadWrite` (or equivalent) so the live project can append.
8. Perf numbers recorded (§9.1); no hard time ceiling. Entire-cache only if §4.6 says so.
9. §9.2 **ship gate** met (expected §2.1 deltas allowed; unexpected diffs fail).
10. Interactive manager pick accepts range syntax (`1-3,10`).
11. `VERSION.txt` is **0.5.0**; changelog explains the runtime change for operators
    (“faster engine; same usage”) and notes the §2.1 detection/prompt upgrades.

---

## 12. Review checklist

- [x] **TFM:** **net10.0-windows** (LTS → 2028-11-14)
- [x] Published **exe name:** `DesigoLogWatcher.exe` (repo may remain `PVSS_II_Watcher`)
- [x] Sources under **`src\`**, publish into **`Watch\`**; `.cs` not in field zips
- [x] **Scope:** direct port of **0.4.0** + **only** §2.1 exceptions (multi-scope, BACnet-
      scoped rules, manager pick ranges); cache per §4.6; other polish → **0.5.1**
- [x] **§2.1 ships in 0.5.0.** Byte-identical vs 0.4.0 is a **dev gate** before enabling
      those exceptions (§9.2 / 5E → 5E.1); ship fails only on *unexpected* diffs
- [x] **Entire-window cache deferred** to phase 5H after measured cold-parse times (§4.6)
- [x] **No hard perf ceiling** — record aspirations; large win vs ~8 min PS is enough (§9.1)
- [x] **5A API inventory** defines HttpServer scope; **5F implements that list**
- [ ] Status → **Locked / ready to build** → create [`PROGRESS-V0.5.md`](PROGRESS-V0.5.md)
