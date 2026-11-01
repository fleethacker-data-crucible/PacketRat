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
    if($script:LastResult -and $script:LastResult.Provider -eq 'Files'){throw 'This message was read from a file, so there is no Outlook copy to open. Open the source file instead.'}
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
function Invoke-PacketRatApiCore {
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
    if($Route -eq '/api/burden') {return @{ok=$true;burden=(Get-PacketRatBurdenView -Root $Root)}}
    if($Route -eq '/api/burden/baseline') {return @{ok=$true;burden=(Set-PacketRatBurdenBaseline -Task ([string]$Data.task) -Seconds ([string]$Data.seconds) -Replace:([bool]$Data.replace) -Root $Root)}}
    if($Route -eq '/api/burden/record') {return @{ok=$true;burden=(Add-PacketRatBurdenRun -Task ([string]$Data.task) -Seconds ([string]$Data.seconds) -Root $Root)}}
    if($Route -eq '/api/log') {return @{ok=$true;log=(Get-PacketRatActionLogView -Root $Root)}}
    if($Route -eq '/api/log/verify') {$v=Test-PacketRatActionLog -Root $Root;return @{ok=[bool]$v.Valid;verify=$v}}
    if($Route -eq '/api/commands') {return @{ok=$true;schema='packetrat.commands/1';commands=@(Get-PacketRatCommandList)}}
    if($Route -eq '/api/authority') {return @{ok=$true;authority=(Get-PacketRatAuthority)}}
    if($Route -eq '/api/credentials/status') {return @{ok=$true;credentials=(Get-PacketRatCredentialStatus)}}
    $store=Get-PacketRatStore -Root $Root
    switch($Route){
      '/api/state' {
          $summary=if($script:LastResult){$script:LastResult}else{$null}
          return @{ok=$true;store=$store;credentials=(Get-PacketRatCredentialStatus);report=if($summary){$summary.Report}else{$null};reportStructure=if($summary){@($summary.ReportStructure)}else{@()};responseProtocol=if($summary){[string]$summary.ResponseProtocol}else{''};reportItems=if($summary){@($summary.ReportItems)}else{@()};reportSections=if($summary){@($summary.ReportSections)}else{@()};reportQuality=if($summary){$summary.ReportQuality}else{$null};lastRun=if($summary){@{AnalyzedCount=$summary.AnalyzedCount;Provider=$summary.Provider;Profile=$summary.Profile;Model=$summary.Model;GeneratedAt=$summary.GeneratedAt}}else{$null}}
      }
      '/api/credentials/check' {
          # Local check only: is the Fairlead key for PacketRat in Windows Credential Manager? Never returns the key
          # and never contacts Fairlead or reads mail.
          $status=Get-PacketRatCredentialStatus
          return @{ok=$true;credentialAvailable=[bool]$status.keyInstalled;router='Fairlead';note=[string]$status.message}
      }
      '/api/analyze' {
          $provider=if(@('COM','Graph','Files') -contains $Data.provider){$Data.provider}else{'COM'}
          $max=[Math]::Max(1,[Math]::Min(150,[int]$Data.maxEmails))
          $days=[Math]::Max(1,[Math]::Min(90,[int]$Data.daysBack))
          # Fail before scanning Outlook if the Fairlead key for PacketRat is not installed.
          $null=Get-PacketRatFairleadKey
          $extra=@{}
          if($provider -eq 'Files'){$extra.Folder=[string]$Data.folder}
          if(@('Single','Batch') -contains [string]$Data.classification){$extra.Classification=[string]$Data.classification}
          $script:LastResult=Invoke-PacketRatInboxAnalysis -Provider $provider -MaxEmails $max -DaysBack $days -Root $Root @extra
          $run=$script:LastResult
          if($run.Success){$null=Add-PacketRatUsage -Action triaged -Count ([int]$run.AnalyzedCount) -Root $Root;$null=Add-PacketRatUsage -Action reports -Root $Root}
          return @{ok=[bool]$run.Success;message=$run.Message;report=$run.Report;reportStructure=@($run.ReportStructure);responseProtocol=[string]$run.ResponseProtocol;reportItems=@($run.ReportItems);reportSections=@($run.ReportSections);reportQuality=$run.ReportQuality;store=(Get-PacketRatStore -Root $Root);summary=@{AnalyzedCount=$run.AnalyzedCount;Provider=$run.Provider;Profile=$run.Profile;Model=$run.Model;GeneratedAt=$run.GeneratedAt}}
      }
      '/api/report/generate' {
          if(-not $script:LastResult -or -not $script:LastResult.Success){throw 'Analyze inbox before generating report intelligence.'}
          $mode=[string]$Data.mode
          if(@('Brief','Actions','Risks','Explain') -cnotcontains $mode){throw 'Invalid report generation mode.'}
          $sectionId=[string]$Data.sectionId
          if(-not $sectionId){$sectionId='all'}
          if($sectionId -cne 'all' -and $sectionId -notmatch '^section-\d{1,3}$'){throw 'Invalid report section.'}
          $generated=Invoke-PacketRatReportFollowup -Analysis $script:LastResult -Mode $mode -SectionId $sectionId
          $null=Add-PacketRatUsage -Action reports -Root $Root
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
          $null=Add-PacketRatUsage -Action dismissed -Root $Root
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
          $instruction=[string]$Data.instruction
          if($instruction.Length -gt 2000){throw 'Draft instruction exceeds limit'}
          $draft=New-PacketRatDraftReply -Email $email -ExtraInstruction $instruction
          $null=Add-PacketRatUsage -Action drafts -Root $Root
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
      '/api/cancel' {
          # Stops a streaming AI generation that is running in this PacketRat process (the next chunk check sees the flag).
          $null=Request-PacketRatCancel
          return @{ok=$true;cancelRequested=$true}
      }
      '/api/item/archive' {
          $key=[string]$Data.key
          $item=Find-PacketRatItem $store $key
          if(-not $item){$item=Find-PacketRatReportSource $key}
          if(-not $item -or -not $item.EntryID){throw 'Original Outlook message unavailable for this item.'}
          if($script:LastResult -and $script:LastResult.Provider -in @('Graph','Files')){throw 'Inbox actions require classic Outlook (COM mode); mail read from files or Graph cannot be changed here.'}
          $null=Move-PacketRatMailToArchive -EntryID ([string]$item.EntryID)
          if((Find-PacketRatItem $store $key) -and -not (Test-PacketRatDismissed -Store $store -Key $key)){
              $fromVal=if($item.PSObject.Properties['From']){[string]$item.From}else{[string]$item.FromName}
              $null=Add-PacketRatDismissal -Store $store -Key $key -Subject ([string]$item.Subject) -From $fromVal -Reason 'Archived' -Root $Root
              $store=Get-PacketRatStore -Root $Root
              $null=Set-PacketRatChecklistStatus -Store $store -Key $key -Status dismissed -Root $Root
          }
          $null=Add-PacketRatUsage -Action archived -Root $Root
          return @{ok=$true;store=(Get-PacketRatStore -Root $Root)}
      }
      '/api/item/move' {
          $key=[string]$Data.key
          $item=Find-PacketRatItem $store $key
          if(-not $item){$item=Find-PacketRatReportSource $key}
          if(-not $item -or -not $item.EntryID){throw 'Original Outlook message unavailable for this item.'}
          if($script:LastResult -and $script:LastResult.Provider -in @('Graph','Files')){throw 'Inbox actions require classic Outlook (COM mode); mail read from files or Graph cannot be changed here.'}
          $folder=[string]$Data.folder
          if([string]::IsNullOrWhiteSpace($folder) -or $folder.Length -gt 256){throw 'A folder name of 1-256 characters is required.'}
          $null=Move-PacketRatMailToFolder -EntryID ([string]$item.EntryID) -FolderName $folder
          $null=Add-PacketRatUsage -Action moved -Root $Root
          return @{ok=$true;store=$store}
      }
      '/api/item/categorize' {
          $key=[string]$Data.key
          $item=Find-PacketRatItem $store $key
          if(-not $item){$item=Find-PacketRatReportSource $key}
          if(-not $item -or -not $item.EntryID){throw 'Original Outlook message unavailable for this item.'}
          if($script:LastResult -and $script:LastResult.Provider -in @('Graph','Files')){throw 'Inbox actions require classic Outlook (COM mode); mail read from files or Graph cannot be changed here.'}
          $category=[string]$Data.category
          if([string]::IsNullOrWhiteSpace($category) -or $category.Length -gt 255 -or $category -match ';'){throw 'Category must be 1-255 characters with no semicolons.'}
          $null=Set-PacketRatMailCategory -EntryID ([string]$item.EntryID) -Category $category
          $null=Add-PacketRatUsage -Action categorized -Root $Root
          return @{ok=$true;store=$store}
      }
      '/api/item/mark-read' {
          $key=[string]$Data.key
          $item=Find-PacketRatItem $store $key
          if(-not $item){$item=Find-PacketRatReportSource $key}
          if(-not $item -or -not $item.EntryID){throw 'Original Outlook message unavailable for this item.'}
          if($script:LastResult -and $script:LastResult.Provider -in @('Graph','Files')){throw 'Inbox actions require classic Outlook (COM mode); mail read from files or Graph cannot be changed here.'}
          $unread=[bool]$Data.unread
          $null=Set-PacketRatMailRead -EntryID ([string]$item.EntryID) -Unread:$unread
          $null=Add-PacketRatUsage -Action markedRead -Root $Root
          return @{ok=$true;store=$store}
      }
      '/api/item/handoff' {
          $handoff=New-PacketRatHalyardHandoff -Store $store -Key ([string]$Data.key) -Root $Root
          return @{ok=$true;handoff=$handoff.Document;file=$handoff.File;note='Written locally only. A person reviews it before Halyard uses it.'}
      }
      '/api/stats' { return @{ok=$true;stats=(Get-PacketRatUsageStats -Root $Root)} }
      '/api/stats/export' { return @{ok=$true;usage=(Get-PacketRatUsageExport -Root $Root)} }
      '/api/stats/reset' { Reset-PacketRatUsage -Root $Root; return @{ok=$true;stats=(Get-PacketRatUsageStats -Root $Root)} }
      '/api/assist/brief' { return @{ok=$true;briefing=(Get-PacketRatSpokenBriefing -Store $store)} }
      '/api/assist/ask' {
          $answer=Invoke-PacketRatAssistAsk -Store $store -Question ([string]$Data.question)
          return @{ok=$true;say=$answer.Say;proposals=@($answer.Proposals);model=$answer.Model;note='Proposals are suggestions only; nothing was changed.'}
      }
      '/api/voice/status' { return @{ok=$true;voice=(Get-PacketRatVoiceStatus -Root $Root)} }
      default {throw 'Unknown API route'}
    }
}

# Every route goes through here so the action log sees what ran. Core errors are logged as failed and re-thrown unchanged.
function Invoke-PacketRatApi {
    param([string]$Route,$Data)
    $outcome='ok'
    try {
        $result=Invoke-PacketRatApiCore -Route $Route -Data $Data
        if($result -is [System.Collections.IDictionary] -and $result.Contains('ok') -and -not [bool]$result['ok']){$outcome='failed'}
        return $result
    } catch {
        $outcome='failed'
        throw
    } finally {
        if(Get-Command Write-PacketRatActionLogFor -ErrorAction SilentlyContinue){
            $itemKey=Get-PacketRatActionLogKey $Data
            Write-PacketRatActionLogFor -Route $Route -Key $itemKey -Outcome $outcome -Root $Root
        }
    }
}
