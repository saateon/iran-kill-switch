@echo off
rem Iran Kill Switch - remove everything and restore the previous state.
title Iran Kill Switch - Uninstall
net session >nul 2>&1
if %errorlevel% neq 0 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
set "IKS=%ProgramFiles%\IranKillSwitch\IKS.ps1"
if not exist "%IKS%" set "IKS=%~dp0app\IKS.ps1"
echo.
echo   1 = Remove Iran Kill Switch (recommended)
echo   2 = Remove AND restore the complete firewall policy saved before first use
echo   3 = Cancel
echo.
choice /c 123 /n /m "  Choose 1, 2 or 3: "
if errorlevel 3 exit /b 0
if errorlevel 2 (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%IKS%" -Action Uninstall -RestoreOriginal
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%IKS%" -Action Uninstall
)
echo.
pause
