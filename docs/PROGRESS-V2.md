# Implementation Progress — PVSS Log Analyzer V2

**Release target: V2.0** (PowerShell host + browser live dashboard)

Tracks work against locked [`PRD-V2.md`](PRD-V2.md).  
V1.1 batch tool remains under `batch\` (see [`PROGRESS.md`](PROGRESS.md)).

| Status | Meaning |
|--------|---------|
| **Built** | Implemented in code by the agent; not yet verified by you |
| **Confirmed** | You have run it and confirmed it works |

**Rule:** Confirm with you before marking an item **Confirmed** / phase done. Review the next phase before starting it.

---

## Phases

| Phase | Description | Built | Confirmed | Notes |
|-------|-------------|:-----:|:---------:|-------|
| **2A** | UI shell: sticky chrome, section nav, mock pulse/section/manager JSON | | | No live host yet |
| **2B** | Host serves `ui\` + `/api/pulse` + `/api/section` (+ generation/304, catch-up, filters) | | | |
| **2C** | Tail + poll rules + path/Start + Pause/Resume/Restart + rotate + on-page errors | | | Port try-next before browser open |
| **2D** | Charts, filters, §7.5 modules/patterns, any-manager drill-down, Desigo colors | | | |
| **2E** | Docs, package polish, `VERSION.txt` → 2.0; Snapshot if time else leave P1 | | | `batch\` layout done early |

---

## Layout (done early)

| Item | Built | Confirmed |
|------|:-----:|:---------:|
| V1.1 under `batch\` with own readMe/VERSION | yes | |
| Root Watch stub `readMe.txt` + `VERSION.txt` (`2.0-dev`) | yes | |
| `watch-log-path.example.txt` | yes | |
| `ui\` + `ui\vendor\` placeholder | yes | |
| Dev docs under `docs\` (PRD / PROGRESS) | yes | |
| Example/test logs under `docs\PVSS_II_Examples\` | yes | |

### 2A — UI shell + mocks

| Item | Built | Confirmed |
|------|:-----:|:---------:|
| `ui\index.html` / `app.css` / `app.js` skeleton | | |
| Sticky chrome (path, Start/Pause/Resume/Restart, window, severity, status) | | |
| Section nav: Overview, Patterns, Managers, BACnet, CNS, CoHo, Apogee, More | | |
| Mock `/api/pulse` + `/api/section` + `/api/manager` JSON shapes | | |
| Overview composition (findings, severity tiles, chart placeholders, manager strip) | | |
| Vendored chart library placeholder under `ui\vendor\` | | |
| Dark Siemens theme tokens in `app.css` (§7.0.1) | | |

### 2B — Host + pulse/section APIs

| Item | Built | Confirmed |
|------|:-----:|:---------:|
| `Watch-PvssLog.ps1` HttpListener on `127.0.0.1`, port try-next | | |
| Serve static `ui\` | | |
| Read-only log open (`FileAccess.Read` + share) | | |
| UTF-8 catch-up (rolling window from EOF; Entire from start) | | |
| In-memory window state + `generation` | | |
| `GET /api/pulse` (+ 304) | | |
| `GET /api/section?name=` (+ 304) | | |
| Host-side severity + manager filters | | |
| Loading/spinner flags during catch-up | | |

### 2C — Live control + resilience

| Item | Built | Confirmed |
|------|:-----:|:---------:|
| Path text box + Start; prefill; placeholder; persist `watch-log-path.txt` | | |
| Pause / Resume / Restart | | |
| Tail new bytes; UI pulse every 3 s with refresh rules (§8.4) | | |
| Rotate: auto-reopen, reset, banner | | |
| Missing/locked file → clear on-page error | | |
| `Run-Watch.cmd` opens browser to **bound** URL | | |
| `POST /api/logPath`, `POST /api/control`, `GET /api/health` | | |

### 2D — Full triage surface

| Item | Built | Confirmed |
|------|:-----:|:---------:|
| Chart 1 + Chart 2 (vendored, offline) | | |
| Desigo-aligned severity colors | | |
| Findings + severity counts (window-scoped) | | |
| Patterns by severity (Top N, first/last, samples) | | |
| BACnet / CNS / CoHo / Apogee module views (V1.1 parity) | | |
| Any manager listed + `/api/manager` Path D–style drill-down | | |
| BACnet INFO still tracked when INFO chip off | | |
| Perf + unparsed under More | | |

### 2E — Package + docs

| Item | Built | Confirmed |
|------|:-----:|:---------:|
| Move V1.1 into `batch\` with its own readMe/VERSION | yes | | Done early (pre-2A) |
| Root Watch `readMe.txt` + `watch-log-path.example.txt` | yes | | Stub readMe; expand in 2E |
| Root `VERSION.txt` → 2.0 | | | Currently `2.0-dev` |
| Snapshot export (or explicitly deferred to P1) | | |
| Field zip contents documented (exclude PRD/PROGRESS/examples/logs) | | |

---

## P1 / Deferred (not blocking 2.0 MVP)

| Item | Priority | Notes |
|------|----------|-------|
| Snapshot HTML/JSON from live payload | P1 | |
| Adjustable poll interval; preferred `-Port` UX polish | P1 | Port fallback already P0 |
| Catch-up / Entire **%** progress | P1 | Spinner is P0 |
| WebSocket/SSE | Deferred | |
| Area (SYS/IMPL); manager instance rollup | Deferred | |
| Shared parser library batch+Watch | Deferred | Copy/adapt logic for MVP |
| Full .NET multi-line reassembly | Deferred | |
| Keyword organize; remote bind/auth | Deferred | |

---

## Changelog

| Date | Event |
|------|--------|
| 2026-09-05 | `PRD-V2.md` locked; `PROGRESS-V2.md` created |
| 2026-09-05 | Locked: sectioned UI; pulse/section API; any-manager drill-down |
| 2026-09-05 | UI theme: Siemens palette + dark surfaces (§7.0.1); Desigo severity retained |
| 2026-09-05 | Repo layout: V1.1 → `batch\`; `ui\`, watch-log-path.example, root 2.0-dev stubs |
| 2026-09-05 | Dev docs moved to `docs\` (PRD / PROGRESS) |
| 2026-09-05 | Example/test logs under `docs\PVSS_II_Examples\` |
