@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "ROOT=%~dp0"
cd /d "%ROOT%" || (echo [PacketRat] Cannot access the application directory. & pause & exit /b 1)
where powershell.exe >nul 2>&1 || (echo [PacketRat] Windows PowerShell is unavailable. & pause & exit /b 1)

REM Single browser-GUI entrypoint. Matches Halyard's process-scoped launch convention.
REM Use only where authorized; this cannot override centrally enforced security policy.
if "%~1"=="" goto GUI
if /i "%~1"=="gui" goto GUI
if /i "%~1"=="demo" goto DEMO
if /i "%~1"=="diagnostics" goto DIAGNOSTICS
if /i "%~1"=="check" goto DIAGNOSTICS
if /i "%~1"=="-Demo" goto ARGUMENTS
if /i "%~1"=="-NoBrowser" goto ARGUMENTS
if /i "%~1"=="-Port" goto ARGUMENTS
echo [PacketRat] Unknown mode: %~1
echo Usage: Launch-PacketRat.bat [gui ^| demo ^| diagnostics]
echo        Launch-PacketRat.bat -NoBrowser
echo        Launch-PacketRat.bat -Port 8766
exit /b 2

:GUI
echo [PacketRat] Opening local browser GUI...
powershell.exe -NoProfile -NoLogo -STA -ExecutionPolicy Bypass -File "%ROOT%Start-PacketRat-Web.ps1"
goto FINISH

:ARGUMENTS
powershell.exe -NoProfile -NoLogo -STA -ExecutionPolicy Bypass -File "%ROOT%Start-PacketRat-Web.ps1" %*
goto FINISH

:DEMO
echo [PacketRat] Opening offline demonstration...
powershell.exe -NoProfile -NoLogo -STA -ExecutionPolicy Bypass -File "%ROOT%Start-PacketRat-Web.ps1" -Demo
goto FINISH

:DIAGNOSTICS
echo [PacketRat] Running safe local startup checks...
powershell.exe -NoProfile -NoLogo -STA -ExecutionPolicy Bypass -File "%ROOT%tools\Test-PacketRatStartup.ps1"
goto FINISH

:FINISH
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" (
  echo.
  echo [PacketRat] Failed with exit code %EXIT_CODE%.
  echo Run Launch-PacketRat.bat diagnostics to check PowerShell syntax and startup prerequisites.
  echo Do not attempt to override centrally enforced workstation security restrictions.
  pause
)
exit /b %EXIT_CODE%
