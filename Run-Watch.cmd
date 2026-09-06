@echo off
REM Launch PVSS Log Watch (V2) — localhost dashboard
REM Package root holds only this launcher + readMe.txt; runtime lives in Watch\
cd /d "%~dp0Watch"
if not exist "%CD%\Watch-PvssLog.ps1" (
  echo ERROR: Watch\Watch-PvssLog.ps1 not found beside this launcher.
  echo Expected: %~dp0Watch\Watch-PvssLog.ps1
  pause
  exit /b 1
)
echo Starting Watch-PvssLog.ps1 in:
echo   %CD%
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%CD%\Watch-PvssLog.ps1" -NoPause %*
set ERR=%ERRORLEVEL%
echo.
if not "%ERR%"=="0" echo Script exited with error code %ERR%.
pause
exit /b %ERR%
