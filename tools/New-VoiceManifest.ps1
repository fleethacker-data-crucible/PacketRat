#requires -Version 5.1
<#
.SYNOPSIS
  Records the SHA-256 of PacketRat's local voice files in Config\voice-assets.json.
.DESCRIPTION
  Two independent parts; give either or both:
    -TalkForgeAssets  your local TalkForge clone's assets folder: lists the engine, ONNX Runtime, phonemizer and one voice
                      model (speech OUT) as "tts/..." entries and records the voice setting.
    -VoiceInputDir    a folder of speech-input files (transformers.js, its ONNX runtime files and a Whisper model, speech IN):
                      every file under it is listed with its relative name.
  Run it on folders you trust: the hashes it records are the ones PacketRat later enforces. Nothing is downloaded and nothing
  is sent anywhere. Entries of the part you did not pass are kept.
.EXAMPLE
  .\tools\New-VoiceManifest.ps1 -TalkForgeAssets C:\Users\me\Projects\TalkForge\assets -Model en_US-lessac-high
  .\tools\New-VoiceManifest.ps1 -VoiceInputDir .\Web\vendor\voice
#>
param(
    [string]$TalkForgeAssets,
    [string]$VoiceInputDir,
    [string]$Model = 'en_US-lessac-high',
    [int]$Speaker = 0,
    [double]$LengthScale = 1.0
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
if (-not $TalkForgeAssets -and -not $VoiceInputDir) { throw 'Give -TalkForgeAssets, -VoiceInputDir, or both.' }

function Get-HashOf([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create(); $fs = [IO.File]::OpenRead($Path)
    try { return (($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $fs.Dispose(); $sha.Dispose() }
}

$path = Join-Path $Root 'Config\voice-assets.json'
$doc = if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllText($path) | ConvertFrom-Json } else { [pscustomobject]@{ version = 1 } }
$existing = @($doc.files | Where-Object { $null -ne $_ })
$ttsKeep = @($existing | Where-Object { ([string]$_.name).StartsWith('tts/') })
$sttKeep = @($existing | Where-Object { -not ([string]$_.name).StartsWith('tts/') })
$ttsCfg = if ($doc.PSObject.Properties['tts'] -and $doc.tts) { $doc.tts } else { [ordered]@{ model = $Model; speaker = $Speaker; lengthScale = $LengthScale } }

if ($TalkForgeAssets) {
    if ($Model -notmatch '^[A-Za-z0-9_-]+$') { throw 'Model must be a voice id such as en_US-lessac-high.' }
    $assets = (Resolve-Path -LiteralPath $TalkForgeAssets).Path
    $engine = Join-Path $assets 'vendor\piper-engine.js'
    if (-not (Test-Path -LiteralPath $engine)) { throw "Not a TalkForge assets folder (no vendor\piper-engine.js): $assets" }
    # The engine imports a hashed phonemizer bundle from ./dist/; read its name instead of guessing.
    $dist = [regex]::Match([IO.File]::ReadAllText($engine), "import\('\./dist/([A-Za-z0-9._-]+\.js)'\)").Groups[1].Value
    if (-not $dist) { throw 'Could not find the phonemizer bundle name in piper-engine.js.' }
    $rel = @('vendor/piper-engine.js', 'vendor/onnx/ort.min.mjs',
        'vendor/onnx/ort-wasm-simd-threaded.mjs', 'vendor/onnx/ort-wasm-simd-threaded.wasm',
        'vendor/onnx/ort-wasm-simd-threaded.jsep.mjs', 'vendor/onnx/ort-wasm-simd-threaded.jsep.wasm',
        "vendor/dist/$dist", 'wasm/piper_phonemize.wasm', 'wasm/piper_phonemize.data', "models/$Model.onnx", "models/$Model.onnx.json")
    $ttsKeep = @()
    foreach ($r in $rel) {
        $p = Join-Path $assets ($r -replace '/', '\')
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "Missing $r in $assets. For a voice model that is not there yet, run TalkForge's populate-assets first." }
        $h = Get-HashOf $p
        $ttsKeep += [ordered]@{ name = "tts/$r"; sha256 = $h }
        Write-Host ('  {0}  tts/{1}' -f $h.Substring(0, 12), $r)
    }
    $ttsCfg = [ordered]@{ model = $Model; speaker = $Speaker; lengthScale = $LengthScale }
}

if ($VoiceInputDir) {
    $dir = (Resolve-Path -LiteralPath $VoiceInputDir).Path.TrimEnd('\')
    $sttKeep = @()
    $files = @(Get-ChildItem -LiteralPath $dir -Recurse -File | Where-Object { $_.FullName.Substring($dir.Length + 1) -notmatch '^tts\\' -and $_.Name -ne '.gitkeep' })
    if ($files.Count -eq 0) { throw "No files under $dir." }
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($dir.Length + 1) -replace '\\', '/'
        if ($rel -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$') { throw "File name not allowed in the manifest: $rel" }
        $h = Get-HashOf $f.FullName
        $sttKeep += [ordered]@{ name = $rel; sha256 = $h }
        Write-Host ('  {0}  {1}' -f $h.Substring(0, 12), $rel)
    }
}

$out = [ordered]@{ version = 1; note = [string]$doc.note; tts = $ttsCfg; files = @($sttKeep + $ttsKeep) }
[IO.File]::WriteAllText($path, ($out | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
Write-Host "Wrote $(@($sttKeep).Count) speech-input and $(@($ttsKeep).Count) TalkForge entries to $path"
if ($TalkForgeAssets) { Write-Host "Point PacketRat at TalkForge:  `$env:PACKETRAT_TTS_DIR = '$assets'" }
