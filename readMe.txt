PVSS / WinCC OA Log Analyzer
============================
Version: 1.1

What this is
------------
A standalone PowerShell tool that scans a large PVSS_II.log (WinCC OA / GMS)
and writes an analysis report. It streams the file (does not load the whole
log into memory) and needs no Python or other installs.

Reports can be shaped after the scan by severity or by driver/manager, with
BACnet, CNS, CoHo, and Apogee module statistics.


Files (package for V1.1)
------------------------
  Analyze-PvssLog.ps1            Main analyzer script
  Run-Analyze.cmd                Non-interactive full report as HTML (keeps window open)
  Run-Analyze-Interactive.cmd    Scan then prompt for Severity / Driver / All
  readMe.txt                     This file
  VERSION.txt                    Version number (1.1)


Requirements
------------
  - Windows
  - PowerShell 5.1 or later (built into modern Windows)
  - A PVSS_II.log (or PVSS_II*.log / PVSS_II*.log.bak) to analyze


How to run (recommended on a server)
------------------------------------
Keep this toolset in its own folder (do NOT copy these files into the
WinCC OA project log directory).

1. Copy PVSS_II.log (or PVSS_II.log.bak) from the project log folder into this
   tools folder.
   Typical project log path:
     E:\GMSprojects\Project_Name\log\PVSS_II.log
     E:\GMSprojects\Project_Name\log\PVSS_II.log.bak
   Example destination: D:\Tools\PvssLogAnalyze\PVSS_II.log

2. Double-click Run-Analyze.cmd for a full default report (HTML),
   or Run-Analyze-Interactive.cmd to choose Severity / Driver / All after
   the scan. Press Enter at prompts to accept defaults.

3. Open the HTML report next to the log:
     PVSS_II.log.analysis.html

Launchers use ExecutionPolicy Bypass so the script can run even when
double-clicking .ps1 files is blocked.


How to run from PowerShell
--------------------------
  From the tools folder:

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
    Looks for PVSS_II.log in the same folder as Analyze-PvssLog.ps1,
    then in the current working directory.
    If missing: PVSS_II.log.bak, then newest PVSS_II*.log or
    PVSS_II*.log.bak in those folders.

  Report file:
    <logname>.analysis.txt next to the log
    Example: PVSS_II.log.analysis.txt


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
  -Format Text|Html|Both          Report format (default Text; Run-Analyze.cmd
                                     uses Html; Both also writes .analysis.txt)
  -Organize All|Severity|Driver      Report shape (with -NonInteractive)
  -Severities FATAL,SEVERE,ERROR     For Organize=Severity
  -Driver 1                          Manager index or name substring
                                     (Organize=Driver)
  -NoPause                           Do not wait for Enter at the end


Interactive defaults (empty Enter)
----------------------------------
  Time filter: Entire file
    Then choose [E] Entire  [H] Last N hours  [W] Absolute From/To
    Bad date/time or hour values are rejected and re-prompted
  Organize mode: All
  Severity selection: critical pack (FATAL+SEVERE+ERROR)
  Top N: 10
  Driver pick: #1 on the current page
  Report format: Both (text + HTML)


What the report contains
------------------------
  - Options used (organize mode, severities, drivers, time window, TopN, format)
  - Findings (volume / chatter heuristics; no suggested next-steps list)
  - Severity counts
  - BACnet module: device Failed/OK summary, status activity table (Failed/OK/flips/last),
    devices that ended Failed, object-list warnings
  - CNS module (thin): ResolveNodes / ReducedFunction / TryRenewSession
  - CoHo module (thin): stuck/drop counts and names
  - Apogee module (thin): CoHo.Apogee*/Orch.Apogee* events, UpdatePoints, top PPCL names
  - Top managers, performance keyword categories, hourly volume (All mode;
    if more than 25 hours in the window: most recent 24 + top 10 busiest)
  - Top message patterns separated by severity (FATAL / SEVERE / ERROR /
    WARNING), each with first/last timestamps, or a driver deep-dive when
    Organize=Driver
  - Severity mode: short module headlines + selected severity patterns only

Console shows a short scan summary; full detail is in the report file(s).
Text default: <logname>.analysis.txt
HTML (Format Html/Both): <logname>.analysis.html (open in a browser)


Typical runtime
---------------
  Roughly 50-60 seconds for a ~50 MB log on a typical workstation
  (depends on disk and CPU; larger or denser logs take longer).


Notes
-----
  - Do not install or leave these tools inside the WinCC OA project folder.
    Copy the log into the tools folder instead.
  - Prefer analyzing a log captured during a slow period; use -From/-To to
    narrow to that window.
  - Rotated logs may be *.log.bak; discovery finds those automatically.
  - Only lines matching the standard WinCC OA single-line header are fully
    parsed; multi-line .NET continuation text may not appear as separate events.
  - Logs are read as UTF-8 so markers like «MacroManager» display correctly.
  - BACnet device Failed/OK is INFO device status (entering/leaving Failed),
    reported under the BACnet module.
  - This is a triage aid, not a substitute for Siemens GMS / WinCC OA support.


Example layout on the server
----------------------------
  D:\Tools\PvssLogAnalyze\          <-- tools live here (not under the project)
    Analyze-PvssLog.ps1
    Run-Analyze.cmd
    Run-Analyze-Interactive.cmd
    readMe.txt
    PVSS_II.log                     <-- copied in from project log folder
    PVSS_II.log.analysis.txt        <-- created after a successful run
    PVSS_II.log.analysis.html       <-- when using -Format Html or Both
