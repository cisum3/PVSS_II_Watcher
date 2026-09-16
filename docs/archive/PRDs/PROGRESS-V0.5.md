# PROGRESS-V0.5 — shipped checklist

**Date:** 2026-09-14  
**Baseline:** Watch 0.4.0 → DesigoLogWatcher **0.5.0**  
**Gate rules:** [`PRD-V0.5.md`](PRD-V0.5.md) §9.2.  
**Status:** Shipped as Watch **0.5.0** (2026-09-14).

## Completed

| Task / pack | Notes |
|---|---|
| **T1–T7, T9** | Core port through HTTP API |
| **T8 §2.1** | Multi-scope + BACnetDrv families + manager ranges; unit tests green; C1P deltas recorded |
| **T10 / T13** | Dashboard path operator-verified (B1–B4); B5 rotation waived |
| **T11** | Launchers → exe; `VERSION` / `readMe` / CHANGELOG = **0.5.0** |
| **T12** | A-gate + ~50 MB perf (524 s → 6 s); formal API harness → **0.5.1** |
| Reports / interactive / browser / pulse race / shutdown | As prior sessions |

## Tests

`dotnet test` — **83** passed (incl. T8 multi-scope / BACnetDrv / DevGate vs ShipGate).

---

## §9.2 verification checklist

### A. Dev gate — non-interactive snapshots — **pass** (A1–A4)

### B. Dashboard live path

| # | Status | Notes |
|---|---|---|
| B1–B4 | **pass** | Operator 2026-09-14 |
| B5 rotation / truncation | **waived** | Low risk; unit `Truncation_ReseeksToStart`; not field-tested (Desigo truncate behavior unclear) |

### C. API contract

| # | Status | Notes |
|---|---|---|
| C1 formal key-diff | **waived → 0.5.1** | Live top-level compare on Test.log (see below). No UI breakage found. |
| C2 snapshot formats | **pass** | html/text/json 200 |

**C1 findings (2026-09-14, Test.log @8784/8785):**

| Surface | Diff | Ship impact |
|---|---|---|
| `/api/health` | 0.5 **adds** `loadProgressPct`, `loadMessage` | Additive; fine |
| `/api/pulse` | 0.5 **missing** `areaOtherNames` (0.4 has it; state still tracks names) | UI does **not** read this key → slip to **0.5.1** |
| `/api/section` bacnet/cns/coho/apogee/detections | Top-level + payload keys **match** | OK |
| `/api/manager` | Top-level keys **match** | OK |

Artifacts: `docs/_parity_gate/api_keys/keydiff.txt`.

### D. Config / packaging

| # | Status |
|---|---|
| D1–D3 | **pass** |
| D4 VERSION / CHANGELOG / readMe | **pass** (0.5.0) |

### E. Ship gate

| # | Status | Notes |
|---|---|---|
| E1 T8 | **pass** | Tests + C1P expected deltas; operator OK with T8 |
| E2 perf | **pass** | 50.27 MB Entire Html: 0.4 **524 s**, 0.5 **~6 s** (~87×). No Entire-cache. |

### Expected ship-gate detection deltas (C1P Entire)

| Id | ShipGate vs 0.4 |
|---|---|
| `bacnetDrv.trendOverflow` / `trendSeq` | **+133** / **+133** (new) |
| `bacnetDrv.queryTimeout` | **+49** (new) |
| `bacnetDrv.alertId` / `getDataFail` | 0 on C1P |
| `trend.seqLess` | Multi-scoped (no C1P count change) |
| Apogee scopes | Unchanged |

---

## Gaps / deferred

- **Entire-cache** — out of 0.5.0  
- **`areaOtherNames` on pulse** — 0.5.1  
- Formal automated API schema harness — 0.5.1  
- Absolute-window options label wording; unparsed ±1 — waived  

## Inventory

[`INVENTORY-V0.5.md`](INVENTORY-V0.5.md)
