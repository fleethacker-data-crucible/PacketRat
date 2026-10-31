#requires -Version 5.1
# Offline tests for the hash-checked local speech-input assets. Synthetic stand-in files only; no model is used.
$ErrorActionPreference='Stop'
$Root=Split-Path $PSScriptRoot -Parent
foreach($name in @('LazaretteBridge','PacketRatLogging','PacketRatLifecycle','PacketRatLlm','PacketRatStore','PacketRatUsage','PacketRatAssistant','PacketRatVoiceAssets','PacketRatRules','PacketRatProtocol','PacketRatReport','Get-OutlookMailSummary','PacketRatGraph','PacketRatDraft','PacketRatApi','PacketRatCommands')){
    . (Join-Path $Root "Private\$name.ps1")
}
function Assert-Voice([bool]$Pass,[string]$Message){if(-not $Pass){throw ('Voice assets test failed: '+$Message)}}
# Invoke-PacketRatApi has no -Root parameter: it reads $Root from the caller's scope, so scope it here (the repo's own Logs store is never touched).
function Invoke-ApiAt([string]$Dir,[string]$Route,$Data){ $Root=$Dir; Invoke-PacketRatApi -Route $Route -Data $Data }
function Assert-Throws([scriptblock]$Block,[string]$Pattern,[string]$Message){
    $threw=$null
    try{& $Block}catch{$threw=$_.Exception.Message}
    Assert-Voice ($null -ne $threw -and $threw -match $Pattern) ($Message+" (got: $threw)")
}
function Get-Sha([byte[]]$b){$s=[Security.Cryptography.SHA256]::Create();try{(($s.ComputeHash($b)|ForEach-Object{$_.ToString('x2')}) -join '')}finally{$s.Dispose()}}

# The shipped manifest lists nothing, so the feature reports "not installed" instead of failing.
$shipped=Get-PacketRatVoiceStatus -Root $Root
Assert-Voice ($shipped.installed -eq $false -and $shipped.listed -eq 0 -and $shipped.note -match 'not installed') 'the shipped manifest means not installed'
$cmd=Find-PacketRatCommand 'voice status'
Assert-Voice ($null -ne $cmd -and $cmd.Method -eq 'GET') 'voice status is a GET command'

