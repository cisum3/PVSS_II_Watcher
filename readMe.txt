PVSS / WinCC OA Log Analyzer — Watch (V2)
========================================
Version: 2.0-dev (in progress)

What this folder is
-------------------
Root package for the **live dashboard** (PowerShell host + browser UI).

  Watch-PvssLog.ps1              Localhost host (read-only log tail + JSON APIs)
  Run-Watch.cmd                  Double-click launcher (opens browser)
  ui\                            Dashboard (Siemens dark theme + Chart.js)
  watch-log-path.example.txt     Copy to watch-log-path.txt for path prefill
  VERSION.txt                    Watch version (2.0 when released)
  Test-WatchSelf.ps1             Dev self-test (optional)

How to run
----------
1. Keep this folder outside the WinCC OA project log directory.
2. Double-click Run-Watch.cmd (or: powershell -File .\Watch-PvssLog.ps1).
3. Enter / confirm the live PVSS_II.log path → Start.
4. Use Pause / Resume / Restart; change time window and severity filters as needed.
5. Ctrl+C in the host window stops the server.

The live log is opened with FileAccess.Read only (WinCC may still append).

Batch (offline) analyzer — V1.1
-------------------------------
  batch\Run-Analyze.cmd
  batch\Run-Analyze-Interactive.cmd
  batch\readMe.txt


Dev docs & test assets (not for field zips)
------------------------------------------
  docs\PRD.md
  docs\PRD-V2.md
  docs\PROGRESS.md
  docs\PROGRESS-V2.md
  docs\PVSS_II_Examples\     sample logs for local testing
