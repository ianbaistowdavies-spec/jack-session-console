@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0app\JackConsole.ps1"
if errorlevel 1 pause
