# PacketRat - make sure the Fairlead model router is running when PacketRat is set to use it
#requires -Version 5.1
# Fairlead is a shared background service for the Fleet tools, so
# PacketRat starts it when nothing answers on its address and never stops it:
#   running already          -> use it, no prompt
#   not running, not set up  -> start it through Start-FleetService (Fairlead keeps its tray; PacketRat does not open a browser)
#   not running, set up      -> ask: use the previous setup, or reconfigure (non-interactive runs just use it)
# PACKETRAT_FAIRLEAD_AUTOSTART=off turns this off. FAIRLEAD_DIR names the Fairlead folder when it is not a sibling.
# The start itself is edge-ops FleetPort Start-FleetService -Name fairlead (hidden, with its tray, and it keeps
# running after PacketRat exits). PacketRat does not launch that copy in the console or hide its tray.

function Get-PacketRatFairleadDir {
    param([string]$Root)
    if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
    $cands = @()
    foreach ($n in 'FAIRLEAD_DIR', 'FAIRLEAD_PATH') { $v = [Environment]::GetEnvironmentVariable($n); if ($v) { $cands += $v } }
    $cands += (Join-Path (Split-Path $Root -Parent) 'Fairlead')
    if ($env:USERPROFILE) { $cands += (Join-Path $env:USERPROFILE 'Projects\Fairlead') }
    foreach ($c in $cands) {
        if ($c -and (Test-Path -LiteralPath (Join-Path $c 'scripts\Start-Fairlead.ps1') -PathType Leaf)) { return (Resolve-Path -LiteralPath $c).Path }
    }
    return $null
}

function Get-PacketRatFairleadUri {
    $url = [Environment]::GetEnvironmentVariable('PACKETRAT_FAIRLEAD_URL')
    if ([string]::IsNullOrWhiteSpace($url)) { $url = 'http://127.0.0.1:8776/v1/chat/completions' }
    $u = $null
    if (-not [Uri]::TryCreate($url.Trim(), [UriKind]::Absolute, [ref]$u)) { return $null }
    return $u
}

function Test-PacketRatFairleadUp {
    # True when something accepts connections on Fairlead's address (a quick TCP check; no request is sent).
    param([Uri]$Uri)
    if (-not $Uri) { return $false }
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($Uri.Host, $Uri.Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(800)) { return $false }
        $client.EndConnect($iar); return $true
    } catch { return $false } finally { $client.Close() }
}

function Get-PacketRatFairleadSetupState {
    # 'complete', 'incomplete' or 'new' (no settings file yet), from Fairlead's own settings file.
    $path = [Environment]::GetEnvironmentVariable('PACKETRAT_FAIRLEAD_CONFIG')
    if (-not $path) { $path = Join-Path $env:LOCALAPPDATA 'Fairlead\fairlead.json' }
    if (-not (Test-Path -LiteralPath $path)) { return 'new' }
    try {
        $cfg = [IO.File]::ReadAllText($path) | ConvertFrom-Json
        if ($cfg.PSObject.Properties['setupComplete'] -and [bool]$cfg.setupComplete) { return 'complete' }
        return 'incomplete'
    } catch { return 'incomplete' }
}

function Show-PacketRatFairleadChoice {
    # Returns 'use' (keep the previous setup), 'reconfigure' or 'cancel'.
    Add-Type -AssemblyName System.Windows.Forms
    $text = "Fairlead, PacketRat's AI router, is not running, but it is already set up.`r`n`r`nYes = start it with your previous setup`r`nNo = start it and open its setup page to reconfigure`r`nCancel = don't start it (PacketRat's AI features won't work until it runs)"
    $r = [System.Windows.Forms.MessageBox]::Show($text, 'PacketRat - Fairlead', [System.Windows.Forms.MessageBoxButtons]::YesNoCancel, [System.Windows.Forms.MessageBoxIcon]::Question)
    switch ($r) { 'Yes' { 'use' } 'No' { 'reconfigure' } default { 'cancel' } }
}

# $null means "look beside PacketRat". A test sets this to a module path, or to a missing path so the real
# sibling checkout is not started.
$script:PacketRatFleetPortModule = $null

