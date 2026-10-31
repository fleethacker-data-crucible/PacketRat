# PacketRat - local voice assets: speech OUT (TalkForge / Piper TTS) and speech IN (Whisper). The big files are NOT in git.
#requires -Version 5.1
# Config\voice-assets.json lists every file the page may load, with its SHA-256. The server serves /voice-assets/<name> only
# for a listed name whose bytes still match the hash, so a swapped or truncated file is refused, never executed.
# Names starting "tts/" are TalkForge's assets folder (its vendor\, wasm\ and models\ trees, same layout); PACKETRAT_TTS_DIR
# points at that folder (default <voice dir>\tts). Every other name lives in the voice dir (PACKETRAT_VOICE_DIR, default
# Web\vendor\voice) and is used for speech input.

$script:PacketRatVoiceCache = @{}

function Get-PacketRatVoiceDir {
    param([string]$Root)
    if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
    $dir = [string]$env:PACKETRAT_VOICE_DIR
    if (-not $dir) { $dir = Join-Path $Root 'Web\vendor\voice' }
    return $dir
}

function Get-PacketRatVoiceDocument {
    param([string]$Root)
    if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
    $path = Join-Path $Root 'Config\voice-assets.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return ([IO.File]::ReadAllText($path) | ConvertFrom-Json) } catch { throw "voice-assets.json is not valid JSON: $($_.Exception.Message)" }
}

function Get-PacketRatVoiceManifest {
    param([string]$Root)
    $doc = Get-PacketRatVoiceDocument -Root $Root
    if (-not $doc) { return @() }
    $files = @($doc.files | Where-Object { $null -ne $_ })
    foreach ($f in $files) {
        if ([string]$f.name -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or [string]$f.name -match '\.\.' -or [string]$f.sha256 -notmatch '^[0-9a-fA-F]{64}$') {
            throw "voice-assets.json has a bad entry: $($f.name)"
        }
    }
    return $files
}

