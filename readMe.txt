PVSS / WinCC OA Log Analyzer — Watch (V2)
========================================
Version: 2.0

What this folder is
-------------------
Field package for the **live dashboard**. Root stays simple:

  Run-Watch.cmd                  Double-click launcher (opens browser)
  readMe.txt                     This file
  Watch\                         Runtime (host, UI, optional OfflineAnalyze)

  Watch\Watch-PvssLog.ps1        Localhost host (read-only log tail + JSON APIs)
  Watch\ui\                      Dashboard (Siemens dark theme + Chart.js)
  Watch\VERSION.txt              Watch version
  Watch\watch-log-path.example.txt
                                 Copy to Watch\watch-log-path.txt for path prefill
  Watch\OfflineAnalyze\                   Optional V1.1 offline analyzer

How to run
----------
1. Keep this folder outside the WinCC OA project log directory.
2. Double-click Run-Watch.cmd
   (or: powershell -File .\Watch\Watch-PvssLog.ps1).
3. Enter / confirm the live PVSS_II.log path → Start.
4. Use Pause / Resume / Restart; change time window and severity filters as needed.
5. Snapshot downloads an HTML report of the **current** analysis (browser download only).
6. Ctrl+C in the host window stops the server.

The live log is opened with FileAccess.Read only (WinCC may still append).

Batch (offline) analyzer — V1.1
-------------------------------
  Watch\OfflineAnalyze\Run-Analyze.cmd
  Watch\OfflineAnalyze\Run-Analyze-Interactive.cmd
  Watch\OfflineAnalyze\readMe.txt

Field zip (ship this, not the whole repo)
-----------------------------------------
Include:
  Run-Watch.cmd
  readMe.txt
  Watch\   (Watch-PvssLog.ps1, VERSION.txt, ui\, watch-log-path.example.txt,
            and optionally OfflineAnalyze\)

Exclude:
  docs\ (PRD / PROGRESS / example logs)
  Test-WatchSelf.ps1
  .git\, .taskmaster\
  Watch\watch-log-path.txt (site-local path; do not ship)
  *.log / *.bak / archives


Dev docs & test assets (not for field zips)
------------------------------------------
  docs\PRD.md
  docs\PRD-V2.md
  docs\PROGRESS.md
  docs\PROGRESS-V2.md
  docs\PVSS_II_Examples\     sample logs for local testing
  Test-WatchSelf.ps1         Dev self-test (optional)
