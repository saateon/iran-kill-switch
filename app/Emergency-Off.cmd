@echo off
rem Iran Kill Switch - EMERGENCY OFF. Removes every filter and route even if the app is broken.
title Iran Kill Switch - Emergency OFF
net session >nul 2>&1
if %errorlevel% neq 0 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0IKS.ps1" -Action Disable
if %errorlevel% equ 0 goto done
echo.
echo   Normal turn-off failed - forcing removal ...
schtasks /Change /TN IKS-Guard /Disable >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "$d='%~dp0'; try { Add-Type -LiteralPath (Join-Path $d 'native\IksNative.cs'); $s = New-Object IKS.Native.WfpSession($false); 'WFP filters removed: ' + $s.RemoveAll(); $s.Dispose() } catch { 'WFP: ' + $_ }; Get-NetFirewallRule -Group 'Iran Kill Switch' -ErrorAction SilentlyContinue | Remove-NetFirewallRule; $f = Join-Path $d 'state\settings.json'; if (Test-Path $f) { $j = Get-Content $f -Raw | ConvertFrom-Json; $j.Enabled = $false; $j | ConvertTo-Json -Depth 6 | Set-Content $f }"
echo   Done. The background guard is paused. Run Setup.cmd again to repair.
:done
echo.
pause
