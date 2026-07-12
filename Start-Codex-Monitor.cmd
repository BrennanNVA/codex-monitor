@echo off
setlocal
title Codex Monitor
mode con: cols=110 lines=24 >nul 2>&1
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\codex-monitor.ps1" %*
set "ExitCode=%ERRORLEVEL%"
if not "%ExitCode%"=="0" (
  echo.
  echo Codex Monitor stopped with an error. Review the message above.
  pause
)
exit /b %ExitCode%
