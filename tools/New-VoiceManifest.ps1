#requires -Version 5.1
<#
.SYNOPSIS
  Lists TalkForge's voice files in Config\voice-assets.json with their SHA-256, so PacketRat can speak with the TalkForge voice.
.DESCRIPTION
  Reads the engine, ONNX Runtime, phonemizer and one voice model from your local TalkForge clone (its assets folder), hashes
  them, and writes the "tts/..." entries and the "tts" voice setting. Run it once, on a TalkForge folder you trust: the hashes
  it records are the ones PacketRat later enforces. Nothing is downloaded and nothing is sent anywhere. Other entries (speech
  input) in the file are kept.
.EXAMPLE
  .\tools\New-VoiceManifest.ps1 -TalkForgeAssets C:\Users\me\Projects\TalkForge\assets -Model en_US-lessac-high
  $env:PACKETRAT_TTS_DIR = 'C:\Users\me\Projects\TalkForge\assets'
#>
param(
    [Parameter(Mandatory)][string]$TalkForgeAssets,
    [string]$Model = 'en_US-lessac-high',
    [int]$Speaker = 0,
    [double]$LengthScale = 1.0
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$assets = (Resolve-Path -LiteralPath $TalkForgeAssets).Path
if ($Model -notmatch '^[A-Za-z0-9_-]+$') { throw 'Model must be a voice id such as en_US-lessac-high.' }

$engine = Join-Path $assets 'vendor\piper-engine.js'
if (-not (Test-Path -LiteralPath $engine)) { throw "Not a TalkForge assets folder (no vendor\piper-engine.js): $assets" }
# The engine imports a hashed phonemizer bundle from ./dist/; read its name instead of guessing.
$dist = [regex]::Match([IO.File]::ReadAllText($engine), "import\('\./dist/([A-Za-z0-9._-]+\.js)'\)").Groups[1].Value
if (-not $dist) { throw 'Could not find the phonemizer bundle name in piper-engine.js.' }

$rel = @(
    'vendor/piper-engine.js', 'vendor/onnx/ort.min.mjs',
    'vendor/onnx/ort-wasm-simd-threaded.mjs', 'vendor/onnx/ort-wasm-simd-threaded.wasm',
    'vendor/onnx/ort-wasm-simd-threaded.jsep.mjs', 'vendor/onnx/ort-wasm-simd-threaded.jsep.wasm',
    "vendor/dist/$dist", 'wasm/piper_phonemize.wasm', 'wasm/piper_phonemize.data',
    "models/$Model.onnx", "models/$Model.onnx.json"
)
$entries = @()
foreach ($r in $rel) {
    $p = Join-Path $assets ($r -replace '/', '\')
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
        throw "Missing $r in $assets. For a voice model that is not there yet, run TalkForge's populate-assets first."
    }
    $sha = [Security.Cryptography.SHA256]::Create(); $fs = [IO.File]::OpenRead($p)
    try { $h = (($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $fs.Dispose(); $sha.Dispose() }
    $entries += [ordered]@{ name = "tts/$r"; sha256 = $h }
    Write-Host ('  {0}  {1}' -f $h.Substring(0, 12), $r)
}

$path = Join-Path $Root 'Config\voice-assets.json'
$doc = if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllText($path) | ConvertFrom-Json } else { [pscustomobject]@{ version = 1 } }
$keep = @($doc.files | Where-Object { $null -ne $_ -and -not ([string]$_.name).StartsWith('tts/') })
$out = [ordered]@{
    version = 1
    note    = [string]$doc.note
    tts     = [ordered]@{ model = $Model; speaker = $Speaker; lengthScale = $LengthScale }
    files   = @($keep + $entries)
}
[IO.File]::WriteAllText($path, ($out | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
Write-Host "Wrote $($entries.Count) TalkForge entries to $path"
Write-Host "Now point PacketRat at the folder:  `$env:PACKETRAT_TTS_DIR = '$assets'"
