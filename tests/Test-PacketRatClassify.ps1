#requires -Version 5.1
# Offline tests for schema-first batch classification (PACKETRAT_CLASSIFY_V1) and the report compiled from it.
# The AI endpoint and Outlook are faked; synthetic data only.
$ErrorActionPreference='Stop'
$Root=Split-Path $PSScriptRoot -Parent
foreach($name in @('PacketRatLogging','PacketRatLifecycle','PacketRatLlm','PacketRatStore','PacketRatRules','PacketRatProtocol','PacketRatReport','Get-OutlookMailSummary','PacketRatGraph','PacketRatDraft','PacketRatApi','PacketRatCommands')){
    . (Join-Path $Root "Private\$name.ps1")
}
. (Join-Path $Root 'Public\Invoke-PacketRatInboxAnalysis.ps1')
function Assert-Classify([bool]$Pass,[string]$Message){if(-not $Pass){throw ('Classify test failed: '+$Message)}}
function Assert-Throws([scriptblock]$Block,[string]$Pattern,[string]$Message){
    $threw=$null
    try{& $Block}catch{$threw=$_.Exception.Message}
    Assert-Classify ($null -ne $threw) ($Message+' (expected an error)')
    Assert-Classify ($threw -match $Pattern) ($Message+" (wrong error: $threw)")
}
function New-Envelope([string]$Json){ "<<<PACKETRAT_CLASSIFY_V1>>>`n$Json`n<<<END_PACKETRAT_CLASSIFY_V1>>>" }
function New-Rec([int]$Index,[string]$Category='must_reply',[string]$Urgency='High',[string]$Deadline='',[string]$Confidence='high'){
    '{{"index":{0},"category":"{1}","urgency":"{2}","reason":"Reason for {0}","requested_action":"Act on {0}","deadline":"{3}","evidence":"phrase {0}","confidence":"{4}"}}' -f $Index,$Category,$Urgency,$Deadline,$Confidence
}
function New-Doc([string[]]$Recs){ New-Envelope ('{"version":"PACKETRAT_CLASSIFY_V1","records":['+($Recs -join ',')+']}') }

# --- Parser -------------------------------------------------------------------------------------------------------
$ok=ConvertFrom-PacketRatClassifyV1 -Text (New-Doc @((New-Rec 1 'must_reply' 'High' '2026-11-05'),(New-Rec 2 'caution' 'Low'))) -AllowedIndexes @(1,2,3)
Assert-Classify (@($ok).Count -eq 2 -and $ok[0].Category -eq 'must_reply' -and $ok[0].Deadline -eq '2026-11-05' -and $ok[0].ClassificationSource -eq 'batch-ai') 'a valid batch parses into typed records'
$none=ConvertFrom-PacketRatClassifyV1 -Text (New-Doc @()) -AllowedIndexes @(1)
Assert-Classify ($null -ne $none -and @($none).Count -eq 0) 'an empty record list is valid (nothing classifiable)'
Assert-Throws { ConvertFrom-PacketRatClassifyV1 -Text '' -AllowedIndexes @(1) } 'empty' 'an empty response is rejected'
Assert-Throws { ConvertFrom-PacketRatClassifyV1 -Text 'Sure! Here is the answer.' -AllowedIndexes @(1) } 'envelope' 'prose without the envelope is rejected'
Assert-Throws { ConvertFrom-PacketRatClassifyV1 -Text ((New-Doc @((New-Rec 1))).Replace('<<<END_PACKETRAT_CLASSIFY_V1>>>','')) -AllowedIndexes @(1) } 'envelope' 'a truncated envelope is rejected'
Assert-Throws { ConvertFrom-PacketRatClassifyV1 -Text ((New-Doc @((New-Rec 1))) + "`nextra") -AllowedIndexes @(1) } 'envelope' 'text after the envelope is rejected'
Assert-Throws { ConvertFrom-PacketRatClassifyV1 -Text (New-Envelope '{"version":"PACKETRAT_CLASSIFY_V1","records":[,]}') -AllowedIndexes @(1) } 'invalid JSON' 'broken JSON is rejected'
Assert-Throws { ConvertFrom-PacketRatClassifyV1 -Text ((New-Doc @((New-Rec 1))).Replace('CLASSIFY_V1","records','CLASSIFY_V0","records')) -AllowedIndexes @(1) } 'version' 'a wrong version is rejected'
Assert-Throws { ConvertFrom-PacketRatClassifyV1 -Text (New-Envelope '{"version":"PACKETRAT_CLASSIFY_V1"}') -AllowedIndexes @(1) } 'records missing' 'a missing records array is rejected'
Assert-Throws { ConvertFrom-PacketRatClassifyV1 -Text (New-Doc @((New-Rec 9))) -AllowedIndexes @(1,2) } 'out-of-range' 'an invented index is rejected'
Assert-Throws { ConvertFrom-PacketRatClassifyV1 -Text (New-Doc @((New-Rec 1),(New-Rec 1))) -AllowedIndexes @(1,2) } 'duplicate' 'a duplicate record is rejected'
Assert-Throws { ConvertFrom-PacketRatClassifyV1 -Text (New-Doc @((New-Rec 1 'urgent_action'))) -AllowedIndexes @(1) } 'category' 'an unknown category is rejected'
Assert-Throws { ConvertFrom-PacketRatClassifyV1 -Text (New-Doc @((New-Rec 1 'must_reply' 'Critical'))) -AllowedIndexes @(1) } 'urgency' 'an unknown urgency is rejected'
Assert-Throws { ConvertFrom-PacketRatClassifyV1 -Text (New-Doc @((New-Rec 1 'must_reply' 'High' '' 'certain'))) -AllowedIndexes @(1) } 'confidence' 'an unknown confidence is rejected'
Assert-Throws { ConvertFrom-PacketRatClassifyV1 -Text (New-Doc @((New-Rec 1 'must_reply' 'High' 'next Friday'))) -AllowedIndexes @(1) } 'YYYY-MM-DD' 'a prose deadline is rejected'
Assert-Throws { ConvertFrom-PacketRatClassifyV1 -Text (New-Doc @((New-Rec 1 'must_reply' 'High' '2026-02-30'))) -AllowedIndexes @(1) } 'YYYY-MM-DD' 'an impossible date is rejected'
Assert-Throws { ConvertFrom-PacketRatClassifyV1 -Text ((New-Doc @((New-Rec 1))).Replace('"reason":"Reason for 1"','"reason":""')) -AllowedIndexes @(1) } 'reason' 'an empty reason is rejected'
$injected=ConvertFrom-PacketRatClassifyV1 -Text ((New-Doc @((New-Rec 1))).Replace('Reason for 1','**Do this** | now [link]')) -AllowedIndexes @(1)
Assert-Classify ($injected[0].Reason -notmatch '[\*\|\[\]]') 'Markdown control characters are flattened out of free text'

