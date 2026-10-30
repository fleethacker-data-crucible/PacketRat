#requires -Version 5.1
<#
 .SYNOPSIS
  PacketRat browser UI over a loopback-only TCP HTTP server.
 .NOTES
  No HttpListener URLACL or administrator elevation required.
  Outlook COM calls and AI requests are synchronous in this implementation.
  The browser tab owns this server: it stops itself once no PacketRat tab has sent a
  heartbeat for 20 s (5 s after a tab's leaving signal), never in the middle of a request.
 .PARAMETER Stay
  Keep running after the browser tab closes. Also: --stay, or PACKETRAT_AUTO_STOP=0.
 .PARAMETER Replace
  If PacketRat is already running, stop it and start fresh without asking. Also: --replace.
#>
[CmdletBinding(PositionalBinding=$false)]
param(
    [ValidateRange(0,65535)][int]$Port=8766,
    [switch]$NoBrowser,
    [switch]$Demo,
    [switch]$Stay,
    [switch]$Replace,
    [Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest
)
$ErrorActionPreference='Stop'
$Root=$PSScriptRoot
foreach($option in @($Rest)){
    switch -Regex ([string]$option){
        '^--?stay$' {$Stay=$true}
        '^--?replace$' {$Replace=$true}
        '^--?no-browser$' {$NoBrowser=$true}
        '^(--?)?demo$' {$Demo=$true}
        '^gui$' {}
        default {if($option){Write-Warning "Ignoring unknown option $option"}}
    }
}
foreach($name in @('LazaretteBridge','PacketRatLogging','PacketRatLifecycle','PacketRatLlm','PacketRatStore','PacketRatRules','PacketRatProtocol','PacketRatReport','Get-OutlookMailSummary','PacketRatGraph','PacketRatMailFiles','PacketRatDraft','PacketRatApi','PacketRatCommands')) {
    . (Join-Path $Root "Private\$name.ps1")
}
. (Join-Path $Root 'Public\Invoke-PacketRatInboxAnalysis.ps1')
# Config\packetrat.env
$envFile=Join-Path $Root 'Config\packetrat.env'
if(Test-Path $envFile){
    foreach($line in Get-Content $envFile){
        if($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$'){
            [Environment]::SetEnvironmentVariable($Matches[1],$Matches[2].Trim().Trim('"').Trim("'"),'Process')
        }
    }
}
# One instance: a running server holds the store and Outlook session; offer to replace it.
$running=@(Get-PacketRatProcesses -Root $Root)
if($running.Count -gt 0){
    $where=($running | ForEach-Object {Format-PacketRatProcess $_}) -join ', '
    Write-Host ('PacketRat is already running: '+$where) -ForegroundColor Yellow
    $answer=if($Replace){'y'}else{Read-Host 'Stop it and start fresh? [Y/n]'}
    if($answer -eq '' -or $answer -match '^[Yy]'){
        foreach($stopped in @(Stop-PacketRatProcesses -Root $Root)){Write-Host ('  Stopped PacketRat '+(Format-PacketRatProcess $stopped)) -ForegroundColor DarkGray}
    }else{
        Write-Host 'Leaving the running server alone. Use End session in its browser tab, or Stop-PacketRat.ps1.' -ForegroundColor DarkGray
        if($running[0].Url -and -not $NoBrowser){try{Start-Process $running[0].Url}catch{}}
        exit 0
    }
}
$script:Presence=New-PacketRatPresence -AutoStop (Test-PacketRatAutoStopEnabled -Stay:$Stay)
$script:BusyUntil=[DateTime]::MinValue
$script:StopReason=''
$script:LastResult=$null
$script:Nonce=[guid]::NewGuid().ToString('N')
$script:Mime=@{'.html'='text/html; charset=utf-8';'.css'='text/css; charset=utf-8';'.js'='application/javascript; charset=utf-8';'.png'='image/png';'.ico'='image/x-icon';'.svg'='image/svg+xml; charset=utf-8'}
# Exact allow-list of served files (Fleet UI: vendored fleet.css, brand mark and emblems, Lucide icons).
$script:AllowedAssets=@('index.html','app.js','report-experience.js','style.css','shell.js','icons.js','vendor/fleet/fleet.css','brand/mark.svg','brand/emblem-dark.png','brand/emblem-light.png','brand/icon-256.png','brand/favicon.ico')
$script:UTF8=New-Object System.Text.UTF8Encoding $false

function Send-PacketRatResponse {
    param([System.IO.Stream]$Stream,[int]$Status,[byte[]]$Bytes,[string]$Type='application/json; charset=utf-8')
    $reason=switch($Status){200{'OK'}400{'Bad Request'}403{'Forbidden'}404{'Not Found'}405{'Method Not Allowed'}413{'Payload Too Large'}500{'Internal Server Error'}default{'Error'}}
    $head="HTTP/1.1 $Status $reason`r`nContent-Type: $Type`r`nContent-Length: $($Bytes.Length)`r`nCache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`nX-Frame-Options: DENY`r`nReferrer-Policy: no-referrer`r`nContent-Security-Policy: default-src 'self'; style-src 'self'; script-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`r`nConnection: close`r`n`r`n"
    $hb=[Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($hb,0,$hb.Length)
    $Stream.Write($Bytes,0,$Bytes.Length)
    $Stream.Flush()
}
function Send-PacketRatText {
    param([System.IO.Stream]$Stream,[int]$Status,[string]$Body,[string]$Type='application/json; charset=utf-8')
    Send-PacketRatResponse -Stream $Stream -Status $Status -Bytes $script:UTF8.GetBytes($Body) -Type $Type
}
function Read-PacketRatLine {
    param([System.IO.Stream]$Stream,[int]$Limit=8192)
    $bytes=New-Object System.Collections.Generic.List[byte]
    while($true){
        $value=$Stream.ReadByte()
        if($value -lt 0){throw 'Unexpected end of HTTP stream'}
        if($value -eq 10){break}
        if($value -ne 13){$bytes.Add([byte]$value)}
        if($bytes.Count -gt $Limit){throw 'HTTP header too long'}
    }
    return [Text.Encoding]::ASCII.GetString($bytes.ToArray())
}
function Read-PacketRatBody {
    param([System.IO.Stream]$Stream,[int]$Length)
    if($Length -lt 0 -or $Length -gt 131072){throw 'Request body too large'}
    $buffer=New-Object byte[] $Length
    $offset=0
    while($offset -lt $Length){
        $read=$Stream.Read($buffer,$offset,$Length-$offset)
        if($read -le 0){throw 'Incomplete HTTP body'}
        $offset+=$read
    }
    return $script:UTF8.GetString($buffer)
}

$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port)
try{$listener.Start()}catch{
    Write-Warning "Requested port unavailable. Selecting a free loopback port."
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $listener.Start()
}
$Port=([Net.IPEndPoint]$listener.LocalEndpoint).Port
$url="http://127.0.0.1:$Port/"
$runtimeFile=$null
$pendingAccept=$null
try {
 # Runtime file for Stop-PacketRat.ps1 and the single-instance check: no nonce, ever.
 $runtimeFile=Write-PacketRatRuntimeFile -Root $Root -Port $Port -Url $url
 Write-Host "PacketRat browser interface: $url" -ForegroundColor Cyan
 Write-Host "Offline demo: ${url}?demo=1" -ForegroundColor DarkCyan
 if($script:Presence.AutoStop){
     Write-Host 'Closing the PacketRat browser tab stops this server (use -Stay or PACKETRAT_AUTO_STOP=0 to keep it running).' -ForegroundColor DarkGray
 }else{
     Write-Host 'Auto-stop is off: this server keeps running after the tab closes.' -ForegroundColor DarkGray
 }
 Write-Host 'Stop with End session in the browser, Stop-PacketRat.ps1, or Ctrl+C here.' -ForegroundColor DarkGray
 if(-not $NoBrowser){try{Start-Process ($url + $(if($Demo){'?demo=1'}else{''}))}catch{Write-Warning 'Could not automatically open browser. Copy the URL shown above.'}}
 while(-not $script:StopReason){
    if($null -eq $pendingAccept){$pendingAccept=$listener.BeginAcceptTcpClient($null,$null)}
    # Presence tick: wake every second. Queued connections are served before presence is
    # judged, so heartbeats that waited behind a long scan still count.
    if(-not $pendingAccept.AsyncWaitHandle.WaitOne(1000)){
        if(Test-PacketRatBrowserGone -State $script:Presence -BusyUntil $script:BusyUntil){
            $script:StopReason='No PacketRat browser tab is open.'
        }
        continue
    }
    $client=$listener.EndAcceptTcpClient($pendingAccept)
    $pendingAccept=$null
    $client.ReceiveTimeout=30000;$client.SendTimeout=30000
    try {
      $stream=$client.GetStream()
      $first=Read-PacketRatLine -Stream $stream
      if(-not $first){continue}
      $parts=$first.Split(' ')
      if($parts.Count -lt 3){Send-PacketRatText $stream 400 '{"ok":false,"error":"Invalid HTTP request"}';continue}
      $method=$parts[0];$path=$parts[1].Split('?')[0]
      $headers=@{};$headerSize=0
      while($true){
          $line=Read-PacketRatLine -Stream $stream
          if(-not $line){break}
          $headerSize+=$line.Length
          if($headerSize -gt 16384){throw 'Headers too large'}
          $pos=$line.IndexOf(':')
          if($pos -gt 0){$headers[$line.Substring(0,$pos).ToLowerInvariant()]=$line.Substring($pos+1).Trim()}
      }
      if($headers['host'] -notin @("127.0.0.1:$Port","localhost:$Port")){
          Send-PacketRatText $stream 403 '{"ok":false,"error":"Invalid host"}';continue
      }
      if($path -match '^/api/'){
          if($method -eq 'GET' -and $path -notin @('/api/state','/api/health','/api/credentials/status','/api/commands')){
              Send-PacketRatText $stream 405 '{"ok":false,"error":"POST required"}';continue
          }
          if($method -eq 'POST'){
              # navigator.sendBeacon cannot set headers: /api/heartbeat alone may carry the
              # nonce in its JSON body instead (checked below). Never in the query string.
              $isBeacon=($path -eq '/api/heartbeat')
              $origin=$headers['origin']
              $originOk=($origin -ceq $url.TrimEnd('/')) -or ($isBeacon -and [string]::IsNullOrEmpty($origin))
              $headerToken=($headers['x-packetrat-token'] -ceq $script:Nonce)
              if(-not $originOk -or (-not $headerToken -and -not $isBeacon)){
                  Send-PacketRatText $stream 403 '{"ok":false,"error":"Unauthorized request"}';continue
              }
              if($headers['content-type'] -notmatch '^application/json(?:;|$)'){
                  Send-PacketRatText $stream 400 '{"ok":false,"error":"JSON content type required"}';continue
              }
              $rawLength=$headers['content-length']
              $length=0
              if(-not [int]::TryParse($rawLength,[ref]$length) -or $length -lt 1 -or $length -gt 131072){
                  Send-PacketRatText $stream 413 '{"ok":false,"error":"Invalid request body length"}';continue
              }
              # Never echo or log request bodies: they can carry manual tokens or the nonce.
              try{$data=ConvertFrom-Json (Read-PacketRatBody -Stream $stream -Length $length)}catch{
                  Send-PacketRatText $stream 400 '{"ok":false,"error":"Invalid JSON body"}';continue
              }
              if(-not $headerToken -and -not (Test-PacketRatBeaconToken -Data $data -Expected $script:Nonce)){
                  Send-PacketRatText $stream 403 '{"ok":false,"error":"Unauthorized request"}';continue
              }
          }elseif($method -eq 'GET'){$data=$null}
          else{Send-PacketRatText $stream 405 '{"ok":false,"error":"Method not allowed"}';continue}
          $requestStarted=[DateTime]::UtcNow
          try {
              $result=Invoke-PacketRatApi -Route $path -Data $data
              Send-PacketRatText $stream 200 (ConvertTo-Json -InputObject $result -Depth 15 -Compress)
          }catch{
              Write-Warning "PacketRat API error: $($_.Exception.Message)"
              Send-PacketRatText $stream 400 (ConvertTo-Json -InputObject @{ok=$false;error=$_.Exception.Message} -Compress)
          }finally{
              # Heartbeats wait while a long request (scan, report, draft) runs; do not
              # count that time against the open tabs.
              if(([DateTime]::UtcNow-$requestStarted).TotalSeconds -ge 2){$script:BusyUntil=[DateTime]::UtcNow}
          }
      }elseif($method -eq 'GET'){
          $name=if($path -eq '/'){'index.html'}else{$path.TrimStart('/')}
          if($name -cnotin $script:AllowedAssets){Send-PacketRatText $stream 404 'Not found' 'text/plain; charset=utf-8';continue}
          $file=Join-Path (Join-Path $Root 'Web') $name
          if(-not (Test-Path -LiteralPath $file)){Send-PacketRatText $stream 404 'Not found' 'text/plain; charset=utf-8';continue}
          $ext=[IO.Path]::GetExtension($file)
          if($ext -eq '.png' -or $ext -eq '.ico'){
              Send-PacketRatResponse -Stream $stream -Status 200 -Bytes ([IO.File]::ReadAllBytes($file)) -Type $script:Mime[$ext]
          }else{
              $content=[IO.File]::ReadAllText($file)
              if($name -eq 'index.html'){$content=$content.Replace('__PACKETRAT_NONCE__',$script:Nonce)}
              Send-PacketRatText $stream 200 $content $script:Mime[$ext]
          }
      }else {Send-PacketRatText $stream 405 'Method not allowed' 'text/plain; charset=utf-8'}
    }catch{Write-Warning "PacketRat HTTP error: $($_.Exception.Message)"}
    finally{$client.Close()}
 }
 Write-Host ('PacketRat stopped: '+$script:StopReason) -ForegroundColor Yellow
 Write-PacketRatLog -Message ('Browser server stopped: '+$script:StopReason) -Root $Root
}finally{
    $listener.Stop()
    Remove-PacketRatRuntimeFile -Path $runtimeFile
}
