Development docs & test assets (not shipped in field packages)
==============================================================

  BACKLOG.md          Living ideas / improvements (keep short)
  Test-WatchSelf.ps1  Self-test harness; -Phase All / Assets / Rules / Report
  archive\            Frozen PRD + PROGRESS history + OfflineAnalyze 1.3 (do not extend)
  PVSS_II_Examples\   Sample / site logs for local testing only

Shipped baseline: Watch **0.4.0** (2026-09-12) — one tool, two modes (dashboard + report);
OfflineAnalyze absorbed. Spec / tracker: archive\PRD-V0.4.md · archive\PROGRESS-V0.4.md.
Frozen OfflineAnalyze 1.3: archive\OfflineAnalyze\.

Field package root (user-facing): Run-Watch.cmd + Run-Report.cmd +
  Run-Report-Interactive.cmd + readMe.txt + CHANGELOG.txt + Watch\ (ui, host,
  PvssRules.ps1). No OfflineAnalyze\ in the field package.
Keep readMe.txt / CHANGELOG.txt operator-focused (no refs to docs\ or the
internal backlog).
