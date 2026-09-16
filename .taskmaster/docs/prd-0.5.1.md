# Watch / DesigoLogWatcher 0.5.1 — Product Requirements

## Overview

Watch / DesigoLogWatcher **0.5.1** is a **patch** release on top of shipped **0.5.0**
(C# single-file host). Scope comes from `docs/BACKLOG.md` §0.5.1 only.

**Goal:** close leftover 0.4 API parity gaps, restore pre-0.3 pattern aggregation
quality (missed triage bug), polish operator-facing Detections UI and host console
copy, fix Project restart / status-line timing consistency while tailing, align
inactive Severity chip styling with Area chips, and verify truncate/rotation recovery
with automated tests — **no new product modes**.

**Audience:** same field operators as 0.5.0. Ship needs VERSION / CHANGELOG / readMe bump to
0.5.1 when work is done.

**Out of scope** (BACKLOG “Later” / parking lot): absolute dashboard windows, chart
granularity ladder, Findings threshold scaling, startup plume research, structured
logging redesign, same-port stale-tab deep dive. Do **not** treat “match 0.4 pattern
Top-N” as acceptance for §9 — 0.3–0.5 share the regression; baseline is Watch **2.2 /
field v0.2.0**.

---

## Core Features

### 1. Pulse API: restore `areaOtherNames`

- **What:** Include `areaOtherNames` on `/api/pulse` as in Watch 0.4.0. AnalysisState already
  tracks other area names; pulse currently omits the key (UI unused today).
- **Why:** API parity with 0.4; avoids silent schema drift for any consumer.
- **How:** Build the same payload shape 0.4 emitted (from existing state); add/adjust a unit
  or API parity assertion.

### 2. Formal API key/schema checks vs 0.4

- **What:** Automated checks that top-level (and key nested) keys for `/api/health`,
  `/api/pulse`, `/api/section/*`, `/api/manager` match 0.4 aside from documented
  allowlist (e.g. additive `loadProgressPct` / `loadMessage` on health).
- **Why:** Prevents further silent contract drift after the 0.5.0 port.
- **How:** Prefer fixtures or a small test harness against a tiny log; document allowlisted
  deltas. Do not require a full 50 MB corpus.

### 3. Detections UI visual polish

- **What:** Improve Detections presentation in `Watch/ui` (sample line dominance, unclear
  bucket labels, other layout/CSS/copy). In particular, make each detection easier to tell
  apart — stronger visual separation between detection rows/cards so the list does not
  read as one continuous block. Keep HTML snapshot (`SnapshotHtml`) and `app.js`
  dual-render in sync — visual/copy only; **do not** change detection meaning, ranking,
  or counts.
- **Why:** Operator readability; called out at 0.5.0 ship as patch-worthy. Crowded /
  similar-looking entries make it hard to scan individual detections.
- **How:** Iterate on CSS/markup/JS rendering (spacing, borders, dividers, or equivalent
  grouping cues); spot-check dashboard + snapshot HTML on a fixture with BACnetDrv /
  other detection groups.

### 4. Host console copy

- **What:** Replace “catch-up” wording with clearer terms (e.g. Reading / Parsing). Light
  polish of existing console lines (same events, less jargon).
- **Why:** Operators find “catch-up” unclear.
- **How:** String/copy changes in host console paths. No structured-logging redesign.
  **Out of scope:** progress % “feel” / throttle investigation — that was a 0.4 concern
  when Entire loads took minutes; 0.5.0 C# catch-up is typically a few seconds (worst
  observed ~6 s), so % polish is not worth patch scope.

### 5. Confirm log truncate / rotation path

- **What:** Verify truncate/rotation recovery (reseek / restart) when the open log is
  shortened or rewritten while watching. Unit `Truncation_ReseeksToStart` already exists;
  0.5.0 did not treat live dashboard confirmation as a ship gate.
- **Why:** Only unchecked live I/O edge from the 0.5.0 checklist (B5 waived).
- **How:** **Automated test verification is sufficient** for 0.5.1 acceptance (rewrite a
  watched file shorter mid-session; assert recovery — generation bump / reload /
  continued tail). Optional live-server observation (e.g. 0.5.0 already running in the
  field) is welcome if a truncate happens soon, but is **not** required to close this
  item. Document only if something unexpected shows up.

