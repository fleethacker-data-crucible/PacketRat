# PacketRat - local server lifecycle: browser presence, runtime files, instance discovery
#requires -Version 5.1
#
# The browser tab owns the server. The UI sends POST /api/heartbeat every 5 s and a
# navigator.sendBeacon "leaving" signal on pagehide. The server stops itself 20 s after the
# last heartbeat, or 5 s after a leaving signal with no newer heartbeat, but only when no
# PacketRat tab is alive and no request (scan, report, draft, store write) is running.
# Requests are served one at a time, so a running request already blocks the presence tick;
# afterwards the time spent busy is not counted as tab silence (see -BusyUntil).
# PACKETRAT_AUTO_STOP=0 (environment or Config\packetrat.env) or -Stay turns this off.
#
# Runtime files: Logs\packetrat-server-<pid>.json holds pid, port, url and startedAt only.
# The session nonce is never written to disk.

function Test-PacketRatAutoStopEnabled {
    [CmdletBinding()]
    param([switch]$Stay)
    if ($Stay) { return $false }
    $value = [Environment]::GetEnvironmentVariable('PACKETRAT_AUTO_STOP', 'Process')
    if ($null -eq $value) { return $true }
    return -not ($value.Trim() -match '^(0|false|no|off)$')
}

function New-PacketRatPresence {
    [CmdletBinding()]
    param(
        [bool]$AutoStop = $true,
        [int]$HeartbeatTimeoutSeconds = 20,
        [int]$LeavingGraceSeconds = 5
    )
    return [pscustomobject]@{
        AutoStop         = $AutoStop
        HeartbeatTimeout = [TimeSpan]::FromSeconds($HeartbeatTimeoutSeconds)
        LeavingGrace     = [TimeSpan]::FromSeconds($LeavingGraceSeconds)
        Tabs             = @{}
    }
}

function Register-PacketRatPresence {
    <#
     .SYNOPSIS
      Records a heartbeat (or, with -Leaving, an unload signal) from one browser tab.
      Each page load uses its own tab id, so a reload is a new tab that heartbeats at once.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$State,
        [string]$Tab,
        [switch]$Leaving,
        [DateTime]$Now = [DateTime]::UtcNow
    )
    $id = 'default'
    if ($Tab -match '^[A-Za-z0-9-]{1,64}$') { $id = $Tab }
    $entry = $State.Tabs[$id]
    if ($null -eq $entry) {
        $entry = [pscustomobject]@{ LastSeen = $Now; LeftAt = $null }
        $State.Tabs[$id] = $entry
    }
    if ($Leaving) {
        $entry.LeftAt = $Now
    } else {
        $entry.LastSeen = $Now
        $entry.LeftAt = $null
    }
    # Forget tabs that have been silent for a long time so the table stays small.
    foreach ($key in @($State.Tabs.Keys)) {
        if ($key -ne $id -and ($Now - $State.Tabs[$key].LastSeen) -gt [TimeSpan]::FromMinutes(10)) {
            $State.Tabs.Remove($key)
        }
    }
}

function Get-PacketRatLiveTabCount {
    <#
     .SYNOPSIS
      Tabs still considered open. -BusyUntil is when the last long request (scan, report,
      draft) finished: the single-threaded server could not answer heartbeats before then,
      so silence up to that moment is not held against a tab.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$State,
        [DateTime]$Now = [DateTime]::UtcNow,
        [DateTime]$BusyUntil = [DateTime]::MinValue
    )
    $alive = 0
    foreach ($tab in @($State.Tabs.Values)) {
        if ($null -ne $tab.LeftAt) {
            if (($Now - $tab.LeftAt) -lt $State.LeavingGrace) { $alive++ }
            continue
        }
        $seen = $tab.LastSeen
        if ($BusyUntil -gt $seen) { $seen = $BusyUntil }
        if (($Now - $seen) -lt $State.HeartbeatTimeout) { $alive++ }
    }
    return $alive
}

function Test-PacketRatBrowserGone {
    <#
     .SYNOPSIS
      True when the server should stop itself: auto-stop is on, no request is running,
      at least one tab has connected, and no tab is alive any more.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$State,
        [DateTime]$Now = [DateTime]::UtcNow,
        [DateTime]$BusyUntil = [DateTime]::MinValue,
        [switch]$JobRunning
    )
    if (-not $State.AutoStop -or $JobRunning) { return $false }
    # Nothing ever connected (for example -NoBrowser): stay up until stopped explicitly.
    if ($State.Tabs.Count -eq 0) { return $false }
    return ((Get-PacketRatLiveTabCount -State $State -Now $Now -BusyUntil $BusyUntil) -eq 0)
}

function Test-PacketRatBeaconToken {
    <#
     .SYNOPSIS
      sendBeacon cannot set headers, so /api/heartbeat (only) accepts the session nonce as
      the "token" field of its JSON body. Never in the query string; never logged.
    #>
    [CmdletBinding()]
    param($Data, [string]$Expected)
    if ($null -eq $Data -or [string]::IsNullOrEmpty($Expected)) { return $false }
    $property = $Data.PSObject.Properties['token']
    if ($null -eq $property -or $null -eq $property.Value) { return $false }
    return ([string]$property.Value -ceq $Expected)
}

