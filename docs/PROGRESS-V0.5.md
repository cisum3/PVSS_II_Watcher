# PROGRESS-V0.5 (in progress)

**Date:** 2026-09-13  
**Baseline:** Watch 0.4.0 → DesigoLogWatcher 0.5.0

## Completed

| Task | Notes |
|---|---|
| **T1–T7, T9, T10, T13** | Core port + charts/tail (confirm pending) |
| **API depth** | Lifecycle, module sections, project cycles |
| **Bugfix pack** | Area-filtered manager patterns; last-N from log EOF; HTML KPI coercion; BACnet Failed-on-top |
| **HTML report parity** | Rich detections; pattern First/Last/Example; BACnet OK sample; mgr-health; format=`html`. **Accepted delta:** `N0` commas. |
| **Tie-break + pulse 304** | Count-desc then key-asc tops; `/api/pulse` 304 for `sinceGeneration` (status age). |
| **Text + JSON reports** | Full text port; JSON key/KPI parity; `-Format Json`. |
| **Shutdown / port bump** | Dispose waits for listen loop; ProcessExit cleanup; yellow WARNING when PreferredPort is busy and host binds N+1. |
| **Apogee HTML** | Sample + Top PPCL table + device/trend counts restored. |

## Tests

`dotnet test` — **74** passed. Staging publish: `Watch\_pub_new\DesigoLogWatcher.exe` (running exe locks `Watch\DesigoLogWatcher.exe`).

## Remaining

- Restart 0.5 from staging (or republish after stop) to pick up text/JSON/304/tie-break
- Confirm UI + reports vs 0.4.0
- **T8** §2.1 / Driver organize deep-dive
- **T11** packaging / VERSION 0.5.0
- **T12** formal corpus harness

## Inventory

[`docs/INVENTORY-V0.5.md`](INVENTORY-V0.5.md)
