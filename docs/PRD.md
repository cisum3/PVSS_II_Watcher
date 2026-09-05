# PRD: PVSS / WinCC OA Log Analyzer Improvements

> **V1 frozen (release V1.1).** This document is the historical V1 PRD.  
> **V2 work** is locked in [`PRD-V2.md`](PRD-V2.md). Track build in [`PROGRESS-V2.md`](PROGRESS-V2.md).

**Product:** `Analyze-PvssLog.ps1` (+ `Run-Analyze.cmd`, `Run-Analyze-Interactive.cmd`, `readMe.txt`)  
**Status:** Locked / shipped as **V1.1**  
**Date:** 2026-09-04 (freeze noted 2026-09-05)  

**Goal:** One-pass scan, then shape the report by **severity** or by **driver/manager**. Keep severity triage and driver-health statistics as separate sections. Ship BACnet plus thin CNS and CoHo modules. Call out excessive BACnet INFO chatter when volume itself is notable.

---

## 1. Problem

1. **Severity is flattened in ranking.** One Top N list mixes severities; high-volume patterns crowd out rarer FATAL/SEVERE/ERROR.
2. **BACnet device Failed/OK is driver health, logged as INFO.** Lines like `Device <id> Status is now Failed` mean individual devices entering or leaving Failed. They need statistics of their own. High volume of that chatter can still signal a broader problem and should be noted even when the pattern dump is limited to the critical pack.
3. **No driver-focused deep dive** after seeing which managers dominate the log.
4. **One-size-fits-all report** with no post-scan choice of severity vs driver organization.

**Constraints:** Standalone PowerShell 5.1+, stream the file (do not load it whole), double-click friendly, tools live outside the WinCC OA project folder. Typical logs rotate/backup automatically around **~50 MB**.

---

## 2. Design principles

| Track | What it is |
|-------|------------|
| **Severity triage** | FATAL, SEVERE, ERROR, WARNING message patterns and related findings |
| **Driver modules** | BACnet (full), CNS/ApplicationFramework (thin), CoHo (thin) |

**Report wording:** Say what a section *is* (e.g. “Individual devices entering/leaving Failed”). No “not FATAL” disclaimers. No assumptions about site size.

**INFO stays INFO** in severity fields and pattern buckets. Excessive INFO/driver chatter can still appear as its own finding or driver-health headline when volume is high.

**No suggested next steps** in the report. Present counts, patterns, and module statistics only — operators decide follow-up themselves.

**Interactive Enter = defaults.** At every interactive prompt, pressing Enter with an empty answer accepts the documented default for that prompt.

---

## 3. Scope

### In scope (v1)

| Priority | Item |
|----------|------|
| P0 | Separate pattern sections per severity: FATAL, SEVERE, ERROR, WARNING |
| P0 | Scan once → console summary → compose report (Severity / Driver / All) |
| P0 | **BACnet module:** Failed/OK transitions, unique devices, object-list WARNING stats, chatter volume finding |
| P0 | **Thin CNS module:** ResolveNodes / ReducedFunction / ICns counts; session renew timeout counts |
| P0 | **Thin CoHo module:** stuck/drop-style message counts; top stuck names when available |
| P0 | Excessive BACnet chatter noted even when pattern dump is critical-only |
| P0 | No “suggested next checks” (or similar) section |
| P1 | Driver picker: top 10 by volume, next/previous page of 10, multi-select by number |
| P1 | Empty Enter at prompts uses sensible defaults (see §5) |
| P1 | `-Interactive` + `Run-Analyze-Interactive.cmd`; non-interactive via `Run-Analyze.cmd` |
| P1 | Named parameters mirroring organize choices |
| P1 | Options used echoed in report header |
| P1 | Console = short summary + path to file; full detail in `.analysis.txt` only |
| P1 | Scan progress while streaming |
| P1 | Optional time window (`-From` / `-To`) |
| P2 | Docs (`readMe.txt` + comment-based help) |
| P2 | Simple registry for additional driver modules later |

