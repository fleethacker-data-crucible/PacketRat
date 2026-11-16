#requires -Version 5.1
# Pester proof that a chat request carrying the Fairlead key does not follow a redirect and does not use the
# system proxy. Executing this file runs the tests. When the Pester module is already loaded, Describe/It/Should
# are Pester's; otherwise the same words run the proof, so CI does not install a module.
$ErrorActionPreference = 'Stop'
if (-not (Get-Module Pester)) {
    function Describe { param($Name, [scriptblock]$Fixture) & $Fixture }
    function It { param($Name, [scriptblock]$Test) & $Test }
    function Should {
        begin { $got = @() }
        process { $got += ,$_ }
        end {
            $actual = $got[-1]
            $op = [string]$args[0]
            $expected = $args[1]
            $ok = $false
            switch -Regex ($op) {
                '^-?Be$' { $ok = ($actual -eq $expected) }
                '^-?Match$' { $ok = ([string]$actual -match [string]$expected) }
                default { throw "Should does not implement $op" }
            }
            if (-not $ok) { throw ("Expected {0} [{1}] but was [{2}]" -f $op, $expected, $actual) }
        }
    }
}

$Root = Split-Path $PSScriptRoot -Parent
foreach ($name in @('PacketRatStore', 'PacketRatLlm')) { . (Join-Path $Root "Private\$name.ps1") }

function Read-RedirectRequest {
    param($Stream, $Encoding)
    $buf = New-Object System.Collections.Generic.List[byte]
    $one = New-Object byte[] 1
    while ($true) {
        if ($Stream.Read($one, 0, 1) -le 0) { break }
        $buf.Add($one[0])
        if ($buf.Count -ge 4 -and $Encoding.GetString($buf.ToArray()).EndsWith("`r`n`r`n")) { break }
        if ($buf.Count -gt 65536) { break }
    }
    $head = $Encoding.GetString($buf.ToArray())
    $len = 0
    if ($head -match '(?im)^content-length:\s*(\d+)') { $len = [int]$Matches[1] }
    $off = 0
    while ($off -lt $len) {
        $left = $len - $off
        $chunk = New-Object byte[] $left
        $n = $Stream.Read($chunk, 0, $left)
        if ($n -le 0) { break }
        $off += $n
    }
    return $head
}

function Start-RedirectListener {
    param([scriptblock]$OnClient, $Shared)
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList @('Read-RedirectRequest', ${function:Read-RedirectRequest}.ToString())))
    $ps = [powershell]::Create($iss)
    [void]$ps.AddScript($OnClient).AddArgument($listener).AddArgument($Shared)
    $handle = $ps.BeginInvoke()
    return @{ Listener = $listener; PS = $ps; Handle = $handle; Port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port }
}

function Stop-RedirectListener($Ep) {
    if (-not $Ep) { return }
    try { $Ep.Listener.Stop() } catch {}
    try { $Ep.PS.Stop() } catch {}
    try { $Ep.PS.Dispose() } catch {}
}

$originLoop = {
    param($Listener, $Shared)
    $enc = New-Object System.Text.UTF8Encoding $false
    while ($true) {
        try { $client = $Listener.AcceptTcpClient() } catch { break }
        try {
            $net = $client.GetStream()
            $net.ReadTimeout = 8000
            $head = Read-RedirectRequest -Stream $net -Encoding $enc
            $Shared.Origin = 1 + [int]$Shared.Origin
            $code = [int]$Shared.Code
            $reason = 'Redirect'
            switch ($code) {
                301 { $reason = 'Moved Permanently' }
                302 { $reason = 'Found' }
                303 { $reason = 'See Other' }
                307 { $reason = 'Temporary Redirect' }
                308 { $reason = 'Permanent Redirect' }
            }
            $msg = "HTTP/1.1 $code $reason`r`nLocation: $($Shared.Location)`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
            $bytes = $enc.GetBytes($msg)
            $net.Write($bytes, 0, $bytes.Length)
            $net.Flush()
        } catch {} finally { try { $client.Close() } catch {} }
    }
}

