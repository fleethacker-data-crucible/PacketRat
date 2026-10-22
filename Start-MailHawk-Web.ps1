#requires -Version 5.1
<#
 .SYNOPSIS
  MailHawk browser UI over a loopback-only TCP HTTP server.
 .NOTES
  No HttpListener URLACL or administrator elevation required.
  Outlook COM calls and AI requests are synchronous in this implementation.
#>
[CmdletBinding()]
param([ValidateRange(0,65535)][int]$Port=8766,[switch]$NoBrowser,[switch]$Demo)
$ErrorActionPreference='Stop'
$Root=$PSScriptRoot
foreach($name in @('ArcBridge','MailHawkLogging','MailHawkLlm','MailHawkStore','MailHawkRules','Get-OutlookMailSummary','MailHawkGraph','MailHawkDraft')) {
    . (Join-Path $Root "Private\$name.ps1")
}
. (Join-Path $Root 'Public\Invoke-MailHawkInboxAnalysis.ps1')
$envFile=Join-Path $Root 'Config\mailhawk.env'
if(Test-Path $envFile){
    foreach($line in Get-Content $envFile){
        if($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$'){
            [Environment]::SetEnvironmentVariable($Matches[1],$Matches[2].Trim().Trim('"').Trim("'"),'Process')
        }
    }
}
$script:LastResult=$null
$script:Nonce=[guid]::NewGuid().ToString('N')
$script:Mime=@{'.html'='text/html; charset=utf-8';'.css'='text/css; charset=utf-8';'.js'='application/javascript; charset=utf-8';'.png'='image/png'}
$script:AllowedAssets=@('index.html','app.js','style.css','mailhawk-logo.png','mailhawk-icon.png')
$script:UTF8=New-Object System.Text.UTF8Encoding $false

