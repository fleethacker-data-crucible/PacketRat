@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "ROOT=%~dp0"
cd /d "%ROOT%" || (echo [MailHawk] Cannot access the application directory. & pause & exit /b 1)
where powershell.exe >nul 2>&1 || (echo [MailHawk] Windows PowerShell is unavailable. & pause & exit /b 1)

REM Console-only MailHawk analysis. The old WinForms interface is not a launcher.
REM Process-scoped execution policy matches ARC/Cascade startup convention when allowed.
echo [MailHawk] Starting console analysis...
powershell.exe -NoProfile -NoLogo -STA -ExecutionPolicy Bypass -File "%ROOT%Start-MailHawk.ps1" -ConsoleOnly %*
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" (
  echo.
  echo [MailHawk] Console exited with error %EXIT_CODE%.
  echo Use MailHawk.bat diagnostics if initialization fails.
  pause
)
exit /b %EXIT_CODE%