function Resolve-PacketRatVoicePath {
    # Returns @{ Base; Full } for a manifest name, or $null when the result would leave its base folder.
    param([Parameter(Mandatory)][string]$Name, [string]$Root)
    if ($Name.StartsWith('tts/')) {
        $base = [string]$env:PACKETRAT_TTS_DIR
        if (-not $base) { $base = Join-Path (Get-PacketRatVoiceDir -Root $Root) 'tts' }
        $rel = $Name.Substring(4)
    } else { $base = Get-PacketRatVoiceDir -Root $Root; $rel = $Name }
    $baseFull = [IO.Path]::GetFullPath($base).TrimEnd('\') + '\'
    $full = [IO.Path]::GetFullPath((Join-Path $base ($rel -replace '/', '\')))
    if (-not $full.StartsWith($baseFull, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    return @{ Base = $baseFull; Full = $full }
}

function Get-PacketRatFileSha256([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $fs = [IO.File]::OpenRead($Path)
    try { return (($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $fs.Dispose(); $sha.Dispose() }
}

function Test-PacketRatVoiceFile {
    # True when the file exists under its base folder and matches the manifest hash. The hash is cached by size and mtime.
    param($Entry, [string]$Root)
    $p = Resolve-PacketRatVoicePath -Name ([string]$Entry.name) -Root $Root
    if (-not $p -or -not (Test-Path -LiteralPath $p.Full -PathType Leaf)) { return $false }
    $info = Get-Item -LiteralPath $p.Full
    $stamp = '{0}|{1}' -f $info.Length, $info.LastWriteTimeUtc.Ticks
    $c = $script:PacketRatVoiceCache[$p.Full]
    if (-not $c -or $c.Stamp -ne $stamp) { $c = @{ Stamp = $stamp; Hash = (Get-PacketRatFileSha256 $p.Full) }; $script:PacketRatVoiceCache[$p.Full] = $c }
    return ($c.Hash -ieq [string]$Entry.sha256)
}

function Get-PacketRatVoiceGroupStatus {
    param($Files, [string]$Root)
    $missing = @(); $bad = @()
    foreach ($f in @($Files)) {
        $p = Resolve-PacketRatVoicePath -Name ([string]$f.name) -Root $Root
        if (-not $p -or -not (Test-Path -LiteralPath $p.Full -PathType Leaf)) { $missing += [string]$f.name }
        elseif (-not (Test-PacketRatVoiceFile -Entry $f -Root $Root)) { $bad += [string]$f.name }
    }
    return @{ listed = @($Files).Count; missing = $missing; mismatched = $bad; ok = (@($Files).Count -gt 0 -and $missing.Count -eq 0 -and $bad.Count -eq 0) }
}

function Get-PacketRatVoiceStatus {
    # installed = speech input (Whisper) is ready; tts = speech output (TalkForge / Piper) is ready.
    param([string]$Root)
    $doc = Get-PacketRatVoiceDocument -Root $Root
    $files = @(Get-PacketRatVoiceManifest -Root $Root)
    $ttsFiles = @($files | Where-Object { ([string]$_.name).StartsWith('tts/') })
    $sttFiles = @($files | Where-Object { -not ([string]$_.name).StartsWith('tts/') })
    $stt = Get-PacketRatVoiceGroupStatus -Files $sttFiles -Root $Root
    $tts = Get-PacketRatVoiceGroupStatus -Files $ttsFiles -Root $Root
    $cfg = if ($doc -and $doc.PSObject.Properties['tts'] -and $doc.tts) { $doc.tts } else { $null }
    $model = if ($cfg -and $cfg.model) { [string]$cfg.model } else { 'en_US-lessac-high' }
    $ttsDir = if ($env:PACKETRAT_TTS_DIR) { [string]$env:PACKETRAT_TTS_DIR } else { Join-Path (Get-PacketRatVoiceDir -Root $Root) 'tts' }
    return [ordered]@{
        installed = $stt.ok; dir = (Get-PacketRatVoiceDir -Root $Root); listed = $stt.listed; missing = @($stt.missing); mismatched = @($stt.mismatched)
        note = $(if ($stt.ok) { 'Speech input assets are present and match their hashes.' } elseif ($stt.listed -eq 0) { 'Speech input is not installed: Config\voice-assets.json lists no input files. See docs\VOICE.md.' } else { 'Speech input is not ready: missing or changed files. See docs\VOICE.md.' })
        tts = [ordered]@{
            installed = $tts.ok; dir = $ttsDir; listed = $tts.listed; missing = @($tts.missing); mismatched = @($tts.mismatched)
            model = $model; speaker = $(if ($cfg -and $null -ne $cfg.speaker) { [int]$cfg.speaker } else { 0 }); lengthScale = $(if ($cfg -and $null -ne $cfg.lengthScale) { [double]$cfg.lengthScale } else { 1.0 })
            note = $(if ($tts.ok) { 'TalkForge voice files are present and match their hashes.' } elseif ($tts.listed -eq 0) { 'TalkForge voice is not set up: run tools\New-VoiceManifest.ps1. See docs\VOICE.md.' } else { 'TalkForge voice is not ready: missing or changed files (set PACKETRAT_TTS_DIR to TalkForge\assets). See docs\VOICE.md.' })
        }
    }
}

function Read-PacketRatVoiceAsset {
    # Bytes of a listed, hash-verified asset; throws for anything else (unknown name, traversal, missing, changed).
    param([Parameter(Mandatory)][string]$Name, [string]$Root)
    $entry = @(Get-PacketRatVoiceManifest -Root $Root | Where-Object { [string]$_.name -ceq $Name } | Select-Object -First 1)
    if ($entry.Count -eq 0) { throw 'Not a listed voice asset.' }
    if (-not (Test-PacketRatVoiceFile -Entry $entry[0] -Root $Root)) { throw 'Voice asset is missing or does not match its hash.' }
    return [IO.File]::ReadAllBytes((Resolve-PacketRatVoicePath -Name $Name -Root $Root).Full)
}

function Get-PacketRatVoiceMime([string]$Name) {
    switch ([IO.Path]::GetExtension($Name).ToLowerInvariant()) {
        '.js' { 'application/javascript; charset=utf-8' } '.mjs' { 'application/javascript; charset=utf-8' }
        '.wasm' { 'application/wasm' } '.json' { 'application/json; charset=utf-8' } default { 'application/octet-stream' }
    }
}