$tmp=Join-Path ([IO.Path]::GetTempPath()) ('packetrat-voice-'+[guid]::NewGuid().ToString('N'))
$cfg=Join-Path $tmp 'Config'; $vdir=Join-Path $tmp 'voicefiles'
[void](New-Item -ItemType Directory -Path $cfg -Force); [void](New-Item -ItemType Directory -Path (Join-Path $vdir 'models') -Force)
$saved=$env:PACKETRAT_VOICE_DIR
try{
    $env:PACKETRAT_VOICE_DIR=$vdir
    $js=[Text.Encoding]::UTF8.GetBytes('export const env={};'); $bin=[byte[]](1..200)
    [IO.File]::WriteAllBytes((Join-Path $vdir 'transformers.min.js'),$js)
    [IO.File]::WriteAllBytes((Join-Path $vdir 'models\whisper.onnx'),$bin)
    [IO.File]::WriteAllBytes((Join-Path $tmp 'secret.txt'),[byte[]](9,9,9))
    function Write-Manifest($entries){ ([ordered]@{version=1;files=@($entries)} | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath (Join-Path $cfg 'voice-assets.json') -Encoding UTF8 }
    $good=@(@{name='transformers.min.js';sha256=(Get-Sha $js)},@{name='models/whisper.onnx';sha256=(Get-Sha $bin)})
    Write-Manifest $good
    $s=Get-PacketRatVoiceStatus -Root $tmp
    Assert-Voice ($s.installed -and $s.listed -eq 2 -and $s.missing.Count -eq 0 -and $s.mismatched.Count -eq 0) 'matching files are installed'
    Assert-Voice ((Read-PacketRatVoiceAsset -Name 'models/whisper.onnx' -Root $tmp).Length -eq 200) 'a listed asset is served'
    Assert-Voice ((Get-PacketRatVoiceMime 'a.wasm') -eq 'application/wasm' -and (Get-PacketRatVoiceMime 'transformers.min.js') -match 'javascript') 'mime types'

    # Not listed / traversal.
    Assert-Throws { Read-PacketRatVoiceAsset -Name 'secret.txt' -Root $tmp } 'Not a listed' 'an unlisted file is refused'
    Assert-Throws { Read-PacketRatVoiceAsset -Name '..\secret.txt' -Root $tmp } 'Not a listed' 'a traversal name is refused'
    Write-Manifest @(@{name='..\secret.txt';sha256=(Get-Sha ([byte[]](9,9,9)))})
    Assert-Throws { Get-PacketRatVoiceManifest -Root $tmp } 'bad entry' 'a manifest entry with traversal is rejected'
    Write-Manifest @(@{name='transformers.min.js';sha256='abc'})
    Assert-Throws { Get-PacketRatVoiceManifest -Root $tmp } 'bad entry' 'a malformed hash is rejected'

    # Swapped / missing files.
    Write-Manifest $good
    [IO.File]::WriteAllBytes((Join-Path $vdir 'transformers.min.js'),[Text.Encoding]::UTF8.GetBytes('evil();'))
    $s=Get-PacketRatVoiceStatus -Root $tmp
    Assert-Voice (-not $s.installed -and $s.mismatched -contains 'transformers.min.js') 'a changed file is reported as mismatched'
    Assert-Throws { Read-PacketRatVoiceAsset -Name 'transformers.min.js' -Root $tmp } 'hash' 'a changed file is not served'
    Remove-Item (Join-Path $vdir 'models\whisper.onnx')
    $s=Get-PacketRatVoiceStatus -Root $tmp
    Assert-Voice ($s.missing -contains 'models/whisper.onnx') 'a missing file is reported'
    Assert-Throws { Read-PacketRatVoiceAsset -Name 'models/whisper.onnx' -Root $tmp } 'missing' 'a missing file is not served'

    # TalkForge voice (tts/ names live in PACKETRAT_TTS_DIR, same tree as TalkForge's assets folder).
    $ttsDir=Join-Path $tmp 'talkforge-assets'; [void](New-Item -ItemType Directory -Path (Join-Path $ttsDir 'vendor') -Force); [void](New-Item -ItemType Directory -Path (Join-Path $ttsDir 'models') -Force)
    $eng=[Text.Encoding]::UTF8.GetBytes('export class PiperEngine {}'); $mdl=[byte[]](5..90)
    [IO.File]::WriteAllBytes((Join-Path $ttsDir 'vendor\piper-engine.js'),$eng); [IO.File]::WriteAllBytes((Join-Path $ttsDir 'models\v.onnx'),$mdl)
    $env:PACKETRAT_TTS_DIR=$ttsDir
    ([ordered]@{version=1;tts=[ordered]@{model='v';speaker=2;lengthScale=0.9};files=@(@{name='tts/vendor/piper-engine.js';sha256=(Get-Sha $eng)},@{name='tts/models/v.onnx';sha256=(Get-Sha $mdl)})} | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath (Join-Path $cfg 'voice-assets.json') -Encoding UTF8
    $s=Get-PacketRatVoiceStatus -Root $tmp
    Assert-Voice ($s.tts.installed -and $s.tts.model -eq 'v' -and $s.tts.speaker -eq 2 -and $s.tts.lengthScale -eq 0.9 -and $s.tts.listed -eq 2) 'TalkForge files are found in PACKETRAT_TTS_DIR and the voice setting is read'
    Assert-Voice (-not $s.installed -and $s.listed -eq 0) 'speech input stays separate and not installed'
    Assert-Voice ((Read-PacketRatVoiceAsset -Name 'tts/models/v.onnx' -Root $tmp).Length -eq 86) 'a TalkForge asset is served'
    Assert-Throws { Read-PacketRatVoiceAsset -Name 'tts/vendor/other.js' -Root $tmp } 'Not a listed' 'an unlisted TalkForge file is refused'
    [IO.File]::WriteAllBytes((Join-Path $ttsDir 'vendor\piper-engine.js'),[Text.Encoding]::UTF8.GetBytes('evil();'))
    $s=Get-PacketRatVoiceStatus -Root $tmp
    Assert-Voice (-not $s.tts.installed -and $s.tts.mismatched -contains 'tts/vendor/piper-engine.js') 'a changed TalkForge file is reported and refused'
    Assert-Throws { Read-PacketRatVoiceAsset -Name 'tts/vendor/piper-engine.js' -Root $tmp } 'hash' 'a changed TalkForge file is not served'
    $env:PACKETRAT_TTS_DIR=Join-Path $tmp 'nowhere'
    $s=Get-PacketRatVoiceStatus -Root $tmp
    Assert-Voice (-not $s.tts.installed -and $s.tts.missing.Count -eq 2) 'a wrong PACKETRAT_TTS_DIR reports the files missing'
    $env:PACKETRAT_TTS_DIR=$null
    $shippedTts=(Get-PacketRatVoiceStatus -Root $Root).tts
    Assert-Voice ($shippedTts.listed -eq 11 -and $shippedTts.model -eq 'en_US-lessac-high') 'the shipped manifest pins the 11 TalkForge files for the default voice'

    # API route.
    $r=Invoke-ApiAt $tmp '/api/voice/status' $null
    Assert-Voice ($r.ok -and $r.voice.installed -eq $false) 'the API route reports status'
    Write-Host 'Voice assets tests passed.'
}finally{
    $env:PACKETRAT_VOICE_DIR=$saved
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
