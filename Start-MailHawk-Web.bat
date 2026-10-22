@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "REPO=%~dp0"
cd /d "%REPO%" || ( echo ERROR: Unable to open MailHawk directory. & pause & exit /b 1 )
where powershell.exe >nul 2>&1 || ( echo ERROR: Windows PowerShell was not found. & pause & exit /b 1 )

echo [MailHawk] Starting local browser interface (Windows PowerShell 5.1)...
REM Match the approved, process-scoped launch convention used by Cascade.
REM This does not elevate privileges or override Group Policy-enforced restrictions.
REM Use only where your organization authorizes running these scripts.
powershell.exe -NoProfile -NoLogo -STA -ExecutionPolicy Bypass -File "%REPO%Start-MailHawk-Web.ps1" %*
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" (
  echo.
  echo [MailHawk] Launcher failed. Exit code: %EXIT_CODE%
  echo Run Start-MailHawk-Diagnostics.bat for policy and syntax checks.
  echo The launcher will not attempt to disable organizational security controls.
  pause
)
exit /b %EXIT_CODE%
