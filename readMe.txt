PVSS / WinCC OA Log Analyzer
============================
Version: 2.2 (live Watch)  |  OfflineAnalyze: 1.2
Author: Cisum

What this is
------------
A Windows-only triage toolkit for large PVSS_II.log files (WinCC OA / GMS).

  Watch (2.2)            Live localhost dashboard: open a growing log read-only,
                         catch up a time window, tail new lines, filter by
                         severity, browse modules/patterns, download a snapshot.

  OfflineAnalyze (1.2)   One-shot offline scan of a log copy; writes an HTML
                         (and/or text) report with findings, patterns, and
                         BACnet / CNS / CoHo / Apogee modules.

No Python or other installs. PowerShell 5.1+ only.


Requirements
------------
  - Windows
  - PowerShell 5.1 or later (included with modern Windows)
  - A PVSS_II.log (or .log.bak) to analyze
  - A browser on the same PC for the live dashboard


Package layout
--------------
Keep this folder outside the WinCC OA project log directory.

  Run-Watch.cmd              Double-click to start the live dashboard
  readMe.txt                 This file
  Watch\                     Runtime payload
    Watch-PvssLog.ps1        Localhost host + APIs
    VERSION.txt              Watch version (2.2)
    watch-config.txt         Defaults / preferences (edit this)
    ui\                      Dashboard (Siemens dark theme + Chart.js)
    OfflineAnalyze\          Offline report tool (1.2)
      Run-Analyze.cmd
      Run-Analyze-Interactive.cmd
      Analyze-PvssLog.ps1
      readMe.txt             Offline options and parameters
      VERSION.txt            OfflineAnalyze version


Quick start — live Watch
------------------------
1. Double-click Run-Watch.cmd
   (or: powershell -NoProfile -ExecutionPolicy Bypass -File .\Watch\Watch-PvssLog.ps1)

2. Browser opens to the local dashboard (127.0.0.1). If the preferred port
   is busy, the host picks the next free port and opens that URL.

3. Enter / confirm the live log path (example):
     C:\GMSprojects\Project_Name\log\PVSS_II.log
   Optional: set LogPath= in Watch\watch-config.txt for prefill.
   Start writes that path back into watch-config.txt.

4. Choose a time window (e.g. 60m or Entire), then Start.
   - Rolling windows are anchored to the last timestamp in the file
     (not wall-clock "now"), so older logs still show data.
   - While loading, a progress % appears; then the host tails new lines.

5. Use Pause / Resume / Restart as needed.
   Change severity chips and time window anytime (reloads the window).

6. Snapshot downloads an HTML report of the current in-memory analysis
   (browser download only; same Siemens dark look as the dashboard).

7. Ctrl+C in the host console stops the server.


Watch config (Watch\watch-config.txt)
-------------------------------------
Self-documented key=value file (ranges noted in comments). CLI flags override
the file when used. Invalid values are rejected, printed in the host console,
and rewritten back to the default (self-correcting). Host is always localhost
(127.0.0.1) only.

  PreferredPort / MaxPortTries   First port to try, then next N ports
  RefreshSeconds                 Dashboard poll interval (1-60)
  OpenBrowser / Browser          Auto-open UI; default | chrome | msedge | exe path
  DefaultWindowMinutes           Initial window (minutes)
  DefaultWindowEntire            true = start on Entire
  DefaultSeverities              Initial chips, e.g. FATAL,SEVERE,ERROR,WARNING
  TopN / SamplePerPattern        Pattern table depth / samples
  BacFlapMin                     BACnet flapper threshold
  LogPath                        Prefill path; updated automatically on Start


Quick start — OfflineAnalyze
----------------------------
For a full offline report from a log copy (not required to watch live):

1. Copy PVSS_II.log (or .bak) into Watch\OfflineAnalyze\
   (or pass -LogPath to a file elsewhere).

2. Double-click Watch\OfflineAnalyze\Run-Analyze.cmd
   → writes PVSS_II.log.analysis.html next to the log.

   Or Run-Analyze-Interactive.cmd to shape the report by severity /
   driver after the scan.

3. See Watch\OfflineAnalyze\readMe.txt for From/To windows, formats,
   and PowerShell examples.


Important notes
---------------
  - The live log is opened FileAccess.Read only (WinCC may keep appending).
  - Watch binds to 127.0.0.1 only (same Windows session / browser).
  - Do not install or run these scripts inside the project log folder.
  - Preferences live in Watch\watch-config.txt (LogPath updated on Start).
  - This is a triage aid, not a substitute for Siemens GMS / WinCC OA support.
  - Field baseline: Watch 2.2 / OfflineAnalyze 1.2. Bump VERSION.txt (and
    readMes) before the next field package. Dev ideas: docs\BACKLOG.md
    (PRD/PROGRESS history is under docs\archive\).
