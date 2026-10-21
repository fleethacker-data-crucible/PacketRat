@echo off
setlocal
set "REPO=%~dp0"
cd /d "%REPO%" || ( echo ERROR: cannot cd to MailHawk & pause & exit /b 1 )

where powershell >nul 2>&1 || ( echo ERROR: powershell not on PATH & pause & exit /b 1 )

set "PROFILE=%~1"
if "%PROFILE%"=="" set "PROFILE=Auto"

echo [*] Launching MailHawk console...
powershell.exe -NoProfile -ExecutionPolicy Bypass -NoLogo -STA -File "%REPO%Start-MailHawk.ps1" -ConsoleOnly -Profile %PROFILE%

if errorlevel 1 (
  echo.
  echo MailHawk exited with error %ERRORLEVEL%
  pause
)
exit /b %ERRORLEVEL%
