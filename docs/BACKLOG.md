# Future backlog — PVSS Log Analyzer

**Shipped baseline:** Watch **0.4.0** · Author: Cisum (2026-09-12)
OfflineAnalyze **1.3** is absorbed as report mode; frozen copy under
[`archive/OfflineAnalyze/`](archive/OfflineAnalyze/). Spec / tracker for 0.4.0:
[`archive/PRD-V0.4.md`](archive/PRD-V0.4.md) · [`archive/PROGRESS-V0.4.md`](archive/PROGRESS-V0.4.md).

**In progress:** **0.5.0** — C# single-file runtime rewrite.
Spec: [`PRD-V0.5.md`](PRD-V0.5.md) (**pre-finalized**; lock → create `PROGRESS-V0.5.md`).

**Cancelled as a PowerShell patch:** former **0.4.1** — do not implement in PS first.

**0.5.0 scope (see PRD §2.1):** direct port of **0.4.0** + multi-scope + BACnet-scoped rules
+ manager pick ranges; Entire-cache per PRD §4.6. Other polish → **0.5.1**.

**Rule:** Keep this file short — ideas as bullets, not specs. Active scope lives in a PRD
(or the patch list here) and tracker; historical requirements in [`archive/`](archive/).
Anything shipping to the field needs a **version bump** first (`VERSION.txt` + user-facing
`readMe.txt` / `CHANGELOG.txt`). Keep root [`CHANGELOG.txt`](../CHANGELOG.txt)
operator-focused — no docs/backlog links. GitHub: [`CHANGELOG.md`](../CHANGELOG.md).


---

## 0.5.0 intentional deltas (vs 0.4.0)

_In PRD ship scope — not optional “if cheap”:_

- **Multi-scope** (`Scope` as string or list)
- **BACnet-scoped rules** for four Apogee-shaped families (do not widen Apogee scopes)
- **Interactive manager pick ranges** (`1-3,10`)

## 0.5.1 (deferred from former 0.4.1)

- **Detections UI leftovers:** sample line dominates; bucket labels unclear
- **Host console catch-up %** feels inaccurate (throttle vs wrong %)
- **Detections dual render** (HTML vs `app.js`)
- Entire-cache **UX** polish if cache is built in 0.5.0 §4.6/5H and still needs work

---

## Ideas / improvements (post-0.5.0)

### Watch
- **Absolute time window in the dashboard.** Report mode already has `-From` / `-To`
  (and the seek path behind them). Dashboard only offers last-N-minutes and Entire.
  Expose the same absolute bounds in the UI so an incident window can be loaded live
  without dropping to report mode.
- **Finer chart bar granularity.** Today only minute / hour / day. Prefer
  **1m → 5m → 10m → 15m → 1h → 6h → 12h → 1d**, rolled up from existing minute buckets,
  with thresholds tuned so bar count stays readable on live windows and Entire.
- **Blazor / SPA dashboard (post-0.5.0).** 0.5.0 keeps the static `ui\` + `HttpListener`
  contract. A later version could replace the front end with Blazor (or another SPA) for
  richer UI — only after the C# host/API is stable.

### Performance
- ~~**Inline hot helpers in `Process-LogLine`**~~ → **superseded by 0.5.0** C# runtime.
- ~~**Multi-scope (`Scope` as an array)**~~ → **in 0.5.0** PRD.

### Detection / parsing
- **Scale the Findings thresholds to the window.** Absolute counts serve both a 60-minute
  dashboard window and a four-month batch report — only one scale can be “right.” Affects
  ~19 hardcoded comparisons in `Build-Findings` plus rule `FindingAt` values. Critical-
  severity finding is already %-of-parsed-lines (scale-free). Does not reorder Detections
  (window factor cancels in ranking). Settle: rate vs presence vs cardinality; per-hour vs
  per-1k-lines; clamps. Needs parity check + CHANGELOG.
- **Relate severe / high-volume traffic to project startup.** Characterize bursts relative
  to up / shutdown / stopped cycles (before / after / span). Corpus first for a “normal
  startup plume,” then Findings or UI. Ties into Findings window-scaling.
- Rule-engine extensions if the field asks: cross-line correlation; per-rule rate thresholds
  in the rule table (declarative half of Findings scaling)

---

## Known bugs

_None open outside 0.5.0 carry-ins / Parking lot._

---

## Parking lot

_Parked — not addressing yet. One-liners as they come up in the field:_

- Keyword organize path (from V1)
- Driver type-in search (picker is enough for most sites)
- Fuller multi-line log reassembly (beyond single-header-line parse)
- Snapshot download locked up once on a live server (not reproduced locally; if it
  recurs: log size, window, host still printing tail activity)
