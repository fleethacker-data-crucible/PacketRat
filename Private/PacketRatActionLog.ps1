# PacketRat - tamper-evident action log: what PacketRat did, when, and to which message, in a hash chain
#requires -Version 5.1
# One JSON line per action in Logs\packetrat-actions.jsonl:  seq, time (UTC), action, key, result, prev, hash.
# `hash` is SHA-256 over the previous line's hash and this line's own fields, so editing, removing or reordering a line
# in the middle breaks the chain and `log verify` says where. It records NO mail text, subjects, addresses, folder names,
# reasons or tokens: only the action name, the message key (an Outlook id or a fingerprint) and ok or error.
# Limit: removing the NEWEST lines leaves a valid shorter chain. Note the tip hash somewhere outside this PC to catch that.
# Writing the log never breaks the action being logged (best effort, like the usage counter).

$script:PacketRatActionLogGenesis = ('0' * 64)

function Get-PacketRatActionLogPath {
    param([string]$Root)
    return (Join-Path (Split-Path (Get-PacketRatStorePath -Root $Root) -Parent) 'packetrat-actions.jsonl')
}

function Get-PacketRatActionHash([string]$Prev, [int]$Seq, [string]$Time, [string]$Action, [string]$Key, [string]$Result) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Prev, $Seq, $Time, $Action, $Key, $Result) -join '|')
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally { $sha.Dispose() }
}

function Write-PacketRatActionLog {
    param([Parameter(Mandatory)][string]$Action, [string]$Key = '', [ValidateSet('ok', 'error')][string]$Result = 'ok', [string]$Root)
    try {
        $path = Get-PacketRatActionLogPath -Root $Root
        $prev = $script:PacketRatActionLogGenesis; $seq = 0
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $last = [IO.File]::ReadAllLines($path) | Where-Object { $_.Trim() } | Select-Object -Last 1
            if ($last) { $o = $last | ConvertFrom-Json; $prev = [string]$o.hash; $seq = [int]$o.seq }
        }
        $seq++
        if ($Key.Length -gt 200) { $Key = $Key.Substring(0, 200) }
        $time = [DateTime]::UtcNow.ToString('o')
        $hash = Get-PacketRatActionHash $prev $seq $time $Action $Key $Result
        $line = ([ordered]@{ seq = $seq; time = $time; action = $Action; key = $Key; result = $Result; prev = $prev; hash = $hash } | ConvertTo-Json -Compress)
        [IO.File]::AppendAllText($path, $line + "`n", (New-Object Text.UTF8Encoding $false))
        return $true
    } catch { Write-Warning "Action log not written: $($_.Exception.Message)"; return $false }
}

function Read-PacketRatActionLog {
    # Returns the entries in order; throws nothing for a missing file.
    param([string]$Root)
    $path = Get-PacketRatActionLogPath -Root $Root
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    $out = New-Object System.Collections.Generic.List[object]
    $n = 0
    foreach ($l in [IO.File]::ReadAllLines($path)) {
        $n++
        if (-not $l.Trim()) { continue }
        try { [void]$out.Add(($l | ConvertFrom-Json)) } catch { [void]$out.Add([pscustomobject]@{ seq = -1; unreadable = $n }) }
    }
    return $out.ToArray()
}

function Test-PacketRatActionLog {
    # Walks the chain. Returns ok, count, tip, and the first problem (line number and reason).
    param([string]$Root)
    $entries = @(Read-PacketRatActionLog -Root $Root)
    $prev = $script:PacketRatActionLogGenesis; $expectSeq = 1; $i = 0
    foreach ($e in $entries) {
        $i++
        if ($e.PSObject.Properties['unreadable']) { return [ordered]@{ ok = $false; count = $entries.Count; tip = $prev; problemAtLine = $i; reason = 'a line is not valid JSON (damaged or cut off)' } }
        foreach ($f in 'seq', 'time', 'action', 'key', 'result', 'prev', 'hash') {
            if (-not $e.PSObject.Properties[$f]) { return [ordered]@{ ok = $false; count = $entries.Count; tip = $prev; problemAtLine = $i; reason = "field '$f' is missing" } }
        }
        if ([int]$e.seq -ne $expectSeq) { return [ordered]@{ ok = $false; count = $entries.Count; tip = $prev; problemAtLine = $i; reason = "sequence number is $($e.seq), expected $expectSeq (a line was removed, added or reordered)" } }
        if ([string]$e.prev -ne $prev) { return [ordered]@{ ok = $false; count = $entries.Count; tip = $prev; problemAtLine = $i; reason = 'it does not follow the previous line (a line was changed, removed or reordered)' } }
        $want = Get-PacketRatActionHash ([string]$e.prev) ([int]$e.seq) ([string]$e.time) ([string]$e.action) ([string]$e.key) ([string]$e.result)
        if ([string]$e.hash -ne $want) { return [ordered]@{ ok = $false; count = $entries.Count; tip = $prev; problemAtLine = $i; reason = 'its contents do not match its hash (the line was edited)' } }
        $prev = [string]$e.hash; $expectSeq++
    }
    return [ordered]@{ ok = $true; count = $entries.Count; tip = $prev; problemAtLine = 0; reason = '' }
}
