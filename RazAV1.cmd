@echo off
REM Opens the RazAV1 window. Keep this next to av1_helper.ps1 and master_encode.bat.
REM A bin folder next to it [portable pack] goes first in PATH, so its ffmpeg and ffprobe are used.
if exist "%~dp0bin\ffmpeg.exe" set "PATH=%~dp0bin;%PATH%"

REM Windows 11 opens console programs in Windows Terminal, which ignores "start hidden" and leaves an
REM empty PowerShell tab. conhost --headless [Windows 10 1809 and newer] gives the window's PowerShell a
REM console nobody sees; the encoder needs that console for its own tools.
set "AV1_BUILD=0"
for /f "tokens=2 delims=[]" %%v in ('ver') do set "AV1_VERSTR=%%v"
for /f "tokens=4 delims=. " %%b in ("%AV1_VERSTR%") do set "AV1_BUILD=%%b"
if %AV1_BUILD% GEQ 17763 if exist "%SystemRoot%\System32\conhost.exe" (
    start "" "%SystemRoot%\System32\conhost.exe" --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0av1_helper.ps1" -Mode gui
    exit /b 0
)
start "" powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0av1_helper.ps1" -Mode gui
