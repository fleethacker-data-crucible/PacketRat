#requires -Version 5.1
# Offline tests for streaming and cancel. A throwaway server on a loopback port plays the AI endpoint (synthetic text only):
# no real model, no credentials, nothing leaves this PC.
$ErrorActionPreference='Stop'
$Root=Split-Path $PSScriptRoot -Parent
foreach($name in @('LazaretteBridge','PacketRatLogging','PacketRatLifecycle','PacketRatStore','PacketRatRules','PacketRatLlm','PacketRatProtocol','PacketRatReport','Get-OutlookMailSummary','PacketRatGraph','PacketRatDraft','PacketRatApi','PacketRatCommands')){
    . (Join-Path $Root "Private\$name.ps1")
}
function Assert-Stream([bool]$Pass,[string]$Message){if(-not $Pass){throw ('Streaming test failed: '+$Message)}}
function Assert-Throws([scriptblock]$Block,[string]$Pattern,[string]$Message){
    $threw=$null
    try{& $Block}catch{$threw=$_.Exception.Message}
    Assert-Stream ($null -ne $threw) ($Message+' (expected an error)')
    Assert-Stream ($threw -match $Pattern) ($Message+" (wrong error: $threw)")
}

# --- SSE data parsing ---------------------------------------------------------------------------------------------
$e=ConvertFrom-PacketRatSseData '{"choices":[{"delta":{"content":"Hello"}}]}'
Assert-Stream ((-not $e.Done) -and $e.Text -eq 'Hello') 'delta content'
$e=ConvertFrom-PacketRatSseData ' [DONE] '
Assert-Stream ($e.Done -and $e.Text -eq '') '[DONE] ends the stream'
$e=ConvertFrom-PacketRatSseData '{"choices":[{"delta":{"role":"assistant"}}]}'
Assert-Stream ($e.Text -eq '' -and -not $e.Done) 'a role-only delta carries no text'
$e=ConvertFrom-PacketRatSseData '{"choices":[{"text":"legacy"}]}'
Assert-Stream ($e.Text -eq 'legacy') 'legacy completion text'
$e=ConvertFrom-PacketRatSseData '{"choices":[{"delta":{"content":[{"type":"text","text":"part"}]}}]}'
Assert-Stream ($e.Text -eq 'part') 'a block-array delta is flattened'
$e=ConvertFrom-PacketRatSseData 'not json'
Assert-Stream ($e.Text -eq '' -and -not $e.Done) 'a non-JSON keep-alive is ignored'
Assert-Throws { ConvertFrom-PacketRatSseData '{"error":{"message":"quota used up"}}' } 'quota used up' 'an error event is raised'

