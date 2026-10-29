@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "ROOT=%~dp0"
cd /d "%ROOT%" || (echo [PacketRat] Cannot access the application directory. & pause & exit /b 1)
where powershell.exe >nul 2>&1 || (echo [PacketRat] Windows PowerShell is unavailable. & pause & exit /b 1)

REM PacketRat-CLI.bat <noun> <verb> [--option value] [--json]: one named command, the same actions as the browser UI
REM (Invoke-PacketRatCli.ps1; "PacketRat-CLI.bat commands" lists them). No pause, so scripts and agents can use it.
REM With no command word, or options only, this is the console analysis below, as before.
set "FIRST=%~1"
if not defined FIRST goto console
if "%FIRST:~0,1%"=="-" goto console
powershell.exe -NoProfile -NoLogo -STA -ExecutionPolicy Bypass -File "%ROOT%Invoke-PacketRatCli.ps1" %*
exit /b %ERRORLEVEL%

:console
REM Console-only PacketRat analysis. The old WinForms interface is not a launcher.
REM Process-scoped execution policy matches Lazarette/Halyard startup convention when allowed.
echo [PacketRat] Starting console analysis...
powershell.exe -NoProfile -NoLogo -STA -ExecutionPolicy Bypass -File "%ROOT%Start-PacketRat.ps1" -ConsoleOnly %*
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" (
  echo.
  echo [PacketRat] Console exited with error %EXIT_CODE%.
  echo Use Launch-PacketRat.bat diagnostics if initialization fails.
  pause
)
exit /b %EXIT_CODE%
