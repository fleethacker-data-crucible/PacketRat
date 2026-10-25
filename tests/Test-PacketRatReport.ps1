#requires -Version 5.1
# Offline report parsing and identity tests; no Outlook, Lazarette or LLM network access.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Private/PacketRatProtocol.ps1')
. (Join-Path $root 'Private/PacketRatReport.ps1')
. (Join-Path $root 'Private/PacketRatLlm.ps1')
. (Join-Path $root 'Public/Invoke-PacketRatInboxAnalysis.ps1')

function Assert-ReportTest($Value,[string]$Message){
    if(-not $Value){throw ('Report test failed: '+$Message)}
}
$emails=@(
    [pscustomobject]@{Index=1;Fingerprint='id:trusted1';Subject='Access approval';FromName='Reviewer';FromEmail='reviewer@navy.mil';UserDismissed=$false;IsSensitive=$false},
    [pscustomobject]@{Index=2;Fingerprint='id:trusted2';Subject='Routine digest';FromName='Digest';FromEmail='no-reply@example.com';UserDismissed=$false;IsSensitive=$false},
    [pscustomobject]@{Index=3;Fingerprint='id:restricted';Subject='Sensitive';FromName='Private';FromEmail='private@navy.mil';UserDismissed=$false;IsSensitive=$true},
    [pscustomobject]@{Index=4;Fingerprint='id:dismissed';Subject='Dismissed item';FromName='Office';FromEmail='office@navy.mil';UserDismissed=$true;IsSensitive=$false}
)
$model=@(
    [pscustomobject]@{index=1;section='Must Reply';reason='Review required';recommended_action='Respond';urgency='High';fingerprint='fake-id';entry_id='attacker-supplied'},
    [pscustomobject]@{index=2;section='No Action Needed';reason='FYI';recommended_action='';urgency='Low'},
    [pscustomobject]@{index=3;section='Must Reply';reason='Must not surface';recommended_action='Open';urgency='High'},
    [pscustomobject]@{index=4;section='Must Reply';reason='User dismissed';recommended_action='Open';urgency='High'},
    [pscustomobject]@{index=999;section='Must Reply';reason='Fabricated';recommended_action='Open';urgency='High'}
)
$items=@(Get-PacketRatVerifiedReportItems -Emails $emails -ModelItems $model -MustReply @())
Assert-ReportTest ($items.Count -eq 2) 'Only two eligible sources are returned'
Assert-ReportTest ($items[0].Key -eq 'id:trusted1') 'Model-supplied identity ignored'
Assert-ReportTest (-not $items[0].PSObject.Properties['EntryID']) 'No untrusted EntryID returned'
Assert-ReportTest ($items[1].Section -eq 'No Action Needed') 'Model category preserved only for verified index'
Assert-ReportTest ($items[0].Reason -eq 'Review required') 'Source-backed reason preserved'
$markdown=@'
## 3. Must Reply
| High | 1 | Access approval | Need response |
## 4. Already Appears Replied / No Action Needed
| High | 2 | Routine digest | FYI only |
## 6. Quick Summary
| High | 2 | Routine digest | Should not be action |
'@
$fallback=@(ConvertFrom-PacketRatMustReplyFallback -ReportText $markdown -Emails $emails)
Assert-ReportTest ($fallback.Count -eq 1) 'Only Must Reply section may feed fallback'
Assert-ReportTest ($fallback[0].Key -eq 'id:trusted1') 'Fallback resolves source via original scan'
$parts=@(Get-PacketRatReportSections -Report $markdown)
Assert-ReportTest ($parts.Count -eq 3) 'Known report sections extracted'
Assert-ReportTest ($parts[0].Id -eq 'section-0') 'Stable generated section identifier'
$clean=ConvertTo-PacketRatReadableReport -Text ("## Heading"+[char]13+[char]10+"> ## Action")
Assert-ReportTest ($clean.Contains("## Heading")) 'Report content retained'
Assert-ReportTest ($clean -notmatch '[\x00-\x08]') 'Non-printing controls are removed'
$quality=Get-PacketRatReportQuality -Report $clean -Items $items -StructuredPresent $true
Assert-ReportTest ($quality.VerifiedSources -eq 2) 'Quality counts verified sources'
$blocks=@(
    [pscustomobject]@{type='text';text='First section'},
    [pscustomobject]@{type='text';text='Second section'}
)
$allText=ConvertTo-PacketRatLlmText -Value $blocks
Assert-ReportTest ($allText.Contains('First section') -and $allText.Contains('Second section')) 'Typed GenAI parts extracted without object casts'
$gemini=[pscustomobject]@{content=[pscustomobject]@{parts=@([pscustomobject]@{text='Gemini report'})}}
Assert-ReportTest ((ConvertTo-PacketRatLlmText -Value $gemini) -eq 'Gemini report') 'Nested provider part extraction'

# Stub approved service call; ensure follow-up is scoped and read-only.
function Invoke-PacketRatChat {
    param([object[]]$Messages,[string]$Profile,[int]$MaxTokens,[double]$Temperature)
    if($Messages[1].content -notmatch 'Scope: 3. Must Reply'){throw 'Wrong section scope'}
    return [pscustomobject]@{Text='<<<MAILHAWK_INSIGHT_V1>>>'+[char]10+'{"version":"MAILHAWK_INSIGHT_V1","title":"Suggested next steps","summary":"Confirm the deadline against the source.","items":[{"email_index":1,"text":"Review the actual email."}]}' +[char]10+'<<<END_MAILHAWK_INSIGHT_V1>>>';Profile='Demo';Model='Fake'}
}
$run=[pscustomobject]@{Report=$markdown;ReportItems=$items}
$generated=Invoke-PacketRatReportFollowup -Analysis $run -Mode Actions -SectionId 'section-0' -Profile Auto
Assert-ReportTest ($generated.Content -match 'Suggested next steps') 'Scoped follow-up returned'
Assert-ReportTest ($generated.Section -eq '3. Must Reply') 'Correct section selected'
Assert-ReportTest ($generated.Version -eq 'MAILHAWK_INSIGHT_V1') 'Structured generated report contract'
Assert-ReportTest ($generated.Content -match '\[Email #1\]') 'Generated insight uses verified source reference'
Write-Host 'Report source validation, fallback and follow-up tests passed' -ForegroundColor Green
