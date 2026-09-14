# PROGRESS-V0.5 (in progress)

**Date:** 2026-09-13  
**Baseline:** Watch 0.4.0 → DesigoLogWatcher 0.5.0  
**Gate rules:** [`PRD-V0.5.md`](PRD-V0.5.md) §9.2 (dev gate vs ship gate, allowlist).  
**This file:** executable pass/fail tracker — tick rows here; do not duplicate the gate definition.

## Completed

| Task / pack | Notes |
|---|---|
| **T1–T7, T9** | Core port, config/CLI, parser, analysis, rules (single-scope), HTTP API surface |
| **API depth** | Lifecycle, module sections, project cycles |
| **Bugfix pack** | Area-filtered manager patterns; last-N from log EOF; HTML KPI coercion; BACnet Failed-on-top |
| **HTML / text / JSON reports** | Rich HTML; full text; JSON key/KPI parity. **`-Format All`** = text+html+json (`Both` → `All`). **Accepted delta:** `N0` commas |
| **Interactive report** | Window E/H/W (incl. absolute From/To), organize A/S/D/Q, severity/driver picks, format T/H/J/A — exercised on `PVSS_II_C1P.log` |
| **Tie-break + pulse 304** | Count-desc then key-asc tops; `/api/pulse` 304 for `sinceGeneration` |
| **UI pulse race guard** | Drop overlapping/stale mid-load pulses (no HTTP cache layer) |
| **Shutdown / port bump** | Dispose waits for listen loop; ProcessExit cleanup; yellow WARNING when PreferredPort busy |
| **Apogee HTML** | Sample + Top PPCL table + device/trend counts |

## Tests

`dotnet test` — **76** passed. Publish: `dotnet publish src\DesigoLogWatcher\DesigoLogWatcher.csproj -c Release -o Watch\` → `Watch\DesigoLogWatcher.exe`.

Artifacts from interactive/report probes: `docs\_interactive_test\` (local only; not a ship artifact).

---

## §9.2 verification checklist (before T8 / T11 / T12)

Mark each row `pending` → `pass` / `fail` / `waived` with a short note. Owners map to Taskmaster.

### A. Dev gate — non-interactive snapshots (T12 / confirm T7)

_Single-scope rules (T8 still off). Same log + window vs 0.4.0. Allowlist: `meta.generated`, version/tool banner, `gen`, port/url, `N0` commas._

| # | Check | Owner | Status | Notes |
|---|---|---|---|---|
| A1 | `-Report -Entire -Format All` on `PVSS_II_C1P.log` — HTML/text structure + KPI counts vs 0.4 | T12 | pending | |
| A2 | Same on a second corpus file (BACnet/Apogee-heavy) — sections + Detections order | T12 | pending | §9.3 |
| A3 | Organize `Severity` + `Driver` non-interactive vs 0.4 (shape + deep-dive) | T12 | pending | |
| A4 | Absolute `-From`/`-To` and `-LastHours` non-interactive parity | T12 | pending | Interactive W already probed on C1P |

### B. Dashboard live path (T10 / T13)

| # | Check | Owner | Status | Notes |
|---|---|---|---|---|
| B1 | Start → catch-up % → tail; charts + findings settle (no loading flicker) | T10 | pending | One host, one tab |
| B2 | Pause / resume / restart + config reload | T10 | pending | |
| B3 | `setWindow` entire ↔ last-N; Start writes `LogPath` to config | T10 | pending | Report must not write LogPath |
| B4 | Chart series under sev/area filters; HTML snapshot download from UI | T13 | pending | organize All/Severity/Driver |
| B5 | Log rotation / truncation restart path | T10 | pending | |

### C. API contract on a fixed fixture (T12)

| # | Check | Owner | Status | Notes |
|---|---|---|---|---|
| C1 | `/api/health`, `/api/pulse`, `/api/section/*`, `/api/manager` — same keys/types vs 0.4 (or frozen fixture) | T12 | pending | PRD §9.2.2 |
| C2 | `/api/snapshot` download formats html\|text\|json | T12 | pending | |

### D. Config / discovery / packaging pre-reqs

| # | Check | Owner | Status | Notes |
|---|---|---|---|---|
| D1 | Invalid config self-corrects; runtime reload skips port/browser keys | T2/T10 | pending | |
| D2 | Log auto-discover order + `FileShare.ReadWrite` while writer holds file | T4/T12 | pending | |
| D3 | Launchers call `DesigoLogWatcher.exe` (not PS) | T11 | pending | After A–C green |
| D4 | `VERSION.txt` / CHANGELOG / field layout 0.5.0 | T11 | pending | |

### E. After single-scope gate is green

| # | Check | Owner | Status | Notes |
|---|---|---|---|---|
| E1 | **T8** multi-scope + BACnet-scoped families — record **expected** count diffs in this file | T8 | pending | Ship gate, not byte-identical |
| E2 | **T12** perf on ~50 MB corpus; Entire-cache only if §4.6 warrants | T12 | pending | No hard time ceiling |

### Already probed (do not re-litigate unless a gate row fails)

- Interactive report prompts (E/H/W absolute, organize, format All) on C1P  
- Report HTML/text/JSON content shapes for All / Severity / Driver  
- KPI match 0.4 on C1P interactive defaults / severity (SEVERE=10,145 etc.)  
- Accepted formatting delta: thousand-separator `N0`

---

## Remaining work order

1. Execute checklist **A → B → C → D** (single-scope / 0.4-like).  
2. Confirm with user → mark T10 / T13 / related packs done.  
3. **T8** (§2.1) → record expected deltas here.  
4. **T11** launchers + VERSION.  
5. **T12** formal harness + perf + Entire-cache decision.

## Gaps tracked elsewhere

- **`Browser` chrome/msedge/path** — config parsed; open still shell-default → [`BACKLOG.md`](BACKLOG.md) 0.5.1 if not fixed before ship.  
- **Entire-cache** — deferred pending T12 measurement (PRD §4.6).  
- Stale-tab + port-bump operator confusion — mitigated; see BACKLOG known bugs.

## Inventory

[`docs/INVENTORY-V0.5.md`](INVENTORY-V0.5.md)
