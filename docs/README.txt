Development docs & test assets (not shipped in field packages)
==============================================================

  BACKLOG.md          Living ideas / improvements (keep short)
  PRD-V2.4.md         Active spec (locked): rule engine + Watch absorbs OfflineAnalyze
  PROGRESS-V2.4.md    Active build tracker for Watch 2.4
  Test-WatchSelf.ps1  Self-test harness (needs $Root repair after move — see PRD 4.7)
  archive\            Frozen PRD + PROGRESS history (do not extend)
  PVSS_II_Examples\   Sample / site logs for local testing only
  config / progs      Optional site context from sample projects (dev only)

Field package root (user-facing): Run-Watch.cmd + readMe.txt + CHANGELOG.txt
  + Watch\ (ui, host, OfflineAnalyze).
Shipped baseline: Watch 2.3 / OfflineAnalyze 1.3 (zipped 2026-09-07).
Next up: Watch 2.4 — declarative rule engine; Watch absorbs OfflineAnalyze and
OfflineAnalyze\ is removed from the field package (PRD-V2.4.md, locked).
Bump VERSION + user CHANGELOG before the next field zip. Keep readMe.txt /
CHANGELOG.txt operator-focused (no refs to docs\ or internal backlog).
