@echo off
REM Launch PVSS Log Watch (V2) — localhost dashboard
cd /d "%~dp0"
echo Starting Watch-PvssLog.ps1 in:
echo   %CD%
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Watch-PvssLog.ps1" -NoPause %*
set ERR=%ERRORLEVEL%
echo.
if not "%ERR%"=="0" echo Script exited with error code %ERR%.
pause
exit /b %ERR%
