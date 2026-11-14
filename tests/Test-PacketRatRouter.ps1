#requires -Version 5.1
# Offline tests for starting Fairlead on demand. No real Fairlead is started and no dialog is shown: the process start, the
# dialog and the port check are replaced by fakes. Synthetic folders only.
$ErrorActionPreference='Stop'
$Root=Split-Path $PSScriptRoot -Parent
. (Join-Path $Root 'Private\PacketRatLlm.ps1')
. (Join-Path $Root 'Private\PacketRatRouter.ps1')
function Assert-Router([bool]$Pass,[string]$Message){if(-not $Pass){throw ('Router test failed: '+$Message)}}

$tmp=Join-Path ([IO.Path]::GetTempPath()) ('packetrat-router-'+[guid]::NewGuid().ToString('N'))
$fairlead=Join-Path $tmp 'Fairlead'; [void](New-Item -ItemType Directory -Path (Join-Path $fairlead 'scripts') -Force)
[IO.File]::WriteAllText((Join-Path $fairlead 'scripts\Start-Fairlead.ps1'),'# stand-in')
$cfgFile=Join-Path $tmp 'fairlead.json'
$names='PACKETRAT_FAIRLEAD_AUTOSTART','PACKETRAT_FAIRLEAD_URL','PACKETRAT_FAIRLEAD_CONFIG','FAIRLEAD_DIR','FAIRLEAD_PATH'
$saved=@{};foreach($n in $names){$saved[$n]=[Environment]::GetEnvironmentVariable($n)}
function Reset-Env { foreach($n in $names){[Environment]::SetEnvironmentVariable($n,$null)}; $env:PACKETRAT_FAIRLEAD_CONFIG=$cfgFile; $env:FAIRLEAD_DIR=$fairlead; $script:Up=$false; $script:UpAfterStart=$true; $script:Started=@(); $script:Prompts=0; $script:Choice='use' }
# Fakes
function Test-PacketRatFairleadUp { param([Uri]$Uri) return $script:Up }
function Start-PacketRatFairleadProcess { param([string]$Dir,[switch]$OpenSetup) $script:Started+=,@{Dir=$Dir;Open=[bool]$OpenSetup}; if($script:UpAfterStart){$script:Up=$true} }
function Show-PacketRatFairleadChoice { $script:Prompts++; return $script:Choice }
function Set-Setup([string]$state){ Remove-Item $cfgFile -ErrorAction SilentlyContinue; if($state -eq 'complete'){ '{"setupComplete":true}' | Set-Content $cfgFile } elseif($state -eq 'incomplete'){ '{"setupComplete":false}' | Set-Content $cfgFile } elseif($state -eq 'broken'){ '{not json' | Set-Content $cfgFile } }

