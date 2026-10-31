#requires -Version 5.1
# Offline tests for Fairlead as the default intelligence endpoint, against a fake Fairlead on a real loopback socket:
# the fake listens on Fairlead's own address (127.0.0.1:8776) so the default needs no setting at all. If that port is
# already taken (a real Fairlead may be running), the fake uses a free port and PACKETRAT_FAIRLEAD_URL, and the test says so.
# No real Fairlead, model, mailbox or internet is involved; synthetic prompts only.
$ErrorActionPreference='Stop'
$Root=Split-Path $PSScriptRoot -Parent
foreach($name in @('LazaretteBridge','PacketRatStore','PacketRatLlm','PacketRatRouter')){ . (Join-Path $Root "Private\$name.ps1") }
function Assert-Default([bool]$Pass,[string]$Message){if(-not $Pass){throw ('Fairlead default test failed: '+$Message)}}

# --- A fake OpenAI-compatible router: records every request, answers with a fixed completion ------------------------------
$serverScript={
    param($Listener,$Shared)
    $enc=New-Object System.Text.UTF8Encoding $false
    while($true){
        try{ $client=$Listener.AcceptTcpClient() }catch{ break }
        try{
            $net=$client.GetStream()
            $buf=New-Object System.Collections.Generic.List[byte]
            $one=New-Object byte[] 1
            while($true){ if($net.Read($one,0,1) -le 0){break}; $buf.Add($one[0]); if($buf.Count -ge 4 -and $enc.GetString($buf.ToArray()).EndsWith("`r`n`r`n")){break} }
            if($buf.Count -eq 0){ continue }   # a bare connect (the "is it up" check): nothing to answer
            $head=$enc.GetString($buf.ToArray())
            $len=0; if($head -match '(?im)^content-length:\s*(\d+)'){$len=[int]$Matches[1]}
            $body=New-Object byte[] $len; $off=0
            while($off -lt $len){ $r=$net.Read($body,$off,$len-$off); if($r -le 0){break}; $off+=$r }
            [void]$Shared['requests'].Add(@{Head=$head;Body=$enc.GetString($body)})
            $payload=$enc.GetBytes('{"choices":[{"message":{"role":"assistant","content":"routed by fake fairlead"}}]}')
            $resp=$enc.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($payload.Length)`r`nConnection: close`r`n`r`n")
            $net.Write($resp,0,$resp.Length); $net.Write($payload,0,$payload.Length); $net.Flush()
        }catch{} finally{ try{$client.Close()}catch{} }
    }
}
function Start-FakeFairlead([int]$Port){
    $listener=New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback),$Port
    $listener.Start()
    $shared=[hashtable]::Synchronized(@{requests=[System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))})
    $ps=[powershell]::Create()
    [void]$ps.AddScript($serverScript).AddArgument($listener).AddArgument($shared)
    $handle=$ps.BeginInvoke()
    [pscustomobject]@{Listener=$listener;Shared=$shared;PS=$ps;Handle=$handle;Port=([Net.IPEndPoint]$listener.LocalEndpoint).Port}
}
function Stop-FakeFairlead($Ep){ try{$Ep.Listener.Stop()}catch{}; try{$Ep.PS.Stop()}catch{}; try{$Ep.PS.Dispose()}catch{} }