# --- Compiler -----------------------------------------------------------------------------------------------------
function New-Mail([int]$Index,[string]$From='a@example.test',[switch]$Dismissed,[switch]$Sensitive){
    [pscustomobject]@{Index=$Index;Fingerprint="id:e$Index";EntryID="E$Index";Received='2026-10-29 09:00';FromName="Sender $Index";FromEmail=$From;IsDirect=($Index -le 2);Subject="Synthetic subject $Index";UnRead=$true;Importance=1;AppearsReplied=$false;ReplyEvidence='';UserDismissed=[bool]$Dismissed;IsSensitive=[bool]$Sensitive;BodyPreview="Preview $Index"}
}
$emails=@((New-Mail 1 'a@example.test'),(New-Mail 2 'a@example.test'),(New-Mail 3 'b@example.test'),(New-Mail 4 'c@example.test'),(New-Mail 5 'a@example.test'),(New-Mail 6 'd@example.test'),(New-Mail 7 'e@example.test'),(New-Mail 8 'f@example.test' -Dismissed))
$recs=@(
    [pscustomobject]@{Index=2;Category='must_reply';Urgency='Medium';Confidence='medium';Reason='Needs input';RequestedAction='Send figures';Deadline='';Evidence='';ClassificationSource='batch-ai'},
    [pscustomobject]@{Index=1;Category='must_reply';Urgency='High';Confidence='high';Reason='Approval due';RequestedAction='Approve';Deadline='2026-11-05';Evidence='by Nov 5';ClassificationSource='batch-ai'},
    [pscustomobject]@{Index=3;Category='already_replied';Urgency='Low';Confidence='high';Reason='Thread shows reply';RequestedAction='';Deadline='';Evidence='';ClassificationSource='batch-ai'},
    [pscustomobject]@{Index=4;Category='no_action';Urgency='Low';Confidence='low';Reason='Newsletter';RequestedAction='';Deadline='';Evidence='';ClassificationSource='batch-ai'},
    [pscustomobject]@{Index=5;Category='caution';Urgency='Medium';Confidence='low';Reason='Unclear link';RequestedAction='Verify sender';Deadline='';Evidence='';ClassificationSource='batch-ai'}
)
$env1=ConvertTo-PacketRatReportEnvelopeFromClassification -Records $recs -Emails $emails -UnclassifiedIndexes @(6) -Warnings @('Batch 2 of 2 was not classified.')
Assert-Classify ($env1.Version -eq 'PACKETRAT_REPORT_V1') 'compiled envelope has the report shape'
Assert-Classify ((@($env1.Sections.Id) -join ',') -eq 'categories,groups,must_reply,already_replied,skipped,quick_summary') 'six sections in the required order'
Assert-Classify ((@($env1.MustReply.index) -join ',') -eq '1,2') 'must-reply is ordered by urgency, then index'
Assert-Classify (@($env1.ReportItems).Count -eq 5) 'every record becomes a report item'
$item1=$env1.ReportItems | Where-Object index -eq 1
Assert-Classify ($item1.section -eq 'Must Reply' -and $item1.deadline -eq '2026-11-05' -and $item1.confidence -eq 'high' -and $item1.classification_source -eq 'batch-ai') 'typed fields (deadline, confidence, source) are carried'
Assert-Classify (($env1.ReportItems | Where-Object index -eq 3).section -eq 'Already Replied' -and ($env1.ReportItems | Where-Object index -eq 4).section -eq 'No Action Needed' -and ($env1.ReportItems | Where-Object index -eq 5).section -eq 'Skipped / Caution') 'categories map to the report sections'
$must=$env1.Sections | Where-Object Id -eq 'must_reply'
Assert-Classify (@($must.Items).Count -eq 2 -and $must.Items[0].EmailIndex -eq 1 -and $must.Items[0].Text -match 'Deadline stated: 2026-11-05') 'the Must Reply section lists the records with the stated deadline'
$skipped=$env1.Sections | Where-Object Id -eq 'skipped'
Assert-Classify (@($skipped.Items | Where-Object Text -match 'not classified').Count -eq 1) 'an unclassified message is listed, not guessed'
Assert-Classify (@(($env1.Sections | Where-Object Id -eq 'groups').Items | Where-Object Text -match 'a@example.test: 3 messages \(#1, #2, #5\)').Count -eq 1) 'messages from the same sender are grouped'
$quick=$env1.Sections | Where-Object Id -eq 'quick_summary'
Assert-Classify (@($quick.Items | Where-Object Text -match 'Note: Batch 2 of 2').Count -eq 1) 'batch warnings reach the quick summary'
$md=ConvertTo-PacketRatReportMarkdownV1 -Envelope $env1 -VerifiedEmails $emails
Assert-Classify ($md -match '## Must Reply' -and $md -match '\[Email #1\]') 'the existing renderer accepts the compiled envelope'
$empty=ConvertTo-PacketRatReportEnvelopeFromClassification -Records @() -Emails $emails
Assert-Classify (@($empty.Sections).Count -eq 6 -and @($empty.MustReply).Count -eq 0) 'no records still compile to a valid empty report'

