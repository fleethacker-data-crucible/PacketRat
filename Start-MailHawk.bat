@echo off
setlocal
set "REPO=%~dp0"
cd /d "%REPO%" || ( echo ERROR: cannot cd to MailHawk & pause & exit /b 1 )

where powershell >nul 2>&1 || ( echo ERROR: powershell not on PATH & pause & exit /b 1 )

echo [*] Launching MailHawk GUI (STA)...
REM -STA is required for Windows Forms. Without it the window can hang after load.
powershell.exe -NoProfile -ExecutionPolicy Bypass -NoLogo -STA -File "%REPO%Start-MailHawk.ps1" %*

if errorlevel 1 (
  echo.
  echo MailHawk exited with error %ERRORLEVEL%
  echo See Logs\mailhawk-error.log if present.
  pause
)
exit /b %ERRORLEVEL%
