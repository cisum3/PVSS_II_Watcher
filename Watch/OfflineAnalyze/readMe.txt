PVSS / WinCC OA Log Analyzer - OfflineAnalyze
=============================================
Version: 1.2
Author: Cisum

What this is
------------
One-shot offline scanner for large PVSS_II.log files (WinCC OA / GMS).
It streams the file (does not load the whole log into memory), needs no
Python or other installs, and writes an HTML and/or text triage report.

Reports can be shaped by severity or by driver/manager, and include
BACnet, CNS, CoHo, and Apogee module statistics.

For the live Watch dashboard, see ..\..\readMe.txt (package root) or
double-click ..\..\Run-Watch.cmd.


Requirements
------------
  - Windows
  - PowerShell 5.1 or later (included with modern Windows)
  - A PVSS_II.log (or PVSS_II*.log / PVSS_II*.log.bak) to analyze


Folder contents
---------------
Keep this toolset outside the WinCC OA project log directory.

  Analyze-PvssLog.ps1            Main analyzer
  Run-Analyze.cmd                Full report as HTML (non-interactive)
  Run-Analyze-Interactive.cmd    Scan, then prompt for Severity / Driver / All
  readMe.txt                     This file
  VERSION.txt                    1.2


Quick start
-----------
1. Copy PVSS_II.log (or .log.bak) from the project log folder into this
   OfflineAnalyze folder (or use -LogPath to a copy elsewhere).

   Typical project log path:
     E:\GMSprojects\Project_Name\log\PVSS_II.log
     E:\GMSprojects\Project_Name\log\PVSS_II.log.bak

2. Double-click Run-Analyze.cmd
   → writes PVSS_II.log.analysis.html next to the log.

   Or Run-Analyze-Interactive.cmd to choose how the report is organized
   after the scan. Press Enter at prompts to accept defaults.

3. Open the .analysis.html file in a browser.

Launchers use ExecutionPolicy Bypass so the script can run even when
double-clicking .ps1 files is blocked.


How to run from PowerShell
--------------------------
From this Offline folder:

  powershell -NoProfile -ExecutionPolicy Bypass -File .\Analyze-PvssLog.ps1 -NonInteractive

Interactive:

  powershell -NoProfile -ExecutionPolicy Bypass -File .\Analyze-PvssLog.ps1 -Interactive

Specific log path:

  powershell -NoProfile -ExecutionPolicy Bypass -File .\Analyze-PvssLog.ps1 -LogPath "E:\GMSprojects\Project_Name\log\PVSS_II.log" -NonInteractive

Time window (slow period):

  powershell -NoProfile -ExecutionPolicy Bypass -File .\Analyze-PvssLog.ps1 -NonInteractive -From "2026.09.04 09:00" -To "2026.09.04 12:00"


Defaults
--------
  Log file:
    Looks for PVSS_II.log next to Analyze-PvssLog.ps1, then in the current
    directory. If missing: PVSS_II.log.bak, then newest PVSS_II*.log or
    PVSS_II*.log.bak in those folders.

  Report files (next to the log):
    <logname>.analysis.html     when Format is Html or Both
    <logname>.analysis.txt      when Format is Text or Both
    Run-Analyze.cmd defaults to Html.


Useful parameters
-----------------
  -LogPath "C:\path\PVSS_II.log"     Specific log (or .log.bak)
  -OutPath "C:\path\report.txt"      Custom report path
  -TopN 10                           Top patterns per section (default 10)
  -SamplePerPattern 1                Example lines kept per pattern
  -From "2026.09.04 09:00"           Analyze lines at/after this time
  -To "2026.09.04 12:00"             Analyze lines at/before this time
                                     Date-only -To = end of that day
  -LastHours 6                       Last N hours from end of the log
                                     (overrides -From/-To)
  -NonInteractive                    No prompts (Run-Analyze.cmd)
  -Interactive                       Post-scan organize prompts
  -Format Text|Html|Both          Report format (default Text;
                                     Run-Analyze.cmd uses Html)
  -Organize All|Severity|Driver      Report shape (with -NonInteractive)
  -Severities FATAL,SEVERE,ERROR     For Organize=Severity
  -Driver 1                          Manager index or name substring
                                     (Organize=Driver)
  -NoPause                           Do not wait for Enter at the end


Interactive defaults (empty Enter)
----------------------------------
  Time filter: Entire file
    Then choose [E] Entire  [H] Last N hours  [W] Absolute From/To
  Organize mode: All
  Severity selection: critical pack (FATAL+SEVERE+ERROR)
  Top N: 10
  Driver pick: #1 on the current page
  Report format: Both (text + HTML)


What the report contains
------------------------
  - Options used (organize mode, severities, drivers, time window, TopN)
  - Findings (volume / chatter heuristics)
  - Severity counts
  - BACnet: Failed/OK summary, device activity, ended Failed, object-list
  - CNS (thin): ResolveNodes / ReducedFunction / TryRenewSession
  - CoHo (thin): stuck/drop counts and names
  - Apogee (thin): events, UpdatePoints, top PPCL names
  - Top managers, performance keyword categories, hourly volume (All mode)
  - Top message patterns by severity (or a driver deep-dive)

Console shows a short scan summary; full detail is in the report file(s).
HTML uses the same Siemens dark theme as the live Watch dashboard.


Typical runtime
---------------
  Roughly 50-60 seconds for a ~50 MB log on a typical workstation
  (depends on disk and CPU; larger or denser logs take longer).


Important notes
---------------
  - Do not install or leave these tools inside the WinCC OA project folder.
    Copy the log into this folder (or point -LogPath at a copy elsewhere).
  - Prefer a log from a slow period; use -From/-To or -LastHours to narrow.
  - Rotated logs may be *.log.bak; discovery finds those automatically.
  - Only standard WinCC OA single-line headers are fully parsed; multi-line
    .NET continuation text may not appear as separate events.
  - Logs are read as UTF-8.
  - BACnet device Failed/OK comes from INFO device-status lines.
  - This is a triage aid, not a substitute for Siemens GMS / WinCC OA support.
