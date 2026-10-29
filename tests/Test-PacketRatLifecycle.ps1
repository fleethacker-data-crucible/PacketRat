#requires -Version 5.1
# Offline, deterministic lifecycle tests: simulated clock, no sockets, no Outlook, no LLM.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Private/PacketRatLifecycle.ps1')
function Assert-Lifecycle([bool]$Pass,[string]$Message){if(-not $Pass){throw ('Lifecycle test failed: '+$Message)}}

$t0=[DateTime]::new(2026,1,1,12,0,0,[DateTimeKind]::Utc)

# Server stops itself only after the browser is gone.
$state=New-PacketRatPresence -AutoStop $true
Assert-Lifecycle (-not (Test-PacketRatBrowserGone -State $state -Now $t0.AddMinutes(5))) 'never stops before any tab connected (-NoBrowser)'
Register-PacketRatPresence -State $state -Tab 'tab-a' -Now $t0
Assert-Lifecycle (-not (Test-PacketRatBrowserGone -State $state -Now $t0.AddSeconds(19))) 'alive within 20 s of heartbeat'
Assert-Lifecycle (Test-PacketRatBrowserGone -State $state -Now $t0.AddSeconds(20)) 'stops 20 s after last heartbeat'
Register-PacketRatPresence -State $state -Tab 'tab-a' -Now $t0.AddSeconds(15)
Assert-Lifecycle (-not (Test-PacketRatBrowserGone -State $state -Now $t0.AddSeconds(30))) 'fresh heartbeat extends the timeout'

# Leaving signal: 5 s grace, cancelled by a new heartbeat.
$state=New-PacketRatPresence -AutoStop $true
Register-PacketRatPresence -State $state -Tab 'tab-a' -Now $t0
Register-PacketRatPresence -State $state -Tab 'tab-a' -Leaving -Now $t0.AddSeconds(1)
Assert-Lifecycle (-not (Test-PacketRatBrowserGone -State $state -Now $t0.AddSeconds(5))) 'leaving grace not yet over'
Assert-Lifecycle (Test-PacketRatBrowserGone -State $state -Now $t0.AddSeconds(6)) 'stops 5 s after leaving signal'
Register-PacketRatPresence -State $state -Tab 'tab-a' -Now $t0.AddSeconds(3)
Assert-Lifecycle (-not (Test-PacketRatBrowserGone -State $state -Now $t0.AddSeconds(6))) 'heartbeat after leaving cancels the stop'

# Reload: the old page sends leaving, the new page heartbeats under a new tab id.
$state=New-PacketRatPresence -AutoStop $true
Register-PacketRatPresence -State $state -Tab 'old-page' -Now $t0
Register-PacketRatPresence -State $state -Tab 'old-page' -Leaving -Now $t0.AddSeconds(2)
Register-PacketRatPresence -State $state -Tab 'new-page' -Now $t0.AddSeconds(3)
Assert-Lifecycle (-not (Test-PacketRatBrowserGone -State $state -Now $t0.AddSeconds(10))) 'reload does not stop the server'
Assert-Lifecycle ((Get-PacketRatLiveTabCount -State $state -Now $t0.AddSeconds(10)) -eq 1) 'reloaded page counts as the one live tab'

# Two tabs: closing one keeps the server; it stops only when none is alive.
$state=New-PacketRatPresence -AutoStop $true
Register-PacketRatPresence -State $state -Tab 'tab-a' -Now $t0
Register-PacketRatPresence -State $state -Tab 'tab-b' -Now $t0
Register-PacketRatPresence -State $state -Tab 'tab-a' -Leaving -Now $t0.AddSeconds(1)
Register-PacketRatPresence -State $state -Tab 'tab-b' -Now $t0.AddSeconds(10)
Assert-Lifecycle (-not (Test-PacketRatBrowserGone -State $state -Now $t0.AddSeconds(12))) 'second tab keeps the server alive'
Register-PacketRatPresence -State $state -Tab 'tab-b' -Leaving -Now $t0.AddSeconds(13)
Assert-Lifecycle (Test-PacketRatBrowserGone -State $state -Now $t0.AddSeconds(18)) 'stops when the last tab leaves'

