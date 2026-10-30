# PacketRat command core: every action the browser UI takes goes through Invoke-PacketRatApi by route.
# Dot-sourced by Start-PacketRat-Web.ps1 (the browser server) and Invoke-PacketRatCli.ps1 (the command line), so the GUI,
# the CLI and the HTTP API run the same code (Fleet CLI parity). Expects $Root, $script:Presence, $script:StopReason and
# $script:LastResult in the caller's script scope.
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
function Resolve-PacketRatOutlookEntryId($Item) {
    # Classic Outlook opens a message by EntryID. A Graph message has only a Graph id, so find the same message in
    # classic Outlook by its Internet message id (a read-only lookup). Returns the EntryID or throws a clear reason.
    $entryId=[string]$Item.EntryID
    if(-not ($script:LastResult -and $script:LastResult.Provider -eq 'Graph')){return $entryId}
    $internetId=if($Item.PSObject.Properties['InternetMessageId']){[string]$Item.InternetMessageId}else{''}
    if(-not $internetId -and $script:LastResult.Summary){
        $email=@($script:LastResult.Summary.Emails | Where-Object {[string]$_.EntryID -ceq $entryId} | Select-Object -First 1)
        if($email.Count -gt 0 -and $email[0].PSObject.Properties['InternetMessageId']){$internetId=[string]$email[0].InternetMessageId}
    }
    if(-not $internetId){throw 'This Graph message has no Internet message id in the current analysis, so classic Outlook cannot be asked for it. Run the analysis again.'}
    $found=Find-PacketRatOutlookEntryIdByInternetMessageId -InternetMessageId $internetId
    if(-not $found){throw 'The message is not in the classic Outlook profile on this PC (it may not be synced, or classic Outlook is not signed in to this mailbox).'}
    return [string]$found
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
    if($Route -eq '/api/commands') {return @{ok=$true;schema='packetrat.commands/1';commands=@(Get-PacketRatCommandList)}}
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
          $entryId=Resolve-PacketRatOutlookEntryId $item
          $outlook=New-Object -ComObject Outlook.Application
          $mail=$outlook.Session.GetItemFromID($entryId)
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
          $entryId=Resolve-PacketRatOutlookEntryId $item
          $body=[string]$Data.body
          if(-not $body.Trim()){throw 'Empty draft'}
          if($body.Length -gt 16000){throw 'Draft exceeds 16000 characters'}
          $outlook=New-Object -ComObject Outlook.Application
          $mail=$outlook.Session.GetItemFromID($entryId)
          if(-not $mail){throw 'Email not found in Outlook'}
          $subject=[string]$Data.subject
          $apply=[bool]$Data.applySubject
          if($apply -and ([string]::IsNullOrWhiteSpace($subject) -or $subject.Length -gt 240 -or $subject -match '[`r`n]')){
              throw 'Suggested subject must be a single line with 1-240 characters.'
          }
          # Classic Outlook injects its configured per-account reply signature
          # when the reply inspector opens. Preserve the existing HTML and
          # append the reviewed text before it; never invent a new signature.
          $null=New-PacketRatOutlookReplyDraft -EntryID $entryId -Body $body -SuggestedSubject $subject -ApplySuggestedSubject:$apply
          return @{ok=$true}
      }
      default {throw 'Unknown API route'}
    }
}
