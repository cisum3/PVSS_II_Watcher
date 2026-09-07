# Future backlog — PVSS Log Analyzer

**Shipped baseline:** Watch **2.3** · OfflineAnalyze **1.3** · Author: Cisum (2026-09-07)  
**In progress:** nothing — 2.3 / 1.3 is zipped and in the field  
**Next field bump:** Watch **2.4** (shared parser library — see below)

**Rule:** Keep this file short. Add ideas as bullets. Do **not** grow archived PRDs/PROGRESS.
Any change that ships to the field needs a **version bump** first (Watch and/or OfflineAnalyze `VERSION.txt` + user-facing `readMe.txt` / `CHANGELOG.txt`).

Historical requirements / build trackers: [`archive/`](archive/).
User-facing history: root [`CHANGELOG.txt`](../CHANGELOG.txt) (keep operator-focused — no docs/backlog links).

---

## Next major: Watch 2.4 — shared parser library

**Decided 2026-09-07. Unblocked — 2.3 / 1.3 shipped the same day, so this is ready to plan.**

- One shared parser library used by **both** Watch and OfflineAnalyze — no duplicated
  detection logic. Plain dot-sourced `.ps1` (no module/manifest; PS 5.1, no installs).
- Full scope (all three layers):
  1. Rules + helpers — header regex, normalize regexes, perf categories, `Add-Pattern`,
     lifecycle cycles, duration formatting
  2. Line classify — `ConvertFrom-PvssLogLine` + `Get-PvssDetections` (rule-id hits)
  3. Shared accumulator state — OfflineAnalyze adopts Watch's state shape, so a new
     counter is wired once (also gives Offline the area dimension)
- Prefix shared functions (`Pvss…`) so call sites can migrate one at a time.
- **OfflineAnalyze becomes an additional tool inside Watch.** The standalone flat-zip
  option for `OfflineAnalyze\` (noted in `archive/PROGRESS.md`) is **retired** — the
  field package is Watch, which includes OfflineAnalyze.
- Add a dev-only rule test harness fed by `PVSS_II_Examples\` so field feedback
  ("this line isn't detected") is cheap: add rule + test line, both tools pick it up.
- Driver: incoming feedback on desired features / refined detection.

---

## Ideas / improvements

### Watch (→ 2.4+)
- WebSocket / SSE vs poll (parked — adaptive poll covers most UX gain)
- Manager instance rollup helpers
- Remote bind / auth (explicitly out of current security model — localhost only)

### OfflineAnalyze
- Keyword organize path (parked from V1)
- Driver type-in search (parked — picker is enough for most sites)

### Shared / either
- Fuller multi-line log reassembly (beyond single-header-line parse)

---

## Parking lot

_Add one-liners here when something comes up in the field:_

-