# --- Reading a whole stream from memory ---------------------------------------------------------------------------
$sse=": keep-alive`r`n`r`ndata: {`"choices`":[{`"delta`":{`"content`":`"One `"}}]}`r`n`r`nevent: ping`r`ndata: {`"choices`":[{`"delta`":{`"content`":`"two`"}}]}`r`n`r`ndata: [DONE]`r`n`r`ndata: {`"choices`":[{`"delta`":{`"content`":`"after done`"}}]}`r`n"
$ms=New-Object IO.MemoryStream (,[Text.Encoding]::UTF8.GetBytes($sse))
$seen=New-Object System.Collections.ArrayList
$text=Read-PacketRatSseStream -Stream $ms -OnToken { param($t) [void]$seen.Add($t) }
Assert-Stream ($text -eq 'One two') 'joined text stops at [DONE] and skips comments and non-data lines'
Assert-Stream ((@($seen) -join '|') -eq 'One |two') 'OnToken sees each piece'
$ms=New-Object IO.MemoryStream (,[Text.Encoding]::UTF8.GetBytes($sse))
Assert-Throws { Read-PacketRatSseStream -Stream $ms -ShouldCancel { $true } } 'cancelled' 'cancel is honoured before the first read'

# --- A fake endpoint on loopback ----------------------------------------------------------------------------------
$serverScript={
    param($Listener,$Mode,$Shared)
    $enc=New-Object System.Text.UTF8Encoding $false
    $client=$Listener.AcceptTcpClient()
    $client.NoDelay=$true
    $net=$client.GetStream()
    function Send([byte[]]$b){ $net.Write($b,0,$b.Length); $net.Flush() }
    function Chunk([byte[]]$b){ Send ($enc.GetBytes(('{0:x}' -f $b.Length)+"`r`n")); Send $b; Send ($enc.GetBytes("`r`n")) }
    # Read the request head and body.
    $buf=New-Object System.Collections.Generic.List[byte]
    $one=New-Object byte[] 1
    while($true){ if($net.Read($one,0,1) -le 0){break}; $buf.Add($one[0]); $t=$enc.GetString($buf.ToArray()); if($t.EndsWith("`r`n`r`n")){break} }
    $head=$enc.GetString($buf.ToArray())
    $len=0; if($head -match '(?im)^content-length:\s*(\d+)'){$len=[int]$Matches[1]}
    $body=New-Object byte[] $len; $off=0
    while($off -lt $len){ $r=$net.Read($body,$off,$len-$off); if($r -le 0){break}; $off+=$r }
    $Shared['head']=$head; $Shared['body']=$enc.GetString($body)
    try{
        switch($Mode){
            'hang' { Start-Sleep -Seconds 20 }
            'error' { Send ($enc.GetBytes("HTTP/1.1 500 Internal Server Error`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")) }
            default {
                Send ($enc.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: text/event-stream`r`nTransfer-Encoding: chunked`r`nConnection: close`r`n`r`n"))
                if($Mode -eq 'normal'){
                    Chunk ($enc.GetBytes("data: {`"choices`":[{`"delta`":{`"content`":`"Stream `"}}]}`n`n"))
                    # Split a multi-byte character (the euro sign) across two network writes.
                    $ev=$enc.GetBytes("data: {`"choices`":[{`"delta`":{`"content`":`"costs 5 $([char]0x20AC)`"}}]}`n`n")
                    $cut=([Array]::IndexOf($ev,[byte]0xE2))+1
                    Chunk ([byte[]]$ev[0..($cut-1)]); Start-Sleep -Milliseconds 150
                    Chunk ([byte[]]$ev[$cut..($ev.Length-1)]); Start-Sleep -Milliseconds 100
                    Chunk ($enc.GetBytes("data: [DONE]`n`n"))
                    Send ($enc.GetBytes("0`r`n`r`n"))
                }else{ # 'slow': one event, then silence with the connection open
                    Chunk ($enc.GetBytes("data: {`"choices`":[{`"delta`":{`"content`":`"first`"}}]}`n`n"))
                    Start-Sleep -Seconds 20
                }
            }
        }
    }catch{} finally { try{$client.Close()}catch{} }
}
function Start-FakeEndpoint([string]$Mode){
    $listener=New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback),0
    $listener.Start()
    $shared=[hashtable]::Synchronized(@{})
    $ps=[powershell]::Create()
    [void]$ps.AddScript($serverScript).AddArgument($listener).AddArgument($Mode).AddArgument($shared)
    $handle=$ps.BeginInvoke()
    [pscustomobject]@{Listener=$listener;Shared=$shared;PS=$ps;Handle=$handle;Url=('http://127.0.0.1:{0}/v1/chat/completions' -f ([Net.IPEndPoint]$listener.LocalEndpoint).Port)}
}
function Stop-FakeEndpoint($Ep){
    try{$Ep.Listener.Stop()}catch{}
    try{$Ep.PS.Stop()}catch{}
    try{$Ep.PS.Dispose()}catch{}
}

$envNames=@('LLM_URL','LLM_MODEL','LLM_TOKEN','PACKETRAT_AI_ENDPOINT_URL','PACKETRAT_LLM_STREAM')+@($script:PacketRatLlmTokenEnv.AiEndpoint)
$savedEnv=@{};foreach($n in $envNames){$savedEnv[$n]=[Environment]::GetEnvironmentVariable($n);[Environment]::SetEnvironmentVariable($n,$null)}
$msgs=@(@{role='user';content='Say something synthetic.'})
try{
    # Streaming end to end, including a character split across network writes.
    $ep=Start-FakeEndpoint 'normal'
    try{
        $env:LLM_URL=$ep.Url
        $pieces=New-Object System.Collections.ArrayList
        $r=Invoke-PacketRatChat -Messages $msgs -Profile AiEndpoint -Stream -OnToken { param($t) [void]$pieces.Add($t) } -TimeoutSec 20
        Assert-Stream ($r.Text -eq "Stream costs 5 $([char]0x20AC)") "streamed text is joined and the split character survives (got '$($r.Text)')"
        Assert-Stream ($r.Streamed) 'result is marked streamed'
        Assert-Stream (@($pieces).Count -ge 2) 'tokens arrived piece by piece'
        $sent=$ep.Shared['body'] | ConvertFrom-Json
        Assert-Stream ($sent.stream -eq $true) 'the request asked for stream=true'
        Assert-Stream ($ep.Shared['head'] -match '(?im)^accept:\s*text/event-stream') 'the request accepts an event stream'
        Assert-Stream ($ep.Shared['head'] -notmatch '(?im)^authorization:') 'no Authorization header without a token (loopback)'
    }finally{ Stop-FakeEndpoint $ep }

    # The environment switch turns streaming on without -Stream.
    $ep=Start-FakeEndpoint 'normal'
    try{
        $env:LLM_URL=$ep.Url; $env:PACKETRAT_LLM_STREAM='1'
        $r=Invoke-PacketRatChat -Messages $msgs -Profile AiEndpoint -TimeoutSec 20
        Assert-Stream ($r.Streamed -and $r.Text.StartsWith('Stream costs')) 'PACKETRAT_LLM_STREAM=1 streams'
        $env:PACKETRAT_LLM_STREAM=$null
    }finally{ Stop-FakeEndpoint $ep }

    # Cancel by callback while the endpoint goes quiet.
    $ep=Start-FakeEndpoint 'slow'
    try{
        $env:LLM_URL=$ep.Url
        $script:got=0
        $clock=[Diagnostics.Stopwatch]::StartNew()
        Assert-Throws { Invoke-PacketRatChat -Messages $msgs -Profile AiEndpoint -Stream -TimeoutSec 30 -OnToken { param($t) $script:got++ } -ShouldCancel { $script:got -ge 1 } } 'cancelled' 'a stalled generation is cancelled from the callback'
        Assert-Stream ($clock.Elapsed.TotalSeconds -lt 8) 'cancel returns promptly, not after the 20 s stall'
        Assert-Stream ($script:got -eq 1) 'the text before the cancel was delivered'
    }finally{ Stop-FakeEndpoint $ep }

    # Cancel by flag file (what "inbox cancel" writes), raised from the token callback.
    $ep=Start-FakeEndpoint 'slow'
    try{
        $env:LLM_URL=$ep.Url
        Clear-PacketRatCancel
        Assert-Throws { Invoke-PacketRatChat -Messages $msgs -Profile AiEndpoint -Stream -TimeoutSec 30 -OnToken { param($t) $null=Request-PacketRatCancel } } 'cancelled' 'the cancel flag file stops a running generation'
        Assert-Stream (Test-PacketRatCancelRequested) 'the flag stays until the next run clears it'
        Clear-PacketRatCancel
        Assert-Stream (-not (Test-PacketRatCancelRequested)) 'Clear-PacketRatCancel removes it'
    }finally{ Stop-FakeEndpoint $ep; Clear-PacketRatCancel }

    # A stale flag does not kill the next run.
    $ep=Start-FakeEndpoint 'normal'
    try{
        $env:LLM_URL=$ep.Url
        $null=Request-PacketRatCancel
        $r=Invoke-PacketRatChat -Messages $msgs -Profile AiEndpoint -Stream -TimeoutSec 20
        Assert-Stream ($r.Text.StartsWith('Stream costs')) 'a flag left from an earlier run is cleared at the start of a new one'
    }finally{ Stop-FakeEndpoint $ep; Clear-PacketRatCancel }

    # Cancel while waiting for the first byte.
    $ep=Start-FakeEndpoint 'hang'
    try{
        $env:LLM_URL=$ep.Url
        $script:polls=0
        $clock=[Diagnostics.Stopwatch]::StartNew()
        Assert-Throws { Invoke-PacketRatChat -Messages $msgs -Profile AiEndpoint -Stream -TimeoutSec 30 -ShouldCancel { $script:polls++; $script:polls -ge 3 } } 'cancelled' 'cancel works before the endpoint answers'
        Assert-Stream ($clock.Elapsed.TotalSeconds -lt 8) 'cancel while waiting returns promptly'
    }finally{ Stop-FakeEndpoint $ep }

    # An HTTP error is explained.
    $ep=Start-FakeEndpoint 'error'
    try{
        $env:LLM_URL=$ep.Url
        Assert-Throws { Invoke-PacketRatChat -Messages $msgs -Profile AiEndpoint -Stream -TimeoutSec 20 } 'refused the request \(HTTP 500\)' 'an HTTP 500 is reported with its status'
    }finally{ Stop-FakeEndpoint $ep }

    # Grok / serving-endpoints keep the non-streaming shape even when asked to stream.
    $env:PACKETRAT_GROK_URL='https://databricks.example.org/serving-endpoints/x/invocations'
    $global:grokBody=$null
    function global:Invoke-RestMethod { param($Uri,$Method,$Headers,$Body,$ContentType,$TimeoutSec) $global:grokBody=[Text.Encoding]::UTF8.GetString($Body); [pscustomobject]@{choices=@([pscustomobject]@{message=[pscustomobject]@{content='ok'}})} }
    $env:DATABRICKS_TOKEN='synthetic-test-token'
    $env:LLM_URL=$null
    try{
        $r=Invoke-PacketRatChat -Messages $msgs -Profile Grok -Stream
        Assert-Stream ($r.Text -eq 'ok' -and -not $r.Streamed) 'Grok profile falls back to the normal call'
        Assert-Stream ($global:grokBody -notmatch '"stream"') 'the Grok payload never carries stream'
    }finally{ Remove-Item Function:\Invoke-RestMethod -ErrorAction SilentlyContinue; $env:DATABRICKS_TOKEN=$null; $env:PACKETRAT_GROK_URL=$null }

    # Default stays non-streaming with stream=false.
    $global:plainBody=$null
    function global:Invoke-RestMethod { param($Uri,$Method,$Headers,$Body,$ContentType,$TimeoutSec) $global:plainBody=[Text.Encoding]::UTF8.GetString($Body); [pscustomobject]@{choices=@([pscustomobject]@{message=[pscustomobject]@{content='ok'}})} }
    try{
        $null=Invoke-PacketRatChat -Messages $msgs -Profile AiEndpoint
        Assert-Stream (($global:plainBody | ConvertFrom-Json).stream -eq $false) 'streaming is off by default (stream=false)'
    }finally{ Remove-Item Function:\Invoke-RestMethod -ErrorAction SilentlyContinue }
}finally{
    foreach($n in $envNames){[Environment]::SetEnvironmentVariable($n,$savedEnv[$n])}
    Clear-PacketRatCancel
}

# --- Command and route --------------------------------------------------------------------------------------------
$cmd=Find-PacketRatCommand 'packetrat inbox cancel'
Assert-Stream ($null -ne $cmd -and $cmd.Route -eq '/api/cancel') 'inbox cancel is a registered command'
Clear-PacketRatCancel
$realRoot=$Root
$Root=Join-Path ([IO.Path]::GetTempPath()) ('packetrat-stream-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $Root -Force)
try{ $out=Invoke-PacketRatApi -Route '/api/cancel' -Data $null }finally{ Remove-Item -Recurse -Force $Root -ErrorAction SilentlyContinue; $Root=$realRoot }
Assert-Stream ($out.ok -and (Test-PacketRatCancelRequested)) '/api/cancel writes the cancel flag'
Clear-PacketRatCancel

'PacketRat streaming tests passed.'
