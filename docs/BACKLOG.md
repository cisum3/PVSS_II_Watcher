# Future backlog — PVSS Log Analyzer

**Shipped baseline:** Watch **2.1** · OfflineAnalyze **1.2** · Author: Cisum (2026-09-06)  
**In progress / next ship:** Watch **2.2** — `watch-config.txt` (Tier A+B; replaces watch-log-path)

**Rule:** Keep this file short. Add ideas as bullets. Do **not** grow archived PRDs/PROGRESS.
Any change that ships to the field needs a **version bump** first (Watch and/or OfflineAnalyze `VERSION.txt` + readMes).

Historical requirements / build trackers: [`archive/`](archive/).

---

## Ideas / improvements

### Watch
- WebSocket/SSE instead of polling (optional)
- Area (SYS/IMPL) filter; manager instance rollup helpers
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