function Get-PacketRatFleetPortModule {
    param([string]$Root)
    if ($null -ne $script:PacketRatFleetPortModule) {
        if ($script:PacketRatFleetPortModule -and (Test-Path -LiteralPath $script:PacketRatFleetPortModule -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $script:PacketRatFleetPortModule).Path
        }
        return $null
    }
    if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
    $cands = @()
    $parent = Split-Path $Root -Parent
    if ($parent) { $cands += (Join-Path $parent 'edge-ops\tools\fleet-port\FleetPort.psm1') }
    if ($env:USERPROFILE) { $cands += (Join-Path $env:USERPROFILE 'Projects\edge-ops\tools\fleet-port\FleetPort.psm1') }
    foreach ($c in $cands) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return (Resolve-Path -LiteralPath $c).Path }
    }
    return $null
}

function Start-PacketRatFairleadProcess {
    # $OpenSetup is still accepted so Ensure-PacketRatFairlead can tell a first-run start from a reuse.
    # Start-FleetService always launches Fairlead hidden with its tray and without opening a browser.
    # PacketRat does not pass a console switch, a tray switch, or an environment (no token on the command line).
    param([string]$Dir, [switch]$OpenSetup)
    $root = Split-Path $PSScriptRoot -Parent
    $module = Get-PacketRatFleetPortModule -Root $root
    if (-not $module) {
        throw 'FleetPort was not found. Put edge-ops next to PacketRat (tools\fleet-port\FleetPort.psm1) so PacketRat can start Fairlead.'
    }
    Import-Module -Name $module -Force -ErrorAction Stop -DisableNameChecking
    if (-not (Get-Command Start-FleetService -ErrorAction SilentlyContinue)) {
        throw 'FleetPort does not provide Start-FleetService, so PacketRat did not start Fairlead.'
    }
    $started = Start-FleetService -Name fairlead -Folder $Dir -CallerRoot $root -WaitSeconds 0
    if (-not $started -or [string]$started.State -eq 'unavailable') {
        $why = 'Fairlead was not started.'
        if ($started -and $started.Message) { $why = [string]$started.Message }
        throw $why
    }
}

function Ensure-PacketRatFairlead {
    # Returns @{ State; Message }. State: Skipped | AlreadyRunning | Started | StartedForSetup | Declined | NotFound | Failed
    param([string]$Root, [switch]$Interactive, [int]$WaitSeconds = 40)
    if (([string][Environment]::GetEnvironmentVariable('PACKETRAT_FAIRLEAD_AUTOSTART')).Trim() -match '^(?i:off|0|false|no)$') {
        return @{ State = 'Skipped'; Message = 'Fairlead autostart is off (PACKETRAT_FAIRLEAD_AUTOSTART).' }
    }
    $uri = Get-PacketRatFairleadUri
    if (-not $uri) { return @{ State = 'Failed'; Message = 'PACKETRAT_FAIRLEAD_URL is not a valid address.' } }
    if (-not $uri.IsLoopback) { return @{ State = 'Skipped'; Message = 'Fairlead is not on this PC, so PacketRat does not start it.' } }
    if (Test-PacketRatFairleadUp -Uri $uri) { return @{ State = 'AlreadyRunning'; Message = 'Fairlead is already running.' } }

    $dir = Get-PacketRatFairleadDir -Root $Root
    if (-not $dir) { return @{ State = 'NotFound'; Message = 'Fairlead is not running and its folder was not found. Put it next to PacketRat or set FAIRLEAD_DIR.' } }

    $setup = Get-PacketRatFairleadSetupState
    $openSetup = $false
    if ($setup -ne 'complete') { $openSetup = $true }
    elseif ($Interactive) {
        $choice = Show-PacketRatFairleadChoice
        if ($choice -eq 'cancel') { return @{ State = 'Declined'; Message = 'Fairlead was not started.' } }
        if ($choice -eq 'reconfigure') { $openSetup = $true }
    }
    try {
        Start-PacketRatFairleadProcess -Dir $dir -OpenSetup:$openSetup
    } catch {
        return @{ State = 'Failed'; Message = $_.Exception.Message }
    }
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-PacketRatFairleadUp -Uri $uri) {
            return @{ State = $(if ($openSetup) { 'StartedForSetup' } else { 'Started' }); Message = $(if ($openSetup) { 'Fairlead started. Finish its setup page, then PacketRat can use it.' } else { 'Fairlead started with the previous setup.' }) }
        }
        Start-Sleep -Milliseconds 500
    }
    return @{ State = 'Failed'; Message = "Fairlead was started from $dir but did not answer within $WaitSeconds seconds." }
}