### Explicitly deferred

| Item | Notes |
|------|--------|
| Driver type-in / substring search (D6) | Paging + number multi-select only for now |
| Last-known BACnet device status | Backlog |
| Ranked flapping-device list | Backlog; chatter **volume** finding is v1 |
| Keyword/regex organize path | Backlog |
| Live tail / watch mode | Later |
| Log comparison | Not now |
| HTML report | Later optional (see §10) |
| Full .NET multi-line reassembly | Later / limitation today (see §10) |

### Non-goals

- GUI
- Replacing Siemens support tools
- Loading the entire log into a single string/array
- Folding BACnet device Failed/OK INFO lines into FATAL/SEVERE pattern Top N by default
- Suggested remediation / next-check lists in the report
- Auto-upload / ticketing

---

## 4. Baseline (today)

- Streams `PVSS_II.log` / newest `PVSS_II*.log`
- Parses component, timestamp, area, severity
- Severity counts, components, hourly volume, perf categories
- One mixed Top N of WARNING/SEVERE/perf patterns
- Includes a “Suggested next checks” block (**remove in v1**)
- Params: `-LogPath`, `-OutPath`, `-TopN`, `-SamplePerPattern`, `-NoPause`

---

## 5. UX flow

```text
[1] Resolve log → stream once (with progress) → build indexes
[2] Console summary:
      lines / span / runtime
      severity counts
      top 5 managers
      Module headlines (BACnet / CNS / CoHo) when data present
      Chatter finding if thresholds exceeded
[3] If interactive → prompts (Enter = default at each step)
[4] Write report file; console prints path (not the full dump)
```

### Interactive defaults (empty Enter)

