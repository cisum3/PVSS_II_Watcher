# Future backlog — PVSS Log Analyzer

**Shipped baseline:** Watch **2.1** · OfflineAnalyze **1.2** · Author: Cisum (2026-09-06)  
**Current:** Watch **2.2** — feature-complete; documentation review before ship confirm

**Rule:** Keep this file short. Add ideas as bullets. Do **not** grow archived PRDs/PROGRESS.
Any change that ships to the field needs a **version bump** first (Watch and/or OfflineAnalyze `VERSION.txt` + readMes).

Historical requirements / build trackers: [`archive/`](archive/).

---

## Ideas / improvements

### Watch
- ~~Adaptive poll (fast while loading, RefreshSeconds after)~~ done in 2.2
- ~~Snapshot HTML: sticky section jumps + project restart timeline~~ done in 2.2
- ~~Snapshot closer Offline parity (module tables/samples; no hourly/INFO/driver deep-dive)~~ done in 2.2
- WebSocket / SSE vs poll (parked — adaptive poll covers most UX gain)
- ~~Overview project restart timeline (live)~~ done in 2.2
- ~~Area (SYS/IMPL/CTRL/PARAM/OTHER) filter chips~~ done in 2.2
- Manager instance rollup helpers
- Remote bind / auth (explicitly out of current security model — localhost only)

### OfflineAnalyze
- Keyword organize path (parked from V1)
- Driver type-in search (parked — picker is enough for most sites)

### Shared / either
- Shared parser library used by both Watch and OfflineAnalyze
- Fuller multi-line log reassembly (beyond single-header-line parse)

---

## Parking lot

_Add one-liners here when something comes up in the field:_

-
