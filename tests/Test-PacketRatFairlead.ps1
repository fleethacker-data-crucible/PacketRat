#requires -Version 5.1
# Offline tests for the Fairlead client: the address, the route name, the key from Windows Credential Manager (replaced by
# a fake reader), the headers and the error messages. No network: Invoke-RestMethod is replaced and no router runs.
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

$envNames=@('PACKETRAT_FAIRLEAD_URL','PACKETRAT_FAIRLEAD_MODEL','PACKETRAT_FAIRLEAD_PRIVACY','PACKETRAT_LLM_STREAM','LOCALAPPDATA','FAIRLEAD_LOCAL_TOKEN','FAIRLEAD_LOCAL_TOKEN_FILE')
$savedEnv=@{};foreach($n in $envNames){$savedEnv[$n]=[Environment]::GetEnvironmentVariable($n);[Environment]::SetEnvironmentVariable($n,$null)}
$tokenRoot=Join-Path ([IO.Path]::GetTempPath()) ('packetrat-token-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tokenRoot -Force)
$env:LOCALAPPDATA=$tokenRoot
$global:sent=$null
function global:Invoke-RestMethod { param($Uri,$Method,$Headers,$Body,$ContentType,$TimeoutSec) $global:sent=@{Uri=$Uri;Headers=$Headers;Body=[Text.Encoding]::UTF8.GetString($Body)}; [pscustomobject]@{choices=@([pscustomobject]@{message=[pscustomobject]@{role='assistant';content='routed'}})} }
$msgs=@(@{role='user';content='Synthetic prompt.'})
$script:Asked=@()
Set-PacketRatCredentialReader { param([string]$Target) $script:Asked+=$Target; 'fl-synthetic-key' }
Use-PacketRatFairleadTestIdentity
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
    Assert-Router (-not $global:sent.Headers.ContainsKey('X-Fairlead-Privacy')) 'no privacy header unless asked for'
    $body=$global:sent.Body | ConvertFrom-Json
    Assert-Router ($body.model -eq 'auto' -and $body.stream -eq $false -and $body.messages[0].content -eq 'Synthetic prompt.') 'the request body asks for the auto route, without streaming'
    Assert-Router ($r.PSObject.Properties['Profile'] -eq $null) 'there is no provider profile in the result'

    # Status never carries the key.
    $st=Get-PacketRatCredentialStatus
    Assert-Router ($st.router -eq 'Fairlead' -and $st.keyInstalled -and $st.target -eq 'Fairlead/PacketRat') 'status reports Fairlead and an installed key'
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
    Assert-Throws { Invoke-PacketRatChat -Messages $msgs } 'Open Fairlead and install a key for PacketRat' 'a missing key is explained'
    Assert-Router ($null -eq $global:sent) 'nothing is sent without a key'
    $st=Get-PacketRatCredentialStatus
    Assert-Router (-not $st.keyInstalled -and $st.keySource -eq '' -and $st.message -match 'install a key for PacketRat') 'status says the key is missing'
    Set-PacketRatCredentialReader { param([string]$Target) throw 'credential store unavailable' }
    Assert-Throws { Get-PacketRatFairleadKey } 'install a key for PacketRat' 'a reader failure reads as a missing key'

    # Local token: first line only, and only when the credential is absent. The env tokens above are still not a source.
    $tokenFile=Join-Path (Join-Path $tokenRoot 'Fairlead') 'local-token'
    [void](New-Item -ItemType Directory -Path (Split-Path $tokenFile -Parent) -Force)
    [IO.File]::WriteAllText($tokenFile, "fl-local-token`r`nfl-second-line-must-not-travel`r`n")
    $global:sent=$null
    $r=Invoke-PacketRatChat -Messages $msgs
    Assert-Router ($r.Text -eq 'routed') 'a local token is enough to call Fairlead'
    Assert-Router ($global:sent.Headers['Authorization'] -eq 'Bearer fl-local-token') 'the first line of the local token is the bearer token'
    Assert-Router ($global:sent.Headers['X-Fairlead-Label'] -eq 'PacketRat') 'the app label is still sent with the local token'
    Assert-Router ($global:sent.Headers['Authorization'] -notmatch 'second-line' -and $global:sent.Headers['Authorization'] -notmatch 'provider-token') 'the second line and environment tokens are not sent'
    $st=Get-PacketRatCredentialStatus
    Assert-Router ($st.keyInstalled -and $st.keySource -eq 'local-token') 'status names the local token without returning it'
    Assert-Router (((ConvertTo-Json -InputObject $st -Depth 4)) -notmatch 'fl-local-token') 'status never contains the local token'
    Set-PacketRatCredentialReader { param([string]$Target) 'fl-from-credential' }
    $null=Invoke-PacketRatChat -Messages $msgs
    Assert-Router ($global:sent.Headers['Authorization'] -eq 'Bearer fl-from-credential') 'an installed credential wins over the local token'
    $env:FAIRLEAD_LOCAL_TOKEN='off'
    Set-PacketRatCredentialReader { param([string]$Target) $null }
    $global:sent=$null
    Assert-Throws { Invoke-PacketRatChat -Messages $msgs } 'install a key for PacketRat' 'FAIRLEAD_LOCAL_TOKEN=off does not use the file'
    Assert-Router ($null -eq $global:sent) 'nothing is sent when the local token is off and no credential is installed'
    $env:FAIRLEAD_LOCAL_TOKEN=$null
    $moved=Join-Path $tokenRoot 'moved-token'
    [IO.File]::WriteAllText($moved, "fl-moved-token")
    $env:FAIRLEAD_LOCAL_TOKEN_FILE=$moved
    $null=Invoke-PacketRatChat -Messages $msgs
    Assert-Router ($global:sent.Headers['Authorization'] -eq 'Bearer fl-moved-token') 'FAIRLEAD_LOCAL_TOKEN_FILE names the file that is read'
    [IO.File]::WriteAllText($moved, ("x" * 5000))
    Assert-Throws { Get-PacketRatFairleadKey } 'install a key for PacketRat' 'a local-token file over 4 KB is not a key'
    $env:AI_ENDPOINT_TOKEN=$null; $env:DATABRICKS_TOKEN=$null; $env:FAIRLEAD_TOKEN=$null

    # Identity: the key stays off the wire unless the address is Fairlead and that process holds the port.
    $env:FAIRLEAD_LOCAL_TOKEN_FILE=$null
    Set-PacketRatCredentialReader { param([string]$Target) 'fl-synthetic-key' }
    Use-PacketRatFairleadTestIdentity
    Set-PacketRatFairleadReaders -IdReader { param($Uri) [pscustomobject]@{ tool = 'other-tool'; pid = 4242; path = 'C:\Fairlead\scripts\Start-Fairlead.ps1' } }
    $global:sent=$null
    Assert-Throws { Invoke-PacketRatChat -Messages $msgs } 'key was not sent' 'a different tool is refused'
    Assert-Router ($null -eq $global:sent) 'nothing is sent when the id names another tool'
    Set-PacketRatFairleadReaders -IdReader { param($Uri) [pscustomobject]@{ tool = 'fairlead'; pid = 50; path = 'C:\Fairlead\scripts\Start-Fairlead.ps1' } }
    $global:sent=$null
    Assert-Throws { Invoke-PacketRatChat -Messages $msgs } 'key was not sent' 'a pid that does not hold the port is refused'
    Assert-Router ($null -eq $global:sent) 'nothing is sent when the reported pid is not the listener'
    Set-PacketRatFairleadReaders -IdReader { param($Uri) [pscustomobject]@{ tool = 'fairlead'; pid = 4242; path = 'C:\Fairlead\scripts\Start-Fairlead.ps1' } } -ProcessInfo { param($ProcessId) @{ CommandLine = 'powershell.exe -Command "echo C:\Fairlead\scripts\Start-Fairlead.ps1"'; ExecutablePath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' } }
    $global:sent=$null
    Assert-Throws { Invoke-PacketRatChat -Messages $msgs } 'key was not sent' 'a path that is only a substring of the command line is refused'
    Assert-Router ($null -eq $global:sent) 'nothing is sent on a substring path match'
    Set-PacketRatFairleadReaders -PortOwners { param($Port) @(4) }
    Assert-Throws { Invoke-PacketRatChat -Messages $msgs } 'could not confirm' 'pid 4 is not accepted as the listener'
    Use-PacketRatFairleadTestIdentity
    Set-PacketRatFairleadReaders -IdReader { param($Uri) [pscustomobject]@{ tool = 'fairlead'; pid = 4242 } }
    $null=Invoke-PacketRatChat -Messages $msgs
    Assert-Router ($global:sent.Headers['Authorization'] -eq 'Bearer fl-synthetic-key') 'a missing path is accepted only when the process itself is Start-Fairlead.ps1'
    Assert-Router (-not (Test-PacketRatReportedPath -Path 'scripts\Start-Fairlead.ps1' -CommandLine 'powershell.exe -File C:\Fairlead\scripts\Start-Fairlead.ps1' -ExecutablePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe')) 'a relative path is not a match'
    $dotted = Test-PacketRatReportedPath -Path 'C:\Fairlead\..\Fairlead\scripts\Start-Fairlead.ps1' -CommandLine 'powershell.exe -File C:\Fairlead\scripts\Start-Fairlead.ps1' -ExecutablePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    if ($env:OS -eq 'Windows_NT') { Assert-Router $dotted 'on Windows a .. path is normalized and then compared exactly' }
    else { Assert-Router (-not $dotted) 'off Windows a .. path is refused because it cannot be normalized' }
}finally{
    Remove-Item Function:\Invoke-RestMethod -ErrorAction SilentlyContinue
    foreach($n in $envNames){[Environment]::SetEnvironmentVariable($n,$savedEnv[$n])}
    Remove-Item -LiteralPath $tokenRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# The blob decoder: Fairlead writes UTF-16 text; UTF-8 text is accepted too; anything unprintable is "no key".
Assert-Router ((ConvertFrom-PacketRatCredentialBlob -Blob ([Text.Encoding]::Unicode.GetBytes('fl-abc123'))) -eq 'fl-abc123') 'a UTF-16 key is decoded'
Assert-Router ((ConvertFrom-PacketRatCredentialBlob -Blob ([Text.Encoding]::UTF8.GetBytes('fl-abc123'))) -eq 'fl-abc123') 'a UTF-8 key is decoded'
Assert-Router ((ConvertFrom-PacketRatCredentialBlob -Blob ([byte[]]@(1,2,3,4,5))) -eq '') 'unprintable bytes are not a key'
Assert-Router ((ConvertFrom-PacketRatCredentialBlob -Blob ([byte[]]@())) -eq '') 'an empty blob is not a key'
Assert-Router ((ConvertFrom-PacketRatCredentialBlob -Blob $null) -eq '') 'no blob is not a key'
'PacketRat Fairlead client tests passed.'
