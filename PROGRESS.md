# Implementation Progress — PVSS Log Analyzer

**Release: V1.1** (batch triage tool — frozen for packaging)

Tracks work against `PRD.md` (draft v5) plus post-v1 backlog through V1.1.

| Status | Meaning |
|--------|---------|
| **Built** | Implemented in code by the agent; not yet verified by you |
| **Confirmed** | You have run it and confirmed it works |

---

## Phases (v1 PRD) — complete

| Phase | Description | Built | Confirmed |
|-------|-------------|:-----:|:---------:|
| 1–6 | Foundation through time window / docs | yes | yes |

---

## Post-v1 backlog (through V1.1)

| Item | Built | Confirmed | Notes |
|------|:-----:|:---------:|-------|
| BACnet last-known status (ended Failed vs OK) | yes | yes | |
| BACnet status activity table (Failed/OK/flips/last) | yes | yes | Merged former Failed + flapping lists; flapper count in summary |
| Apogee module (thin) | yes | yes | CoHo.Apogee*/Orch.Apogee*; UpdatePoints + top PPCL |
| Driver type-in search | | | Parked — prompted picker is enough |
| Keyword organize path | | | Parked — leave on backlog |
| First/last timestamp per top pattern | yes | yes | Severity, CNS, and Path D pattern lists |
| Optional HTML report | yes | yes | -Format Text\|Html\|Both; Run-Analyze.cmd defaults to Html |
| UTF-8 log encoding | yes | yes | Fixes Â« mojibake for « » markers |
| Hourly volume cap | yes | yes | >25 hours: recent 24 + top 10 busiest |

---

## Deferred to V2 (not in V1.1)

| Item | Notes |
|------|--------|
| Live tail / watch | Console or PowerShell host + Chrome UI |
| PowerShell host + Chrome dashboard | Charts, live updates, richer triage |
| Area (SYS/IMPL) breakdown | |
| Manager instance rollup | |

---

## V1.1 package contents

Zip for field use (do not include PRD/PROGRESS/examples/logs):

- `Analyze-PvssLog.ps1`
- `Run-Analyze.cmd`
- `Run-Analyze-Interactive.cmd`
- `readMe.txt`
- `VERSION.txt`

---

## Changelog

| Date | Event |
|------|--------|
| 2026-09-04 | v1 phases 1–6 complete |
| 2026-09-04 | BACnet last-known ended Failed/OK + flapping list (3+ flips) |
| 2026-09-04 | BACnet: merge Failed/flapping into one status-activity table |
| 2026-09-04 | Apogee thin module (UpdatePoints / PPCL names) |
| 2026-09-04 | First/last timestamp on top patterns; UTF-8 read; HTML reports |
| 2026-09-04 | Run-Analyze.cmd defaults to HTML; TOC/scroll HTML fixes |
| 2026-09-05 | **V1.1 tagged** — batch triage freeze; V2 = live web dashboard |
