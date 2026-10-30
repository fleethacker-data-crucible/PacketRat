# PacketRat - minutes-saved counter (an ESTIMATE of time saved, never a measurement or a score for a person)
#requires -Version 5.1
# Counts the actions PacketRat performed or prepared and multiplies them by the per-action minutes in
# Config\minutes-saved.json. Counts live in the local store (Logs\packetrat-store.json, gitignored, plain local JSON like
# the rest of the store) and are never sent anywhere. Counting must never break the action being counted.

$script:PacketRatUsageActions = [ordered]@{
    triaged     = 'Messages triaged'
    drafts      = 'Reply drafts generated'
    reports     = 'Reports generated'
    archived    = 'Messages archived'
    moved       = 'Messages moved to a folder'
    categorized = 'Messages categorized'
    markedRead  = 'Messages marked read or unread'
    dismissed   = 'Items dismissed'
}
$script:PacketRatUsageDefaultMinutes = @{ triaged = 0.5; drafts = 6; reports = 10; archived = 0.5; moved = 0.5; categorized = 0.3; markedRead = 0.2; dismissed = 0.3 }
$script:PacketRatUsageNote = 'Estimate, not a measurement: counts of actions PacketRat performed or prepared, times the minutes assumed per action in Config\minutes-saved.json. Not a performance score for anyone.'

function Get-PacketRatUsageMinutes {
    param([string]$Root)
    if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
    $minutes = @{}
    foreach ($k in $script:PacketRatUsageDefaultMinutes.Keys) { $minutes[$k] = [double]$script:PacketRatUsageDefaultMinutes[$k] }
    $path = Join-Path $Root 'Config\minutes-saved.json'
    if (Test-Path -LiteralPath $path) {
        try {
            $cfg = [IO.File]::ReadAllText($path) | ConvertFrom-Json
            foreach ($k in @($script:PacketRatUsageActions.Keys)) {
                $p = $cfg.minutesPerAction.PSObject.Properties[$k]
                $v = 0.0
                if ($p -and [double]::TryParse([string]$p.Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v)) {
                    $minutes[$k] = [Math]::Max(0.0, [Math]::Min(240.0, $v))
                }
            }
        } catch { Write-Warning "minutes-saved.json unreadable, using defaults: $($_.Exception.Message)" }
    }
    return $minutes
}

function Add-PacketRatUsage {
    # Adds Count to one action's counter in the saved store. Best effort: returns $false instead of throwing.
    param([Parameter(Mandatory)][string]$Action, [int]$Count = 1, [string]$Root)
    if (-not $script:PacketRatUsageActions.Contains($Action) -or $Count -lt 1) { return $false }
    try {
        $store = Get-PacketRatStore -Root $Root
        if (-not $store.PSObject.Properties['Usage'] -or -not $store.Usage) {
            $store | Add-Member -NotePropertyName Usage -NotePropertyValue ([pscustomobject]@{ Since = (Get-Date).ToString('o'); Counts = [pscustomobject]@{} }) -Force
        }
        if (-not $store.Usage.PSObject.Properties['Counts'] -or -not $store.Usage.Counts) { $store.Usage | Add-Member -NotePropertyName Counts -NotePropertyValue ([pscustomobject]@{}) -Force }
        $current = 0
        $p = $store.Usage.Counts.PSObject.Properties[$Action]
        if ($p) { $current = [int]$p.Value }
        $store.Usage.Counts | Add-Member -NotePropertyName $Action -NotePropertyValue ([int]($current + $Count)) -Force
        Save-PacketRatStore -Store $store -Root $Root
        return $true
    } catch { Write-Warning "Usage count not saved: $($_.Exception.Message)"; return $false }
}

function Get-PacketRatUsageCounts {
    param([string]$Root)
    $store = Get-PacketRatStore -Root $Root
    $counts = [ordered]@{}
    $hasUsage = $store.PSObject.Properties['Usage'] -and $store.Usage
    foreach ($k in $script:PacketRatUsageActions.Keys) {
        $n = 0
        if ($hasUsage -and $store.Usage.PSObject.Properties['Counts'] -and $store.Usage.Counts) {
            $p = $store.Usage.Counts.PSObject.Properties[$k]
            if ($p) { $n = [Math]::Max(0, [int]$p.Value) }
        }
        $counts[$k] = $n
    }
    $since = if ($hasUsage -and $store.Usage.PSObject.Properties['Since']) { [string]$store.Usage.Since } else { '' }
    return [pscustomobject]@{ Counts = $counts; Since = $since }
}

function Get-PacketRatUsageStats {
    param([string]$Root)
    $u = Get-PacketRatUsageCounts -Root $Root
    $minutes = Get-PacketRatUsageMinutes -Root $Root
    $rows = New-Object System.Collections.Generic.List[object]
    $total = 0.0; $actions = 0
    foreach ($k in $script:PacketRatUsageActions.Keys) {
        $each = [double]$minutes[$k]; $n = [int]$u.Counts[$k]
        $total += $n * $each; $actions += $n
        [void]$rows.Add([ordered]@{ id = $k; label = $script:PacketRatUsageActions[$k]; count = $n; minutesEach = $each; minutes = [Math]::Round($n * $each, 1) })
    }
    return [ordered]@{
        schema = 'packetrat.stats/1'; estimate = $true; note = $script:PacketRatUsageNote
        since = $u.Since; totalActions = $actions; totalMinutes = [Math]::Round($total, 1)
        actions = $rows.ToArray()
    }
}

function Get-PacketRatUsageExport {
    # Raw counts only, for another tool to consume. No minutes, no message data.
    param([string]$Root)
    $u = Get-PacketRatUsageCounts -Root $Root
    return [ordered]@{ schema = 'packetrat.usage-counts/1'; estimate = $true; since = $u.Since; exportedAt = (Get-Date).ToString('o'); counts = $u.Counts }
}

function Reset-PacketRatUsage {
    param([string]$Root)
    $store = Get-PacketRatStore -Root $Root
    $store | Add-Member -NotePropertyName Usage -NotePropertyValue ([pscustomobject]@{ Since = (Get-Date).ToString('o'); Counts = [pscustomobject]@{} }) -Force
    Save-PacketRatStore -Store $store -Root $Root
}
