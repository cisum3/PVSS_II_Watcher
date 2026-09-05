PVSS / WinCC OA Log Analyzer — Watch (V2)
========================================
Version: 2.0-dev (in progress)

What this folder is
-------------------
Root package for the **live dashboard** (PowerShell host + browser UI).

  Watch-PvssLog.ps1 / Run-Watch.cmd   — not built yet (see docs\PROGRESS-V2.md)
  ui\                                — dashboard static files
  watch-log-path.example.txt         — copy to watch-log-path.txt for path prefill
  VERSION.txt                        — Watch version (2.0 when released)

Batch (offline) analyzer — V1.1
-------------------------------
The one-shot HTML/text report tool lives in:

  batch\

Open batch\readMe.txt, or double-click:

  batch\Run-Analyze.cmd
  batch\Run-Analyze-Interactive.cmd

Keep this whole project folder outside the WinCC OA project log directory.
Do not point tools at writing into the live log; Watch opens the log read-only.


Dev docs & test assets (not for field zips)
------------------------------------------
  docs\PRD.md
  docs\PRD-V2.md
  docs\PROGRESS.md
  docs\PROGRESS-V2.md
  docs\PVSS_II_Examples\     sample logs for local testing
