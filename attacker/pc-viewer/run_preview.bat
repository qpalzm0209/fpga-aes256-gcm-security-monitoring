@echo off
cd /d "%~dp0"
if not exist "%~dp0.venv\Scripts\python.exe" (
    call "%~dp0setup_venv.bat"
    if errorlevel 1 exit /b 1
)
"%~dp0.venv\Scripts\python.exe" "%~dp0preview.py" %*