### 6. Project restart timers: live “still up” count + clearer window-start uptime

- **What:**
  1. **Active (last) cycle timer keeps ticking.** When the newest Project restart cycle is
     still up (`stillUp`), the Uptime duration must continue counting on the dashboard
     while the host is tailing — not only refresh when a new log line arrives / pulse
     recalculates from a newer `windowLast`.
  2. **Window-start uptime is visually distinct.** The first cycle whose `up` is implied
     at the analysis window start (`upImplied`) must make it obvious that Uptime is
     measured **from the window start**, not from the project’s true start. Today a short
     number next to a real shutdown (e.g. after a mid-window project stop) reads like the
     project was only up for that short span, when actual uptime may be much longer.
- **Why:** Operators triage live systems; frozen “still up” timers and ambiguous first-row
  uptime mislead during long idle tails and when a shutdown sits inside a rolling window.
- **How:** Prefer client-side tick from cycle timestamps / `uptimeSec` for the open
  `stillUp` row (and sync snapshot/HTML if the same values are shown there). Strengthen
  labeling for `upImplied` rows (Up column and/or Uptime cell / note) so “from window
  start” cannot be mistaken for full project uptime. Do **not** invent pre-window up
  events; clarify scope only.

### 7. Status line: show effective displayed window while tailing

- **What:** Beside “tailing” in the top-left status, the window phrase must describe the
  **time span actually reflected in the dashboard data**, not only the filter preset that
  was selected. Example: filter set to **15m**, host has been tailing for **3 hours** →
  status still says `window 15m` while charts/KPIs cover ~**3h 15m**. Show an effective /
  elapsed window (e.g. grown span since catch-up, or span from window start through latest
  log time) that matches what is displayed.
- **Why:** During live tail the rolling window grows past the initial catch-up size; the
  preset label becomes inaccurate and erodes trust in the status chrome.
- **How:** Derive the displayed label from pulse/window metadata the UI already has (or
  add a small additive field if needed: e.g. effective span minutes / formatted span).
  Keep preset controls as the *requested* window; status reflects *effective* coverage
  while tailing. Entire-file mode stays “Entire file” (or equivalent). Avoid implying a
  hard absolute From/To product mode.

### 8. Severity filter chips: grey when inactive (match Area)

- **What:** Severity filter buttons (`#sevChips` / `.chip-sev`) keep their colored
  enabled look when active. When a severity is **toggled off** (not `.active` — operator
  “disabled”), the chip must look like an inactive Area filter chip: neutral grey
  border/text (same family as `.chip-area:not(.active)`), not the severity’s tinted
  border/label. Today inactive FATAL/SEVERE/… chips still show severity colors and only
  drop opacity, so they still read “on.”
- **Why:** Area chips already communicate off as grey; Severity should match so operators
  can tell included vs excluded filters at a glance.
- **How:** CSS-only in `Watch/ui/app.css` (and HTML class hooks if needed). Scope color
  rules to `.chip-sev.active` (or clear tint on `:not(.active)`). Do not change filter
  semantics, defaults, or click behavior. HTML `disabled` (window lock mid-load) is out of
  scope unless it already shares the same inactive styling path.

### 9. Pattern aggregation: restore pre-0.3 triage grouping

- **What:** Patterns by severity and per-manager deep-dive pattern tables fragment
  high-volume message families in **0.3.0–0.5.0** vs Watch **2.2** (field package
  `PVSS_II_Watcher_V0.2.0`, UI “v2.2”). Same log / Entire window: v0.2 keeps one
  ~8k-count CoHo `ICommand.Execution` / Style.IndValues SEVERE bucket and groups
  Orch.Alarm.Queue WARNINGs; 0.5.0 (aligned with 0.3/0.4) drops that family from Top N
  and shows many low-count variants with full `System1:GmsDevice_…` / source paths.
  Related symptom: `Repetition [#N] of a former trace` often appears once as
  `[#<NUM>]` (large N) and many times as literal `[#1]`, `[#2]`, `[#1000]`, … because
  `ReNormNum` only replaces **5+ digit** runs (`\b\d{5,}\b`). Tie ordering differences
  are **ignored**. pmon Blocking ±2 (43 vs 41) is **out of scope** unless a separate
  parse bug is proven — not pattern-key related.
