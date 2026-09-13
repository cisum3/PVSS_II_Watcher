# Development docs & test assets

Not shipped in field packages.

| Path | Purpose |
|------|---------|
| [`BACKLOG.md`](BACKLOG.md) | Living ideas / improvements (keep short) |
| [`PRD-V0.5.md`](PRD-V0.5.md) | Draft spec for 0.5.0 C# single-file runtime rewrite |
| [`Test-WatchSelf.ps1`](Test-WatchSelf.ps1) | Self-test harness; `-Phase All` / `Assets` / `Rules` / `Report` |
| [`archive/`](archive/) | Frozen PRD + PROGRESS history + OfflineAnalyze 1.3 (do not extend) |
| `PVSS_II_Examples\` | Sample / site logs for local testing only |

**Shipped baseline:** Watch **0.4.0** (2026-09-12) — one tool, two modes (dashboard + report); OfflineAnalyze absorbed.

**In progress:** **0.5.0** pre-finalized [`PRD-V0.5.md`](PRD-V0.5.md) — direct port of 0.4.0 + §2.1 exceptions. See [`BACKLOG.md`](BACKLOG.md).

Spec / tracker for 0.4.0: [`archive/PRD-V0.4.md`](archive/PRD-V0.4.md) · [`archive/PROGRESS-V0.4.md`](archive/PROGRESS-V0.4.md).

Frozen OfflineAnalyze 1.3: [`archive/OfflineAnalyze/`](archive/OfflineAnalyze/).

## Field package (user-facing)

Root of the repo (and field zip):

- `Run-Watch.cmd` + `Run-Report.cmd` + `Run-Report-Interactive.cmd`
- `readMe.txt` + `CHANGELOG.txt`
- `Watch\` (ui, host, `PvssRules.ps1`)

No `OfflineAnalyze\` in the field package.

Keep `readMe.txt` / `CHANGELOG.txt` operator-focused (no refs to `docs\` or the internal backlog). GitHub overview: root [`README.md`](../README.md).
