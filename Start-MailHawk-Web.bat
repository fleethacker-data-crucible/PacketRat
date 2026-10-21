@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -NoLogo -STA -File "%~dp0Start-MailHawk-Web.ps1" %*
if errorlevel 1 (
  echo.
  echo MailHawk could not start. Copy the error output for troubleshooting.
  pause
)
