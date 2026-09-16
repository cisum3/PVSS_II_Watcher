# Development docs & test assets

Not shipped in field packages.

| Path | Purpose |
|------|---------|
| [`BACKLOG.md`](BACKLOG.md) | Living ideas / improvements (keep short) |
| [`archive/`](archive/) | Frozen specs, trackers, and prior field builds |
| `PVSS_II_Examples\` | Sample / site logs for local testing only (gitignored) |

**Shipped baseline:** Watch **0.5.0** (2026-09-14) — `DesigoLogWatcher.exe` single-file host.

**Next:** **0.5.1** items in [`BACKLOG.md`](BACKLOG.md).

### `archive/` layout

| Path | Purpose |
|------|---------|
| [`archive/PRDs/`](archive/PRDs/) | Frozen PRD + PROGRESS docs (V1 → V0.5) |
| [`archive/Old Builds/`](archive/Old%20Builds/) | Field zips (and any extracted prior packages) |
| [`archive/INVENTORY-V0.5.md`](archive/INVENTORY-V0.5.md) | 0.4→0.5 contract inventory |
| [`archive/README.md`](archive/README.md) | Archive index |

## Field package (user-facing)

Repo / field-zip root:

- `Run-Watch.cmd` · `Run-Report.cmd` · `Run-Report-Interactive.cmd`
- `readMe.txt` · `CHANGELOG.txt` · `LICENSE` (MIT)
- `Watch\` → `DesigoLogWatcher.exe`, `VERSION.txt`, `watch-config.txt`, `ui\`

No PowerShell host, no `src\`, no `docs\` in the field zip.

Keep `readMe.txt` / `CHANGELOG.txt` operator-focused. GitHub: root [`README.md`](../README.md) · [`CHANGELOG.md`](../CHANGELOG.md).

**Dev rebuild:** `dotnet publish src\DesigoLogWatcher\DesigoLogWatcher.csproj -c Release -o Watch\` then delete `Watch\DesigoLogWatcher.pdb` if present. Tests: `dotnet test src\DesigoLogWatcher.Tests\DesigoLogWatcher.Tests.csproj -c Release`.
