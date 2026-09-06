# PRD: PVSS Log Analyzer V2 — Live Dashboard

**Product:** PowerShell local host + Chrome UI (`Watch-PvssLog.ps1` / `Run-Watch.cmd`)  
**Status:** Locked / ready to build  
**Date:** 2026-09-05  
**Depends on:** V1.1 OfflineAnalyze analyzer (kept under `OfflineAnalyze\`; not replaced)

**Goal:** A **live triage dashboard in Chrome**, fed by a **local PowerShell host** that tails the live `PVSS_II.log`. Charts, filters, and module stats update as the log grows. Fully offline (no CDN, no installs beyond Windows PowerShell + a browser).

---

## 1. Problem

V1.1 covers **batch** triage (copy log → report). It does not cover watching a **growing** live log, interactive filter/zoom, or live trend charts during an incident.

---

## 2. Relationship to V1.1

| | V1.1 (`OfflineAnalyze\`) | V2 (this product) |
|--|-----------------|-------------------|
| Purpose | One-shot analysis + shareable report | Live / interactive dashboard |
| UI | Static `.analysis.html` / `.txt` | Chrome at `http://127.0.0.1:…` |
| Docs | Own `OfflineAnalyze\readMe.txt` | Own root `readMe.txt` (+ `Watch\` runtime) |

V2 is a **standalone Watch implementation** (not “run V1 and convert its report to JSON”). It **reuses V1.1 parse rules, module logic, findings thresholds, and triage layout/language**, adapted for incremental/live summary JSON. Batch V1.1 remains for offline one-shot reports.

---

## 3. Design principles

1. Localhost only (`127.0.0.1`).
2. PowerShell opens and tails the live file; Chrome talks to the host only.
3. Static `ui\` + vendored JS (charts) — no CDN / npm on the target machine.
4. Same triage language as V1 (severity vs driver-health modules; no suggested next-steps).
5. Incremental parse; UI consumes summary JSON, not the whole log.
6. Tools stay **outside** the WinCC OA project folder; live path is chosen explicitly (not V1 “copy log beside script” discovery).
7. Fully offline after copy: PowerShell 5.1+ and a local browser only.
8. Live log is **read-only** (`FileAccess.Read` only).

---

## 4. Architecture

```text
Run-Watch.cmd
  └─ Watch-PvssLog.ps1
        ├─ Bind 127.0.0.1:<port> (try next if busy) → serve ui\ + JSON APIs
        ├─ Confirm actual port, then open browser to that URL
        ├─ On Start: validate path, persist watch-log-path.txt, catch-up, then tail
        └─ Pause / Resume / Restart (Restart returns to path + Start)
```

| Concern | V2.0 choice |
|---------|-------------|
| Updates | **Poll** `GET /api/summary` every **3 s** |
| Catch-up / window | Default **60 minutes**; UI presets **15m / 30m / 60m / 120m / Entire file** plus **custom minutes** (§7.2) |
| Filters | Applied **on the host** when building `/api/summary` (§7.3) |
| Log rotate | **Auto-reopen**, reset window stats, UI banner |
| Missing / locked file | Clear error on the web page; tail stops until Restart / fixed Start |
| Snapshot | HTML/JSON from **current dashboard payload** (no V1 re-scan) — **2E** (download-only) |
| Charts | Vendored Chart.js (or equivalent) in `ui\vendor\` |
| Max log size | ~**50 MB** (WinCC rotate); full-file parse OK with loading UI (&lt; ~60 s class) |

### 4.1 Live log path

1. Host starts and opens the browser **before** tailing (dashboard idle until Start). Port used is the one actually bound.
2. Always show **path text box** + **Start**.
3. Prefill from `-LogPath` / cmd argument, else first real line in `watch-log-path.txt` (`#` comments ignored).
4. Empty box: grey placeholder `C:\GMSprojects\Project_Name\log\PVSS_II.log`.
5. **Start** → `POST /api/logPath` → validate (exists, readable). Fail → error on page, stay on form. Success → update `watch-log-path.txt` (keep comment header), catch-up + tail.
6. No silent auto-start from a saved path alone.
7. **Restart** → stop tail, clear live session state as needed, show path + Start again (path prefilled with last successful path).
8. **Pause** / **Resume** → stop/resume consuming new bytes (P0).

Ship `watch-log-path.example.txt`. Operator file `watch-log-path.txt` is local (gitignored).

### 4.2 Catch-up (how the window is found)

The log is **append-only / sequential** (oldest near the top, newest at the bottom). Catch-up does **not** need random calendar indexing:

1. Open read-only; note file length.
2. For a rolling window (e.g. 60m): determine cutoff from the **newest timestamp near EOF** (file-end anchor), not wall-clock time — so copied/old logs and live files both mean “last N minutes **of this log**.” Then **seek backward from EOF** in expanding chunks until timestamps reach (or pass) the cutoff, and parse **forward** from that byte offset through EOF into live counters. Do **not** scan the whole file when a shorter window is selected. If no EOF timestamp can be read, fall back to wall-clock cutoff.
3. For **Entire**: parse from the start of the file once, then tail new bytes.
4. Show a **loading / spinner** state while catch-up runs (byte **% progress** is nice-to-have later — not MVP).

After catch-up, keep a file position and **tail** new lines. On rotate (size shrink / replace): reopen read-only, reset counters, banner, catch-up again per current window setting.

### 4.3 Implementation stance (vs V1.1)

- **Do not** shell out to `Analyze-PvssLog.ps1` and scrape its report for the dashboard.
- **Do** implement Watch as its own host + incremental state, **reusing** V1.1 regexes, normalization, module counters, finding thresholds, and section meanings (copy/adapt logic as needed).
- Optional later: extract shared `.ps1` helpers used by both batch and Watch — not required for MVP.

---

## 5. Scope

### P0 (MVP)

- Localhost host + `ui\` + `Run-Watch.cmd` + Watch `readMe.txt`
- Path/Start + Pause/Resume/Restart (§4.1); UTF-8 log read; default catch-up 60m; poll 3s
- Port: default **8787**, **try next** if busy; open browser only after bind succeeds
- Time window: presets + Entire + custom minutes (§7.2)
- Host-side severity + manager filters (§7.3)
- **Read-only** log open: `FileAccess.Read` only (share mode lets WinCC keep appending)
- Dashboard: sectioned UI (§7.0); V1.1 content parity (§7.5); **any manager** + top-N drill-down (§7.6)
- Live updates: `/api/pulse` every 3 s + `/api/section` / `/api/manager` on demand; generation/304 (§8)
- Desigo-aligned **severity** colors (§7.4)
- Log rotate auto-reopen + banner; missing/locked errors on page
- Loading spinner during catch-up / Entire / window widen
- V1.1 remains usable from `OfflineAnalyze\`

### P1

- Snapshot export (HTML/JSON from live payload)
- Adjustable poll interval; configurable preferred `-Port` (still fall through if busy)
- Catch-up / Entire **% progress** (bytes)

### Deferred

- WebSocket/SSE; pattern Top N explorer UI beyond V1.1-style lists; keyword organize
- Area (SYS/IMPL) breakdown; manager instance rollup
- Remote bind/auth; Node/Electron
- Shared parser library extracted for batch + Watch
- Full .NET multi-line reassembly (keep V1 single-header-line behavior)

### Non-goals

- Cloud upload / ticketing / replacing Siemens tools  
- Serving on the LAN by default  
- Loading the full raw log into the browser (Entire = **host-side** parse only)  
- Suggested next-steps / remediation text  

---

## 6. Operator flow

```text
1. Copy project folder to server (not into the project log directory)
2. Run-Watch.cmd → host binds port (try next if busy) → browser opens correct URL
3. Confirm/edit path (prefilled or placeholder) → Start
4. Watch dashboard; change window / filters; Pause / Resume as needed
5. Restart to pick a different path or recover from errors
6. (P1) Snapshot export; Ctrl+C stops host
```

---

## 7. UI

Do **not** dump every V1.1 section onto one endless scroll. Use a **sticky control chrome** + **section navigation** so each view has one job.

### 7.0 Information architecture

**Sticky chrome (always visible after Start):** path (read-only while running) · Pause / Resume / Restart · time window · severity chips · “Updated … ago” / loading / rotate banner / errors · (P1: snapshot)

**Primary nav (tabs or left rail):**

| View | Purpose |
|------|---------|
| **Overview** | Findings headlines, severity count tiles, Chart 1, Chart 2, compact top-managers strip |
| **Patterns** | Top N patterns by severity (FATAL / SEVERE / ERROR / WARNING) |
| **Managers** | Ranked manager list (any name seen in the log) → drill-down (§7.6) |
| **BACnet** | Full BACnet module (§7.5) — hide or empty-state if no signal |
| **CNS** | Thin CNS module |
| **CoHo** | Thin CoHo module |
| **Apogee** | Thin Apogee module |
| **More** | Perf categories; unparsed/skipped count; health bits |

Manager multi-select filter lives on Overview/Managers (or chrome) — not duplicated as a wall of chips on every view.

One composition per view; dense tables only inside the view that owns them. Avoid generic purple “AI dashboard” styling and bright white page backgrounds.

### 7.0.1 Theme — Siemens palette, dark ops

**Direction:** Dark industrial UI using Siemens brand colors. Surfaces stay dark; Petrol is the primary interactive accent. Do not use all accents everywhere — reserve natural accents for emphasis, charts helpers, and status where Desigo severity colors do not already apply.

**Primary (chrome & structure)**

| Token | Hex | Role |
|-------|-----|------|
| Siemens Petrol | `#009999` | Primary accent: active nav, primary buttons, focus rings, key links |
| Siemens Snow | `#FFFFFF` | Primary text on dark surfaces; high-emphasis labels |
| Siemens Stone | `#879BAA` | Secondary text, borders, idle controls, muted icons |
| Siemens Sand | `#AAAA96` | Tertiary / meta text, subtle dividers (use sparingly) |

**Surfaces (dark blend — derive in CSS; not official Siemens swatches)**

| Token | Approx. | Role |
|-------|---------|------|
| `--bg-deep` | Siemens Gray Dark `#0F1923` | Page background |
| `--bg-panel` | blend Gray Dark + Stone (~`#15202b`) | Sticky chrome, nav rail, panels |
| `--bg-elevated` | slightly lighter panel (~`#1c2834`) | Active section, table header, input fields |
| `--border` | Stone at ~35% opacity | Hairlines, chip outlines |

**Natural accents (use selectively)**

| Color | Light | Dark | Suggested use |
|-------|-------|------|----------------|
| Yellow | `#FFB900` | `#EB780A` | Warnings in **chrome** (loading, non-severity notices); not a replacement for Desigo WARNING unless tuned later |
| Red | `#AF235F` | `#641946` | Destructive / Restart emphasis; error banners (may sit beside FATAL/ERROR severity color) |
| Blue | `#55A0B9` | `#006487` | Secondary actions, info banners, chart grid accents |
| Green | `#AAB414` | `#647D2D` | Healthy/OK chrome cues (Resume, “tailing”); Chart 2 OK may stay Desigo INFO green for log fidelity |
| Gray | `#505A64` | `#0F1923` | Disabled states; deep background (Gray Dark) |

**Severity colors stay Desigo-aligned (§7.4)** so log meaning matches the operator’s familiar viewer. Brand Petrol/Stone frame the app; severity chips/series keep their Desigo hexes on dark surfaces (ensure contrast; lighten slightly only if WCAG fails).

Define all of the above as CSS variables in `app.css` (e.g. `--siemens-petrol`, `--bg-deep`, `--sev-fatal`, …).

### 7.1 Charts

Both respect current time window and filters. Library: vendored under `ui\vendor\`.

| | Chart 1 — Message volume | Chart 2 — BACnet / critical |
|--|--------------------------|------------------------------|
| Type | Stacked bar by minute | Dual line (or bars) by minute |
| Series | Selected severities (FATAL…INFO) | BACnet Failed vs OK when present; else SEVERE |
| Empty | “No data in window” | Same |

INFO series only if INFO filter is on (default off).

**BACnet note:** Device Failed/OK lines are **INFO** in the log. Module cards and Chart 2 still track them when present, even if the INFO severity chip is off (same rule as V1.1).

### 7.2 Time window

**Goal:** Flexible enough for “last hour,” “last N minutes,” or “whole file,” without a complex calendar UI.

| Control | Behavior |
|---------|----------|
| **Presets** | Segmented: `[ 15m ] [ 30m ] [ 60m ] [ 120m ] [ Entire ]` — default **60m** — minutes are relative to **file end** (newest log timestamp), not wall clock |
| **Custom** | Numeric amount + **minutes / hours** unit + Apply / Enter (max 10080 minutes / 168 hours) — for values outside presets |
| **Entire** | Host parses from start of file, then keeps tailing. On ~50 MB expect &lt; ~60 s class; show spinner. |

Changing the window re-scopes summary/charts. Widening or switching to Entire may trigger additional back-read; show “Loading window…”.

Selecting a preset or custom minutes clears Entire; selecting Entire clears the custom-minutes focus.

**API:** `lastMinutes=60` for a rolling window; `window=entire` for the whole file.

**Series size:** Pulse chart series auto-aggregate by span: **minute** (≤ ~6h), **hour** (≤ ~14d), **day** (longer / Entire multi-week). Host still keeps per-minute analysis maps; only the serialized chart points roll up. Payload includes `series.granularity`. After rotate, counters reset.

### 7.3 Filters (host-side)

**Severity:** chips FATAL · SEVERE · ERROR · WARNING · INFO — default all on except INFO.

**Managers:** multi-select by **name** (default all). Top ~20 by volume; Clear / Select all. Row click in top-managers table toggles filter when practical.

Filters are applied **on the host** when composing pulse/section/manager responses (query params). The UI does not re-filter a giant unfiltered payload. Module BACnet Failed/OK tracking still follows §7.1 INFO exception.

Examples:  
`GET /api/pulse?lastMinutes=60&severities=FATAL,SEVERE,ERROR,WARNING`  
`GET /api/section?name=patterns&window=entire&severities=…`  
`GET /api/manager?name=WCCOAfoo&lastMinutes=60`

### 7.4 Severity colors (Desigo-aligned)

Match Desigo log viewer severity colors. Managers are labeled by text only.

| Severity | CSS (approx.) |
|----------|----------------|
| INFO | `#008000` |
| WARNING | `#E07000` |
| SEVERE | `#C000A0` |
| FATAL | `#E00000` |
| ERROR | `#B00040` (PVSS has ERROR; Desigo’s 4-color legend does not — keep ERROR visible) |

Chart 2: Failed ≈ SEVERE magenta, OK ≈ INFO green. Severity tokens live beside Siemens chrome variables in `app.css`; do not recolor FATAL/SEVERE/etc. to Petrol.

### 7.5 Dashboard content (V1.1 parity)

Scoped to the **current time window** (and host filters where applicable). Same meanings as V1.1 — no remediation text.

#### Findings (short headlines)

Not a raw log dump. Same style as V1.1 threshold / status headlines when triggered, for example:

- BACnet device status chatter (Failed/OK volume + unique devices)
- BACnet last-known: ended Failed / ended OK counts
- BACnet flapping (devices with N+ Failed/OK changes)
- BACnet object-list warnings
- CNS volume / TryRenewSession
- CoHo stuck/drop volume
- Apogee UpdatePoints failures

#### Severity counts

FATAL / SEVERE / ERROR / WARNING / INFO totals in window.

#### Top patterns by severity

Separate lists for FATAL, SEVERE, ERROR, WARNING (default Top N ≈ 10): pattern, count, first/last timestamps, sample line(s) — same idea as V1.1. INFO patterns not listed by default.

#### BACnet module card

- Failed / OK transition counts + unique devices  
- Last-known ended Failed / ended OK  
- Flapper count  
- Device status activity table (top 20 by Failed): Failed, OK, flips, last status, device id  
- Devices that ended Failed (top 20)  
- Object-list WARNING counts + top devices + example  

#### CNS module card (thin)

ResolveNodes / ReducedFunction / ICns / TryRenewSession counts; top CNS-related patterns (count, first/last, example).

#### CoHo module card (thin)

Stuck/drop count; top stuck names; example.

#### Apogee module card (thin)

Events / UpdatePoints / trace repetitions; unique PPCL count; top PPCL by UpdatePoints; example.

#### Top managers + any manager (required)

Managers are discovered from **log headers**. Unknown / site-specific managers appear in the ranked list like any other.

- Overview: top managers by volume (name + count; severity mix when cheap).
- **Managers** view: full ranked list (filterable); selecting a manager opens a **drill-down** (V1.1 Path D style):
  - Line count + severity mix for that manager
  - Top N patterns **per severity** (FATAL / SEVERE / ERROR / WARNING) with count, first/last, sample
  - If that manager also matches a known module (BACnet/CNS/CoHo/Apogee), link or embed the matching module summary
- No special module is required for a manager to be useful — **identity + top patterns** is enough.

#### Perf categories

Include under **More** (same keyword categories as V1.1).

#### Parse notes

Keep V1 **single-header-line** parsing (continuation lines without a new header are skipped). Expose an **unparsed / skipped line count** (or rate) in health or **More** — not a full multi-line reassembly in V2.0.

### 7.6 Managers drill-down (any name)

Same behavior whether the manager appears in our examples or not:

1. Parse manager/component from each header line into the live volume map.  
2. Rank and list by volume in the current window (respect manager filter when set).  
3. On select → `GET /api/manager?name=…` (or detail section) returns Path D–style top patterns for that name.  
4. Special modules remain **additive** when signatures match — they do not gate manager visibility.

---

## 8. API and live update efficiency

### 8.1 Problem

A full V1.1-shaped JSON blob every **3 s** is wasteful: large pattern tables, BACnet device rows, and per-manager maps change slowly relative to headline counts and chart buckets. The UI also only shows **one nav view** at a time.

### 8.2 Approach (locked for MVP)

**Split light vs heavy** + **generation / 304**:

| Endpoint | Cadence | Payload |
|----------|---------|---------|
| **`GET /api/pulse`** | Every **3 s** (and on filter/window change) | `generation`, window, loading/paused/error/rotate flags, findings[], severityCounts, chart `series.byMinute[]`, module **headlines** (counts only), top managers **names+counts** (e.g. top 20), fileLength |
| **`GET /api/section?name=`** | When that nav view is active, or when `generation` changes while viewing it | Heavy body for one section: `patterns` · `bacnet` · `cns` · `coho` · `apogee` · `perf` · `managers` (list) |
| **`GET /api/manager?name=`** | On manager drill-down (and refresh if generation changed while open) | Path D–style patterns for that manager |

**Conditional requests:** both pulse and section accept `If-None-Match: <generation>` (or `?sinceGeneration=`). If nothing material changed → **304** / empty body; UI keeps last render and only bumps “Updated … ago.”

**Host still maintains full in-memory state** for the window; splitting is about **what we serialize and send**, not about dropping analysis.

**Filters / window:** query params on pulse and section (host-side), same as before.

### 8.3 Other endpoints

**`GET /api/health`** — ok, version, logPath, URL/port, tailRunning, paused, fileLength, lastError, generation  

**`POST /api/logPath`** — `{ "path": "..." }` → validate / persist / start  

**`POST /api/control`** — `{ "action": "pause"|"resume"|"restart" }`  

Optional alias: `GET /api/summary` may remain as a **debug / Snapshot** convenience that returns pulse + all sections once (P1 Snapshot can use this or compose from pulse+sections).

Field names may tighten in build; keep JSON under `/api/`.

### 8.4 UI refresh rules

1. Poll **pulse** every 3 s.  
2. If 304 → update timestamp only.  
3. If body returned → update Overview chrome/charts/findings; if `generation` changed and user is on a detail view → re-fetch that **section** / **manager** only.  
4. Switching nav tabs fetches that section once (then follows generation).

---

## 9. Parameters

```text
Watch-PvssLog.ps1
  -LogPath           # prefill only (no silent auto-start)
  -Port              # preferred port; default 8787; try next if busy
  -LastMinutes       # initial/default rolling window; default 60
  -RefreshSeconds    # default 3 (UI poll; P1 may expose control)
  -NoBrowser
  -NoPause           # cmd / double-click convenience (host exit behavior)
```

**Entire file** is a **UI/API window mode** (`window=entire`), not a separate CLI switch for MVP. CLI `-LastMinutes` only sets the initial rolling default.

---

## 10. Package layout

```text
PvssLogAnalyze\                 ← field package root (simple)
  Run-Watch.cmd                 ← double-click launcher
  readMe.txt
  Watch\                        ← runtime payload
    VERSION.txt                 → 2.0 when released
    Watch-PvssLog.ps1
    watch-log-path.example.txt
    ui\
      index.html, app.css, app.js
      vendor\                   ← chart lib (local)
    OfflineAnalyze\                      ← V1.1 (optional in field zip)
      VERSION.txt               → 1.1
      Analyze-PvssLog.ps1
      Run-Analyze.cmd
      Run-Analyze-Interactive.cmd
      readMe.txt
docs\                           ← PRD / PROGRESS / test example logs (dev only; not in field zips)
  PRD.md, PRD-V2.md
  PROGRESS.md, PROGRESS-V2.md
  PVSS_II_Examples\
```

Dev-only under `docs\` (not in field zips).---

## 11. Ops notes

- Bind `127.0.0.1` only; same Windows session can open the URL.  
- If preferred port is in use, bind the **next available** port; print and open that URL.  
- Prefer opening the **default browser** if Chrome is not required by policy; `Run-Watch.cmd` may still try Chrome first when present.  
- **Log file access is read-only.** Open with `FileAccess.Read` only. Use `FileShare.ReadWrite` so *other* processes (WinCC OA) may keep appending while we read — that share flag does **not** grant this tool write permission. Never open the live log with `FileAccess.Write` / `ReadWrite`.  
- On shrink/replace: reopen (still read-only), reset stats, banner “log rotated — counters reset”.  
- Missing or locked file after Start: show a clear on-page error; operator uses Restart when ready.

---

## 12. Acceptance (MVP)

1. `Run-Watch.cmd` serves UI on localhost and opens the browser to the **bound** port (no Node/IIS).  
2. Path + Start works with prefill, placeholder, validation, and persist to `watch-log-path.txt`.  
3. Pause / Resume / Restart work; missing/locked errors appear on the page.  
4. Live updates via **3 s pulse** (+ section/manager on demand); 304 when unchanged (§8).  
5. 60m catch-up default; time window presets including **Entire** + custom minutes; host-side severity + manager filters affect charts/counts.  
6. Sectioned UI (§7.0); V1.1-parity content (§7.5); **any** manager identifiable with top-N pattern drill-down (§7.6).  
7. Two charts render offline via vendored library; Desigo-like severity colors; BACnet INFO exception for modules/Chart 2.  
8. Rotate auto-reopen with banner; spinner during catch-up/Entire.  
9. `OfflineAnalyze\` V1.1 still runs for offline reports.  
10. Watch `readMe.txt` documents path setup, port fallback, and offline use.

---

## 13. Build phases

| Phase | Deliverable |
|-------|-------------|
| **2A** | `ui\` shell + section nav + mock pulse/section/manager JSON |
| **2B** | Host serves `ui\` + `/api/pulse` + `/api/section` (catch-up, filters, generation/304) |
| **2C** | Tail + polling rules + path/Start + Pause/Resume/Restart + rotate + errors |
| **2D** | Charts, filters, §7.5 modules/patterns, any-manager drill-down, Desigo colors |
| **2E** | Docs, `OfflineAnalyze\` layout, version **2.0**; Snapshot download |

---

## 14. Review checklist

- [x] Architecture: PS host + browser; pulse 3s + section/manager; port fallback before open  
- [x] Path/Start + Pause/Resume/Restart; watch-log-path persist  
- [x] Catch-up from EOF for rolling window; Entire = host full parse; spinner  
- [x] Time window presets + Entire + custom; read-only log open  
- [x] Package: V2 root + `OfflineAnalyze\`; separate readMes; offline vendor charts  
- [x] Snapshot from live payload (**P1**); rotate auto-reopen  
- [x] UI §7 (sectioned IA, Siemens dark theme, charts, filters, Desigo severity, V1.1 parity)  
- [x] Any manager discoverable + top-N pattern drill-down  
- [x] Standalone Watch reusing V1.1 logic (not V1 report→JSON)  
- [x] Host-side filters; efficient pulse/section API  
- [x] Status → **Locked / ready to build** → create **PROGRESS-V2.md**
