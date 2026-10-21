@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -NoLogo -STA -File "%~dp0Start-MailHawk-Web.ps1"
if errorlevel 1 pause
