@echo off
REM Interactive launcher: scan then prompt for Severity / Driver / All
REM Enter at prompts accepts defaults (see PRD).
cd /d "%~dp0"
echo Running Analyze-PvssLog.ps1 -Interactive in:
echo   %CD%
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Analyze-PvssLog.ps1" -Interactive -NoPause %*
set ERR=%ERRORLEVEL%
echo.
if not "%ERR%"=="0" echo Script exited with error code %ERR%.
pause
exit /b %ERR%
