#requires -Version 5.1
# Offline, deterministic lifecycle tests: simulated clock, no sockets, no Outlook, no LLM.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Private/MailHawkLifecycle.ps1')
function Assert-Lifecycle([bool]$Pass,[string]$Message){if(-not $Pass){throw ('Lifecycle test failed: '+$Message)}}

$t0=[DateTime]::new(2026,1,1,12,0,0,[DateTimeKind]::Utc)

# Server stops itself only after the browser is gone.
$state=New-MailHawkPresence -AutoStop $true
Assert-Lifecycle (-not (Test-MailHawkBrowserGone -State $state -Now $t0.AddMinutes(5))) 'never stops before any tab connected (-NoBrowser)'
Register-MailHawkPresence -State $state -Tab 'tab-a' -Now $t0
Assert-Lifecycle (-not (Test-MailHawkBrowserGone -State $state -Now $t0.AddSeconds(19))) 'alive within 20 s of heartbeat'
Assert-Lifecycle (Test-MailHawkBrowserGone -State $state -Now $t0.AddSeconds(20)) 'stops 20 s after last heartbeat'
Register-MailHawkPresence -State $state -Tab 'tab-a' -Now $t0.AddSeconds(15)
Assert-Lifecycle (-not (Test-MailHawkBrowserGone -State $state -Now $t0.AddSeconds(30))) 'fresh heartbeat extends the timeout'

# Leaving signal: 5 s grace, cancelled by a new heartbeat.
$state=New-MailHawkPresence -AutoStop $true
Register-MailHawkPresence -State $state -Tab 'tab-a' -Now $t0
Register-MailHawkPresence -State $state -Tab 'tab-a' -Leaving -Now $t0.AddSeconds(1)
Assert-Lifecycle (-not (Test-MailHawkBrowserGone -State $state -Now $t0.AddSeconds(5))) 'leaving grace not yet over'
Assert-Lifecycle (Test-MailHawkBrowserGone -State $state -Now $t0.AddSeconds(6)) 'stops 5 s after leaving signal'
Register-MailHawkPresence -State $state -Tab 'tab-a' -Now $t0.AddSeconds(3)
Assert-Lifecycle (-not (Test-MailHawkBrowserGone -State $state -Now $t0.AddSeconds(6))) 'heartbeat after leaving cancels the stop'

# Reload: the old page sends leaving, the new page heartbeats under a new tab id.
$state=New-MailHawkPresence -AutoStop $true
Register-MailHawkPresence -State $state -Tab 'old-page' -Now $t0
Register-MailHawkPresence -State $state -Tab 'old-page' -Leaving -Now $t0.AddSeconds(2)
Register-MailHawkPresence -State $state -Tab 'new-page' -Now $t0.AddSeconds(3)
Assert-Lifecycle (-not (Test-MailHawkBrowserGone -State $state -Now $t0.AddSeconds(10))) 'reload does not stop the server'
Assert-Lifecycle ((Get-MailHawkLiveTabCount -State $state -Now $t0.AddSeconds(10)) -eq 1) 'reloaded page counts as the one live tab'

# Two tabs: closing one keeps the server; it stops only when none is alive.
$state=New-MailHawkPresence -AutoStop $true
Register-MailHawkPresence -State $state -Tab 'tab-a' -Now $t0
Register-MailHawkPresence -State $state -Tab 'tab-b' -Now $t0
Register-MailHawkPresence -State $state -Tab 'tab-a' -Leaving -Now $t0.AddSeconds(1)
Register-MailHawkPresence -State $state -Tab 'tab-b' -Now $t0.AddSeconds(10)
Assert-Lifecycle (-not (Test-MailHawkBrowserGone -State $state -Now $t0.AddSeconds(12))) 'second tab keeps the server alive'
Register-MailHawkPresence -State $state -Tab 'tab-b' -Leaving -Now $t0.AddSeconds(13)
Assert-Lifecycle (Test-MailHawkBrowserGone -State $state -Now $t0.AddSeconds(18)) 'stops when the last tab leaves'

# Never mid-write: a running request blocks the stop; time spent busy is not tab silence.
$state=New-MailHawkPresence -AutoStop $true
Register-MailHawkPresence -State $state -Tab 'tab-a' -Now $t0
Assert-Lifecycle (-not (Test-MailHawkBrowserGone -State $state -Now $t0.AddSeconds(90) -JobRunning)) 'no stop while a job runs'
Assert-Lifecycle (-not (Test-MailHawkBrowserGone -State $state -Now $t0.AddSeconds(95) -BusyUntil $t0.AddSeconds(90))) 'no stop right after a long scan'
Assert-Lifecycle (Test-MailHawkBrowserGone -State $state -Now $t0.AddSeconds(111) -BusyUntil $t0.AddSeconds(90)) 'stops once the tab stays silent after the scan'
Register-MailHawkPresence -State $state -Tab 'tab-a' -Leaving -Now $t0.AddSeconds(30)
Assert-Lifecycle (Test-MailHawkBrowserGone -State $state -Now $t0.AddSeconds(91) -BusyUntil $t0.AddSeconds(90)) 'tab that left during a scan stops on the next tick after it'