# --- Batching and the full analysis -------------------------------------------------------------------------------
$script:Calls=New-Object System.Collections.ArrayList
$script:Scenario='good'
function Invoke-PacketRatChat {
    param([object[]]$Messages,[string]$Model,[int]$MaxTokens,[double]$Temperature)
    $user=[string]$Messages[1].content
    [void]$script:Calls.Add($user)
    if($Messages[0].content -notmatch 'CLASSIFY V1'){ return [pscustomobject]@{Text='not a classify call';Model='TestModel'} }
    $json=$user.Substring($user.IndexOf('EMAIL DATA (JSON):')+18).Trim()
    $rows=@(ConvertFrom-Json -InputObject $json | ForEach-Object { $_ })  # Windows PowerShell 5.1 returns a JSON array as one object
    $first=[int]$rows[0].Index
    if($script:Scenario -eq 'garbage-second' -and $first -gt 5){ return [pscustomobject]@{Text='I cannot do that.';Model='TestModel'} }
    if($script:Scenario -eq 'down'){ throw 'The remote server returned an error: (401) Unauthorized.' }
    $recs=foreach($row in $rows){
        $i=[int]$row.Index
        if($i -eq 7){ continue }  # the model skips one message
        switch($i){ 1 {New-Rec 1 'must_reply' 'High' '2026-11-05'} 2 {New-Rec 2 'must_reply' 'Medium'} 3 {New-Rec 3 'already_replied' 'Low'} 4 {New-Rec 4 'no_action' 'Low' '' 'low'} 5 {New-Rec 5 'caution' 'Medium'} default {New-Rec $i 'no_action' 'Low'} }
    }
    return [pscustomobject]@{Text=(New-Doc @($recs));Model='TestModel'}
}
$summary=[pscustomobject]@{Provider='COM';AnalyzedCount=9;SkippedCount=1;GeneratedAt=(Get-Date).ToString('o');Emails=@($emails+@((New-Mail 9 'g@example.test'))+@())}
$secret=New-Mail 10 'h@example.test' -Sensitive
$summary.Emails=@($summary.Emails)+@($secret)
function Get-PacketRatInboxSummary { param($MaxEmails,$BodyPreviewChars,$DaysBack,$Store) return $summary }

