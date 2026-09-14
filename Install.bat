@echo off
net session >nul 2>&1
if %errorLevel% neq 0 (
  echo Requesting administrator...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
cd /d "%~dp0"
echo.
echo Jack Session Console — installing what the recorder needs.
echo This does NOT wrap anything in Docker and will not overlay your game.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install\Install-JackConsole.ps1"
echo.
pause
