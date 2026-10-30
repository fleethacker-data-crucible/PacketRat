#requires -Version 5.1
# Offline tests for the opt-in Fairlead router setting. No network: Invoke-RestMethod is replaced and no router runs.
$ErrorActionPreference='Stop'
$Root=Split-Path $PSScriptRoot -Parent
foreach($name in @('LazaretteBridge','PacketRatStore','PacketRatLlm')){ . (Join-Path $Root "Private\$name.ps1") }
function Assert-Router([bool]$Pass,[string]$Message){if(-not $Pass){throw ('Fairlead test failed: '+$Message)}}
function Assert-Throws([scriptblock]$Block,[string]$Pattern,[string]$Message){
    $threw=$null
    try{& $Block}catch{$threw=$_.Exception.Message}
    Assert-Router ($null -ne $threw) ($Message+' (expected an error)')
    Assert-Router ($threw -match $Pattern) ($Message+" (wrong error: $threw)")
}

$envNames=@('LLM_URL','LLM_MODEL','LLM_TOKEN','PACKETRAT_AI_ENDPOINT_URL','PACKETRAT_GROK_URL','PACKETRAT_ROUTER','PACKETRAT_FAIRLEAD_URL','PACKETRAT_FAIRLEAD_MODEL','PACKETRAT_FAIRLEAD_PRIVACY','FAIRLEAD_TOKEN','DATABRICKS_TOKEN','PACKETRAT_LLM_STREAM')+@($script:PacketRatLlmTokenEnv.AiEndpoint)
$savedEnv=@{};foreach($n in $envNames){$savedEnv[$n]=[Environment]::GetEnvironmentVariable($n);[Environment]::SetEnvironmentVariable($n,$null)}
$global:sent=$null
function global:Invoke-RestMethod { param($Uri,$Method,$Headers,$Body,$ContentType,$TimeoutSec) $global:sent=@{Uri=$Uri;Headers=$Headers;Body=[Text.Encoding]::UTF8.GetString($Body)}; [pscustomobject]@{choices=@([pscustomobject]@{message=[pscustomobject]@{content='routed'}})} }
$msgs=@(@{role='user';content='Synthetic prompt.'})
try{
    # Off by default: the profile endpoint (local phoenix-lai) is used, not Fairlead.
    $cfg=Get-PacketRatLlmConfig -Profile Auto
    Assert-Router ($cfg.Router -eq '' -and $cfg.Url -eq 'http://127.0.0.1:1234/v1/chat/completions') 'router is off by default'
    Assert-Router ((Get-PacketRatCredentialStatus).router -eq 'Direct') 'status reports Direct by default'
    $null=Invoke-PacketRatChat -Messages $msgs -Profile AiEndpoint
    Assert-Router ($global:sent.Uri -eq 'http://127.0.0.1:1234/v1/chat/completions') 'a default call does not go to Fairlead'
    $env:PACKETRAT_ROUTER='direct'
    Assert-Router ((Get-PacketRatLlmConfig -Profile Auto).Router -eq '') 'any other router value stays off'

    # On: the default Fairlead address and the "auto" route.
    $env:PACKETRAT_ROUTER='Fairlead'
    $cfg=Get-PacketRatLlmConfig -Profile Auto
    Assert-Router ($cfg.Router -eq 'Fairlead' -and $cfg.Url -eq 'http://127.0.0.1:8776/v1/chat/completions' -and $cfg.Model -eq 'auto') 'opt-in uses the Fairlead address and the auto route'
    Assert-Router ((Get-PacketRatCredentialStatus).router -eq 'Fairlead') 'status reports Fairlead'
    $r=Invoke-PacketRatChat -Messages $msgs -Profile AiEndpoint
    Assert-Router ($r.Text -eq 'routed' -and $global:sent.Uri -eq 'http://127.0.0.1:8776/v1/chat/completions') 'a call goes to Fairlead'
    Assert-Router (($global:sent.Body | ConvertFrom-Json).model -eq 'auto') 'the request asks for the auto route'
    Assert-Router (-not $global:sent.Headers.ContainsKey('Authorization')) 'no Authorization header for a local Fairlead without a key'
    Assert-Router (-not $global:sent.Headers.ContainsKey('X-Fairlead-Privacy')) 'no privacy header unless asked for'

    # Provider tokens are never reused for Fairlead.
    $env:AI_ENDPOINT_TOKEN='provider-token-should-not-travel'
    $env:DATABRICKS_TOKEN='another-provider-token'
    $null=Invoke-PacketRatChat -Messages $msgs -Profile Grok
    Assert-Router (-not $global:sent.Headers.ContainsKey('Authorization')) 'provider tokens are not sent to Fairlead'
    Assert-Router ($global:sent.Uri -eq 'http://127.0.0.1:8776/v1/chat/completions') 'every profile goes to Fairlead when it is on'
    $env:AI_ENDPOINT_TOKEN=$null; $env:DATABRICKS_TOKEN=$null

    # Optional Fairlead key, privacy header, route and address overrides.
    $env:FAIRLEAD_TOKEN='fl-synthetic-key'
    $env:PACKETRAT_FAIRLEAD_PRIVACY='local'
    $env:PACKETRAT_FAIRLEAD_MODEL='fast'
    $env:PACKETRAT_FAIRLEAD_URL='http://localhost:9000/v1/chat/completions/'
    $null=Invoke-PacketRatChat -Messages $msgs -Profile AiEndpoint
    Assert-Router ($global:sent.Headers['Authorization'] -eq 'Bearer fl-synthetic-key') 'the Fairlead key is sent as a bearer token'
    Assert-Router ($global:sent.Headers['X-Fairlead-Privacy'] -eq 'local') 'privacy=local adds the Fairlead header'
    Assert-Router (($global:sent.Body | ConvertFrom-Json).model -eq 'fast') 'PACKETRAT_FAIRLEAD_MODEL picks the route'
    Assert-Router ($global:sent.Uri -eq 'http://localhost:9000/v1/chat/completions') 'PACKETRAT_FAIRLEAD_URL overrides the address (trailing slash trimmed)'
    $env:LLM_MODEL='smart'
    Assert-Router ((Get-PacketRatLlmConfig).Model -eq 'smart') 'LLM_MODEL still wins over the Fairlead route'
    $env:LLM_MODEL=$null

    # A Fairlead that is not on this PC must have its own key.
    $env:FAIRLEAD_TOKEN=$null
    $env:PACKETRAT_FAIRLEAD_URL='https://fairlead.example.org/v1/chat/completions'
    Assert-Throws { Invoke-PacketRatChat -Messages $msgs -Profile AiEndpoint } 'FAIRLEAD_TOKEN' 'a remote Fairlead without a key is explained before any request'

    # LLM_URL (an exact endpoint, on purpose) still wins over the router.
    $env:PACKETRAT_FAIRLEAD_URL=$null
    $env:LLM_URL='http://localhost:5000/v1/chat/completions'
    $cfg=Get-PacketRatLlmConfig
    Assert-Router ($cfg.Router -eq '' -and $cfg.Url -eq $env:LLM_URL) 'LLM_URL overrides the router'
}finally{
    Remove-Item Function:\Invoke-RestMethod -ErrorAction SilentlyContinue
    foreach($n in $envNames){[Environment]::SetEnvironmentVariable($n,$savedEnv[$n])}
}
'PacketRat Fairlead router tests passed.'
