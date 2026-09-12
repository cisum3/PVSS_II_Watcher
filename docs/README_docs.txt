Development docs & test assets (not shipped in field packages)
==============================================================

  BACKLOG.md          Living ideas / improvements (keep short)
  PRD-V0.4.md         Spec for 0.4.0 (locked; §12.13 amended 2026-09-08)
  PROGRESS-V0.4.md    Build tracker for 0.4.0 — 4A-4F done, 4G in progress
  Test-WatchSelf.ps1  Self-test harness; -Phase All / Assets / Rules / Report
  archive\            Frozen PRD + PROGRESS history (do not extend)
  PVSS_II_Examples\   Sample / site logs for local testing only

Field package root (user-facing): Run-Watch.cmd + Run-Report.cmd +
  Run-Report-Interactive.cmd + readMe.txt + CHANGELOG.txt + Watch\ (ui, host,
  PvssRules.ps1). There is no OfflineAnalyze\ in 0.4.0.
Shipped baseline: Watch 0.3.0 / OfflineAnalyze 1.3 (zipped 2026-09-07).
In progress: 0.4.0 — declarative rule engine; OfflineAnalyze absorbed as
report mode. Docs and VERSION.txt are bumped; Watch\OfflineAnalyze\ is still
on disk and the field zip is not built yet.
Keep readMe.txt / CHANGELOG.txt operator-focused (no refs to docs\ or the
internal backlog).