function Send-MailHawkResponse {
    param([System.IO.Stream]$Stream,[int]$Status,[byte[]]$Bytes,[string]$Type='application/json; charset=utf-8')
    $reason=switch($Status){200{'OK'}400{'Bad Request'}403{'Forbidden'}404{'Not Found'}405{'Method Not Allowed'}413{'Payload Too Large'}500{'Internal Server Error'}default{'Error'}}
    $head="HTTP/1.1 $Status $reason`r`nContent-Type: $Type`r`nContent-Length: $($Bytes.Length)`r`nCache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`nX-Frame-Options: DENY`r`nReferrer-Policy: no-referrer`r`nContent-Security-Policy: default-src 'self'; style-src 'self'; script-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`r`nConnection: close`r`n`r`n"
    $hb=[Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($hb,0,$hb.Length)
    $Stream.Write($Bytes,0,$Bytes.Length)
    $Stream.Flush()
}
function Send-MailHawkText {
    param([System.IO.Stream]$Stream,[int]$Status,[string]$Body,[string]$Type='application/json; charset=utf-8')
    Send-MailHawkResponse -Stream $Stream -Status $Status -Bytes $script:UTF8.GetBytes($Body) -Type $Type
}
function Read-MailHawkLine {
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
function Read-MailHawkBody {
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
function Find-MailHawkItem($Store,[string]$Key){
    return @($Store.Checklist | Where-Object {$_.Key -ceq $Key} | Select-Object -First 1)[0]
}
function Invoke-MailHawkApi {
    param([string]$Route,$Data)
    if($Route -eq '/api/health') {return @{ok=$true;service='MailHawk';mode='local';version='2.0'}}
    if($Route -eq '/api/credentials/status') {return @{ok=$true;credentials=(Get-MailHawkCredentialStatus)}}
    $store=Get-MailHawkStore -Root $Root
    switch($Route){
      '/api/state' {
          $summary=if($script:LastResult){$script:LastResult}else{$null}
          return @{ok=$true;store=$store;credentials=(Get-MailHawkCredentialStatus);report=if($summary){$summary.Report}else{$null};lastRun=if($summary){@{AnalyzedCount=$summary.AnalyzedCount;Provider=$summary.Provider;Profile=$summary.Profile;Model=$summary.Model;GeneratedAt=$summary.GeneratedAt}}else{$null}}
      }
      '/api/credentials' {
          $source=[string]$Data.source
          if($source -cnotin @('ARC','Manual')){throw 'Select ARC or Manual as the credential source.'}
          $profile=[string]$Data.profile
          if($profile -cnotin @('GenAi','Grok')){throw 'Select GenAi or Grok for a manual token.'}
          $tokenText=if($null -eq $Data.token){''}else{[string]$Data.token}
          $status=Set-MailHawkCredentialConfiguration -Source $source -Profile $profile -Token $tokenText
          return @{ok=$true;credentials=$status}
      }
      '/api/credentials/check' {
          $requested=if($Data.profile -in @('GenAi','Grok')){[string]$Data.profile}else{'GenAi'}
          # Resolve locally only. Never return token, contact an AI endpoint,
          # or fetch user mailbox data from this diagnostic route.
          $resolved=Get-MailHawkLlmConfig -Profile $requested
          $null=Get-MailHawkLlmToken -ForProfile $resolved.Profile
          return @{ok=$true;profile=$resolved.Profile;credentialAvailable=$true;note='Credential resolved locally; remote endpoint not tested.'}
      }
      '/api/credentials/clear' {
          $status=Clear-MailHawkManualTokens
          return @{ok=$true;credentials=$status}
      }
      '/api/analyze' {
          $profile=if(@('Auto','Grok','GenAi') -contains $Data.profile){$Data.profile}else{'Auto'}
          $provider=if(@('COM','Graph') -contains $Data.provider){$Data.provider}else{'COM'}
          $max=[Math]::Max(1,[Math]::Min(150,[int]$Data.maxEmails))
          $days=[Math]::Max(1,[Math]::Min(90,[int]$Data.daysBack))
          # Fail before scanning Outlook if the chosen AI credential source is unusable.
          # Profile Auto is resolved to the actual endpoint before checking its token.
          $llmProfile=(Get-MailHawkLlmConfig -Profile $profile).Profile
          $null=Get-MailHawkLlmToken -ForProfile $llmProfile
          $script:LastResult=Invoke-MailHawkInboxAnalysis -Profile $profile -Provider $provider -MaxEmails $max -DaysBack $days -Root $Root
          $run=$script:LastResult
          return @{ok=[bool]$run.Success;message=$run.Message;report=$run.Report;store=(Get-MailHawkStore -Root $Root);summary=@{AnalyzedCount=$run.AnalyzedCount;Provider=$run.Provider;Profile=$run.Profile;Model=$run.Model;GeneratedAt=$run.GeneratedAt}}
      }
      '/api/status' {
          $key=[string]$Data.key
          if(-not (Find-MailHawkItem $store $key)){throw 'Unknown checklist item'}
          if(@('open','in_progress','done') -notcontains [string]$Data.status){throw 'Invalid status'}
          $null=Set-MailHawkChecklistStatus -Store $store -Key $key -Status ([string]$Data.status) -Root $Root
          return @{ok=$true;store=(Get-MailHawkStore -Root $Root)}
      }
      '/api/dismiss' {
          $key=[string]$Data.key;$item=Find-MailHawkItem $store $key
          if(-not $item){throw 'Unknown checklist item'}
          $reason=[string]$Data.reason
          if($reason.Length -gt 300){$reason=$reason.Substring(0,300)}
          $null=Add-MailHawkDismissal -Store $store -Key $key -Subject $item.Subject -From $item.From -Reason $reason -Root $Root
          $store=Get-MailHawkStore -Root $Root
          $null=Set-MailHawkChecklistStatus -Store $store -Key $key -Status dismissed -Root $Root
          return @{ok=$true;store=(Get-MailHawkStore -Root $Root)}
      }
      '/api/restore' {
          $key=[string]$Data.key
          if(-not @($store.Dismissals|Where-Object {$_.Key -ceq $key}).Count){throw 'Unknown dismissal'}
          $null=Remove-MailHawkDismissal -Store $store -Key $key -Root $Root
          $store=Get-MailHawkStore -Root $Root
          if(Find-MailHawkItem $store $key){$null=Set-MailHawkChecklistStatus -Store $store -Key $key -Status open -Root $Root}
          return @{ok=$true;store=(Get-MailHawkStore -Root $Root)}
      }
      '/api/open' {
          $item=Find-MailHawkItem $store ([string]$Data.key)
          if(-not $item -or -not $item.EntryID){throw 'Outlook EntryID unavailable'}
          $outlook=New-Object -ComObject Outlook.Application
          $mail=$outlook.Session.GetItemFromID([string]$item.EntryID)
          if(-not $mail){throw 'Email not found in Outlook'}
          $mail.Display()
          return @{ok=$true}
      }
      '/api/draft' {
          $key=[string]$Data.key
          if(-not $script:LastResult){throw 'Run analysis in this session before drafting'}
          $email=@($script:LastResult.Summary.Emails|Where-Object {$_.Fingerprint -ceq $key}|Select-Object -First 1)[0]
          if(-not $email){throw 'Email not available in current analysis'}
          $profile=if(@('Auto','Grok','GenAi') -contains $Data.profile){$Data.profile}else{'Auto'}
          $instruction=[string]$Data.instruction
          if($instruction.Length -gt 2000){throw 'Draft instruction exceeds limit'}
          $draft=New-MailHawkDraftReply -Email $email -Profile $profile -ExtraInstruction $instruction
          return @{ok=$true;draft=$draft}
      }
      '/api/open-draft' {
          $item=Find-MailHawkItem $store ([string]$Data.key)
          if(-not $item -or -not $item.EntryID){throw 'Outlook EntryID unavailable'}
          $body=[string]$Data.body
          if(-not $body.Trim()){throw 'Empty draft'}
          if($body.Length -gt 16000){throw 'Draft exceeds 16000 characters'}
          $outlook=New-Object -ComObject Outlook.Application
          $mail=$outlook.Session.GetItemFromID([string]$item.EntryID)
          if(-not $mail){throw 'Email not found in Outlook'}
          $reply=$mail.Reply()
          $reply.Body=$body+"`r`n`r`n"+$reply.Body
          $reply.Display() # human review; never call Send()
          return @{ok=$true}
      }
      default {throw 'Unknown API route'}
    }
}

$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port)
try{$listener.Start()}catch{
    Write-Warning "Requested port unavailable. Selecting a free loopback port."
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $listener.Start()
}
$Port=([Net.IPEndPoint]$listener.LocalEndpoint).Port
$url="http://127.0.0.1:$Port/"
Write-Host "MailHawk browser interface: $url" -ForegroundColor Cyan
Write-Host "Offline demo: ${url}?demo=1" -ForegroundColor DarkCyan
Write-Host 'Press Ctrl+C to stop the server.' -ForegroundColor DarkGray
if(-not $NoBrowser){try{Start-Process ($url + $(if($Demo){'?demo=1'}else{''}))}catch{Write-Warning 'Could not automatically open browser. Copy the URL shown above.'}}
try {
 while($true){
    $client=$listener.AcceptTcpClient()
    $client.ReceiveTimeout=30000;$client.SendTimeout=30000
    try {
      $stream=$client.GetStream()
      $first=Read-MailHawkLine -Stream $stream
      if(-not $first){continue}
      $parts=$first.Split(' ')
      if($parts.Count -lt 3){Send-MailHawkText $stream 400 '{"ok":false,"error":"Invalid HTTP request"}';continue}
      $method=$parts[0];$path=$parts[1].Split('?')[0]
      $headers=@{};$headerSize=0
      while($true){
          $line=Read-MailHawkLine -Stream $stream
          if(-not $line){break}
          $headerSize+=$line.Length
          if($headerSize -gt 16384){throw 'Headers too large'}
          $pos=$line.IndexOf(':')
          if($pos -gt 0){$headers[$line.Substring(0,$pos).ToLowerInvariant()]=$line.Substring($pos+1).Trim()}
      }
      if($headers['host'] -notin @("127.0.0.1:$Port","localhost:$Port")){
          Send-MailHawkText $stream 403 '{"ok":false,"error":"Invalid host"}';continue
      }
      if($path -match '^/api/'){
          if($method -eq 'GET' -and $path -notin @('/api/state','/api/health','/api/credentials/status')){
              Send-MailHawkText $stream 405 '{"ok":false,"error":"POST required"}';continue
          }
          if($method -eq 'POST'){
              if($headers['x-mailhawk-token'] -cne $script:Nonce -or $headers['origin'] -cne $url.TrimEnd('/')){
                  Send-MailHawkText $stream 403 '{"ok":false,"error":"Unauthorized request"}';continue
              }
              if($headers['content-type'] -notmatch '^application/json(?:;|$)'){
                  Send-MailHawkText $stream 400 '{"ok":false,"error":"JSON content type required"}';continue
              }
              $rawLength=$headers['content-length']
              $length=0
              if(-not [int]::TryParse($rawLength,[ref]$length) -or $length -lt 1 -or $length -gt 131072){
                  Send-MailHawkText $stream 413 '{"ok":false,"error":"Invalid request body length"}';continue
              }
              $data=ConvertFrom-Json (Read-MailHawkBody -Stream $stream -Length $length)
          }elseif($method -eq 'GET'){$data=$null}
          else{Send-MailHawkText $stream 405 '{"ok":false,"error":"Method not allowed"}';continue}
          try {
              $result=Invoke-MailHawkApi -Route $path -Data $data
              Send-MailHawkText $stream 200 (ConvertTo-Json -InputObject $result -Depth 15 -Compress)
          }catch{
              Write-Warning "MailHawk API error: $($_.Exception.Message)"
              Send-MailHawkText $stream 400 (ConvertTo-Json -InputObject @{ok=$false;error=$_.Exception.Message} -Compress)
          }
      }elseif($method -eq 'GET'){
          $name=if($path -eq '/'){'index.html'}else{$path.TrimStart('/')}
          if($name -cnotin $script:AllowedAssets){Send-MailHawkText $stream 404 'Not found' 'text/plain; charset=utf-8';continue}
          $file=Join-Path (Join-Path $Root 'Web') $name
          if(-not (Test-Path -LiteralPath $file)){Send-MailHawkText $stream 404 'Not found' 'text/plain; charset=utf-8';continue}
          $ext=[IO.Path]::GetExtension($file)
          if($ext -eq '.png'){
              Send-MailHawkResponse -Stream $stream -Status 200 -Bytes ([IO.File]::ReadAllBytes($file)) -Type $script:Mime[$ext]
          }else{
              $content=[IO.File]::ReadAllText($file)
              if($name -eq 'index.html'){$content=$content.Replace('__MAILHAWK_NONCE__',$script:Nonce)}
              Send-MailHawkText $stream 200 $content $script:Mime[$ext]
          }
      }else {Send-MailHawkText $stream 405 'Method not allowed' 'text/plain; charset=utf-8'}
    }catch{Write-Warning "MailHawk HTTP error: $($_.Exception.Message)"}
    finally{$client.Close()}
 }
}finally{$listener.Stop()}