function Get-PacketRatRuntimeDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root)
    # Same ignored Logs\ folder as packetrat.log and the action store.
    return (Join-Path $Root 'Logs')
}

function Write-PacketRatRuntimeFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [int]$Port,
        [string]$Url,
        [int]$ProcessId = $PID
    )
    $dir = Get-PacketRatRuntimeDirectory -Root $Root
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir ('packetrat-server-' + $ProcessId + '.json')
    $info = [ordered]@{
        pid       = $ProcessId
        port      = $Port
        url       = $Url
        startedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    $json = ConvertTo-Json -InputObject $info -Compress
    [IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding $false))
    return $path
}

function Remove-PacketRatRuntimeFile {
    [CmdletBinding()]
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

function Test-PacketRatServerProcess {
    [CmdletBinding()]
    param([int]$ProcessId, [string]$StartedAt)
    if ($ProcessId -le 0) { return $false }
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $process) { return $false }
    if ($process.ProcessName -notmatch '^(powershell|pwsh)$') { return $false }
    # A recycled PID belongs to a process that started after the runtime file was written.
    try {
        if ($StartedAt) {
            $written = [DateTime]::Parse($StartedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
            if ($process.StartTime.ToUniversalTime() -gt $written.AddSeconds(5)) { return $false }
        }
    } catch { }
    return $true
}

function Get-PacketRatRuntimeEntries {
    <#
     .SYNOPSIS
      Live servers from Logs\packetrat-server-*.json. Files whose process is gone are deleted.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root)
    $entries = @()
    $dir = Get-PacketRatRuntimeDirectory -Root $Root
    if (-not (Test-Path -LiteralPath $dir)) { return $entries }
    $files = @(Get-ChildItem -LiteralPath $dir -Filter 'packetrat-server-*.json' -File -ErrorAction SilentlyContinue)
    foreach ($file in $files) {
        $live = $false
        $info = $null
        try {
            $info = [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json
            $live = Test-PacketRatServerProcess -ProcessId ([int]$info.pid) -StartedAt ([string]$info.startedAt)
        } catch { $live = $false }
        if ($live) {
            $entries += [pscustomobject]@{
                Pid = [int]$info.pid; Port = $info.port; Url = [string]$info.url
                StartedAt = [string]$info.startedAt; File = $file.FullName; Source = 'runtime file'
            }
        } else {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    return $entries
}

function Get-PacketRatProcesses {
    <#
     .SYNOPSIS
      Running PacketRat browser servers other than this process: runtime files first, then any
      PowerShell whose command line runs Start-PacketRat-Web.ps1.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root)
    $found = @{}
    foreach ($entry in @(Get-PacketRatRuntimeEntries -Root $Root)) {
        if ($entry.Pid -ne $PID) { $found[$entry.Pid] = $entry }
    }
    try {
        $candidates = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop)
        foreach ($candidate in $candidates) {
            $id = [int]$candidate.ProcessId
            if ($id -eq $PID -or $found.ContainsKey($id)) { continue }
            if ($candidate.CommandLine -and $candidate.CommandLine -match 'Start-PacketRat-Web\.ps1') {
                $found[$id] = [pscustomobject]@{
                    Pid = $id; Port = $null; Url = ''; StartedAt = [string]$candidate.CreationDate
                    File = ''; Source = 'process scan'
                }
            }
        }
    } catch { }
    return @($found.Values | Sort-Object Pid)
}

function Format-PacketRatProcess {
    [CmdletBinding()]
    param($Process)
    if ($Process.Url) { return ([string]$Process.Url + ' (PID ' + $Process.Pid + ')') }
    return ('PID ' + $Process.Pid)
}

function Stop-PacketRatProcesses {
    <#
     .SYNOPSIS
      Stops every running PacketRat browser server found by Get-PacketRatProcesses and returns
      the ones stopped. Used by Stop-PacketRat.ps1 and the launcher's single-instance check.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root)
    $stopped = New-Object System.Collections.Generic.List[object]
    foreach ($server in @(Get-PacketRatProcesses -Root $Root)) {
        try {
            Stop-Process -Id $server.Pid -Force -ErrorAction Stop
            try { Wait-Process -Id $server.Pid -Timeout 5 -ErrorAction SilentlyContinue } catch { }
            if ($server.File) { Remove-Item -LiteralPath $server.File -Force -ErrorAction SilentlyContinue }
            $stopped.Add($server)
        } catch {
            Write-Warning ('Could not stop PacketRat server ' + (Format-PacketRatProcess $server) + ': ' + $_.Exception.Message)
        }
    }
    # A killed process cannot delete its own runtime file; sweep any that are now stale.
    $null = Get-PacketRatRuntimeEntries -Root $Root
    return $stopped.ToArray()
}
