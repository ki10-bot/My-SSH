@echo off
REM RemoteGate — GENERATE TEMPLATE (Windows double-click)
REM ➡️  Doppelklick hier → Wizard startet
REM Or: powershell -File Generate-RemoteGate.bat is not needed, just double-click

echo ============================================================
echo   RemoteGate — Generator (Windows)
echo   Starte Wizard...
echo ============================================================
echo Repo: %~dp0
echo.

REM Check template exists
if not exist "%~dp0templates\RemoteGate-Deployment.template.ps1" (
  echo Fehler: templates\RemoteGate-Deployment.template.ps1 nicht gefunden
  echo Hast du das komplette Repo heruntergeladen?
  pause
  exit /b 1
)

REM Prefer pwsh (PowerShell 7) then Windows PowerShell 5.1
where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
  echo -> Starte PowerShell Wizard (pwsh gefunden)...
  pwsh -File "%~dp0generator\New-RemoteGateDeployment.ps1"
  goto :end
)

where powershell >nul 2>nul
if %ERRORLEVEL%==0 (
  echo -> Starte PowerShell Wizard...
  powershell -ExecutionPolicy Bypass -File "%~dp0generator\New-RemoteGateDeployment.ps1"
  goto :end
)

echo Kein PowerShell gefunden — bitte installieren: https://aka.ms/powershell
pause
exit /b 1

:end
echo.
echo ✅ Fertig! Prüfe dist\RemoteGate-Final.ps1 und Yandex URL oben.
echo.
pause
exit /b %ERRORLEVEL%
