# Future backlog — PVSS Log Analyzer

**Shipped baseline:** Watch **0.5.0** · Author: Cisum (2026-09-14)  
Prior: **0.4.0** (2026-09-12). Spec/tracker: [`archive/PRD-V0.5.md`](archive/PRD-V0.5.md) ·
[`archive/PROGRESS-V0.5.md`](archive/PROGRESS-V0.5.md). Field zips:
[`archive/DesigoLogWatcher_v0.5.0.zip`](archive/DesigoLogWatcher_v0.5.0.zip) ·
[`archive/DesigoLogWatcher_v0.4.0.zip`](archive/DesigoLogWatcher_v0.4.0.zip).

**Rule:** Keep this short — bullets, not specs. Ship needs a version bump
(`VERSION.txt` + `readMe.txt` / `CHANGELOG.txt`). Operator CHANGELOG stays free of
docs/backlog links. GitHub: [`CHANGELOG.md`](../CHANGELOG.md).

---

## 0.5.1 (patch)

_Parity leftovers, UX polish, and cheap mitigations — no new product modes.
Visual-only UI tweaks (layout/CSS/copy that do not change analysis meaning) are in scope._

- **`/api/pulse` `areaOtherNames`** — 0.4 had it; AnalysisState still tracks names; pulse
  omits the key (UI unused). Restore for API parity.
- Formal automated API key/schema checks vs 0.4 (health / pulse / section / manager)
- **Detections UI** — visual polish (sample line dominates; bucket labels unclear; any
  other layout/CSS/copy fixes). Keep HTML snapshot vs `app.js` dual-render in sync.
- **Host console catch-up %** feels inaccurate (throttle vs wrong %)
- **Confirm log truncate / rotation** — synthetic smoke: shorten/rewrite the open log
  while the dashboard is running; expect reseek/restart path (unit covered; not
  field-tested at 0.5.0 ship)

---

## Later (feature / research — not a quiet patch)

### Dashboard
- **Absolute From/To in the dashboard** (report mode already has it)
- **Finer chart granularity** — 1m → 5m → 10m → 15m → 1h → 6h → 12h → 1d from minute buckets
- **Blazor / SPA front end** — only after the C# host/API stays stable; 0.5.0 keeps static `ui\`

### Findings / detections
- **Scale Findings thresholds to the window** (60m vs multi-month Entire). Affects
  hardcoded comparisons in `SnapshotBuilder.BuildFindings` plus rule `FindingAt`. Needs
  a deliberate settle (rate vs presence vs cardinality) + CHANGELOG — behavior change.
- **Relate severe / high-volume traffic to project startup** (plume vs up/stop cycles).
  Corpus first; ties into Findings scaling.
- Rule-engine extensions if the field asks: cross-line correlation; declarative per-rule
  rate thresholds

---

## Known bugs / residual quirks

- **Stale browser tab still open after a host restart.** The old “two backends / port bump
  looks like flipping KPIs” path was addressed in **0.5.0** (dispose wait, louder port-bump
  warning). A leftover tab that happens to hit the **same** port again is still undefined —
  close old tabs and use the Listening URL the console prints.

---

## Parking lot

_Not addressing yet — one-liners from the field:_

- Keyword organize path (from V1)
- Driver type-in search (picker is enough for most sites)
- Fuller multi-line log reassembly (beyond single-header-line parse)
- Snapshot download locked up once on a live server (not reproduced; if it recurs: log
  size, Format, whether host was still tailing)
