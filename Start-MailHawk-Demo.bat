@echo off
setlocal EnableExtensions DisableDelayedExpansion
REM Use the same startup path and process-scoped policy as the normal GUI.
call "%~dp0Start-MailHawk-Web.bat" -Demo %*
exit /b %ERRORLEVEL%
