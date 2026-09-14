# Siemens Desigo CC PVSS_II Log Analyzer

**Version:** 0.5.0 · **Author:** Cisum

Windows-only triage toolkit for large Siemens Desigo CC `PVSS_II.log` files. Single-file self-contained host (`DesigoLogWatcher.exe`) — no separate .NET install, no PowerShell required for analysis.

## One tool, two modes

| Mode | Launcher | What it does |
|------|----------|--------------|
| **Dashboard** | `Run-Watch.cmd` | Live localhost UI: open a growing log read-only, catch up a time window, tail new lines, filter by severity, browse modules/patterns, download a snapshot |
| **Report** | `Run-Report.cmd` | One-shot scan that writes an HTML and/or text report and exits — no dashboard, browser, or network port |

Both modes share the same analyzer. A report is a snapshot without opening the dashboard first.

## Quick start

**Dashboard**

1. Double-click `Run-Watch.cmd`
2. Confirm the live log path (or set `LogPath=` in `Watch\watch-config.txt`)
3. Choose a time window and **Start**

**Report**

1. Place `PVSS_II.log` next to the launchers, or pass `-LogPath`
2. Double-click `Run-Report.cmd` (or `Run-Report-Interactive.cmd` for prompts)

## Requirements

- Windows x64
- A `PVSS_II.log` (or `.log.bak`) to analyze
- A browser on the same PC for the live dashboard (not needed for reports)

## Repository layout

```text
Run-Watch.cmd / Run-Report*.cmd   Field launchers
readMe.txt                        Operator guide (ships in field zips)
CHANGELOG.txt                     Release notes (ships in field zips)
Watch\                            Runtime (exe, UI, config, VERSION)
src\DesigoLogWatcher\             C# source (dev only)
docs\                             Dev docs + archive (not in field zips)
```

Field packages are operator-focused: use **[`readMe.txt`](readMe.txt)** for full setup, switches, detections, and config details. See **[`CHANGELOG.txt`](CHANGELOG.txt)** (or **[`CHANGELOG.md`](CHANGELOG.md)** on GitHub) for what changed per release.

## Development docs

- [`docs/BACKLOG.md`](docs/BACKLOG.md) — living ideas (0.5.1+)
- [`docs/README.md`](docs/README.md) — what’s in `docs\`
- [`docs/archive/`](docs/archive/) — frozen PRDs / progress / prior field zip (0.4.0)

## Notes

- The live log is opened read-only (`FileAccess.Read`); WinCC may keep appending.
- The dashboard binds to `127.0.0.1` only. Report mode binds nothing.
- Do not install or run this toolkit inside the project log folder.
- This is a triage aid, not a substitute for Siemens Desigo CC support.
