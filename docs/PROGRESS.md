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

See [`PROGRESS-V2.md`](PROGRESS-V2.md) / [`PRD-V2.md`](PRD-V2.md) — live dashboard in progress.

Notable V2 backlog (tracked there): cache Entire analysis across window switches so returning to Entire does not full re-parse.

---

## V1.1 package contents

Zip for field use — batch-only package (do not include PRD/PROGRESS/examples/logs):

- `OfflineAnalyze\Analyze-PvssLog.ps1`
- `OfflineAnalyze\Run-Analyze.cmd`
- `OfflineAnalyze\Run-Analyze-Interactive.cmd`
- `OfflineAnalyze\readMe.txt`
- `OfflineAnalyze\VERSION.txt`

(Or zip the contents of `OfflineAnalyze\` as a flat V1.1 folder for sites that only need offline reports.)

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
| 2026-09-05 | `PRD-V2.md` **locked**; progress moves to [`PROGRESS-V2.md`](PROGRESS-V2.md) |
| 2026-09-05 | V1.1 tools moved under `OfflineAnalyze\` |
| 2026-09-05 | Dev docs (PRD/PROGRESS) moved under `docs\` |
| 2026-09-05 | Example logs under `docs\PVSS_II_Examples\` |
