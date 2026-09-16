@echo off
REM One-shot PVSS log report (no dashboard, no browser) — HTML next to the log
REM Pass -LogPath "C:\...\PVSS_II.log" to pick a log; otherwise it is auto-discovered.
cd /d "%~dp0Watch"
if not exist "%CD%\Watch-PvssLog.ps1" (
  echo ERROR: Watch\Watch-PvssLog.ps1 not found beside this launcher.
  echo Expected: %~dp0Watch\Watch-PvssLog.ps1
  pause
  exit /b 1
)
echo Building report with Watch-PvssLog.ps1 in:
echo   %CD%
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%CD%\Watch-PvssLog.ps1" -Report -Format Html -NoPause %*
set ERR=%ERRORLEVEL%
echo.
if not "%ERR%"=="0" echo Script exited with error code %ERR%.
pause
exit /b %ERR%
