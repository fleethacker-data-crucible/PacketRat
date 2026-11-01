# PacketRat - tamper-evident action log (local, append-only, hash-chained; never holds mail content)
#requires -Version 5.1
# One JSON line per action PacketRat ran for a person, in Logs\packetrat-actions.jsonl (gitignored, local only, never sent
# anywhere). Each line carries the SHA-256 of the line before it, so editing, removing or reordering an earlier line breaks
# the chain and `log verify` says where. This is tamper-EVIDENT, not tamper-proof: someone who rewrites the whole file can
# rebuild a chain, so note the head hash that `log show` prints if you need to prove the log was not rewritten.
# A line holds only: seq, at (UTC), route, outcome, keyRef (a short hash of the item key, never the key or any message text).
# Logging must never break the action being logged.

$script:PacketRatActionLogFile = 'packetrat-actions.jsonl'
$script:PacketRatActionLogGenesis = ('0' * 64)
# Routes that do something (change data, call the AI, open Outlook). Read-only routes are not logged.
$script:PacketRatLoggedRoutes = @(
    '/api/burden/baseline', '/api/burden/record',
    '/api/analyze', '/api/cancel', '/api/report/generate', '/api/report/track', '/api/status', '/api/priority', '/api/priority/reset',
    '/api/rules', '/api/dismiss', '/api/restore', '/api/open', '/api/draft', '/api/open-draft', '/api/item/archive', '/api/item/move',
    '/api/item/categorize', '/api/item/mark-read', '/api/item/handoff', '/api/stats/reset', '/api/assist/ask', '/api/credentials/check'
)

function Get-PacketRatActionLogPath {
    param([string]$Root)
    if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
    $dir = Join-Path $Root 'Logs'
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    return (Join-Path $dir $script:PacketRatActionLogFile)
}

function Get-PacketRatActionLogHash([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) -replace '-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}

# The text that is hashed for a line: every field except the hash itself, in a fixed order.
function Get-PacketRatActionLogEntryHash($Entry) {
    return Get-PacketRatActionLogHash (('{0}|{1}|{2}|{3}|{4}|{5}' -f $Entry.seq, $Entry.at, $Entry.route, $Entry.outcome, $Entry.keyRef, $Entry.prev))
}

function Read-PacketRatActionLogLines([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @([IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8) | Where-Object { $_.Trim() })
}

function Add-PacketRatActionLog {
    # Appends one line. Best effort: returns $false instead of throwing.
    param([Parameter(Mandatory)][string]$Route, [ValidateSet('ok', 'failed')][string]$Outcome = 'ok', [string]$Key, [string]$Root)
    try {
        $path = Get-PacketRatActionLogPath -Root $Root
        $lines = @(Read-PacketRatActionLogLines $path)
        $seq = 1; $prev = $script:PacketRatActionLogGenesis
        if ($lines.Count -gt 0) {
            $last = $lines[$lines.Count - 1] | ConvertFrom-Json
            $seq = [int]$last.seq + 1; $prev = [string]$last.hash
        }
        $keyRef = if ($Key) { (Get-PacketRatActionLogHash $Key).Substring(0, 12) } else { '' }
        $entry = [ordered]@{ seq = $seq; at = [DateTime]::UtcNow.ToString('o'); route = $Route; outcome = $Outcome; keyRef = $keyRef; prev = $prev }
        $entry['hash'] = Get-PacketRatActionLogEntryHash ([pscustomobject]$entry)
        [IO.File]::AppendAllText($path, ((ConvertTo-Json -InputObject $entry -Compress) + "`n"), (New-Object Text.UTF8Encoding $false))
        return $true
    } catch { Write-Warning "Action log not written: $($_.Exception.Message)"; return $false }
}

function New-PacketRatActionLogResult([bool]$Valid, [int]$Entries, [string]$Head, [int]$BrokenAt, [string]$Reason) {
    return [pscustomobject]@{ Valid = $Valid; Entries = $Entries; Head = $Head; BrokenAt = $BrokenAt; Reason = $Reason }
}

function Test-PacketRatActionLog {
    # Walks the chain. Returns Valid, Entries, Head and, when broken, BrokenAt (line number) and Reason.
    param([string]$Root)
    $path = Get-PacketRatActionLogPath -Root $Root
    $lines = @(Read-PacketRatActionLogLines $path)
    $prev = $script:PacketRatActionLogGenesis; $n = 0
    foreach ($line in $lines) {
        $n++
        try { $e = $line | ConvertFrom-Json } catch { return New-PacketRatActionLogResult $false $lines.Count $prev $n 'line is not valid JSON' }
        foreach ($f in 'seq', 'at', 'route', 'outcome', 'keyRef', 'prev', 'hash') {
            if (-not $e.PSObject.Properties[$f]) { return New-PacketRatActionLogResult $false $lines.Count $prev $n "line is missing '$f'" }
        }
        if ([int]$e.seq -ne $n) { return New-PacketRatActionLogResult $false $lines.Count $prev $n "sequence number is $($e.seq), expected $n (a line was removed, added or reordered)" }
        if ([string]$e.prev -ne $prev) { return New-PacketRatActionLogResult $false $lines.Count $prev $n 'link to the previous line does not match (an earlier line changed or was removed)' }
        if ([string]$e.hash -ne (Get-PacketRatActionLogEntryHash $e)) { return New-PacketRatActionLogResult $false $lines.Count $prev $n 'line content does not match its hash (the line was edited)' }
        $prev = [string]$e.hash
    }
    return New-PacketRatActionLogResult $true $lines.Count $prev 0 ''
}

function Get-PacketRatActionLogView {
    # The newest lines (default 100) plus the chain head, for `log show`.
    param([string]$Root, [int]$Last = 100)
    $path = Get-PacketRatActionLogPath -Root $Root
    $lines = @(Read-PacketRatActionLogLines $path)
    $shown = @($lines | Select-Object -Last $Last | ForEach-Object { try { $_ | ConvertFrom-Json } catch { [pscustomobject]@{ unreadable = $true } } })
    $head = $script:PacketRatActionLogGenesis
    if ($lines.Count -gt 0) { try { $head = [string]($lines[$lines.Count - 1] | ConvertFrom-Json).hash } catch { $head = '' } }
    return [ordered]@{
        schema = 'packetrat.action-log/1'; file = ('Logs\' + $script:PacketRatActionLogFile); total = $lines.Count; shown = $shown.Count; head = $head
        note = 'Holds the route, outcome and a short hash of the item key for each action; never mail content. Run log verify to check the chain.'
        entries = $shown
    }
}

# Only the item key is taken from a request body (and only to be hashed); nothing else of the body is read.
function Get-PacketRatActionLogKey($Data) {
    if ($Data -is [System.Collections.IDictionary]) { if ($Data.Contains('key')) { return [string]$Data['key'] } }
    elseif ($null -ne $Data -and $Data.PSObject.Properties['key']) { return [string]$Data.key }
    return ''
}

function Write-PacketRatActionLogFor {
    # Called by Invoke-PacketRatApi after a route ran. Logs the routes in $script:PacketRatLoggedRoutes only.
    param([string]$Route, [string]$Key, [string]$Outcome, [string]$Root)
    if ($script:PacketRatLoggedRoutes -cnotcontains $Route) { return }
    $null = Add-PacketRatActionLog -Route $Route -Outcome $Outcome -Key $Key -Root $Root
}
