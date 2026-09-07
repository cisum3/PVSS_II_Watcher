# Future backlog — PVSS Log Analyzer

**Shipped baseline:** Watch **2.2** · OfflineAnalyze **1.2** · Author: Cisum (2026-09-06)  
**Next field bump:** Watch **2.3** (do not edit 2.2 behavior without a version bump)

**Rule:** Keep this file short. Add ideas as bullets. Do **not** grow archived PRDs/PROGRESS.
Any change that ships to the field needs a **version bump** first (Watch and/or OfflineAnalyze `VERSION.txt` + user-facing `readMe.txt` / `CHANGELOG.txt`).

Historical requirements / build trackers: [`archive/`](archive/).
User-facing history: root [`CHANGELOG.txt`](../CHANGELOG.txt) (keep operator-focused — no docs/backlog links).

---

## Ideas / improvements

### Watch (→ 2.3+)
- Project restart **cycle/uptime view** (replace flat up/shutdown/stopped list; uptime = up→shutdown, downtime = stopped→next up; Overview + snapshot)
- WebSocket / SSE vs poll (parked — adaptive poll covers most UX gain)
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
