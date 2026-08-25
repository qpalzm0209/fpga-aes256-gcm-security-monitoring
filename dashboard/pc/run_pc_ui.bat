@echo off
setlocal
cd /d "%~dp0"

rem Machine-specific values stay outside the source.  Copy the example file only
rem when this PC needs overrides; the defaults work for the current lab setup.
if exist "pc_rx_ui.env.cmd" call "pc_rx_ui.env.cmd"

if exist ".venv\\Scripts\\python.exe" (
  ".venv\\Scripts\\python.exe" server.py
  goto :done
)

where py >nul 2>nul
if not errorlevel 1 (
  py -3 server.py
  goto :done
)

where python >nul 2>nul
if not errorlevel 1 (
  python server.py
  goto :done
)

echo Python 3 was not found.

:done
if errorlevel 1 pause
endlocal
