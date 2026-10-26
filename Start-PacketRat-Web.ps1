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
  Keep running after the browser tab closes. Also: --stay, or PACKETRAT_AUTO_STOP=0 (former MAILHAWK_AUTO_STOP still read).
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
foreach($name in @('LazaretteBridge','PacketRatLogging','PacketRatLifecycle','PacketRatLlm','PacketRatStore','PacketRatRules','PacketRatProtocol','PacketRatReport','Get-OutlookMailSummary','PacketRatGraph','PacketRatDraft')) {
    . (Join-Path $Root "Private\$name.ps1")
}
. (Join-Path $Root 'Public\Invoke-PacketRatInboxAnalysis.ps1')
# Config\packetrat.env; an installed copy's former Config\mailhawk.env is still read when the new file is absent.
$envFile=Join-Path $Root 'Config\packetrat.env'
if(-not (Test-Path $envFile)){$legacyEnv=Join-Path $Root 'Config\mailhawk.env';if(Test-Path $legacyEnv){$envFile=$legacyEnv}}
if(Test-Path $envFile){
    foreach($line in Get-Content $envFile){
        if($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$'){
            [Environment]::SetEnvironmentVariable($Matches[1],$Matches[2].Trim().Trim('"').Trim("'"),'Process')
        }
    }
}
Initialize-PacketRatLegacyEnvironment
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
function Find-PacketRatItem($Store,[string]$Key){
    return @($Store.Checklist | Where-Object {$_.Key -ceq $Key} | Select-Object -First 1)[0]
}
function Find-PacketRatReportSource([string]$Key) {
    if(-not $script:LastResult -or -not $script:LastResult.Summary){return $null}
    $source=@($script:LastResult.ReportItems | Where-Object {$_.Key -ceq $Key} | Select-Object -First 1)
    if($source.Count -eq 0){return $null}
    $email=@($script:LastResult.Summary.Emails | Where-Object {
        $_.Fingerprint -ceq $Key -and -not $_.UserDismissed -and -not $_.IsSensitive
    } | Select-Object -First 1)
    if($email.Count -eq 0){return $null}
    return $email[0]
}
function Invoke-PacketRatApi {
    param([string]$Route,$Data)
    if($Route -eq '/api/heartbeat') {
        Register-PacketRatPresence -State $script:Presence -Tab ([string]$Data.tab) -Leaving:($Data.leaving -eq $true)
        return @{ok=$true;autoStop=[bool]$script:Presence.AutoStop;liveTabs=(Get-PacketRatLiveTabCount -State $script:Presence);timeoutSeconds=[int]$script:Presence.HeartbeatTimeout.TotalSeconds}
    }
    if($Route -eq '/api/session/stop') {
        # Requests are handled one at a time, so nothing else is mid-write here.
        $script:StopReason='End session was selected in the browser.'
        return @{ok=$true;stopping=$true}
    }
    if($Route -eq '/api/health') {return @{ok=$true;service='PacketRat';mode='local';version='2.0'}}
    if($Route -eq '/api/credentials/status') {return @{ok=$true;credentials=(Get-PacketRatCredentialStatus)}}
    $store=Get-PacketRatStore -Root $Root
    switch($Route){
      '/api/state' {
          $summary=if($script:LastResult){$script:LastResult}else{$null}
          return @{ok=$true;store=$store;credentials=(Get-PacketRatCredentialStatus);report=if($summary){$summary.Report}else{$null};reportStructure=if($summary){@($summary.ReportStructure)}else{@()};responseProtocol=if($summary){[string]$summary.ResponseProtocol}else{''};reportItems=if($summary){@($summary.ReportItems)}else{@()};reportSections=if($summary){@($summary.ReportSections)}else{@()};reportQuality=if($summary){$summary.ReportQuality}else{$null};lastRun=if($summary){@{AnalyzedCount=$summary.AnalyzedCount;Provider=$summary.Provider;Profile=$summary.Profile;Model=$summary.Model;GeneratedAt=$summary.GeneratedAt}}else{$null}}
      }
      '/api/credentials' {
          $source=[string]$Data.source
          if($source -cnotin @('Lazarette','Manual')){throw 'Select Lazarette or Manual as the credential source.'}
          $profile=[string]$Data.profile
          try{$profile=ConvertTo-PacketRatLlmProfile -Profile $profile}catch{$profile=''}
          if($profile -cnotin @('AiEndpoint','Grok')){throw 'Select AI endpoint or Grok for a manual token.'}
          $tokenText=if($null -eq $Data.token){''}else{[string]$Data.token}
          $status=Set-PacketRatCredentialConfiguration -Source $source -Profile $profile -Token $tokenText
          return @{ok=$true;credentials=$status}
      }
      '/api/credentials/check' {
          $requested=try{ConvertTo-PacketRatLlmProfile -Profile ([string]$Data.profile)}catch{'AiEndpoint'}
          if($requested -eq 'Auto'){$requested='AiEndpoint'}
          # Resolve locally only. Never return token, contact an AI endpoint,
          # or fetch user mailbox data from this diagnostic route.
          $resolved=Get-PacketRatLlmConfig -Profile $requested
          $found=Get-PacketRatLlmAuthToken -Config $resolved
          if(-not $found){return @{ok=$true;profile=$resolved.Profile;credentialAvailable=$false;note='Local AI endpoint on this PC: no token needed unless its API key is turned on; endpoint not tested.'}}
          return @{ok=$true;profile=$resolved.Profile;credentialAvailable=$true;note='Credential resolved locally; remote endpoint not tested.'}
      }
      '/api/credentials/clear' {
          $status=Clear-PacketRatManualTokens
          return @{ok=$true;credentials=$status}
      }
      '/api/analyze' {
          $profile=try{ConvertTo-PacketRatLlmProfile -Profile ([string]$Data.profile)}catch{'Auto'}
          $provider=if(@('COM','Graph') -contains $Data.provider){$Data.provider}else{'COM'}
          $max=[Math]::Max(1,[Math]::Min(150,[int]$Data.maxEmails))
          $days=[Math]::Max(1,[Math]::Min(90,[int]$Data.daysBack))
          # Fail before scanning Outlook if the chosen AI credential source is unusable.
          # Profile Auto is resolved to the actual endpoint before checking its token.
          # A local (loopback) endpoint needs no token; a remote one throws here when its token is missing.
          $null=Get-PacketRatLlmAuthToken -Config (Get-PacketRatLlmConfig -Profile $profile)
          $script:LastResult=Invoke-PacketRatInboxAnalysis -Profile $profile -Provider $provider -MaxEmails $max -DaysBack $days -Root $Root
          $run=$script:LastResult
          return @{ok=[bool]$run.Success;message=$run.Message;report=$run.Report;reportStructure=@($run.ReportStructure);responseProtocol=[string]$run.ResponseProtocol;reportItems=@($run.ReportItems);reportSections=@($run.ReportSections);reportQuality=$run.ReportQuality;store=(Get-PacketRatStore -Root $Root);summary=@{AnalyzedCount=$run.AnalyzedCount;Provider=$run.Provider;Profile=$run.Profile;Model=$run.Model;GeneratedAt=$run.GeneratedAt}}
      }
      '/api/report/generate' {
          if(-not $script:LastResult -or -not $script:LastResult.Success){throw 'Analyze inbox before generating report intelligence.'}
          $mode=[string]$Data.mode
          if(@('Brief','Actions','Risks','Explain') -cnotcontains $mode){throw 'Invalid report generation mode.'}
          $sectionId=[string]$Data.sectionId
          if(-not $sectionId){$sectionId='all'}
          if($sectionId -cne 'all' -and $sectionId -notmatch '^section-\d{1,3}$'){throw 'Invalid report section.'}
          $profile=try{ConvertTo-PacketRatLlmProfile -Profile ([string]$Data.profile)}catch{'Auto'}
          $generated=Invoke-PacketRatReportFollowup -Analysis $script:LastResult -Mode $mode -SectionId $sectionId -Profile $profile
          return @{ok=$true;generated=$generated}
      }
      '/api/report/track' {
          $key=[string]$Data.key
          $source=Find-PacketRatReportSource $key
          if(-not $source){throw 'Only verified, current report source messages can become actions.'}
          if(Test-PacketRatDismissed -Store $store -Key $key){throw 'Restore this message from dismissals before tracking it.'}
          $level=if(@('High','Medium','Low') -contains [string]$Data.urgency){[string]$Data.urgency}else{'Medium'}
          $item=@($script:LastResult.ReportItems | Where-Object {$_.Key -ceq $key} | Select-Object -First 1)[0]
          if(-not $item){throw 'Verified report item not found'}
          $existing=Find-PacketRatItem $store $key
          if(-not $existing){
              $proposal=[pscustomobject]@{
                  Key=$key;Index=[int]$source.Index;EntryID=[string]$source.EntryID
                  Subject=[string]$source.Subject;From=[string]$source.FromName;FromEmail=[string]$source.FromEmail
                  Why=$(if($item.RecommendedAction){[string]$item.RecommendedAction}else{[string]$item.Reason})
                  Urgency=$level;TriageSource='Manual';RuleName=''
              }
              $store=Merge-PacketRatChecklist -Store $store -Items @($proposal) -Root $Root
          }
          $store=Set-PacketRatChecklistPriority -Store $store -Key $key -Urgency $level -Root $Root
          $null=Set-PacketRatChecklistStatus -Store $store -Key $key -Status open -Root $Root
          return @{ok=$true;store=(Get-PacketRatStore -Root $Root)}
      }
      '/api/status' {
          $key=[string]$Data.key
          if(-not (Find-PacketRatItem $store $key)){throw 'Unknown checklist item'}
          if(@('open','in_progress','done') -notcontains [string]$Data.status){throw 'Invalid status'}
          $null=Set-PacketRatChecklistStatus -Store $store -Key $key -Status ([string]$Data.status) -Root $Root
          return @{ok=$true;store=(Get-PacketRatStore -Root $Root)}
      }
      '/api/priority' {
          $key=[string]$Data.key
          if(-not (Find-PacketRatItem $store $key)){throw 'Unknown checklist item'}
          $priority=[string]$Data.urgency
          if(@('High','Medium','Low') -cnotcontains $priority){throw 'Choose High, Medium or Low'}
          $store=Set-PacketRatChecklistPriority -Store $store -Key $key -Urgency $priority -Root $Root
          return @{ok=$true;store=$store}
      }
      '/api/priority/reset' {
          $key=[string]$Data.key
          if(-not (Find-PacketRatItem $store $key)){throw 'Unknown checklist item'}
          $store=Clear-PacketRatChecklistPriorityOverride -Store $store -Key $key -Root $Root
          return @{ok=$true;store=$store}
      }
      '/api/rules' {
          if($null -eq $Data.rules){throw 'Rules payload is required'}
          $rules=@($Data.rules)
          $store=Set-PacketRatRules -Store $store -Rules $rules -Root $Root
          return @{ok=$true;store=$store}
      }
      '/api/dismiss' {
          $key=[string]$Data.key;$item=Find-PacketRatItem $store $key
          if(-not $item){throw 'Unknown checklist item'}
          $reason=[string]$Data.reason
          if($reason.Length -gt 300){$reason=$reason.Substring(0,300)}
          $null=Add-PacketRatDismissal -Store $store -Key $key -Subject $item.Subject -From $item.From -Reason $reason -Root $Root
          $store=Get-PacketRatStore -Root $Root
          $null=Set-PacketRatChecklistStatus -Store $store -Key $key -Status dismissed -Root $Root
          return @{ok=$true;store=(Get-PacketRatStore -Root $Root)}
      }
      '/api/restore' {
          $key=[string]$Data.key
          if(-not @($store.Dismissals|Where-Object {$_.Key -ceq $key}).Count){throw 'Unknown dismissal'}
          $null=Remove-PacketRatDismissal -Store $store -Key $key -Root $Root
          $store=Get-PacketRatStore -Root $Root
          if(Find-PacketRatItem $store $key){$null=Set-PacketRatChecklistStatus -Store $store -Key $key -Status open -Root $Root}
          return @{ok=$true;store=(Get-PacketRatStore -Root $Root)}
      }
      '/api/open' {
          $item=Find-PacketRatItem $store ([string]$Data.key)
          if(-not $item){$item=Find-PacketRatReportSource ([string]$Data.key)}
          if(-not $item -or -not $item.EntryID){throw 'Original Outlook message unavailable for this verified source.'}
          if($script:LastResult -and $script:LastResult.Provider -eq 'Graph'){throw 'Opening Graph-only messages in classic Outlook is not yet supported.'}
          $outlook=New-Object -ComObject Outlook.Application
          $mail=$outlook.Session.GetItemFromID([string]$item.EntryID)
          if(-not $mail){throw 'Email not found in Outlook'}
          $mail.Display()
          return @{ok=$true}
      }
      '/api/draft' {
          $key=[string]$Data.key
          if(-not $script:LastResult){throw 'Run analysis in this session before drafting'}
          $email=Find-PacketRatReportSource $key
          if(-not $email){throw 'Email not available in current verified analysis'}
          $profile=try{ConvertTo-PacketRatLlmProfile -Profile ([string]$Data.profile)}catch{'Auto'}
          $instruction=[string]$Data.instruction
          if($instruction.Length -gt 2000){throw 'Draft instruction exceeds limit'}
          $draft=New-PacketRatDraftReply -Email $email -Profile $profile -ExtraInstruction $instruction
          return @{ok=$true;draft=$draft}
      }
      '/api/open-draft' {
          $item=Find-PacketRatItem $store ([string]$Data.key)
          if(-not $item){$item=Find-PacketRatReportSource ([string]$Data.key)}
          if(-not $item -or -not $item.EntryID){throw 'Original Outlook message unavailable for this verified source.'}
          if($script:LastResult -and $script:LastResult.Provider -eq 'Graph'){throw 'Opening Graph-only messages in classic Outlook is not yet supported.'}
          $body=[string]$Data.body
          if(-not $body.Trim()){throw 'Empty draft'}
          if($body.Length -gt 16000){throw 'Draft exceeds 16000 characters'}
          $outlook=New-Object -ComObject Outlook.Application
          $mail=$outlook.Session.GetItemFromID([string]$item.EntryID)
          if(-not $mail){throw 'Email not found in Outlook'}
          $subject=[string]$Data.subject
          $apply=[bool]$Data.applySubject
          if($apply -and ([string]::IsNullOrWhiteSpace($subject) -or $subject.Length -gt 240 -or $subject -match '[`r`n]')){
              throw 'Suggested subject must be a single line with 1-240 characters.'
          }
          # Classic Outlook injects its configured per-account reply signature
          # when the reply inspector opens. Preserve the existing HTML and
          # append the reviewed text before it; never invent a new signature.
          $null=New-PacketRatOutlookReplyDraft -EntryID ([string]$item.EntryID) -Body $body -SuggestedSubject $subject -ApplySuggestedSubject:$apply
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
          if($method -eq 'GET' -and $path -notin @('/api/state','/api/health','/api/credentials/status')){
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