$envNames=@('LLM_URL','LLM_MODEL','LLM_TOKEN','PACKETRAT_AI_ENDPOINT_URL','PACKETRAT_GROK_URL','PACKETRAT_ROUTER','PACKETRAT_FAIRLEAD_URL','PACKETRAT_FAIRLEAD_MODEL','PACKETRAT_FAIRLEAD_PRIVACY','PACKETRAT_FAIRLEAD_AUTOSTART','FAIRLEAD_TOKEN','FAIRLEAD_DIR','AI_ENDPOINT_TOKEN','DATABRICKS_TOKEN')
$savedEnv=@{};foreach($n in $envNames){$savedEnv[$n]=[Environment]::GetEnvironmentVariable($n);[Environment]::SetEnvironmentVariable($n,$null)}
$msgs=@(@{role='user';content='Synthetic prompt for the router.'})
$fake=$null;$other=$null
try{
    $onDefaultPort=$true
    try{ $fake=Start-FakeFairlead 8776 }catch{ $onDefaultPort=$false; $fake=Start-FakeFairlead 0 }
    if(-not $onDefaultPort){
        $env:PACKETRAT_FAIRLEAD_URL=('http://127.0.0.1:{0}/v1/chat/completions' -f $fake.Port)
        Write-Host 'Note: 127.0.0.1:8776 is in use (a real Fairlead?), so the fake listens on a free port and PACKETRAT_FAIRLEAD_URL points at it.'
    }
    $expectedUri=('http://127.0.0.1:{0}/v1/chat/completions' -f $fake.Port)
    $reqs=$fake.Shared['requests']

    # --- Nothing configured: the call reaches Fairlead -----------------------------------------------------------------------
    $cfg=Get-PacketRatLlmConfig -Profile Auto
    Assert-Default ($cfg.Router -eq 'Fairlead' -and $cfg.Url -eq $expectedUri -and $cfg.Model -eq 'auto') 'with nothing set, the config is Fairlead and the auto route'
    $r=Invoke-PacketRatChat -Messages $msgs -Profile Auto -TimeoutSec 15
    Assert-Default ($r.Text -eq 'routed by fake fairlead') 'the answer comes back from the fake Fairlead'
    Assert-Default ($reqs.Count -eq 1) 'exactly one request reached the fake'
    $q=$reqs[0]
    Assert-Default ($q.Head -match '(?m)^POST /v1/chat/completions HTTP') 'it is an OpenAI-style chat completion request'
    Assert-Default (($q.Body | ConvertFrom-Json).model -eq 'auto' -and ($q.Body | ConvertFrom-Json).messages[0].content -eq 'Synthetic prompt for the router.') 'the body asks for the auto route and carries the prompt'
    Assert-Default ($q.Head -notmatch '(?im)^authorization:') 'no Authorization header for a local Fairlead without a key'
    Assert-Default ($q.Head -notmatch '(?im)^x-fairlead-privacy:') 'no privacy header unless asked for'

    # --- Every profile goes there; provider tokens never travel --------------------------------------------------------------------
    $env:AI_ENDPOINT_TOKEN='provider-token-should-not-travel'; $env:DATABRICKS_TOKEN='another-provider-token'
    $null=Invoke-PacketRatChat -Messages $msgs -Profile Grok -TimeoutSec 15
    Assert-Default ($reqs.Count -eq 2 -and $reqs[1].Head -notmatch '(?im)^authorization:' -and $reqs[1].Head -notmatch 'provider-token') 'the Grok profile also goes to Fairlead, with no provider token'
    $env:AI_ENDPOINT_TOKEN=$null; $env:DATABRICKS_TOKEN=$null

    # --- The Fairlead key and the privacy header -------------------------------------------------------------------------------------
    $env:FAIRLEAD_TOKEN='fl-synthetic-key'; $env:PACKETRAT_FAIRLEAD_PRIVACY='local'; $env:PACKETRAT_FAIRLEAD_MODEL='fast'
    $null=Invoke-PacketRatChat -Messages $msgs -Profile AiEndpoint -TimeoutSec 15
    $q=$reqs[2]
    Assert-Default ($q.Head -match '(?im)^authorization:\s*Bearer fl-synthetic-key' -and $q.Head -match '(?im)^x-fairlead-privacy:\s*local') 'the Fairlead key and local-privacy header are sent when set'
    Assert-Default (($q.Body | ConvertFrom-Json).model -eq 'fast') 'the route name can be changed'
    $env:FAIRLEAD_TOKEN=$null; $env:PACKETRAT_FAIRLEAD_PRIVACY=$null; $env:PACKETRAT_FAIRLEAD_MODEL=$null

    # --- The "is it up" check sees the fake, so nothing is started ----------------------------------------------------------------
    $before=$reqs.Count
    Assert-Default (Test-PacketRatFairleadUp -Uri (Get-PacketRatFairleadUri)) 'the up check sees the fake on the default address'
    $e=Ensure-PacketRatFairlead -Root $Root -WaitSeconds 1
    Assert-Default ($e.State -eq 'AlreadyRunning') 'with the router on by default and Fairlead answering, nothing is started'
    Assert-Default ($reqs.Count -eq $before) 'the up check sends no request'

    # --- Opting out and exact endpoints never touch Fairlead --------------------------------------------------------------------------
    $other=Start-FakeFairlead 0
    $otherUri=('http://127.0.0.1:{0}/v1/chat/completions' -f $other.Port)
    $env:PACKETRAT_AI_ENDPOINT_URL=$otherUri
    $before=$reqs.Count
    $r=Invoke-PacketRatChat -Messages $msgs -Profile AiEndpoint -TimeoutSec 15
    Assert-Default ($r.Text -eq 'routed by fake fairlead' -and $other.Shared['requests'].Count -eq 1 -and $reqs.Count -eq $before) 'an exact endpoint variable goes straight to that endpoint, not to Fairlead'
    Assert-Default ((Ensure-PacketRatFairlead -Root $Root).State -eq 'Skipped') 'and Fairlead is not started for it'
    $env:PACKETRAT_AI_ENDPOINT_URL=$null
    $env:PACKETRAT_ROUTER='direct'; $env:LLM_URL=$otherUri
    $null=Invoke-PacketRatChat -Messages $msgs -Profile AiEndpoint -TimeoutSec 15
    Assert-Default ($other.Shared['requests'].Count -eq 2 -and $reqs.Count -eq $before) 'PACKETRAT_ROUTER=direct with LLM_URL does not reach Fairlead'
    Assert-Default ((Ensure-PacketRatFairlead -Root $Root).State -eq 'Skipped') 'and nothing is started when the router is opted out'

    # --- Fairlead gone: the failure is a plain connection error, not a hang ----------------------------------------------------------------
    $env:PACKETRAT_ROUTER=$null; $env:LLM_URL=$null
    Stop-FakeFairlead $fake; $fake=$null
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $failed=$false
    try{ $null=Invoke-PacketRatChat -Messages $msgs -Profile AiEndpoint -TimeoutSec 10 }catch{ $failed=$true }
    Assert-Default ($failed -and $clock.Elapsed.TotalSeconds -lt 10) 'with nothing listening the call fails promptly'
}finally{
    if($fake){Stop-FakeFairlead $fake}
    if($other){Stop-FakeFairlead $other}
    foreach($n in $envNames){[Environment]::SetEnvironmentVariable($n,$savedEnv[$n])}
}
'PacketRat Fairlead default tests passed.'