- **Why:** 0.3.0 raised pattern **fingerprint** truncation from a hard **180** chars to
  `SampleMaxChars` (default **500**) while still using that string as the hashtable key
  (“longer pattern labels”). Unique DP/device suffixes past ~180 shatter one triage
  bucket into many. Path/number tokenization was already weak; the longer key exposed
  it. Truncation must **not** be the aggregation strategy. This is **older than 0.4
  parity** — fixing toward v0.2 aggregation is correct for **0.5.1** (keep in patch;
  do not defer the whole item to Later).
- **How:** In `AnalysisState.NormalizeMessage` / `AddPattern` (and config/docs copy):
  1. **Decouple entirely:** `SampleMaxChars` affects **display/sample text only**. The
     pattern hashtable key must **not** be truncated by `SampleMaxChars` (or any operator
     knob). Smaller SampleMaxChars must never change counts or Top-N membership.
  2. **Primary fix — strengthen programmatic normalization** (not truncation luck):
     - Collapse numeric variance that is not semantic: e.g. `[#1]` / `[#1000]` /
       `[#10000]` → `[#<NUM>]`; broaden beyond today’s 5+ digit-only rule where safe;
     - Tokenize volatile paths/IDs (`SystemN:…`, `GmsDevice_*`, quoted `Property "…"`)
       so CoHo/Orch families group without relying on cutting the string mid-path.
     - Keep timestamps/`<TS>`/`<TIME>` normalized; preserve command names and
       meaningful error-code structure (do not over-merge distinct failure modes).
  3. **Do not** implement pairwise “diff two lines and merge if only numbers differ”
     clustering — too costly on large Entire-file runs. Regex/token normalization at
     ingest is the efficient, robust approach; make rules general enough to catch
     unseen shapes, not a long list of one-off message templates.
  4. Optional safety: an **internal** fixed key max (if any) is a last-resort guard,
     independent of SampleMaxChars — not the main fix.
  5. Unit fixtures: many near-ID CoHo ICommand + Orch.Alarm + `Repetition [#N]` lines →
     stable triage keys; samples still show concrete paths when SampleMaxChars allows.
  6. Spot-check Patterns + WCCOAGmsCoHoMngr deep dive vs archived v0.2 on the same log.
     Do **not** use “match 0.4 Top N” as the pass criterion.
  7. **Out of 0.5.1 / → Later:** improving usefulness of “repetition of a former trace”
     rows themselves (they often add little triage signal beyond a counter) — see
     BACKLOG Later.

---

## User Experience

- Dashboard and report workflows unchanged aside from clearer console text, nicer
  Detections visuals, more trustworthy Project restart durations, an accurate
  tailing window label in the status line, Severity chips that grey out when off
  like Area chips, and pattern Top-N / manager deep-dives that again group high-volume
  families the way Watch 2.2 did (samples stay readable).
- No new CLI switches or config keys required unless a tiny diagnostic flag proves
  necessary (prefer none). `SampleMaxChars` becomes **display/sample only** — it must
  not alter pattern keys, counts, or Top-N.
- Field package shape unchanged: exe + ui + launchers + docs + LICENSE.

---

## Technical Architecture

- **Host:** existing `src/DesigoLogWatcher` (HttpServer pulse builders, AnalysisState
  including `NormalizeMessage` / pattern keys, LogParser truncate detection, console
  write sites; optionally LifecycleBuilder / pulse window metadata for effective span).
- **UI:** `Watch/ui/app.js` (+ CSS/HTML as needed) — Project restart table tick/labels;
  status line window wording; Severity chip inactive grey styling in `app.css`; report
  HTML via `SnapshotHtml` / related builders where dual-render or snapshot shows the
  same durations.
- **Tests:** `src/DesigoLogWatcher.Tests` — extend for `areaOtherNames` and API key
  allowlist; automated truncate/rotation recovery coverage (acceptance for §5);
  pattern-normalization fixtures for §9 (CoHo ICommand + Orch.Alarm fragmentation);
  lifecycle / UI labeling cases for `upImplied` and still-up duration as needed.
