#requires -Version 5.1
# Offline, deterministic AI protocol and Outlook HTML signature tests.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Private/MailHawkProtocol.ps1')
. (Join-Path $root 'Private/MailHawkDraft.ps1')
. (Join-Path $root 'Private/Get-OutlookMailSummary.ps1')
function Assert-Protocol([bool]$Pass,[string]$Message){if(-not $Pass){throw ('Protocol test failed: '+$Message)}}
function Expect-ProtocolError([scriptblock]$Work,[string]$Message){
    $rejected=$false
    try{& $Work}catch{$rejected=$true}
    Assert-Protocol $rejected $Message
}
$validDraft=@'
<<<MAILHAWK_DRAFT_V1>>>
<<<SUBJECT>>>
RE: Access workflow
<<<END_SUBJECT>>>
<<<BODY>>>
Thank you for your message.

I will review the request and confirm the next steps.
<<<END_BODY>>>
<<<END_MAILHAWK_DRAFT_V1>>>
'@
$one=ConvertFrom-MailHawkDraftV1 -Text $validDraft
Assert-Protocol ($one.Version -eq 'MAILHAWK_DRAFT_V1') 'Version known'
Assert-Protocol ($one.Subject -eq 'RE: Access workflow') 'Subject split'
Assert-Protocol ($one.Body -match 'confirm the next steps') 'Body split'
Assert-Protocol ($one.Body -notmatch '<<<') 'No delimiters leak into body'
Expect-ProtocolError {ConvertFrom-MailHawkDraftV1 -Text ($validDraft+"`n"+$validDraft)} 'Duplicate replies rejected'
Expect-ProtocolError {ConvertFrom-MailHawkDraftV1 -Text $validDraft.Replace('<<<END_BODY>>>','<<<NOT_THE_END>>>')} 'Missing terminator rejected'
Expect-ProtocolError {ConvertFrom-MailHawkDraftV1 -Text '{"responses":[{"body":"Old style A"},{"body":"Old style B"}]}'} 'Legacy A/B JSON rejected'
Expect-ProtocolError {ConvertFrom-MailHawkDraftV1 -Text ("preamble`n"+$validDraft)} 'Unexpected preface rejected'
$inside=$validDraft.Replace('I will review',("<<<BODY>>>"+[char]10+"I will review"))
Expect-ProtocolError {ConvertFrom-MailHawkDraftV1 -Text $inside} 'Nested delimiter rejected'
$goodReport=@'
<<<MAILHAWK_REPORT_V1>>>
{"version":"MAILHAWK_REPORT_V1","must_reply":[{"index":1,"urgency":"High","why":"Needs review"}],"report_items":[{"index":1,"section":"Must Reply","reason":"A reply is requested","recommended_action":"Verify and respond","urgency":"High"}],"sections":[{"id":"categories","title":"Categories","summary":"There is one high-priority request.","items":[{"email_index":1,"text":"The user should review the email."}]},{"id":"groups","title":"Groups","summary":"","items":[]},{"id":"must_reply","title":"Must Reply","summary":"","items":[{"email_index":1,"text":"Please provide an update."}]},{"id":"already_replied","title":"Already Replied / No Action Needed","summary":"","items":[]},{"id":"skipped","title":"Skipped / Caution","summary":"","items":[]},{"id":"quick_summary","title":"Quick Summary","summary":"Confirm required action in Outlook.","items":[]}]}
<<<END_MAILHAWK_REPORT_V1>>>
'@
$report=ConvertFrom-MailHawkReportV1 -Text $goodReport -MaxSourceIndex 2
Assert-Protocol ($report.Version -eq 'MAILHAWK_REPORT_V1') 'Report version'
Assert-Protocol (@($report.Sections).Count -eq 6) 'Exactly six sections'
Assert-Protocol (@($report.MustReply).Count -eq 1) 'Structured must-reply'
$emails=@(
 [pscustomobject]@{Index=1;Fingerprint='trusted-1';UserDismissed=$false;IsSensitive=$false},
 [pscustomobject]@{Index=2;Fingerprint='restricted';UserDismissed=$false;IsSensitive=$true}
)
$compiled=ConvertTo-MailHawkReportMarkdownV1 -Envelope $report -VerifiedEmails $emails
Assert-Protocol ($compiled.Contains('[Email #1]')) 'Link to verified source'
Assert-Protocol ($compiled -notmatch '<<<|```') 'No model formatting markers in compiled report'
$fakeIndex=$goodReport.Replace('"index":1','"index":999')
Expect-ProtocolError {ConvertFrom-MailHawkReportV1 -Text $fakeIndex -MaxSourceIndex 2} 'Invalid email index rejected'
Expect-ProtocolError {ConvertFrom-MailHawkReportV1 -Text $goodReport.Replace('"version":"MAILHAWK_REPORT_V1"','"version":"V0"')} 'Unsupported schema version rejected'
Expect-ProtocolError {ConvertFrom-MailHawkReportV1 -Text $goodReport.Replace('<<<END_MAILHAWK_REPORT_V1>>>','')} 'Truncated report rejected'
$signature='<html><body class="WordSection1"><div id="signature">Authorized Outlook signature<img src="cid:logo.png"></div><blockquote>Prior email</blockquote></body></html>'
$joined=Join-MailHawkReplyHtml -ExistingHtml $signature -DraftText 'Review <this> & confirm'
Assert-Protocol ($joined.Contains('Review &lt;this&gt; &amp; confirm')) 'HTML escape message'
Assert-Protocol ($joined.Contains($signature.Substring($signature.IndexOf('<div id="signature">')))) 'Existing signature and quoted message intact'
Assert-Protocol (($joined.Split('id="signature"').Length-1) -eq 1) 'Signature not duplicated'
Assert-Protocol ($joined.IndexOf('Review &lt;this&gt;') -lt $joined.IndexOf('Authorized Outlook signature')) 'Message before Outlook signature'
function Invoke-MailHawkChat {
    param($Messages,[string]$Profile,[string]$Model,[int]$MaxTokens,[double]$Temperature)
    if($Messages[0].content -notmatch 'DRAFT V1'){throw 'Missing protocol instruction'}
    return [pscustomobject]@{Text=$validDraft;Profile='Test';Model='TestModel'}
}
$mail=[pscustomobject]@{EntryID='example';FromName='Reviewer';FromEmail='reviewer@example.test';Received='2026-10-22';Subject='Access workflow';BodyPreview='Request an update'}
$created=New-MailHawkDraftReply -Email $mail
Assert-Protocol ($created.Subject -eq 'RE: Access workflow') 'One suggested subject'
Assert-Protocol ($created.Body -eq $one.Body) 'One parsed response'
Assert-Protocol ($created.OutputTokenBudget -eq 20000) 'Requested 20k output token budget retained'
Assert-Protocol ($created.SignatureSource -eq 'OutlookReply') 'Signature delegated to Outlook'
Assert-Protocol (-not $created.PSObject.Properties['Options']) 'Never return A/B options'
Write-Host 'MailHawk strict protocol, single draft and Outlook signature HTML tests passed' -ForegroundColor Green
