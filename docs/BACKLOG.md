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

### Detection / parsing
- Fuller multi-line log reassembly (beyond single-header-line parse)
- Rule-engine extensions, if the field asks: cross-line correlation, rate thresholds over a
  time window. Neither is expressible in the 2.4 rule table.

---

## Parking lot

_One-liners as they come up in the field:_

-
