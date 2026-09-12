@echo off
REM Double-click friendly launcher for Analyze-PvssLog.ps1
REM Keeps the window open and bypasses ExecutionPolicy.
cd /d "%~dp0"
echo Running Analyze-PvssLog.ps1 in:
echo   %CD%
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Analyze-PvssLog.ps1" -NonInteractive -NoPause -Format Html %*
set ERR=%ERRORLEVEL%
echo.
if not "%ERR%"=="0" echo Script exited with error code %ERR%.
pause
exit /b %ERR%
