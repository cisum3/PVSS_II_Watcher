Development docs & test assets (not shipped in field packages)
==============================================================

  BACKLOG.md          Living ideas / improvements (keep short)
  PRD-V2.4.md         Spec for 2.4 (locked; §12.13 amended 2026-09-08)
  PROGRESS-V2.4.md    Build tracker for 2.4 — 4A-4F done, 4G in progress
  Test-WatchSelf.ps1  Self-test harness; -Phase All = 40 checks
  _*.ps1              Throwaway verification harnesses (see PROGRESS 4F)
  archive\            Frozen PRD + PROGRESS history (do not extend)
  PVSS_II_Examples\   Sample / site logs for local testing only
  config / progs      Optional site context from sample projects (dev only)

Field package root (user-facing): Run-Watch.cmd + Run-Report.cmd +
  Run-Report-Interactive.cmd + readMe.txt + CHANGELOG.txt + Watch\ (ui, host,
  PvssRules.ps1). There is no OfflineAnalyze\ in 2.4.
Shipped baseline: Watch 2.3 / OfflineAnalyze 1.3 (zipped 2026-09-07).
In progress: 2.4 — declarative rule engine; OfflineAnalyze absorbed as
report mode. Docs and VERSION.txt are bumped; Watch\OfflineAnalyze\ is still
on disk and the field zip is not built yet.
Keep readMe.txt / CHANGELOG.txt operator-focused (no refs to docs\ or the
internal backlog).