# Never mid-write: a running request blocks the stop; time spent busy is not tab silence.
$state=New-PacketRatPresence -AutoStop $true
Register-PacketRatPresence -State $state -Tab 'tab-a' -Now $t0
Assert-Lifecycle (-not (Test-PacketRatBrowserGone -State $state -Now $t0.AddSeconds(90) -JobRunning)) 'no stop while a job runs'
Assert-Lifecycle (-not (Test-PacketRatBrowserGone -State $state -Now $t0.AddSeconds(95) -BusyUntil $t0.AddSeconds(90))) 'no stop right after a long scan'
Assert-Lifecycle (Test-PacketRatBrowserGone -State $state -Now $t0.AddSeconds(111) -BusyUntil $t0.AddSeconds(90)) 'stops once the tab stays silent after the scan'
Register-PacketRatPresence -State $state -Tab 'tab-a' -Leaving -Now $t0.AddSeconds(30)
Assert-Lifecycle (Test-PacketRatBrowserGone -State $state -Now $t0.AddSeconds(91) -BusyUntil $t0.AddSeconds(90)) 'tab that left during a scan stops on the next tick after it'

# Off switch: -Stay or PACKETRAT_AUTO_STOP=0.
$saved=[Environment]::GetEnvironmentVariable('PACKETRAT_AUTO_STOP','Process')
try {
    [Environment]::SetEnvironmentVariable('PACKETRAT_AUTO_STOP',$null,'Process')
    Assert-Lifecycle (Test-PacketRatAutoStopEnabled) 'auto-stop on by default'
    Assert-Lifecycle (-not (Test-PacketRatAutoStopEnabled -Stay)) '-Stay disables auto-stop'
    [Environment]::SetEnvironmentVariable('PACKETRAT_AUTO_STOP','0','Process')
    Assert-Lifecycle (-not (Test-PacketRatAutoStopEnabled)) 'PACKETRAT_AUTO_STOP=0 disables auto-stop'
    [Environment]::SetEnvironmentVariable('PACKETRAT_AUTO_STOP','1','Process')
    Assert-Lifecycle (Test-PacketRatAutoStopEnabled) 'PACKETRAT_AUTO_STOP=1 keeps auto-stop'
    # Rename compatibility: the former MAILHAWK_AUTO_STOP is read only when PACKETRAT_AUTO_STOP is unset.
    $savedLegacy=[Environment]::GetEnvironmentVariable('MAILHAWK_AUTO_STOP','Process')
    try {
        [Environment]::SetEnvironmentVariable('PACKETRAT_AUTO_STOP',$null,'Process')
        [Environment]::SetEnvironmentVariable('MAILHAWK_AUTO_STOP','0','Process')
        Assert-Lifecycle (-not (Test-PacketRatAutoStopEnabled)) 'legacy MAILHAWK_AUTO_STOP=0 still disables auto-stop'
        [Environment]::SetEnvironmentVariable('PACKETRAT_AUTO_STOP','1','Process')
        Assert-Lifecycle (Test-PacketRatAutoStopEnabled) 'PACKETRAT_AUTO_STOP wins over MAILHAWK_AUTO_STOP'
    } finally { [Environment]::SetEnvironmentVariable('MAILHAWK_AUTO_STOP',$savedLegacy,'Process') }
} finally { [Environment]::SetEnvironmentVariable('PACKETRAT_AUTO_STOP',$saved,'Process') }
$state=New-PacketRatPresence -AutoStop $false
Register-PacketRatPresence -State $state -Tab 'tab-a' -Now $t0
Assert-Lifecycle (-not (Test-PacketRatBrowserGone -State $state -Now $t0.AddHours(2))) 'disabled auto-stop never stops'

# Beacon token: body field only, exact match.
Assert-Lifecycle (Test-PacketRatBeaconToken -Data ([pscustomobject]@{token='abc';leaving=$true}) -Expected 'abc') 'beacon token accepted'
Assert-Lifecycle (-not (Test-PacketRatBeaconToken -Data ([pscustomobject]@{token='ABC'}) -Expected 'abc')) 'beacon token is case-sensitive'
Assert-Lifecycle (-not (Test-PacketRatBeaconToken -Data ([pscustomobject]@{leaving=$true}) -Expected 'abc')) 'missing beacon token rejected'
Assert-Lifecycle (-not (Test-PacketRatBeaconToken -Data $null -Expected 'abc')) 'empty beacon body rejected'