try{
    # --- off switches ---
    Reset-Env; $env:PACKETRAT_FAIRLEAD_AUTOSTART='off'
    $r=Ensure-PacketRatFairlead -Root $Root
    Assert-Router ($r.State -eq 'Skipped' -and $script:Started.Count -eq 0) 'autostart off: nothing happens'
    Reset-Env; $env:PACKETRAT_FAIRLEAD_URL='https://fairlead.example.test/v1/chat/completions'
    $r=Ensure-PacketRatFairlead -Root $Root
    Assert-Router ($r.State -eq 'Skipped' -and $r.Message -match 'not on this PC' -and $script:Started.Count -eq 0) 'a remote Fairlead is never started'
    Reset-Env; $env:PACKETRAT_FAIRLEAD_URL='not a url'
    Assert-Router ((Ensure-PacketRatFairlead -Root $Root).State -eq 'Failed') 'a bad address is reported'

    # --- already running: no start, no prompt ---
    Reset-Env; $script:Up=$true; Set-Setup 'complete'
    $r=Ensure-PacketRatFairlead -Root $Root -Interactive
    Assert-Router ($r.State -eq 'AlreadyRunning' -and $script:Started.Count -eq 0 -and $script:Prompts -eq 0) 'already running: used as is, no dialog'

    # --- not running, never set up: start and open the setup page ---
    Reset-Env; Set-Setup 'new'
    $r=Ensure-PacketRatFairlead -Root $Root -Interactive -WaitSeconds 2
    Assert-Router ($r.State -eq 'StartedForSetup' -and $script:Started.Count -eq 1 -and $script:Started[0].Open -and $script:Prompts -eq 0) 'first run: started with the setup page, no dialog'
    Assert-Router ($script:Started[0].Dir -eq (Resolve-Path $fairlead).Path) 'it starts the Fairlead folder it found'
    Reset-Env; Set-Setup 'incomplete'
    Assert-Router ((Ensure-PacketRatFairlead -Root $Root -WaitSeconds 2).State -eq 'StartedForSetup') 'an unfinished setup opens the setup page'
    Reset-Env; Set-Setup 'broken'
    Assert-Router ((Ensure-PacketRatFairlead -Root $Root -WaitSeconds 2).State -eq 'StartedForSetup') 'an unreadable settings file counts as unfinished'

    # --- not running, already set up ---
    Reset-Env; Set-Setup 'complete'; $script:Choice='use'
    $r=Ensure-PacketRatFairlead -Root $Root -Interactive -WaitSeconds 2
    Assert-Router ($r.State -eq 'Started' -and $script:Prompts -eq 1 -and -not $script:Started[0].Open) 'set up + "use previous": asked once, started without the setup page'
    Reset-Env; Set-Setup 'complete'; $script:Choice='reconfigure'
    $r=Ensure-PacketRatFairlead -Root $Root -Interactive -WaitSeconds 2
    Assert-Router ($r.State -eq 'StartedForSetup' -and $script:Started[0].Open) 'set up + "reconfigure": started with the setup page'
    Reset-Env; Set-Setup 'complete'; $script:Choice='cancel'
    $r=Ensure-PacketRatFairlead -Root $Root -Interactive -WaitSeconds 2
    Assert-Router ($r.State -eq 'Declined' -and $script:Started.Count -eq 0) 'set up + cancel: nothing is started'
    Reset-Env; Set-Setup 'complete'
    $r=Ensure-PacketRatFairlead -Root $Root -WaitSeconds 2
    Assert-Router ($r.State -eq 'Started' -and $script:Prompts -eq 0 -and -not $script:Started[0].Open) 'non-interactive (CLI, headless): previous setup, no dialog'

    # --- problems ---
    Reset-Env; $env:FAIRLEAD_DIR=Join-Path $tmp 'nowhere'; Set-Setup 'complete'
    $saveUp=$env:USERPROFILE; $env:USERPROFILE=Join-Path $tmp 'nobody'
    $r=Ensure-PacketRatFairlead -Root (Join-Path (Join-Path $tmp 'alone') 'PacketRat')
    $env:USERPROFILE=$saveUp
    Assert-Router ($r.State -eq 'NotFound' -and $r.Message -match 'FAIRLEAD_DIR' -and $script:Started.Count -eq 0) 'a missing Fairlead folder is explained'
    Reset-Env; Set-Setup 'complete'; $script:UpAfterStart=$false
    $t0=Get-Date; $r=Ensure-PacketRatFairlead -Root $Root -WaitSeconds 1
    Assert-Router ($r.State -eq 'Failed' -and $r.Message -match 'did not answer' -and ((Get-Date)-$t0).TotalSeconds -lt 8) 'a start that never answers fails after the wait, not forever'
    Reset-Env; $env:FAIRLEAD_DIR=$null; $sib=Join-Path $tmp 'sib'; [void](New-Item -ItemType Directory (Join-Path $sib 'PacketRat') -Force); Copy-Item $fairlead (Join-Path $sib 'Fairlead') -Recurse
    Assert-Router ((Get-PacketRatFairleadDir -Root (Join-Path $sib 'PacketRat')) -eq (Resolve-Path (Join-Path $sib 'Fairlead')).Path) 'a sibling Fairlead folder is found without any setting'
}finally{
    foreach($n in $names){[Environment]::SetEnvironmentVariable($n,$saved[$n])}
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# --- the real port check, against a real loopback listener ---
Remove-Item function:Test-PacketRatFairleadUp
. (Join-Path $Root 'Private\PacketRatRouter.ps1')
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0); $listener.Start()
try{
    $port=([Net.IPEndPoint]$listener.LocalEndpoint).Port
    Assert-Router (Test-PacketRatFairleadUp -Uri ([Uri]"http://127.0.0.1:$port/v1/chat/completions")) 'the port check sees a listener'
    $listener.Stop()
    Assert-Router (-not (Test-PacketRatFairleadUp -Uri ([Uri]"http://127.0.0.1:$port/"))) 'the port check sees a closed port'
    Assert-Router (-not (Test-PacketRatFairleadUp -Uri $null)) 'no address means not up'
}finally{ try{$listener.Stop()}catch{} }

