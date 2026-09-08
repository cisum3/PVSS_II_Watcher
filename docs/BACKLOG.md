# Future backlog — PVSS Log Analyzer

**Shipped baseline:** Watch **2.3** · OfflineAnalyze **1.3** · Author: Cisum (2026-09-07)
**In progress:** Watch **2.4** — declarative rule engine; OfflineAnalyze absorbed into Watch
as a `-Report` batch mode. Spec: [`PRD-V2.4.md`](PRD-V2.4.md) (locked) · Tracker:
[`PROGRESS-V2.4.md`](PROGRESS-V2.4.md)

**Rule:** Keep this file short — ideas as bullets, not specs. Active scope lives in the PRD
and tracker; historical requirements in [`archive/`](archive/).
Anything shipping to the field needs a **version bump** first (`VERSION.txt` + user-facing
`readMe.txt` / `CHANGELOG.txt`). Keep root [`CHANGELOG.txt`](../CHANGELOG.txt)
operator-focused — no docs/backlog links.

---

## Ideas / improvements

_Not scoped into 2.4. Promote to a PRD when one becomes the next version._

### Watch
- WebSocket / SSE vs poll (parked — adaptive poll covers most UX gain)
- Manager instance rollup helpers
- Remote bind / auth (explicitly out of the current security model — localhost only)

### Reporting (post-2.4)
- Keyword organize path (parked from V1)
- Driver type-in search (parked — picker is enough for most sites)
- **Omit modules with zero hits.** If a module card / report section has nothing to show,
  drop it rather than printing an empty one. Applies to text, HTML and the dashboard.
  Note this **reverses** a 2.4 decision (`PROGRESS-V2.4.md` §10.2, "a zeroed section is a
  useful triage answer") — V1.3 already omitted them, so this returns to that behaviour.
  Watch the §10.1 batch≡dashboard check when doing it: both renderers must drop the same
  sections, which is what `Get-ReportSections` is for.

### Performance (post-2.4)
_Scan cost was never a 2.4 regression — the 2.3 baseline was measured on a much faster
desktop, and the apparent slowdown was the move to a slower laptop. See `PROGRESS-V2.4.md`
4A/4F for the back-to-back A/B on one machine._
- **Inline the four hot helpers into `Process-LogLine`**: `Add-Pattern` (55 % of the
  function), `Ensure-Minute` / `Ensure-MinuteArea` (20 %), `Get-PerfCategory` (15 %),
  `Normalize-Message` (13 %). PowerShell call overhead dominates the scan — removing ~8
  calls per line should cut it by roughly 70 %. Same trick 4A used on the rule loop.
  Mechanical but ugly; the §10.1 byte-identical check makes it verifiable.
- **Add `Scope` to rules that only fire for one component.** 18 of 23 rules are unscoped, so
  they run a regex on every parsed line; that costs 13-19 % (4A A/B). This one is a data edit
  in `PvssRules.ps1`, not a code change.

### Detection / parsing
- Fuller multi-line log reassembly (beyond single-header-line parse)
- Rule-engine extensions, if the field asks: cross-line correlation, rate thresholds over a
  time window. Neither is expressible in the 2.4 rule table.

---

## Parking lot

_One-liners as they come up in the field:_

-
