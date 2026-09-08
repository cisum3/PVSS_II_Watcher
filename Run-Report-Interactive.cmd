@echo off
REM One-shot PVSS log report with prompts: time window, report shape, output format
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
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%CD%\Watch-PvssLog.ps1" -Report -Interactive -NoPause %*
set ERR=%ERRORLEVEL%
echo.
if not "%ERR%"=="0" echo Script exited with error code %ERR%.
pause
exit /b %ERR%
