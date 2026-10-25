@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "ROOT=%~dp0"
cd /d "%ROOT%" || (echo [PacketRat] Cannot access the application directory. & pause & exit /b 1)
where powershell.exe >nul 2>&1 || (echo [PacketRat] Windows PowerShell is unavailable. & pause & exit /b 1)

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
