#requires -Version 5.1
# Offline tests for Fairlead as the default intelligence endpoint, against a fake Fairlead on a real loopback socket:
# the fake listens on Fairlead's own address (127.0.0.1:8776) so the default needs no setting at all. If that port is
# already taken (a real Fairlead may be running), the fake uses a free port and PACKETRAT_FAIRLEAD_URL, and the test says so.
# No real Fairlead, model, mailbox or internet is involved; synthetic prompts only.
$ErrorActionPreference='Stop'
$Root=Split-Path $PSScriptRoot -Parent
foreach($name in @('PacketRatStore','PacketRatLlm','PacketRatRouter')){ . (Join-Path $Root "Private\$name.ps1") }
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
            if($head -match '(?m)^GET /__fleethacker/id\s'){
                $payload=$enc.GetBytes('{"tool":"fairlead","pid":4242,"path":"C:\\Fairlead\\scripts\\Start-Fairlead.ps1"}')
            }else{
                $payload=$enc.GetBytes('{"choices":[{"message":{"role":"assistant","content":"routed by fake fairlead"}}]}')
            }
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

$envNames=@('PACKETRAT_FAIRLEAD_URL','PACKETRAT_FAIRLEAD_MODEL','PACKETRAT_FAIRLEAD_PRIVACY','PACKETRAT_FAIRLEAD_AUTOSTART','PACKETRAT_LLM_STREAM')
$savedEnv=@{};foreach($n in $envNames){$savedEnv[$n]=[Environment]::GetEnvironmentVariable($n);[Environment]::SetEnvironmentVariable($n,$null)}
$msgs=@(@{role='user';content='Synthetic prompt for the router.'})
Set-PacketRatCredentialReader { param([string]$Target) 'fl-synthetic-key' }
Set-PacketRatFairleadReaders -PortOwners { param($Port) ,@(4242) } -ProcessInfo { param($ProcessId) @{ CommandLine = 'powershell.exe -NoProfile -File C:\Fairlead\scripts\Start-Fairlead.ps1'; ExecutablePath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' } }
$fake=$null
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
    $cfg=Get-PacketRatFairleadConfig
    Assert-Default ($cfg.Url -eq $expectedUri -and $cfg.Model -eq 'auto') 'with nothing set, the config is the default Fairlead address and the auto route'
    $r=Invoke-PacketRatChat -Messages $msgs -TimeoutSec 15
    Assert-Default ($r.Text -eq 'routed by fake fairlead') 'the answer comes back from the fake Fairlead'
    Assert-Default ($reqs.Count -eq 2) 'the identity check runs, then one chat request'
    Assert-Default ($reqs[0].Head -match '(?m)^GET /__fleethacker/id ') 'the first request asks Fairlead to identify itself'
    Assert-Default ($reqs[0].Head -notmatch '(?im)^authorization:') 'the identity check carries no key'
    $q=$reqs[1]
    Assert-Default ($q.Head -match '(?m)^POST /v1/chat/completions HTTP') 'the chat request follows the identity check'
    Assert-Default (($q.Body | ConvertFrom-Json).model -eq 'auto' -and ($q.Body | ConvertFrom-Json).messages[0].content -eq 'Synthetic prompt for the router.') 'the body asks for the auto route and carries the prompt'
    Assert-Default ($q.Head -match '(?im)^authorization:\s*Bearer fl-synthetic-key' -and $q.Head -match '(?im)^x-fairlead-label:\s*PacketRat') 'the key from Credential Manager and the app label are sent'
    Assert-Default ($q.Head -notmatch '(?im)^x-fairlead-privacy:') 'no privacy header unless asked for'

    # --- The privacy header and the route name -------------------------------------------------------------------------------------
    $env:PACKETRAT_FAIRLEAD_PRIVACY='local'; $env:PACKETRAT_FAIRLEAD_MODEL='fast'
    $null=Invoke-PacketRatChat -Messages $msgs -TimeoutSec 15
    $q=$reqs[3]
    Assert-Default ($q.Head -match '(?im)^x-fairlead-privacy:\s*local') 'the local-privacy header is sent when set'
    Assert-Default (($q.Body | ConvertFrom-Json).model -eq 'fast') 'the route name can be changed'
    $env:PACKETRAT_FAIRLEAD_PRIVACY=$null; $env:PACKETRAT_FAIRLEAD_MODEL=$null

    # --- The "is it up" check sees the fake, so nothing is started ----------------------------------------------------------------
    $before=$reqs.Count
    Assert-Default (Test-PacketRatFairleadUp -Uri (Get-PacketRatFairleadUri)) 'the up check sees the fake on the default address'
    $e=Ensure-PacketRatFairlead -Root $Root -WaitSeconds 1
    Assert-Default ($e.State -eq 'AlreadyRunning') 'with Fairlead answering, nothing is started'
    Assert-Default ($reqs.Count -eq $before) 'the up check sends no request'

    # --- Fairlead gone: the failure is a plain connection error, not a hang ----------------------------------------------------------------
    Stop-FakeFairlead $fake; $fake=$null
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $failed=$false
    try{ $null=Invoke-PacketRatChat -Messages $msgs -TimeoutSec 10 }catch{ $failed=$true }
    Assert-Default ($failed -and $clock.Elapsed.TotalSeconds -lt 10) 'with nothing listening the call fails promptly'
}finally{
    if($fake){Stop-FakeFairlead $fake}
    foreach($n in $envNames){[Environment]::SetEnvironmentVariable($n,$savedEnv[$n])}
}
'PacketRat Fairlead default tests passed.'
