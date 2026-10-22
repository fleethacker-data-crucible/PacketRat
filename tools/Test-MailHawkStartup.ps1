#requires -Version 5.1
<#
  Safe workstation startup preflight: read-only checks plus ephemeral TCP bind.
  Does not load ARC, connect to Outlook, query email, or change security policy.
#>
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$failures=New-Object System.Collections.Generic.List[string]
Write-Host '=== MailHawk Startup Preflight ===' -ForegroundColor Cyan
Write-Host ('PowerShell version: ' + $PSVersionTable.PSVersion.ToString())
Write-Host ('PowerShell edition: ' + $PSVersionTable.PSEdition)
Write-Host ('Process policy: ' + (Get-ExecutionPolicy -Scope Process))
Write-Host ('Effective policy: ' + (Get-ExecutionPolicy))
$policy=Get-ExecutionPolicy -List
$machinePolicy=($policy | Where-Object Scope -eq 'MachinePolicy' | Select-Object -First 1).ExecutionPolicy
$userPolicy=($policy | Where-Object Scope -eq 'UserPolicy' | Select-Object -First 1).ExecutionPolicy
if(($machinePolicy -and $machinePolicy -ne 'Undefined') -or ($userPolicy -and $userPolicy -ne 'Undefined')) {
  Write-Host 'Note: A centrally managed execution policy applies. Organizational policy takes precedence.' -ForegroundColor Yellow
}
if($PSVersionTable.PSVersion.Major -lt 5){$failures.Add('Windows PowerShell 5.1 or later is required.')}
$required=@(
  'Start-MailHawk-Web.ps1','MailHawk.bat','MailHawk-CLI.bat',
  'Web/index.html','Web/app.js','Web/style.css',
  'Web/mailhawk-logo.png','Web/mailhawk-icon.png',
  'Private/ArcBridge.ps1','Private/MailHawkLlm.ps1',
  'Private/MailHawkStore.ps1','Private/Get-OutlookMailSummary.ps1',
  'Private/MailHawkDraft.ps1','Private/MailHawkGraph.ps1',
  'Private/MailHawkLogging.ps1','Public/Invoke-MailHawkInboxAnalysis.ps1'
)
foreach($relative in $required) {
  $path=Join-Path $root $relative
  if(-not (Test-Path -LiteralPath $path -PathType Leaf)){$failures.Add('Missing file: '+$relative)}
}
foreach($relative in @('Start-MailHawk-Web.ps1','tools/Test-MailHawkStartup.ps1',
  'Private/ArcBridge.ps1','Private/MailHawkLlm.ps1','Private/MailHawkStore.ps1',
  'Private/Get-OutlookMailSummary.ps1','Private/MailHawkDraft.ps1',
  'Private/MailHawkGraph.ps1','Private/MailHawkLogging.ps1',
  'Public/Invoke-MailHawkInboxAnalysis.ps1')) {
  $path=Join-Path $root $relative
  if(-not(Test-Path -LiteralPath $path)){continue}
  $tokens=$null; $errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
  if($errors.Count -gt 0){$failures.Add('PowerShell parse error in '+$relative+': '+$errors[0].Message)}
}
try {
  $tcp=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
  $tcp.Start()
  Write-Host ('Loopback TCP bind: OK (ephemeral port '+([Net.IPEndPoint]$tcp.LocalEndpoint).Port+')') -ForegroundColor Green
} catch {
  $failures.Add('Local loopback port bind failed: '+$_.Exception.Message)
} finally { if($tcp){try{$tcp.Stop()}catch{}} }
if($failures.Count -gt 0){
  Write-Host 'Preflight failures:' -ForegroundColor Red
  foreach($entry in $failures){Write-Host (' - '+$entry) -ForegroundColor Red}
  exit 1
}
Write-Host 'Preflight OK. Real Outlook, AI provider and ARC credentials were not tested.' -ForegroundColor Green
exit 0
