# Development docs & test assets

Not shipped in field packages.

| Path | Purpose |
|------|---------|
| [`BACKLOG.md`](BACKLOG.md) | Living ideas / improvements (keep short) |
| [`archive/`](archive/) | Frozen PRDs, progress trackers, prior releases |
| `PVSS_II_Examples\` | Sample / site logs for local testing only (gitignored) |

**Shipped baseline:** Watch **0.5.0** (2026-09-14) — `DesigoLogWatcher.exe` single-file host.

**Next:** **0.5.1** items in [`BACKLOG.md`](BACKLOG.md).

Archived 0.5.0 spec/tracker: [`archive/PRD-V0.5.md`](archive/PRD-V0.5.md) · [`archive/PROGRESS-V0.5.md`](archive/PROGRESS-V0.5.md) · [`archive/INVENTORY-V0.5.md`](archive/INVENTORY-V0.5.md).

## Field package (user-facing)

Repo / field-zip root:

- `Run-Watch.cmd` · `Run-Report.cmd` · `Run-Report-Interactive.cmd`
- `readMe.txt` · `CHANGELOG.txt`
- `Watch\` → `DesigoLogWatcher.exe`, `VERSION.txt`, `watch-config.txt`, `ui\`

No PowerShell host, no `src\`, no `docs\` in the field zip.

Keep `readMe.txt` / `CHANGELOG.txt` operator-focused. GitHub: root [`README.md`](../README.md) · [`CHANGELOG.md`](../CHANGELOG.md).

**Dev rebuild:** `dotnet publish src\DesigoLogWatcher\DesigoLogWatcher.csproj -c Release -o Watch\` then delete `Watch\DesigoLogWatcher.pdb` if present. Tests: `dotnet test src\DesigoLogWatcher.Tests\DesigoLogWatcher.Tests.csproj -c Release`.
