@echo off
REM One-shot PVSS log report (no dashboard, no browser) — HTML next to the log
REM Pass -LogPath "C:\...\PVSS_II.log" to pick a log; otherwise it is auto-discovered.
cd /d "%~dp0Watch"
if not exist "%CD%\DesigoLogWatcher.exe" (
  echo ERROR: Watch\DesigoLogWatcher.exe not found.
  echo Expected: %~dp0Watch\DesigoLogWatcher.exe
  pause
  exit /b 1
)
echo Building report with DesigoLogWatcher in:
echo   %CD%
echo.
"%CD%\DesigoLogWatcher.exe" -Report -Format Html -NoPause %*
set ERR=%ERRORLEVEL%
echo.
if not "%ERR%"=="0" echo Host exited with error code %ERR%.
pause
exit /b %ERR%