# Runtime file: written without the nonce, found while live, removed when stale.
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('pr-life-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testRoot -Force)
try {
    $file=Write-PacketRatRuntimeFile -Root $testRoot -Port 8766 -Url 'http://127.0.0.1:8766/'
    Assert-Lifecycle ((Split-Path $file -Leaf) -eq ('packetrat-server-'+$PID+'.json')) 'runtime file named by pid'
    $info=[IO.File]::ReadAllText($file) | ConvertFrom-Json
    $names=@($info.PSObject.Properties | ForEach-Object {$_.Name})
    Assert-Lifecycle ((($names | Sort-Object) -join ',') -eq 'pid,port,startedAt,url') 'runtime file holds pid, port, url, startedAt only'
    $live=@(Get-PacketRatRuntimeEntries -Root $testRoot)
    Assert-Lifecycle ($live.Count -eq 1 -and $live[0].Pid -eq $PID) 'live runtime file found'
    Assert-Lifecycle (@(Get-PacketRatProcesses -Root $testRoot | Where-Object {$_.Pid -eq $PID}).Count -eq 0) 'own process never reported as another instance'
    $stale=Join-Path (Split-Path $file -Parent) 'packetrat-server-999999.json'
    [IO.File]::WriteAllText($stale,'{"pid":999999,"port":1,"url":"http://127.0.0.1:1/","startedAt":"2026-01-01T00:00:00Z"}')
    $null=Get-PacketRatRuntimeEntries -Root $testRoot
    Assert-Lifecycle (-not (Test-Path -LiteralPath $stale)) 'stale runtime file removed on sight'
    $broken=Join-Path (Split-Path $file -Parent) 'packetrat-server-1.json'
    [IO.File]::WriteAllText($broken,'not json')
    $null=Get-PacketRatRuntimeEntries -Root $testRoot
    Assert-Lifecycle (-not (Test-Path -LiteralPath $broken)) 'unreadable runtime file removed'
    # A server started by an older MailHawk build wrote mailhawk-server-<pid>.json: still discovered and swept.
    $legacyLive=Join-Path (Split-Path $file -Parent) ('mailhawk-server-'+$PID+'.json')
    [IO.File]::Copy($file,$legacyLive)
    Assert-Lifecycle (@(Get-PacketRatRuntimeEntries -Root $testRoot | Where-Object {$_.File -eq $legacyLive}).Count -eq 1) 'legacy mailhawk-server runtime file found'
    Remove-Item -LiteralPath $legacyLive -Force
    $legacyStale=Join-Path (Split-Path $file -Parent) 'mailhawk-server-999998.json'
    [IO.File]::WriteAllText($legacyStale,'{"pid":999998,"port":1,"url":"http://127.0.0.1:1/","startedAt":"2026-01-01T00:00:00Z"}')
    $null=Get-PacketRatRuntimeEntries -Root $testRoot
    Assert-Lifecycle (-not (Test-Path -LiteralPath $legacyStale)) 'stale legacy runtime file removed on sight'
    Remove-PacketRatRuntimeFile -Path $file
    Assert-Lifecycle (-not (Test-Path -LiteralPath $file)) 'runtime file removed on stop'
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# Server wiring (static): lifecycle routes and the token rules stay in place.
# The server plus the command core it shares with the CLI (Private/PacketRatApi.ps1).
$service=[IO.File]::ReadAllText((Join-Path $root 'Start-PacketRat-Web.ps1'))+[IO.File]::ReadAllText((Join-Path $root 'Private/PacketRatApi.ps1'))
foreach($needle in @("'/api/heartbeat'","'/api/session/stop'",'Write-PacketRatRuntimeFile','Remove-PacketRatRuntimeFile','Test-PacketRatBeaconToken','Test-PacketRatBrowserGone','Get-PacketRatProcesses')){
    Assert-Lifecycle ($service.Contains($needle)) ('service uses '+$needle)
}
$life=[IO.File]::ReadAllText((Join-Path $root 'Private/PacketRatLifecycle.ps1'))
Assert-Lifecycle ($life.Contains("'Start-(PacketRat|MailHawk)-Web\.ps1'")) 'process scan also finds an older MailHawk server'
Assert-Lifecycle (-not ($service -match 'Write-[A-Za-z]+ .*\$Data\b')) 'request bodies are never written out'
Write-Host 'PacketRat lifecycle (presence, runtime file, beacon token) tests passed' -ForegroundColor Green