# Off switch: -Stay or MAILHAWK_AUTO_STOP=0.
$saved=[Environment]::GetEnvironmentVariable('MAILHAWK_AUTO_STOP','Process')
try {
    [Environment]::SetEnvironmentVariable('MAILHAWK_AUTO_STOP',$null,'Process')
    Assert-Lifecycle (Test-MailHawkAutoStopEnabled) 'auto-stop on by default'
    Assert-Lifecycle (-not (Test-MailHawkAutoStopEnabled -Stay)) '-Stay disables auto-stop'
    [Environment]::SetEnvironmentVariable('MAILHAWK_AUTO_STOP','0','Process')
    Assert-Lifecycle (-not (Test-MailHawkAutoStopEnabled)) 'MAILHAWK_AUTO_STOP=0 disables auto-stop'
    [Environment]::SetEnvironmentVariable('MAILHAWK_AUTO_STOP','1','Process')
    Assert-Lifecycle (Test-MailHawkAutoStopEnabled) 'MAILHAWK_AUTO_STOP=1 keeps auto-stop'
} finally { [Environment]::SetEnvironmentVariable('MAILHAWK_AUTO_STOP',$saved,'Process') }
$state=New-MailHawkPresence -AutoStop $false
Register-MailHawkPresence -State $state -Tab 'tab-a' -Now $t0
Assert-Lifecycle (-not (Test-MailHawkBrowserGone -State $state -Now $t0.AddHours(2))) 'disabled auto-stop never stops'

# Beacon token: body field only, exact match.
Assert-Lifecycle (Test-MailHawkBeaconToken -Data ([pscustomobject]@{token='abc';leaving=$true}) -Expected 'abc') 'beacon token accepted'
Assert-Lifecycle (-not (Test-MailHawkBeaconToken -Data ([pscustomobject]@{token='ABC'}) -Expected 'abc')) 'beacon token is case-sensitive'
Assert-Lifecycle (-not (Test-MailHawkBeaconToken -Data ([pscustomobject]@{leaving=$true}) -Expected 'abc')) 'missing beacon token rejected'
Assert-Lifecycle (-not (Test-MailHawkBeaconToken -Data $null -Expected 'abc')) 'empty beacon body rejected'

# Runtime file: written without the nonce, found while live, removed when stale.
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('mh-life-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testRoot -Force)
try {
    $file=Write-MailHawkRuntimeFile -Root $testRoot -Port 8766 -Url 'http://127.0.0.1:8766/'
    Assert-Lifecycle ((Split-Path $file -Leaf) -eq ('mailhawk-server-'+$PID+'.json')) 'runtime file named by pid'
    $info=[IO.File]::ReadAllText($file) | ConvertFrom-Json
    $names=@($info.PSObject.Properties | ForEach-Object {$_.Name})
    Assert-Lifecycle ((($names | Sort-Object) -join ',') -eq 'pid,port,startedAt,url') 'runtime file holds pid, port, url, startedAt only'
    $live=@(Get-MailHawkRuntimeEntries -Root $testRoot)
    Assert-Lifecycle ($live.Count -eq 1 -and $live[0].Pid -eq $PID) 'live runtime file found'
    Assert-Lifecycle (@(Get-MailHawkProcesses -Root $testRoot | Where-Object {$_.Pid -eq $PID}).Count -eq 0) 'own process never reported as another instance'
    $stale=Join-Path (Split-Path $file -Parent) 'mailhawk-server-999999.json'
    [IO.File]::WriteAllText($stale,'{"pid":999999,"port":1,"url":"http://127.0.0.1:1/","startedAt":"2026-01-01T00:00:00Z"}')
    $null=Get-MailHawkRuntimeEntries -Root $testRoot
    Assert-Lifecycle (-not (Test-Path -LiteralPath $stale)) 'stale runtime file removed on sight'
    $broken=Join-Path (Split-Path $file -Parent) 'mailhawk-server-1.json'
    [IO.File]::WriteAllText($broken,'not json')
    $null=Get-MailHawkRuntimeEntries -Root $testRoot
    Assert-Lifecycle (-not (Test-Path -LiteralPath $broken)) 'unreadable runtime file removed'
    Remove-MailHawkRuntimeFile -Path $file
    Assert-Lifecycle (-not (Test-Path -LiteralPath $file)) 'runtime file removed on stop'
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# Server wiring (static): lifecycle routes and the token rules stay in place.
$service=[IO.File]::ReadAllText((Join-Path $root 'Start-MailHawk-Web.ps1'))
foreach($needle in @("'/api/heartbeat'","'/api/session/stop'",'Write-MailHawkRuntimeFile','Remove-MailHawkRuntimeFile','Test-MailHawkBeaconToken','Test-MailHawkBrowserGone','Get-MailHawkProcesses')){
    Assert-Lifecycle ($service.Contains($needle)) ('service uses '+$needle)
}
Assert-Lifecycle (-not ($service -match 'Write-[A-Za-z]+ .*\$Data\b')) 'request bodies are never written out'
Write-Host 'MailHawk lifecycle (presence, runtime file, beacon token) tests passed' -ForegroundColor Green
