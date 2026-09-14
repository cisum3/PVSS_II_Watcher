Siemens Desigo CC PVSS_II Log Analyzer
======================================
Version: 0.5.0
Author: Cisum

What this is
------------
A Windows-only triage toolkit for large Siemens Desigo CC PVSS_II.log files.

One tool, two modes:

  Dashboard mode   Live localhost dashboard: open a growing log read-only,
                   catch up a time window, tail new lines, filter by
                   severity, browse modules/patterns, download a snapshot.
                   Start it with Run-Watch.cmd.

  Report mode      One-shot scan that writes an HTML and/or text report and
                   exits. No dashboard, no browser, no network port.
                   Start it with Run-Report.cmd.

Both modes read the same log the same way and produce the same analysis --
a report is simply a snapshot taken without opening the dashboard first.

No separate .NET runtime install and no PowerShell host required for analysis.
The analyzer is a single-file Windows executable (DesigoLogWatcher.exe).


Requirements
------------
  - Windows (x64)
  - A PVSS_II.log (or .log.bak) to analyze
  - A browser on the same PC for the live dashboard (not needed for reports)


Package layout
--------------
Keep this folder outside the Desigo CC project log directory.

  Run-Watch.cmd              Double-click to start the live dashboard
  Run-Report.cmd             Double-click to write an HTML report and exit
  Run-Report-Interactive.cmd Same, but asks about window / shape / format
  readMe.txt                 This file
  CHANGELOG.txt              What changed per version (newest first)
  Watch\                     Runtime payload
    DesigoLogWatcher.exe     Host, analyzer, and report writer
    VERSION.txt              Version (0.5.0)
    watch-config.txt         Defaults / preferences (edit this)
    ui\                      Dashboard (Siemens dark theme + Chart.js)


Quick start -- live dashboard
-----------------------------
1. Double-click Run-Watch.cmd

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
   Restart also re-reads watch-config.txt, so pattern depth, sample length,
   poll interval and the BACnet flap threshold apply without closing the host
   console (it prints what changed). Port and browser keys still need a host
   restart. Severity / area chips and the time window keep your current
   selection; the file re-seeds them when you reload the page.
   Change severity chips and time window anytime (reloads the window).
   Area chips (SYS / IMPL / CTRL / PARAM / OTHER) filter charts, patterns,
   and managers the same way -- ingest always keeps every area, including
   unknown areas under OTHER. Module pages still show all areas.
   While loading, the UI polls about every 0.5s for % progress; afterward
   it uses RefreshSeconds from watch-config.txt.

6. Snapshot downloads a report of the current in-memory analysis (sticky
   section jumps, project restart cycles with uptime/downtime, manager
   health, charts). Click Snapshot and pick HTML, Text, or JSON. Browser
   download only; same look as the dashboard.

7. Ctrl+C in the host console stops the server.


Quick start -- one-shot report
------------------------------
Use this when you just want a file to read or send on, with no dashboard.

1. Copy PVSS_II.log (or .bak) next to Run-Report.cmd, or pass -LogPath.

2. Double-click Run-Report.cmd
   -> writes PVSS_II.log.analysis.html next to the log, then exits.

   Or Run-Report-Interactive.cmd to be asked for the time window, how to
   organize the report, and the output format. Every question has a
   default -- press Enter to accept it.

3. Both launchers forward any extra switches, e.g.:
     Run-Report.cmd -LogPath "D:\logs\PVSS_II.log" -LastHours 6

If no -LogPath is given, the tool looks beside itself for PVSS_II.log,
then PVSS_II.log.bak, then the newest PVSS_II*.log / .bak it can find.

Report mode never binds a network port, never opens a browser, and never
changes your saved dashboard log path in watch-config.txt.

Common switches (appended to either .cmd, or passed to DesigoLogWatcher.exe):

  -LogPath "C:\...\PVSS_II.log"   Log to read (default: auto-discover)
  -OutPath "C:\...\report.html"   Where to write (default: next to the log)
  -Format Text | Html | Json | All
                                  Default All (text+html+json); Run-Report.cmd
                                  uses Html. Both is accepted as an alias for All.
  -Organize All | Severity | Driver
                                  All      = every section (default)
                                  Severity = top patterns per severity
                                  Driver   = deep-dive on chosen managers
  -Severities FATAL,SEVERE,ERROR  Default FATAL,SEVERE,ERROR,WARNING
  -Areas SYS,IMPL,CTRL,PARAM,OTHER
                                  Default all five
  -Driver "BACnet"                Manager name or list position; Driver mode
  -TopN 25                        Rows per pattern table (5-100)
  -Entire                         Whole file (default in report mode)
  -LastHours 6                    Last N hours, ending at the log's last line
  -LastMinutes 90                 Same, in minutes
  -From "2026.09.04 09:00"        Absolute start; date-only is allowed
  -To   "2026.09.04 12:00"        Absolute end; a date-only -To covers the
                                  whole of that day
  -Interactive                    Ask instead of assuming
  -NoPause                        Do not wait for a keypress on exit

Time formats accepted by -From / -To: "2026.09.04 14:30:00",
"2026.09.04 14:30", "2026.09.04", and the 2026-09-04 equivalents.
-LastHours / -LastMinutes win over -From / -To if both are given.


Detections
----------
Beyond the severity and pattern tables, the tool flags known problem
signatures -- trend buffer loss, driver error codes, offline drivers,
unknown AlertIDs, COV bursts, repeated traces, BACnet trend overflows, and
more. These appear in the Detections view on the dashboard and in a
Detections section of the report, grouped by area of the system.

Signatures ship inside DesigoLogWatcher.exe. If your site sees a recurring
message that is not being picked up, send the log line with a bug report.


Watch config (Watch\watch-config.txt)
-------------------------------------
Self-documented key=value file (ranges noted in comments). CLI flags override
the file when used. Invalid values are rejected, printed in the host console,
and rewritten back to the default (self-correcting). Edits are picked up by
Restart in the dashboard, except PreferredPort / MaxPortTries / OpenBrowser /
Browser, which need Run-Watch.cmd again. Host is always localhost
(127.0.0.1) only.

  PreferredPort / MaxPortTries   First port to try, then next N ports
  RefreshSeconds                 Steady-state poll interval (1-60); ~0.5s while loading
  OpenBrowser / Browser          Auto-open UI; default | chrome | msedge | exe path
  DefaultWindowMinutes           Initial window (minutes)
  DefaultWindowEntire            true = start on Entire
  DefaultSeverities              Initial chips, e.g. FATAL,SEVERE,ERROR,WARNING
  DefaultAreas                   Initial area chips, e.g. SYS,IMPL,CTRL,PARAM,OTHER
  TopN / SamplePerPattern        Pattern table depth / samples
  SampleMaxChars                 Max length for pattern labels and examples
  BacFlapMin                     BACnet flapper threshold
  LogPath                        Prefill path; updated automatically on Start


Important notes
---------------
  - The live log is opened FileAccess.Read only (WinCC may keep appending).
  - The dashboard binds to 127.0.0.1 only (same Windows session / browser).
    Report mode binds nothing at all.
  - Do not install or run this toolkit inside the project log folder.
  - Preferences live in Watch\watch-config.txt (LogPath updated on Start by
    the dashboard; report mode leaves it alone).
  - Large logs are much faster than older PowerShell builds: a ~50 MB
    entire-file HTML report finishes in about 6 seconds on a typical laptop
    (was several minutes before).
  - This is a triage aid, not a substitute for Siemens Desigo CC support.
  - Current version: 0.5.0. See CHANGELOG.txt for what changed in each release.
