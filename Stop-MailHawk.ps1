#requires -Version 5.1
<#
 .SYNOPSIS
  Stops every running MailHawk browser server on this machine.
 .DESCRIPTION
  The server normally stops itself when its browser tab closes, or from End session in the
  browser. This is the fallback when a hidden PowerShell window is still holding the port:
  it reads the runtime files under Logs\ (one per server process), then looks for any other
  PowerShell running Start-MailHawk-Web.ps1, and stops them. No PIDs needed.
 .PARAMETER Quiet
  Print nothing unless something was stopped.
 .EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Stop-MailHawk.ps1
#>
[CmdletBinding()]
param([switch]$Quiet)
$ErrorActionPreference='Stop'
$Root=$PSScriptRoot
. (Join-Path $Root 'Private\MailHawkLifecycle.ps1')
$stopped=@(Stop-MailHawkProcesses -Root $Root)
if($stopped.Count -gt 0){
    foreach($server in $stopped){Write-Host ('Stopped MailHawk '+(Format-MailHawkProcess $server)+'.') -ForegroundColor Yellow}
}elseif(-not $Quiet){
    Write-Host 'No MailHawk server is running.' -ForegroundColor DarkGray
}
exit 0
