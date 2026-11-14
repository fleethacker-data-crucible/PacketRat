#requires -Version 5.1
# Offline tests for the Fairlead client: the address, the route name, the key (Credential Manager, else the local token),
# the id check before that key is sent, the headers and the error messages. Invoke-RestMethod is replaced. The id check
# in the chat tests is a stand-in; the real check is exercised against a loopback stub at the end. No router runs.
$ErrorActionPreference='Stop'
$Root=Split-Path $PSScriptRoot -Parent
foreach($name in @('PacketRatStore','PacketRatLlm')){ . (Join-Path $Root "Private\$name.ps1") }
function Assert-Router([bool]$Pass,[string]$Message){if(-not $Pass){throw ('Fairlead test failed: '+$Message)}}
function Assert-Throws([scriptblock]$Block,[string]$Pattern,[string]$Message){
    $threw=$null
    try{& $Block}catch{$threw=$_.Exception.Message}
    Assert-Router ($null -ne $threw) ($Message+' (expected an error)')
    Assert-Router ($threw -match $Pattern) ($Message+" (wrong error: $threw)")
}

$envNames=@('PACKETRAT_FAIRLEAD_URL','PACKETRAT_FAIRLEAD_MODEL','PACKETRAT_FAIRLEAD_PRIVACY','PACKETRAT_LLM_STREAM','FAIRLEAD_LOCAL_TOKEN_FILE')
$savedEnv=@{};foreach($n in $envNames){$savedEnv[$n]=[Environment]::GetEnvironmentVariable($n);[Environment]::SetEnvironmentVariable($n,$null)}
$tokenDir=Join-Path ([IO.Path]::GetTempPath()) ('packetrat-token-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tokenDir -Force)
$missingToken=Join-Path $tokenDir 'missing-local-token'
Set-PacketRatLocalTokenPath $missingToken
$script:IdChecks=0
Set-PacketRatFairleadIdentity { $script:IdChecks++; $null }
$global:sent=$null
function global:Invoke-RestMethod { param($Uri,$Method,$Headers,$Body,$ContentType,$TimeoutSec) $global:sent=@{Uri=$Uri;Headers=$Headers;Body=[Text.Encoding]::UTF8.GetString($Body)}; [pscustomobject]@{choices=@([pscustomobject]@{message=[pscustomobject]@{role='assistant';content='routed'}})} }
$msgs=@(@{role='user';content='Synthetic prompt.'})
$script:Asked=@()
Set-PacketRatCredentialReader { param([string]$Target) $script:Asked+=$Target; 'fl-synthetic-key' }
try{
    # The default: nothing set, so the call goes to Fairlead on this PC with the auto route and the stored key.
    $cfg=Get-PacketRatFairleadConfig
    Assert-Router ($cfg.Url -eq 'http://127.0.0.1:8776/v1/chat/completions' -and $cfg.Model -eq 'auto' -and $cfg.Privacy -eq '') 'the default address, route and privacy'
    $r=Invoke-PacketRatChat -Messages $msgs
    Assert-Router ($r.Text -eq 'routed' -and $r.Model -eq 'auto') 'a call returns the text and the route'
    Assert-Router ($global:sent.Uri -eq 'http://127.0.0.1:8776/v1/chat/completions') 'the call goes to Fairlead'
    Assert-Router ($script:Asked[-1] -eq 'Fairlead/PacketRat') 'the key is read from the Fairlead/PacketRat credential'
    Assert-Router ($global:sent.Headers['Authorization'] -eq 'Bearer fl-synthetic-key') 'the key is sent as a bearer token'
    Assert-Router ($global:sent.Headers['X-Fairlead-Label'] -eq 'PacketRat') 'the app says who it is'
    Assert-Router ($script:IdChecks -eq 1) 'the id is checked before the key is sent'
    Assert-Router (-not $global:sent.Headers.ContainsKey('X-Fairlead-Privacy')) 'no privacy header unless asked for'
    $body=$global:sent.Body | ConvertFrom-Json
    Assert-Router ($body.model -eq 'auto' -and $body.stream -eq $false -and $body.messages[0].content -eq 'Synthetic prompt.') 'the request body asks for the auto route, without streaming'
    Assert-Router ($r.PSObject.Properties['Profile'] -eq $null) 'there is no provider profile in the result'

    # Status never carries the key.
    $st=Get-PacketRatCredentialStatus
    Assert-Router ($st.router -eq 'Fairlead' -and $st.keyInstalled -and $st.target -eq 'Fairlead/PacketRat' -and $st.keySource -eq 'credential') 'status reports Fairlead and an installed key'
    Assert-Router (((ConvertTo-Json -InputObject $st -Depth 4)) -notmatch 'fl-synthetic-key') 'status never contains the key'

    # Route, privacy and address overrides.
    $env:PACKETRAT_FAIRLEAD_PRIVACY='local'
    $env:PACKETRAT_FAIRLEAD_MODEL='fast'
    $env:PACKETRAT_FAIRLEAD_URL='http://localhost:9000/v1/chat/completions/'
    $null=Invoke-PacketRatChat -Messages $msgs
    Assert-Router ($global:sent.Headers['X-Fairlead-Privacy'] -eq 'local') 'privacy=local adds the Fairlead header'
    Assert-Router (($global:sent.Body | ConvertFrom-Json).model -eq 'fast') 'PACKETRAT_FAIRLEAD_MODEL picks the route'
    Assert-Router ($global:sent.Uri -eq 'http://localhost:9000/v1/chat/completions') 'PACKETRAT_FAIRLEAD_URL overrides the address (trailing slash trimmed)'
    $null=Invoke-PacketRatChat -Messages $msgs -Model 'smart'
    Assert-Router (($global:sent.Body | ConvertFrom-Json).model -eq 'smart') 'an explicit -Model wins for one call'

    # Only an address on this PC is accepted.
    foreach($bad in 'https://fairlead.example.org/v1/chat/completions','http://10.1.2.3:8776/v1/chat/completions','not a url'){
        $env:PACKETRAT_FAIRLEAD_URL=$bad
        $global:sent=$null
        Assert-Throws { Invoke-PacketRatChat -Messages $msgs } 'on this PC' "a non-loopback address is refused ($bad)"
        Assert-Router ($null -eq $global:sent) 'nothing is sent to a refused address'
    }
    $env:PACKETRAT_FAIRLEAD_URL=$null

    # No key installed: a plain instruction, and no request at all. There is no environment or vault fallback.
    $env:AI_ENDPOINT_TOKEN='provider-token-should-not-travel'; $env:DATABRICKS_TOKEN='another-provider-token'; $env:FAIRLEAD_TOKEN='not-a-source'
    Set-PacketRatCredentialReader { param([string]$Target) $null }
    $global:sent=$null
    $checksBefore=$script:IdChecks
    Assert-Throws { Invoke-PacketRatChat -Messages $msgs } 'Open Fairlead and install a key for PacketRat' 'a missing key is explained'
    Assert-Router ($null -eq $global:sent) 'nothing is sent without a key'
    Assert-Router ($script:IdChecks -eq $checksBefore) 'a missing key does not ask the port who it is'
    $st=Get-PacketRatCredentialStatus
    Assert-Router (-not $st.keyInstalled -and $st.keySource -eq 'none' -and $st.message -match 'install a key for PacketRat') 'status says the key is missing'
    Set-PacketRatCredentialReader { param([string]$Target) throw 'credential store unavailable' }
    Assert-Throws { Get-PacketRatFairleadKey } 'install a key for PacketRat' 'a reader failure with no local token reads as a missing key'

    # Local token: used only when the credential is missing, and only when it is a Fairlead client key.
    $localKey='fl-synthetic-local-token'
    $tokenFile=Join-Path $tokenDir 'local-token'
    [IO.File]::WriteAllText($tokenFile, ($localKey + "`nsecond-line-is-ignored`n"))
    Set-PacketRatLocalTokenPath $tokenFile
    $st=Get-PacketRatCredentialStatus
    Assert-Router ($st.keyInstalled -and $st.keySource -eq 'local-token' -and $st.message -match 'local token') 'a local token counts as a key when Credential Manager has none'
    Assert-Router (((ConvertTo-Json -InputObject $st -Depth 4)) -notmatch [regex]::Escape($localKey)) 'status never contains the local token'
    $global:sent=$null
    $r=Invoke-PacketRatChat -Messages $msgs
    Assert-Router ($r.Text -eq 'routed' -and $global:sent.Headers['Authorization'] -eq ('Bearer ' + $localKey) -and $global:sent.Headers['X-Fairlead-Label'] -eq 'PacketRat') 'the local token is sent as the bearer, with the app label'
    Set-PacketRatCredentialReader { param([string]$Target) 'fl-from-credential-store' }
    $null=Invoke-PacketRatChat -Messages $msgs
    Assert-Router ($global:sent.Headers['Authorization'] -eq 'Bearer fl-from-credential-store') 'an installed credential wins over the local token'
    [IO.File]::WriteAllText($tokenFile, "not-a-fairlead-key`n")
    Set-PacketRatCredentialReader { param([string]$Target) $null }
    Assert-Throws { Get-PacketRatFairleadKey } 'install a key for PacketRat' 'a file that is not a Fairlead client key is not a token'
    [IO.File]::WriteAllText($tokenFile, ('x' * 5000))
    Assert-Throws { Get-PacketRatFairleadKey } 'install a key for PacketRat' 'a local-token file larger than 4 KB is ignored'
    Set-PacketRatLocalTokenPath $missingToken

    # A failed id check sends nothing, and the error does not repeat the key.
    Set-PacketRatCredentialReader { param([string]$Target) 'fl-synthetic-key' }
    Set-PacketRatFairleadIdentity { 'Something other than Fairlead is answering, so the key was not sent. fl-synthetic-key' }
    $global:sent=$null
    $leaked=$false; $threwId=$false
    try { Invoke-PacketRatChat -Messages $msgs } catch { $threwId=$true; $leaked = $_.Exception.Message -match 'fl-synthetic-key' }
    Assert-Router ($threwId -and -not $leaked) 'a failed id check refuses the call and does not repeat the key'
    Assert-Router ($null -eq $global:sent) 'nothing is sent when the id check fails'
    $env:AI_ENDPOINT_TOKEN=$null; $env:DATABRICKS_TOKEN=$null; $env:FAIRLEAD_TOKEN=$null
}finally{
    Remove-Item Function:\Invoke-RestMethod -ErrorAction SilentlyContinue
    foreach($n in $envNames){[Environment]::SetEnvironmentVariable($n,$savedEnv[$n])}
    Set-PacketRatLocalTokenPath $null
    Remove-Item -LiteralPath $tokenDir -Recurse -Force -ErrorAction SilentlyContinue
}

# The blob decoder: Fairlead writes UTF-16 text; UTF-8 text is accepted too; anything unprintable is "no key".
Assert-Router ((ConvertFrom-PacketRatCredentialBlob -Blob ([Text.Encoding]::Unicode.GetBytes('fl-abc123'))) -eq 'fl-abc123') 'a UTF-16 key is decoded'
Assert-Router ((ConvertFrom-PacketRatCredentialBlob -Blob ([Text.Encoding]::UTF8.GetBytes('fl-abc123'))) -eq 'fl-abc123') 'a UTF-8 key is decoded'
Assert-Router ((ConvertFrom-PacketRatCredentialBlob -Blob ([byte[]]@(1,2,3,4,5))) -eq '') 'unprintable bytes are not a key'
Assert-Router ((ConvertFrom-PacketRatCredentialBlob -Blob ([byte[]]@())) -eq '') 'an empty blob is not a key'
Assert-Router ((ConvertFrom-PacketRatCredentialBlob -Blob $null) -eq '') 'no blob is not a key'

# Path compare: exact absolute path, case-insensitive, never a substring.
Assert-Router ((ConvertTo-PacketRatNormalPath 'C:\Fleet\Fairlead\scripts\..\scripts\Start-Fairlead.ps1') -eq 'C:\Fleet\Fairlead\scripts\Start-Fairlead.ps1') 'a Windows path is normalized'
Assert-Router ((ConvertTo-PacketRatNormalPath 'relative\Start-Fairlead.ps1') -eq '') 'a relative path is not a path'
Assert-Router ((ConvertTo-PacketRatNormalPath '\\files\share\Fairlead\scripts\Start-Fairlead.ps1') -eq '\\files\share\Fairlead\scripts\Start-Fairlead.ps1') 'a UNC path is kept'

$savedTokenEnv=[Environment]::GetEnvironmentVariable('FAIRLEAD_LOCAL_TOKEN_FILE')
Set-PacketRatLocalTokenPath $null
[Environment]::SetEnvironmentVariable('FAIRLEAD_LOCAL_TOKEN_FILE','C:\Fleet\moved-local-token')
Assert-Router ((Get-PacketRatFairleadLocalTokenPath) -eq 'C:\Fleet\moved-local-token') 'FAIRLEAD_LOCAL_TOKEN_FILE names the local token file'
[Environment]::SetEnvironmentVariable('FAIRLEAD_LOCAL_TOKEN_FILE',$savedTokenEnv)
Set-PacketRatLocalTokenPath 'C:\Fleet\pinned-by-test'
Assert-Router ((Get-PacketRatFairleadLocalTokenPath) -eq 'C:\Fleet\pinned-by-test') 'a test path overrides the real local token file'
Set-PacketRatLocalTokenPath $null

# The real id check, against a one-request loopback stub. Listener pid and process path are fakes; the HTTP request is real.
function Get-PacketRatListenerPids { param([int]$Port) return @(4401) }
function Get-PacketRatProcessPaths { param([int]$ProcessId) return @{ ExecutablePath = 'C:\Fleet\Fairlead\Fairlead.exe'; ScriptPath = 'C:\Fleet\Fairlead\scripts\Start-Fairlead.ps1' } }
function Start-IdStub([string]$Json){
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $listener.Start()
    $port=([Net.IPEndPoint]$listener.LocalEndpoint).Port
    $shared=[hashtable]::Synchronized(@{head=''})
    $server={
        param($Listener,$Body,$Shared)
        $enc=New-Object System.Text.UTF8Encoding $false
        try{ $client=$Listener.AcceptTcpClient() }catch{ return }
        try{
            $net=$client.GetStream()
            $buf=New-Object System.Collections.Generic.List[byte]
            $one=New-Object byte[] 1
            while($true){ if($net.Read($one,0,1) -le 0){break}; $buf.Add($one[0]); if($buf.Count -ge 4 -and $enc.GetString($buf.ToArray()).EndsWith("`r`n`r`n")){break} }
            $Shared['head']=$enc.GetString($buf.ToArray())
            $payload=$enc.GetBytes($Body)
            $resp=$enc.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($payload.Length)`r`nConnection: close`r`n`r`n")
            $net.Write($resp,0,$resp.Length); $net.Write($payload,0,$payload.Length); $net.Flush()
        }catch{} finally{ try{$client.Close()}catch{} }
    }
    $ps=[powershell]::Create()
    [void]$ps.AddScript($server).AddArgument($listener).AddArgument($Json).AddArgument($shared)
    $handle=$ps.BeginInvoke()
    return @{Listener=$listener;PS=$ps;Handle=$handle;Port=$port;Shared=$shared}
}
function Stop-IdStub($Ep){ try{$Ep.Listener.Stop()}catch{}; try{$Ep.PS.Stop()}catch{}; try{$Ep.PS.Dispose()}catch{} }
function Assert-Id([string]$Json,[string]$UrlSuffix,[bool]$Ok,[string]$Message){
    $ep=Start-IdStub $Json
    try{
        $url=('http://127.0.0.1:{0}{1}' -f $ep.Port,$UrlSuffix)
        $why=Test-PacketRatFairleadIdentity -Url $url
        if($Ok){ Assert-Router ($null -eq $why) ($Message + $(if($why){" (got: $why)"}else{''})) }
        else{ Assert-Router ($null -ne $why -and $why -match 'key was not sent') ($Message + " (got: $why)") }
        Assert-Router ($ep.Shared['head'] -match 'GET /__fleethacker/id ') 'the check asks for the id document'
        Assert-Router ($ep.Shared['head'] -notmatch '(?i)authorization:') 'the id request carries no key'
        Assert-Router ($ep.Shared['head'] -notmatch 'secret-user') 'the id request drops any user info from the address'
    }finally{ Stop-IdStub $ep }
}
$fairleadJson='{"tool":"fairlead","pid":4401,"path":"C:\\\\Fleet\\\\Fairlead\\\\scripts\\\\Start-Fairlead.ps1"}'
Assert-Id $fairleadJson '/v1/chat/completions' $true 'a matching tool, pid and path is Fairlead'
$ep=Start-IdStub $fairleadJson
try{
    $why=Test-PacketRatFairleadIdentity -Url ('http://secret-user:secret-pass@127.0.0.1:{0}/v1/chat/completions' -f $ep.Port)
    Assert-Router ($null -eq $why) 'user info on the address does not stop a real Fairlead'
    Assert-Router ($ep.Shared['head'] -notmatch 'secret-') 'user info is not sent on the id request'
}finally{ Stop-IdStub $ep }
Assert-Id '{"tool":"other","pid":4401,"path":"C:\\\\Fleet\\\\Fairlead\\\\scripts\\\\Start-Fairlead.ps1"}' '/' $false 'another tool is refused'
Assert-Id '{"tool":"fairlead","pid":9999,"path":"C:\\\\Fleet\\\\Fairlead\\\\scripts\\\\Start-Fairlead.ps1"}' '/' $false 'a pid that does not hold the port is refused'
Assert-Id '{"tool":"fairlead","pid":4401,"path":"C:\\\\Other\\\\evil.exe"}' '/' $false 'a path the process is not running is refused'
Assert-Id '{"tool":"fairlead","pid":4401}' '/' $true 'a missing path is accepted when the process is Start-Fairlead.ps1'
function Get-PacketRatProcessPaths { param([int]$ProcessId) return @{ ExecutablePath = 'C:\Other\app.exe'; ScriptPath = 'C:\Other\app.ps1' } }
Assert-Id '{"tool":"fairlead","pid":4401}' '/' $false 'a missing path is refused when the process is not Fairlead'
function Get-PacketRatListenerPids { param([int]$Port) return @(4) }
$low=Test-PacketRatFairleadIdentity -Url 'http://127.0.0.1:9/v1/chat/completions'
Assert-Router ($low -match 'key was not sent') 'pid 4 is not accepted as the owner'
function Get-PacketRatListenerPids { param([int]$Port) return @(4401,4402) }
$many=Test-PacketRatFairleadIdentity -Url 'http://127.0.0.1:9/v1/chat/completions'
Assert-Router ($many -match 'key was not sent') 'two listeners on the port are refused'
function Get-PacketRatListenerPids { param([int]$Port) return @() }
$none=Test-PacketRatFairleadIdentity -Url 'http://127.0.0.1:9/v1/chat/completions'
Assert-Router ($none -match 'not running') 'no listener means Fairlead is not running'
function Get-PacketRatListenerPids { param([int]$Port) return @(4401) }
$ep=Start-IdStub $fairleadJson
$port=$ep.Port
Stop-IdStub $ep
$down=Test-PacketRatFairleadIdentity -Url ('http://127.0.0.1:{0}/v1/chat/completions' -f $port)
Assert-Router ($down -match 'did not identify itself as Fairlead') 'nothing answering the id is not Fairlead'
Assert-Router ((Test-PacketRatFairleadIdentity -Url 'http://10.1.2.3:8776/v1/chat/completions') -match 'not on this PC') 'an address off this PC is not asked'

'PacketRat Fairlead client tests passed.'
