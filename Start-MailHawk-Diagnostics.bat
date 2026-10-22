@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "REPO=%~dp0"
cd /d "%REPO%" || ( echo ERROR: Cannot access repository folder. & pause & exit /b 1 )
where powershell.exe >nul 2>&1 || ( echo ERROR: Windows PowerShell not found. & pause & exit /b 1 )
powershell.exe -NoProfile -NoLogo -STA -ExecutionPolicy Bypass -File "%REPO%tools\Test-MailHawkStartup.ps1"
set "EXIT_CODE=%ERRORLEVEL%"
echo.
if "%EXIT_CODE%"=="0" (
  echo [MailHawk] Preflight passed. This does not confirm Outlook or AI connectivity.
) else (
  echo [MailHawk] Preflight found one or more issues. Exit code: %EXIT_CODE%
)
echo Copy only non-sensitive output when seeking help. Do not share tokens or mail contents.
pause
exit /b %EXIT_CODE%
