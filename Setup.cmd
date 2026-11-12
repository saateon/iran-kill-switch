@echo off
rem Iran Kill Switch - install or update (double-click). Settings are kept on update.
title Iran Kill Switch - Setup
net session >nul 2>&1
if %errorlevel% neq 0 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
echo.
echo   Installing Iran Kill Switch ...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0app\IKS.ps1" -Action Install
if %errorlevel% neq 0 (
  echo.
  echo   Setup failed. Nothing was turned on. See the message above.
  pause
  exit /b 1
)
start "" "%ProgramFiles%\IranKillSwitch\IranKillSwitch.exe"