$sinkLoop = {
    param($Listener, $Shared)
    $enc = New-Object System.Text.UTF8Encoding $false
    while ($true) {
        try { $client = $Listener.AcceptTcpClient() } catch { break }
        try {
            $Shared.Sink = 1 + [int]$Shared.Sink
            $net = $client.GetStream()
            $net.ReadTimeout = 8000
            $head = Read-RedirectRequest -Stream $net -Encoding $enc
            if ($head -match 'fl-') { $Shared.SinkSawKey = $true }
            $payload = $enc.GetBytes('{"choices":[{"message":{"content":"stolen"}}]}')
            $resp = $enc.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($payload.Length)`r`nConnection: close`r`n`r`n")
            $net.Write($resp, 0, $resp.Length)
            $net.Write($payload, 0, $payload.Length)
            $net.Flush()
        } catch {} finally { try { $client.Close() } catch {} }
    }
}

$directLoop = {
    param($Listener, $Shared)
    $enc = New-Object System.Text.UTF8Encoding $false
    while ($true) {
        try { $client = $Listener.AcceptTcpClient() } catch { break }
        try {
            $net = $client.GetStream()
            $net.ReadTimeout = 8000
            $head = Read-RedirectRequest -Stream $net -Encoding $enc
            $Shared.Direct = 1 + [int]$Shared.Direct
            if ($head -match '(?i)text/event-stream') {
                $payload = $enc.GetBytes("data: {`"choices`":[{`"delta`":{`"content`":`"streamed`"}}]}`n`ndata: [DONE]`n`n")
                $ctype = 'text/event-stream'
            } else {
                $payload = $enc.GetBytes('{"choices":[{"message":{"role":"assistant","content":"direct"}}]}')
                $ctype = 'application/json'
            }
            $resp = $enc.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: $ctype`r`nContent-Length: $($payload.Length)`r`nConnection: close`r`n`r`n")
            $net.Write($resp, 0, $resp.Length)
            $net.Write($payload, 0, $payload.Length)
            $net.Flush()
        } catch {} finally { try { $client.Close() } catch {} }
    }
}

$proxyLoop = {
    param($Listener, $Shared)
    $enc = New-Object System.Text.UTF8Encoding $false
    while ($true) {
        try { $client = $Listener.AcceptTcpClient() } catch { break }
        try {
            $Shared.Proxy = 1 + [int]$Shared.Proxy
            $net = $client.GetStream()
            $net.ReadTimeout = 8000
            $null = Read-RedirectRequest -Stream $net -Encoding $enc
            $msg = $enc.GetBytes("HTTP/1.1 502 Bad Gateway`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
            $net.Write($msg, 0, $msg.Length)
            $net.Flush()
        } catch {} finally { try { $client.Close() } catch {} }
    }
}

$envNames = @('PACKETRAT_FAIRLEAD_URL', 'PACKETRAT_FAIRLEAD_MODEL', 'PACKETRAT_FAIRLEAD_PRIVACY', 'PACKETRAT_LLM_STREAM')
$savedEnv = @{}; foreach ($n in $envNames) { $savedEnv[$n] = [Environment]::GetEnvironmentVariable($n); [Environment]::SetEnvironmentVariable($n, $null) }
$savedProxy = [Net.WebRequest]::DefaultWebProxy
$state = [hashtable]::Synchronized(@{ Code = 302; Origin = 0; Sink = 0; SinkSawKey = $false; Location = ''; Direct = 0; Proxy = 0 })
$origin = $null; $sink = $null; $direct = $null; $proxy = $null
Set-PacketRatCredentialReader { param([string]$Target) 'fl-synthetic-key' }
Set-PacketRatLocalTokenPath (Join-Path ([IO.Path]::GetTempPath()) ('packetrat-no-token-' + [guid]::NewGuid().ToString('N')))
Set-PacketRatFairleadIdentity { $null }
$msgs = @(@{ role = 'user'; content = 'Synthetic prompt.' })
try {
    $sink = Start-RedirectListener $sinkLoop $state
    $state.Location = ('http://127.0.0.1:{0}/steal?token=fl-synthetic-key' -f $sink.Port)
    $origin = Start-RedirectListener $originLoop $state
    $originUrl = ('http://127.0.0.1:{0}/v1/chat/completions' -f $origin.Port)

    Describe 'Fairlead requests that carry the key' {
        It 'turns redirects and the system proxy off before the request is sent' {
            $req = New-PacketRatFairleadRequest -Url 'http://127.0.0.1:9/v1/chat/completions' -Method 'POST' -Headers @{ Authorization = 'Bearer fl-synthetic-key' } -Accept 'application/json' -ContentType 'application/json; charset=utf-8'
            ($req.AllowAutoRedirect) | Should -Be $false
            ($null -eq $req.Proxy) | Should -Be $true
        }

        It 'refuses every redirect instead of sending the key to the Location' {
            $env:PACKETRAT_FAIRLEAD_URL = $originUrl
            foreach ($code in @(300, 301, 302, 303, 304, 307, 308)) {
                foreach ($stream in @($false, $true)) {
                    $state.Code = $code
                    $state.Origin = 0
                    $state.Sink = 0
                    $state.SinkSawKey = $false
                    $threw = $null
                    try {
                        if ($stream) { $null = Invoke-PacketRatChat -Messages $msgs -Stream -TimeoutSec 10 }
                        else { $null = Invoke-PacketRatChat -Messages $msgs -TimeoutSec 10 }
                    } catch { $threw = [string]$_.Exception.Message }
                    $which = $(if ($stream) { 'stream' } else { 'post' })
                    $refused = ($null -ne $threw) -and ($threw -notmatch 'fl-') -and ($threw -match 'did not follow') -and ($threw -match [regex]::Escape("(HTTP $code)"))
                    $summary = ('{0}:{1}:refused={2}:sink={3}:origin={4}:sawKey={5}' -f $which, $code, $refused, [int]$state.Sink, [int]$state.Origin, [bool]$state.SinkSawKey)
                    $summary | Should -Be ('{0}:{1}:refused=True:sink=0:origin=1:sawKey=False' -f $which, $code)
                }
            }
        }

        It 'does not send the key through the system proxy' {
            $direct = Start-RedirectListener $directLoop $state
            $proxy = Start-RedirectListener $proxyLoop $state
            $directUrl = ('http://127.0.0.1:{0}/v1/chat/completions' -f $direct.Port)
            try {
                [Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy(('http://127.0.0.1:{0}' -f $proxy.Port), $false)
                $env:PACKETRAT_FAIRLEAD_URL = $directUrl
                $state.Direct = 0
                $state.Proxy = 0
                $post = Invoke-PacketRatChat -Messages $msgs -TimeoutSec 10
                ($post.Text) | Should -Be 'direct'
                ([int]$state.Proxy) | Should -Be 0
                ([int]$state.Direct) | Should -Be 1
                $state.Direct = 0
                $state.Proxy = 0
                $streamed = Invoke-PacketRatChat -Messages $msgs -Stream -TimeoutSec 10
                ($streamed.Text) | Should -Be 'streamed'
                ($streamed.Streamed) | Should -Be $true
                ([int]$state.Proxy) | Should -Be 0
                ([int]$state.Direct) | Should -Be 1
            } finally {
                [Net.WebRequest]::DefaultWebProxy = $savedProxy
                Stop-RedirectListener $direct
                Stop-RedirectListener $proxy
                $direct = $null
                $proxy = $null
            }
        }
    }
} finally {
    [Net.WebRequest]::DefaultWebProxy = $savedProxy
    Stop-RedirectListener $origin
    Stop-RedirectListener $sink
    Stop-RedirectListener $direct
    Stop-RedirectListener $proxy
    foreach ($n in $envNames) { [Environment]::SetEnvironmentVariable($n, $savedEnv[$n]) }
    Clear-PacketRatCancel
}

'PacketRat Fairlead redirect tests passed.'
