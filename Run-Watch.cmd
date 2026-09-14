@echo off
REM Launch DesigoLogWatcher dashboard — localhost only
REM Package root holds launchers + readMe; runtime lives in Watch\
cd /d "%~dp0Watch"
if not exist "%CD%\DesigoLogWatcher.exe" (
  echo ERROR: Watch\DesigoLogWatcher.exe not found.
  echo Expected: %~dp0Watch\DesigoLogWatcher.exe
  echo Publish: dotnet publish src\DesigoLogWatcher\DesigoLogWatcher.csproj -c Release -o Watch\
  pause
  exit /b 1
)
echo Starting DesigoLogWatcher in:
echo   %CD%
echo.
"%CD%\DesigoLogWatcher.exe" -NoPause %*
set ERR=%ERRORLEVEL%
echo.
if not "%ERR%"=="0" echo Host exited with error code %ERR%.
pause
exit /b %ERR%