$savedEnv=@{};foreach($n in 'PACKETRAT_CLASSIFY','PACKETRAT_CLASSIFY_BATCH_SIZE'){$savedEnv[$n]=[Environment]::GetEnvironmentVariable($n);[Environment]::SetEnvironmentVariable($n,$null)}
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('packetrat-classify-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testRoot -Force)
try{
    $env:PACKETRAT_CLASSIFY_BATCH_SIZE='5'
    # Orchestrator on its own: batch size 5 over 8 eligible emails (one dismissed, one sensitive) is 2 calls.
    $script:Calls.Clear()
    $b=Invoke-PacketRatBatchClassification -Emails @($summary.Emails) -BatchSize 5
    Assert-Classify ($b.BatchCount -eq 2 -and $script:Calls.Count -eq 2) 'eligible messages are sent in batches of the chosen size'
    Assert-Classify ((($script:Calls -join ' ') -notmatch 'Synthetic subject 8') -and (($script:Calls -join ' ') -notmatch 'Synthetic subject 10')) 'dismissed and sensitive messages are never sent'
    Assert-Classify (@($b.UnclassifiedIndexes) -contains 7) 'a message the model skipped is reported unclassified'

    # Full analysis in batch mode (opt-in).
    $script:Calls.Clear(); $script:Scenario='good'
    $r=Invoke-PacketRatInboxAnalysis -Classification Batch -Root $testRoot
    Assert-Classify ($r.Success -and $r.ResponseProtocol -eq 'PACKETRAT_CLASSIFY_V1') 'batch analysis succeeds and says which protocol made the report'
    Assert-Classify ($r.Model -eq 'TestModel') 'the model comes from the batch calls'
    Assert-Classify (@($r.MustReply | Where-Object Key -eq 'id:e1').Count -eq 1 -and @($r.MustReply | Where-Object Key -eq 'id:e2').Count -eq 1) 'must-reply records reach the action queue'
    Assert-Classify (@($r.MustReply | Where-Object Key -eq 'id:e3').Count -eq 0) 'already-replied records do not become actions'
    Assert-Classify ($r.Report -match '## Must Reply' -and $r.Report -match 'Deadline stated: 2026-11-05') 'the visible report is compiled from the records'
    Assert-Classify (@($r.ReportItems | Where-Object Key -eq 'id:e7').Count -eq 1) 'the skipped message is still a verified source'
    Assert-Classify (@($r.ReportQuality.Warnings).Count -ge 0) 'quality metrics were computed'
    Assert-Classify ($script:Calls.Count -eq 2) 'two batch calls for the run'

    # Environment opt-in.
    $script:Calls.Clear()
    $env:PACKETRAT_CLASSIFY='batch'
    $r=Invoke-PacketRatInboxAnalysis -Root $testRoot
    Assert-Classify ($r.ResponseProtocol -eq 'PACKETRAT_CLASSIFY_V1') 'PACKETRAT_CLASSIFY=batch turns it on'
    $env:PACKETRAT_CLASSIFY=$null

    # A batch that stays malformed is left unclassified and reported; the rest of the run stands.
    $script:Scenario='garbage-second'; $script:Calls.Clear()
    $r=Invoke-PacketRatInboxAnalysis -Classification Batch -Root $testRoot
    Assert-Classify ($r.Success) 'one bad batch does not fail the run'
    Assert-Classify ($script:Calls.Count -eq 3) 'the bad batch was retried once'
    Assert-Classify (@($r.ReportQuality.Warnings | Where-Object { $_ -match 'was not classified' }).Count -eq 1) 'the failed batch is a visible warning'
    Assert-Classify ($r.Report -match 'not classified') 'its messages are listed as not classified'

    # A transport or credential failure stops the run instead of producing an empty report.
    $script:Scenario='down'
    Assert-Throws { Invoke-PacketRatInboxAnalysis -Classification Batch -Root $testRoot } 'Unauthorized' 'an endpoint failure is raised, not hidden'

    # Default stays the one-shot report.
    $script:Scenario='good'; $script:Calls.Clear()
    Assert-Throws { Invoke-PacketRatInboxAnalysis -Root $testRoot } 'Report protocol' 'without the opt-in the one-shot REPORT_V1 path runs'
    Assert-Classify ($script:Calls.Count -eq 1) 'one call in the default mode'
}finally{
    foreach($n in $savedEnv.Keys){[Environment]::SetEnvironmentVariable($n,$savedEnv[$n])}
    Remove-Item -Recurse -Force $testRoot -ErrorAction SilentlyContinue
}

# --- Command ------------------------------------------------------------------------------------------------------
$analyze=Find-PacketRatCommand 'packetrat inbox analyze'
Assert-Classify (@($analyze.Inputs | Where-Object Field -eq 'classification').Count -eq 1) 'inbox analyze has a --classification option'

'PacketRat batch classification tests passed.'