| Prompt | Default on Enter |
|--------|------------------|
| Organize mode `[S] Severity  [D] Driver  [A] All  [Q] Quit` | **A** (full default report) |
| Path S — which severities? | Critical pack: FATAL + SEVERE + ERROR |
| Path S — Top N per severity? | **10** |
| Path D — select drivers on current page? | **All managers on the current page** (or first manager only — lean: **current page top entry #1** if multi-default is ambiguous; prefer documenting **#1 on current page**) |

**Path D Enter lean (locked):** select **item 1** on the current page (highest-volume manager on that page). `[N]` / `[P]` still required to change pages before Enter.

### Path S — Severity

```text
Include pattern sections for:
  1) FATAL
  2) SEVERE
  3) ERROR
  4) WARNING
  5) INFO
  Shortcut: critical pack = FATAL+SEVERE+ERROR
Default (Enter): critical pack
Multi-select allowed (e.g. 1,2,3,4)
Top N per severity? Default (Enter): 10
```

Always include short module headlines (BACnet / CNS / CoHo) and chatter findings when triggered, even if INFO patterns are not listed.

### Path D — Driver

```text
Page of 10 managers by volume:
  [1-10] select one or comma-list
  [N] next 10
  [P] previous 10
  Enter: select #1 on this page
  (Type-in search: deferred)
```

For each selected manager: line count, severity mix, top patterns (by severity), plus matching module block (BACnet / CNS / CoHo) when that manager matches.

### Path A / non-interactive default

Full report: findings, severity counts, all three module summaries, top components, perf categories, hourly volume, separate FATAL/SEVERE/ERROR/WARNING pattern sections. **No** suggested-checks section. No prompts.

---

## 6. Functional requirements

### FR-1 — Severity-separated patterns

- Default/All: separate Top N for **FATAL**, **SEVERE**, **ERROR**, **WARNING**.
- Path S: only selected severities; Enter → critical pack.
- INFO pattern listing only when INFO is selected.

### FR-2 — BACnet module

**Device status (INFO)** — Individual devices entering/leaving Failed:

- Counts of `Status is now Failed` / `Status is now OK`
- Unique device IDs seen in each
- Top devices by Failed transition count (e.g. top 20) in the file when BACnet section is included

**Object list (WARNING):**

- Counts of `Could not get object list` (and similar)
- Unique devices when present; example line(s)

**Chatter volume finding:** when Failed/OK totals or rates exceed thresholds, emit a finding even if INFO patterns are omitted.

**Backlog:** last-known status; ranked flapper list.

### FR-3 — Thin CNS module (ApplicationFramework / ICns)

Match across ApplicationFramework (and related) lines:

- Counts: `ResolveNodes`, `ReducedFunction`, `ICns`
- Counts: session renew / `TryRenewSession` timeouts
- Optional: top normalized CNS-related patterns (small Top N)
- Finding when CNS/Resolve volume is high (reuse/extend existing heuristic thresholds)

Keep this **thin**: counts + short pattern list + finding — not a full device-style subsystem.

### FR-4 — Thin CoHo module (`WCCOAGmsCoHoMngr`)

- Counts of stuck/drop-style messages (e.g. `got stuck`, `dropping it`)
- Top stuck resource/name strings when parseable
- Finding when stuck/drop volume is notable

Keep **thin**: counts, top names, examples — generic Path D covers deeper pattern dumps for a selected CoHo instance.

### FR-5 — Interactive composer

- Post-scan Severity / Driver / All / Quit
- **Empty Enter accepts defaults** (§5)
- Driver paging by 10; multi-select by number
- Single pass

### FR-6 — Report header options

Record organize mode, severities, drivers, Top N, time window, interactive vs not.

### FR-7 — Console vs file

Console: progress, short summary, output path. File: full detail.

### FR-8 — Time window

Optional `-From` / `-To` against log timestamps.

### FR-9 — Progress

Periodic progress during stream (percent by bytes or MB read).

### FR-10 — No suggested steps

Do not write remediation advice, “suggested next checks,” or similar. Findings state observed conditions only.

### FR-11 — Quality bar

- Stream; PS 5.1+
- Default report: `<log>.analysis.txt`
- `Run-Analyze.cmd` = non-interactive All
- `Run-Analyze-Interactive.cmd` / `-Interactive` = composer

### FR-12 — Documentation

Update `readMe.txt` and script help.

---

## 7. Report layout (default / All)

```text
--- Header / meta / options used ---
--- Findings (severity/perf + module chatter/volume when triggered) ---
--- Severity counts ---
--- BACnet module ---
      Device status (INFO): entering/leaving Failed; OK returns; counts; top devices
      Object list (WARNING): counts; devices; examples
--- CNS module (thin) ---
      ResolveNodes / ReducedFunction / ICns counts; session renew timeouts; short top patterns
--- CoHo module (thin) ---
      Stuck/drop counts; top names; examples
--- Top components ---
--- Performance categories ---
--- Hourly volume ---
--- Top patterns by severity ---
      FATAL / SEVERE / ERROR / WARNING
```

No suggested-checks section.

---

## 8. Decisions (locked)

| ID | Topic | Decision |
|----|--------|----------|
| D1 | Critical pattern layout | Separate FATAL, SEVERE, ERROR (+ WARNING in default/All) |
| D2 | BACnet in findings | Chatter/volume finding when excessive; detail under BACnet module |
| D3 | Double-click default | Non-interactive All; interactive via flag / Interactive CMD |
| D4 | Driver page size | 10 |
| D5 | Multi-select drivers | Yes (comma-separated numbers) |
| D6 | Type-in driver search | Deferred |
| D7 | Global INFO patterns | No by default; BACnet metrics always tracked; excessive chatter in findings |
| D8 | Full flapping-device table | Backlog |
| D9 | Suggested next steps | **Removed** from report |
| D10 | Empty Enter in interactive | Accepts sensible default for that prompt (§5) |
| Q1 | Default severities | All = FATAL+SEVERE+ERROR+WARNING; Path S Enter = critical pack; BACnet chatter finding when thresholds hit |
| Q2 | BACnet top devices in file | Yes (top 20) when BACnet section included |
| Q3 | Interactive launcher | `-Interactive` and `Run-Analyze-Interactive.cmd` |
| Q4 | Console vs file | Summary on console; full report in file |
| Q5 | Driver modules | **BACnet (full) + thin CNS + thin CoHo** in v1 |

### Parameters (v1 names)

```text
-LogPath
-OutPath
-TopN                 # default 10 per severity section
-SamplePerPattern
-Interactive
-NonInteractive
-Organize All|Severity|Driver
-Severities FATAL,SEVERE,ERROR,WARNING
-Driver <name-or-index-list>
-From / -To
-NoPause
```

### Memory (~50 MB rotated logs)

Streaming remains mandatory. In-memory maps for ~50 MB logs are practical (severity patterns WARNING+, BACnet per-device counters, CNS/CoHo counters). Soft safety limits only if a map grows pathologically.

---

## 9. Module summary (sample-log context)

| Module | Managers / signals | Depth |
|--------|--------------------|-------|
| **BACnet** | `WCCOAGmsBACnet` — Failed/OK INFO; object-list WARNING; chatter finding | Full (for v1) |
| **CNS** | `Siemens.Gms.ApplicationFramework` — ResolveNodes, ReducedFunction, ICns, TryRenewSession | Thin |
| **CoHo** | `WCCOAGmsCoHoMngr` — got stuck / dropping it | Thin |
| **Generic Path D** | Any other manager | Severity mix + top patterns |

Apogee and core `WCCIL*` managers: generic deep-dive only unless promoted later.

---

## 10. Notes on deferred technical items

### .NET multi-line messages

Some `.NET` payloads continue on lines without a new WinCC OA header; those lines are skipped today. **v1:** single-header-line parsing; report unparsed line count/rate. Full reassembly is backlog.

### HTML reports

PowerShell can emit HTML (`ConvertTo-Html` or templates). **v1 stays plain text.**

### Live tail

Follow the active log and refresh summaries — after batch v1 is solid.

---

## 11. Acceptance criteria

1. Default report has separate FATAL, SEVERE, ERROR, and WARNING pattern sections.
2. BACnet, CNS, and CoHo module sections appear when their signals are present (All / matching Path D).
3. Excessive BACnet Failed/OK chatter produces a finding even when INFO patterns are not listed.
4. Interactive: Enter with no input uses defaults (organize **A**; Path S critical pack + TopN 10; Path D select #1).
5. Report contains **no** suggested next-steps / remediation section.
6. Console shows summary + file path; full content is in the report file.
7. Report header lists options used.
8. Progress is visible during the scan.
9. Optional `-From`/`-To` limits the analysis window.
10. Single pass for a normal interactive session.
11. `readMe.txt` documents severity vs module behavior and interactive defaults.

---

## 12. Implementation sketch

1. Stream with progress; fill severity→pattern maps, component totals, BACnet/CNS/CoHo module maps, findings counters.  
2. Evaluate module volume thresholds → findings.  
3. Interactive composer (Enter = defaults) or parameters / All.  
4. Writers: header, findings, three modules, severity patterns, driver deep-dive.  
5. Remove suggested-checks text; update docs; smoke-test.

---

## 13. Backlog (ordered)

1. Last-known BACnet device status (ended Failed vs OK)  
2. Ranked flapping-device list  
3. Driver type-in search (D6)  
4. Keyword organize path  
5. First/last timestamp per top pattern  
6. Area (SYS/IMPL) breakdown  
7. Manager instance rollup (`ApplicationFramework` family)  
8. Optional CSV export  
9. Live tail / watch mode  
10. Optional HTML report  
11. .NET multi-line reassembly  
12. Apogee (or other) driver module if field patterns justify it  

---

## 14. Out of scope

Standalone triage aid only. Not a substitute for Siemens GMS / WinCC OA support.