- **Baseline compare:** 0.4 behavior for API keys; **pattern aggregation baseline is
  Watch 2.2 / v0.2.0** (`docs/archive/Old Builds/PVSS_II_Watcher_V0.2.0`), not 0.3–0.5.

---

## Development Roadmap

### Phase A — API parity

1. Emit `areaOtherNames` on `/api/pulse` matching 0.4 shape from existing state.
2. Add automated API key/schema checks (health, pulse, section, manager) with
   explicit allowlist for intentional 0.5 additives.
3. Tests green; no UI dependency.

### Phase B — Analysis correctness + operator polish

4. Pattern aggregation: SampleMaxChars display-only (no key truncate via that knob);
   strengthen number/path tokenization (incl. `[#N]` / GmsDevice-style IDs); tests +
   spot-check vs Watch 2.2 / v0.2.0 (not vs 0.4). No pairwise line-diff clustering.
5. Detections UI visual polish; sync snapshot HTML render where the same content
   is dual-rendered.
6. Console: rename catch-up → Reading/Parsing (or equivalent); light line polish
   (no progress-% work).
7. Project restart: live still-up timer + clearer window-start uptime labeling
   (dashboard + snapshot/HTML where applicable).
8. Status line: effective displayed window while tailing (not preset-only).
9. Severity filter chips: inactive/off state grey like Area chips (enabled colors unchanged).

### Phase C — Verification and ship

10. Truncate/rotation: automated recovery test green (live field observe optional, not a gate).
11. Version bump to **0.5.1** (`VERSION.txt`, `Program.Version`, CHANGELOG.md/.txt,
    readMe.txt); publish exe to `Watch\`; update BACKLOG (strike or move done 0.5.1
    items). Field zip optional (same layout as 0.5.0, include LICENSE).

---

## Logical Dependency Chain

1. Pulse `areaOtherNames` first (small, unblocks schema harness expectations).
2. API key/schema harness next (locks contract).
3. Pattern aggregation fix early in B (analysis correctness; independent of UI polish).
4. Detections UI, console copy, Project restart timers, status-line window label, and
   Severity chip inactive styling can proceed in parallel after A (no hard dep between them).
5. Truncate automated test can run anytime after host is stable; do before version bump.
6. Version / CHANGELOG / publish last.

---

## Risks and Mitigations

- **Dual-render drift** (UI vs HTML snapshot): treat “in sync” as acceptance for any
  Detections visual change; same for Project restart duration/label copy if shown in
  snapshot.
- **Pattern re-aggregation** may change Top-N / counts vs 0.3–0.5 field muscle memory:
  document in CHANGELOG as restoring Watch 2.2-style grouping + safer numeric/path
  tokens; accept intentional divergence from 0.4. Over-aggressive tokens could merge
  distinct failures — preserve command names and error-code distinctions; validate on
  CoHo + Orch + `Repetition [#N]` fixtures and a real Entire-file spot-check.
- **Relying only on key truncation** is rejected as the primary strategy (truncation
  luck). Decoupling SampleMaxChars is required so display config cannot change analysis.
- **Truncate/rotation test** may expose a real bug: fix in 0.5.1 if cheap; otherwise note
  in CHANGELOG / Known bugs and keep patch focused. Live-server truncate (when it happens)
  may still surprise; treat as follow-up unless cheap to fix in-band.
- **Live still-up timer** clock skew vs log timestamps: prefer log/window-last anchors
  over wall clock alone so idle gaps without new lines still advance consistently with
  operator expectation.
- **Effective window label** must not be confused with absolute From/To feature work
  (out of scope); keep copy about “displayed span while tailing.”
- **Scope creep** into BACKLOG “Later”: refuse; open a follow-up tag/PRD instead.

---

## Appendix

- Source of truth for scope: `docs/BACKLOG.md` §0.5.1.
- Taskmaster tag: `v0_5_1` (empty; parse this PRD into that tag).
- Parse into **11** top-level tasks aligned 1:1 with Development Roadmap items 1–11.
- Pattern baseline archive: `docs/archive/Old Builds/PVSS_II_Watcher_V0.2.0` (VERSION 2.2).
- Prior text PRD path (replaced): `.taskmaster/docs/prd-0.5.1.txt` → this markdown file.
