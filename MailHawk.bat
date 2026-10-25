@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "ROOT=%~dp0"
cd /d "%ROOT%" || (echo [MailHawk] Cannot access the application directory. & pause & exit /b 1)
where powershell.exe >nul 2>&1 || (echo [MailHawk] Windows PowerShell is unavailable. & pause & exit /b 1)

REM Single browser-GUI entrypoint. Matches Cascade's process-scoped launch convention.
REM Use only where authorized; this cannot override centrally enforced security policy.
if "%~1"=="" goto GUI
if /i "%~1"=="gui" goto GUI
if /i "%~1"=="demo" goto DEMO
if /i "%~1"=="diagnostics" goto DIAGNOSTICS
if /i "%~1"=="check" goto DIAGNOSTICS
if /i "%~1"=="-Demo" goto ARGUMENTS
if /i "%~1"=="-NoBrowser" goto ARGUMENTS
if /i "%~1"=="-Port" goto ARGUMENTS
if /i "%~1"=="--stay" goto ARGUMENTS
if /i "%~1"=="-Stay" goto ARGUMENTS
if /i "%~1"=="--replace" goto ARGUMENTS
if /i "%~1"=="-Replace" goto ARGUMENTS
if /i "%~1"=="--no-browser" goto ARGUMENTS
if /i "%~1"=="stop" goto STOP
echo [MailHawk] Unknown mode: %~1
echo Usage: MailHawk.bat [gui ^| demo ^| diagnostics ^| stop] [--replace] [--stay]
echo        MailHawk.bat -NoBrowser
echo        MailHawk.bat -Port 8766
echo   --replace  stop a running MailHawk and start fresh without asking
echo   --stay     keep the local service running after the browser tab closes
exit /b 2

:GUI
REM Closing the MailHawk tab stops the service; --stay or MAILHAWK_AUTO_STOP=0 keeps it.
echo [MailHawk] Opening local browser GUI...
powershell.exe -NoProfile -NoLogo -STA -ExecutionPolicy Bypass -File "%ROOT%Start-MailHawk-Web.ps1" %*
goto FINISH

:ARGUMENTS
powershell.exe -NoProfile -NoLogo -STA -ExecutionPolicy Bypass -File "%ROOT%Start-MailHawk-Web.ps1" %*
goto FINISH

:DEMO
echo [MailHawk] Opening offline demonstration...
powershell.exe -NoProfile -NoLogo -STA -ExecutionPolicy Bypass -File "%ROOT%Start-MailHawk-Web.ps1" -Demo %*
goto FINISH

:DIAGNOSTICS
echo [MailHawk] Running safe local startup checks...
powershell.exe -NoProfile -NoLogo -STA -ExecutionPolicy Bypass -File "%ROOT%tools\Test-MailHawkStartup.ps1"
goto FINISH

:STOP
echo [MailHawk] Stopping every running MailHawk browser service...
powershell.exe -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%ROOT%Stop-MailHawk.ps1"
goto FINISH

:FINISH
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" (
  echo.
  echo [MailHawk] Failed with exit code %EXIT_CODE%.
  echo Run MailHawk.bat diagnostics to check PowerShell syntax and startup prerequisites.
  echo Do not attempt to override centrally enforced workstation security restrictions.
  pause
)
exit /b %EXIT_CODE%
