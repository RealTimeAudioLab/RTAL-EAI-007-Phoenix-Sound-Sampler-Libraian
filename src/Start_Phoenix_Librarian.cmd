@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0PhoenixLibrarian.ps1"
if errorlevel 1 (
  echo.
  echo Phoenix Librarian wurde mit einem Fehler beendet.
  pause
)
