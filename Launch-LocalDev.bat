@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0" || exit /b 1
where powershell.exe >nul 2>&1 || (echo Windows PowerShell 5.1 is required. & exit /b 1)
echo [MAILHAWK LOCAL DEV] Offline demonstration: synthetic messages, no Outlook/CAC/AI calls.
powershell.exe -NoProfile -NoLogo -STA -File "%~dp0Start-MailHawk-Web.ps1" -Demo %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" pause
exit /b %RC%