# --- Start-FleetService, not a hand-rolled console start ----------------------------------------------
$tmp2=Join-Path ([IO.Path]::GetTempPath()) ('packetrat-fleetstart-'+[guid]::NewGuid().ToString('N'))
$fair2=Join-Path $tmp2 'Fairlead'
[void](New-Item -ItemType Directory -Path (Join-Path $fair2 'scripts') -Force)
[IO.File]::WriteAllText((Join-Path $fair2 'scripts\Start-Fairlead.ps1'),'# stand-in')
$cfg2=Join-Path $tmp2 'fairlead.json'
'{"setupComplete":true}' | Set-Content $cfg2
$names2='PACKETRAT_FAIRLEAD_AUTOSTART','PACKETRAT_FAIRLEAD_URL','PACKETRAT_FAIRLEAD_CONFIG','FAIRLEAD_DIR','FLEETPORT_MODULE'
$saved2=@{};foreach($n in $names2){$saved2[$n]=[Environment]::GetEnvironmentVariable($n)}
function Test-PacketRatFairleadUp { param([Uri]$Uri) return [bool]$script:Up2 }
try{
    foreach($n in $names2){[Environment]::SetEnvironmentVariable($n,$null)}
    $env:PACKETRAT_FAIRLEAD_CONFIG=$cfg2
    $env:FAIRLEAD_DIR=(Resolve-Path $fair2).Path
    $script:FleetCalls=@()
    $script:PacketRatFleetServiceStart={ param($Name,$Folder,$WaitSeconds) $script:FleetCalls+=[pscustomobject]@{Name=$Name;Folder=$Folder;Wait=$WaitSeconds}; $script:Up2=$true; return @{ State='starting'; Message='Fairlead is starting.' } }
    $script:Up2=$false
    $r=Ensure-PacketRatFairlead -Root $Root -WaitSeconds 2
    Assert-Router ($r.State -eq 'Started' -and $script:FleetCalls.Count -eq 1 -and $script:FleetCalls[0].Name -eq 'fairlead' -and $script:FleetCalls[0].Wait -eq 0) 'a start asks Start-FleetService for fairlead and does not wait inside the helper'
    Assert-Router ($script:FleetCalls[0].Folder -eq (Resolve-Path $fair2).Path) 'the Fairlead folder is passed through'

    $script:FleetCalls=@(); $script:Up2=$false
    $env:PACKETRAT_FAIRLEAD_AUTOSTART='off'
    $r=Ensure-PacketRatFairlead -Root $Root -WaitSeconds 5
    Assert-Router ($r.State -eq 'Skipped' -and $script:FleetCalls.Count -eq 0) 'PACKETRAT_FAIRLEAD_AUTOSTART=off never calls Start-FleetService'
    $env:PACKETRAT_FAIRLEAD_AUTOSTART=$null

    $script:PacketRatFleetServiceStart={ param($Name,$Folder,$WaitSeconds) return @{ State='unavailable'; Message='FleetPort was not found, so Fairlead was not started.' } }
    $t0=Get-Date
    $r=Ensure-PacketRatFairlead -Root $Root -WaitSeconds 30
    Assert-Router ($r.State -eq 'Failed' -and $r.Message -match 'FleetPort was not found' -and ((Get-Date)-$t0).TotalSeconds -lt 3) 'an unavailable helper fails at once with its own sentence'

    $mod=Join-Path $tmp2 'FleetPort.psm1'
    @'
function Start-FleetService { param([Parameter(Mandatory)][string]$Name,[string]$Folder,[int]$WaitSeconds=0) return @{ State='running'; Name=$Name; Folder=$Folder; Wait=$WaitSeconds } }
Export-ModuleMember -Function Start-FleetService
'@ | Set-Content -LiteralPath $mod -Encoding UTF8
    $env:FLEETPORT_MODULE=$mod
    Assert-Router ((Get-PacketRatFleetPortModule -Root $Root) -eq (Resolve-Path $mod).Path) 'FLEETPORT_MODULE is the module that is imported'
    . (Join-Path $Root 'Private\PacketRatRouter.ps1')
    $called=& $script:PacketRatFleetServiceStart -Name 'fairlead' -Folder (Resolve-Path $fair2).Path -WaitSeconds 0
    Assert-Router ($called.State -eq 'running' -and $called.Name -eq 'fairlead' -and $called.Folder -eq (Resolve-Path $fair2).Path) 'the real starter imports FleetPort and calls Start-FleetService'

    $src=[IO.File]::ReadAllText((Join-Path $Root 'Private\PacketRatRouter.ps1'))
    Assert-Router ($src -match 'Start-FleetService' -and $src -notmatch '--console' -and $src -notmatch '--no-tray' -and $src -notmatch "FilePath 'powershell.exe'") 'the router source no longer starts a console copy of Fairlead'
}finally{
    foreach($n in $names2){[Environment]::SetEnvironmentVariable($n,$saved2[$n])}
    Remove-Item -LiteralPath $tmp2 -Recurse -Force -ErrorAction SilentlyContinue
}
'Router tests passed.'
