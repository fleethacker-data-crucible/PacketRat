# PacketRat - local speech-to-text assets (Whisper via transformers.js, WASM). The files are NOT in git.
#requires -Version 5.1
# Config\voice-assets.json lists every file the page may load, with its SHA-256. The server serves /voice-assets/<name> only
# for a listed name whose bytes still match the hash, so a swapped or truncated file is refused, never executed.

$script:PacketRatVoiceCache = @{}

function Get-PacketRatVoiceDir {
    param([string]$Root)
    if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
    $dir = [string]$env:PACKETRAT_VOICE_DIR
    if (-not $dir) { $dir = Join-Path $Root 'Web\vendor\voice' }
    return $dir
}

function Get-PacketRatVoiceManifest {
    param([string]$Root)
    if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
    $path = Join-Path $Root 'Config\voice-assets.json'
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try { $doc = [IO.File]::ReadAllText($path) | ConvertFrom-Json } catch { throw "voice-assets.json is not valid JSON: $($_.Exception.Message)" }
    $files = @($doc.files | Where-Object { $null -ne $_ })
    foreach ($f in $files) {
        if ([string]$f.name -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or [string]$f.name -match '\.\.' -or [string]$f.sha256 -notmatch '^[0-9a-fA-F]{64}$') {
            throw "voice-assets.json has a bad entry: $($f.name)"
        }
    }
    return $files
}

function Get-PacketRatFileSha256([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $fs = [IO.File]::OpenRead($Path)
    try { return (($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $fs.Dispose(); $sha.Dispose() }
}

function Test-PacketRatVoiceFile {
    # True when the file exists under the voice dir and matches the manifest hash. The hash is cached by size and mtime.
    param($Entry, [string]$Dir)
    $full = [IO.Path]::GetFullPath((Join-Path $Dir ([string]$Entry.name -replace '/', '\')))
    $dirFull = [IO.Path]::GetFullPath($Dir).TrimEnd('\') + '\'
    if (-not $full.StartsWith($dirFull, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return $false }
    $info = Get-Item -LiteralPath $full
    $stamp = '{0}|{1}' -f $info.Length, $info.LastWriteTimeUtc.Ticks
    $c = $script:PacketRatVoiceCache[$full]
    if (-not $c -or $c.Stamp -ne $stamp) { $c = @{ Stamp = $stamp; Hash = (Get-PacketRatFileSha256 $full) }; $script:PacketRatVoiceCache[$full] = $c }
    return ($c.Hash -ieq [string]$Entry.sha256)
}

function Get-PacketRatVoiceStatus {
    param([string]$Root)
    $dir = Get-PacketRatVoiceDir -Root $Root
    $files = @(Get-PacketRatVoiceManifest -Root $Root)
    if ($files.Count -eq 0) {
        return [ordered]@{ installed = $false; dir = $dir; listed = 0; missing = @(); mismatched = @()
            note = 'Speech input is not installed: Config\voice-assets.json lists no files. See docs\VOICE.md.' }
    }
    $missing = @(); $bad = @()
    foreach ($f in $files) {
        $full = Join-Path $dir ([string]$f.name -replace '/', '\')
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $missing += [string]$f.name }
        elseif (-not (Test-PacketRatVoiceFile -Entry $f -Dir $dir)) { $bad += [string]$f.name }
    }
    $ok = ($missing.Count -eq 0 -and $bad.Count -eq 0)
    return [ordered]@{ installed = $ok; dir = $dir; listed = $files.Count; missing = $missing; mismatched = $bad
        note = $(if ($ok) { 'Speech input assets are present and match their hashes.' } else { 'Speech input is not ready: missing or changed files. See docs\VOICE.md.' }) }
}

function Read-PacketRatVoiceAsset {
    # Bytes of a listed, hash-verified asset; throws for anything else (unknown name, traversal, missing, changed).
    param([Parameter(Mandatory)][string]$Name, [string]$Root)
    $entry = @(Get-PacketRatVoiceManifest -Root $Root | Where-Object { [string]$_.name -ceq $Name } | Select-Object -First 1)
    if ($entry.Count -eq 0) { throw 'Not a listed voice asset.' }
    $dir = Get-PacketRatVoiceDir -Root $Root
    if (-not (Test-PacketRatVoiceFile -Entry $entry[0] -Dir $dir)) { throw 'Voice asset is missing or does not match its hash.' }
    return [IO.File]::ReadAllBytes([IO.Path]::GetFullPath((Join-Path $dir ($Name -replace '/', '\'))))
}

function Get-PacketRatVoiceMime([string]$Name) {
    switch ([IO.Path]::GetExtension($Name).ToLowerInvariant()) {
        '.js' { 'application/javascript; charset=utf-8' } '.mjs' { 'application/javascript; charset=utf-8' }
        '.wasm' { 'application/wasm' } '.json' { 'application/json; charset=utf-8' } default { 'application/octet-stream' }
    }
}
