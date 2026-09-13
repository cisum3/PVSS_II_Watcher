# PROGRESS-V0.5 (in progress)

**Date:** 2026-09-13  
**Baseline:** Watch 0.4.0 → DesigoLogWatcher 0.5.0

## Completed

| Task | Notes |
|---|---|
| **T1–T7, T9, T10, T13** | Core port + charts/tail (confirm pending) |
| **API depth** | Lifecycle, module sections, project cycles |
| **Bugfix pack** | Area-filtered manager patterns; last-N from log EOF; HTML KPI coercion; BACnet Failed-on-top |
| **HTML report parity (side-by-side)** | Rich detections (badges/spans/buckets/measures); pattern First/Last/Example; BACnet OK sample + activity heading; mgr-health sort+copy+unblock sample; CNS-related title; format=`html` on snapshot download. **Accepted delta:** thousand-separator commas (`N0`). |

## Tests

`dotnet test` — **72** passed. Published `Watch\DesigoLogWatcher.exe`.

## Remaining

- Confirm UI + new HTML snapshot vs 0.4.0
- **T8** §2.1 / Driver organize deep-dive
- **T11** packaging / VERSION 0.5.0
- **T12** formal corpus harness

## Inventory

[`docs/INVENTORY-V0.5.md`](INVENTORY-V0.5.md)
