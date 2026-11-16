@echo off
net session >nul 2>&1
if %errorlevel% neq 0 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
cd /d "%~dp0"
echo Battery test mode:
echo   [N] Normal (your current power settings)
echo   [S] Battery saver ON for the whole test
choice /c NS /n /m "Press N or S: "
if %errorlevel%==2 (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0BatteryLogger.ps1" -Mode Start -BatterySaver
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0BatteryLogger.ps1" -Mode Start
)
timeout /t 10
