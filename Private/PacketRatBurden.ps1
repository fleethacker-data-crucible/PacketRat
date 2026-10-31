# PacketRat - measured-burden record (the DATA half only: it stores times a person enters, it does not time anything itself)
#requires -Version 5.1
# Holds, per task, a "before" baseline entered once and the elapsed seconds of each later run. The real before/after timing
# (someone with a stopwatch doing the task by hand, then with PacketRat) still needs a person; this file only keeps the
# numbers and shows how they compare. It stores task ids and seconds only: no names, no mail content, never a score for a
# person. Local only: Logs\packetrat-burden.json (gitignored), never sent anywhere.

$script:PacketRatBurdenFile = 'packetrat-burden.json'
$script:PacketRatBurdenMaxSeconds = 86400
$script:PacketRatBurdenMaxRuns = 5000
$script:PacketRatBurdenNote = 'Record only: PacketRat does not time anything itself. Seconds are entered by a person who timed the task. The real before/after timing still needs a person, and one entered baseline is not a study. Not a performance score for anyone.'

function Get-PacketRatBurdenPath {
    param([string]$Root)
    # The data folder: Logs\ under the app folder, or PACKETRAT_DATA_DIR (Get-PacketRatDataDir in PacketRatStore.ps1).
    return (Join-Path (Get-PacketRatDataDir -Root $Root) $script:PacketRatBurdenFile)
}

function Read-PacketRatBurden([string]$Root) {
    # Returns a plain hashtable { baseline = ordered task -> entry; runs = list }. A missing file is an empty record.
    $path = Get-PacketRatBurdenPath -Root $Root
    $data = @{ baseline = [ordered]@{}; runs = (New-Object System.Collections.Generic.List[object]) }
    if (-not (Test-Path -LiteralPath $path)) { return $data }
    $doc = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    if ($doc.baseline) {
        foreach ($p in $doc.baseline.PSObject.Properties) {
            $replaced = @(); if ($p.Value.PSObject.Properties['replaced']) { $replaced = @($p.Value.replaced) }
            $data.baseline[$p.Name] = [ordered]@{ seconds = [int]$p.Value.seconds; recordedAt = [string]$p.Value.recordedAt; replaced = $replaced }
        }
    }
    foreach ($r in @($doc.runs)) { if ($r) { [void]$data.runs.Add([ordered]@{ task = [string]$r.task; seconds = [int]$r.seconds; recordedAt = [string]$r.recordedAt }) } }
    return $data
}

function Save-PacketRatBurden($Data, [string]$Root) {
    $path = Get-PacketRatBurdenPath -Root $Root
    $doc = [ordered]@{ schema = 'packetrat.burden/1'; baseline = $Data.baseline; runs = @($Data.runs.ToArray()) }
    [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $doc -Depth 6), (New-Object Text.UTF8Encoding $false))
}

function Assert-PacketRatBurdenInput([string]$Task, [string]$Seconds) {
    if ($Task -cnotmatch '^[a-z][a-z0-9-]{0,39}$') { throw 'Task must be a short id: lowercase letters, digits and hyphens, starting with a letter (for example triage-inbox).' }
    $n = 0
    if (-not [int]::TryParse($Seconds, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$n) -or $n -lt 1 -or $n -gt $script:PacketRatBurdenMaxSeconds) {
        throw "Seconds must be a whole number from 1 to $($script:PacketRatBurdenMaxSeconds)."
    }
    return $n
}

function Set-PacketRatBurdenBaseline {
    # The "before" time for a task, entered once. A second entry is refused unless -Replace is set; the old value is kept.
    param([string]$Task, [string]$Seconds, [switch]$Replace, [string]$Root)
    $n = Assert-PacketRatBurdenInput $Task $Seconds
    $data = Read-PacketRatBurden -Root $Root
    $now = [DateTime]::UtcNow.ToString('o')
    if ($data.baseline.Contains($Task)) {
        $old = $data.baseline[$Task]
        if (-not $Replace) { throw "A baseline for '$Task' was already entered on $($old.recordedAt) ($($old.seconds) s). It is entered once; pass --replace true to correct it (the old value is kept in the record)." }
        $history = @($old.replaced) + @([ordered]@{ seconds = $old.seconds; recordedAt = $old.recordedAt })
        $data.baseline[$Task] = [ordered]@{ seconds = $n; recordedAt = $now; replaced = $history }
    } else {
        $data.baseline[$Task] = [ordered]@{ seconds = $n; recordedAt = $now; replaced = @() }
    }
    Save-PacketRatBurden $data $Root
    return Get-PacketRatBurdenView -Root $Root
}

function Add-PacketRatBurdenRun {
    # One measured run of a task: elapsed seconds a person timed.
    param([string]$Task, [string]$Seconds, [string]$Root)
    $n = Assert-PacketRatBurdenInput $Task $Seconds
    $data = Read-PacketRatBurden -Root $Root
    if ($data.runs.Count -ge $script:PacketRatBurdenMaxRuns) { throw "The record holds $($script:PacketRatBurdenMaxRuns) runs, the most it keeps. Export it and start a new one." }
    [void]$data.runs.Add([ordered]@{ task = $Task; seconds = $n; recordedAt = [DateTime]::UtcNow.ToString('o') })
    Save-PacketRatBurden $data $Root
    return Get-PacketRatBurdenView -Root $Root
}

function Get-PacketRatBurdenView {
    param([string]$Root)
    $data = Read-PacketRatBurden -Root $Root
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($k in $data.baseline.Keys) { [void]$names.Add($k) }
    foreach ($r in $data.runs) { if (-not $names.Contains($r.task)) { [void]$names.Add($r.task) } }
    $tasks = foreach ($t in ($names | Sort-Object)) {
        $secs = @($data.runs | Where-Object { $_.task -ceq $t } | ForEach-Object { [int]$_.seconds } | Sort-Object)
        $base = if ($data.baseline.Contains($t)) { [int]$data.baseline[$t].seconds } else { $null }
        $mean = $null; $median = $null; $delta = $null; $pct = $null
        if ($secs.Count -gt 0) {
            $mean = [Math]::Round((($secs | Measure-Object -Sum).Sum / $secs.Count), 1)
            $mid = [int][Math]::Floor($secs.Count / 2)
            $median = if ($secs.Count % 2 -eq 1) { [double]$secs[$mid] } else { ([double]$secs[$mid - 1] + [double]$secs[$mid]) / 2 }
            if ($null -ne $base) { $delta = [Math]::Round($mean - $base, 1); $pct = [Math]::Round(100 * ($mean - $base) / $base, 1) }
        }
        [ordered]@{ task = $t; baselineSeconds = $base; runs = $secs.Count; meanSeconds = $mean; medianSeconds = $median; changeSeconds = $delta; changePercent = $pct }
    }
    return [ordered]@{ schema = 'packetrat.burden/1'; note = $script:PacketRatBurdenNote; totalRuns = $data.runs.Count; tasks = @($tasks) }
}
