#requires -Version 5.1
# Offline tests for the optional Microsoft Graph provider and for opening Graph mail in classic Outlook.
# Graph cmdlets and the Outlook object model are replaced by fakes: no sign-in, no mailbox, no network, synthetic data.
$ErrorActionPreference='Stop'
$Root=Split-Path $PSScriptRoot -Parent
foreach($name in @('LazaretteBridge','PacketRatLogging','PacketRatLifecycle','PacketRatLlm','PacketRatStore','PacketRatRules','PacketRatProtocol','PacketRatReport','Get-OutlookMailSummary','PacketRatGraph','PacketRatDraft','PacketRatApi','PacketRatCommands')){
    . (Join-Path $Root "Private\$name.ps1")
}
function Assert-Graph([bool]$Pass,[string]$Message){if(-not $Pass){throw ('Graph test failed: '+$Message)}}
function Assert-Throws([scriptblock]$Block,[string]$Pattern,[string]$Message){
    $threw=$null
    try{& $Block}catch{$threw=$_.Exception.Message}
    Assert-Graph ($null -ne $threw) ($Message+' (expected an error)')
    Assert-Graph ($threw -match $Pattern) ($Message+" (wrong error: $threw)")
}

# --- Connect-PacketRatGraph ---------------------------------------------------------------------------------------
$script:GraphInstalled=$false
$script:GraphContext=$null
$script:ConnectCalls=0
$script:ConnectedScopes=$null
function Test-PacketRatGraphAvailable { return $script:GraphInstalled }
function Import-Module { param([Parameter(ValueFromRemainingArguments=$true)]$Rest) }
function Get-MgContext { param([Parameter(ValueFromRemainingArguments=$true)]$Rest) return $script:GraphContext }
function Connect-MgGraph { param($Scopes,[switch]$NoWelcome) $script:ConnectCalls++; $script:ConnectedScopes=$Scopes; $script:GraphContext=[pscustomobject]@{Account='me@agency.example'} }

Assert-Throws { Connect-PacketRatGraph } 'Microsoft.Graph modules not installed' 'a missing Graph module is explained'
Assert-Graph ($script:ConnectCalls -eq 0) 'no sign-in is attempted without the module'
$script:GraphInstalled=$true
Assert-Graph ([bool](Connect-PacketRatGraph)) 'connect succeeds when the module is present'
Assert-Graph ($script:ConnectCalls -eq 1) 'connect signs in once when there is no context'
Assert-Graph (($script:ConnectedScopes -join ',') -eq 'Mail.Read,Mail.ReadWrite,User.Read') 'default scopes'
$null=Connect-PacketRatGraph
Assert-Graph ($script:ConnectCalls -eq 1) 'an existing context is reused without another sign-in'
$script:GraphContext=$null
$null=Connect-PacketRatGraph -Scopes @('Mail.Read')
Assert-Graph (($script:ConnectedScopes -join ',') -eq 'Mail.Read') 'custom scopes are honoured'

# --- Get-PacketRatInboxSummaryGraph -------------------------------------------------------------------------------
function Connect-PacketRatGraph { return $true }
function New-FakeGraphMessage([string]$Id,[string]$Subject,[string]$From,[string]$To,[string]$Preview,[bool]$IsRead=$false,[string]$Importance='normal',[string]$InternetId=''){
    [pscustomobject]@{
        Id=$Id;InternetMessageId=$InternetId;Subject=$Subject;ConversationId="conv-$Id";IsRead=$IsRead;Importance=$Importance
        BodyPreview=$Preview;ReceivedDateTime=[datetime]'2026-10-29T14:30:00'
        From=[pscustomobject]@{EmailAddress=[pscustomobject]@{Name='Sender '+$Id;Address=$From}}
        ToRecipients=@([pscustomobject]@{EmailAddress=[pscustomobject]@{Address=$To}})
    }
}
$script:GraphMessages=@()
$script:GraphCall=$null
function Get-MgUserMessage { param($UserId,$Filter,$Top,$OrderBy,$Property,$ErrorAction) $script:GraphCall=@{UserId=$UserId;Filter=$Filter;Top=$Top;OrderBy=$OrderBy;Property=$Property}; return $script:GraphMessages }

$savedMine=$env:PACKETRAT_USER_EMAIL
try{
    $env:PACKETRAT_USER_EMAIL='me@agency.example'
    $longPreview=('word ' * 100)
    $script:GraphMessages=@(
        (New-FakeGraphMessage 'g1' 'Please approve the synthetic plan' 'lead@agency.example' 'me@agency.example' 'Need your sign-off by Friday' $false 'high' '<one@mail.example>')
        (New-FakeGraphMessage 'g2' 'Weekly digest' 'news@example.com' 'list@example.com' $longPreview $true 'low' '<two@mail.example>')
        (New-FakeGraphMessage 'g3' 'Re: social security number question' 'hr@agency.example' 'me@agency.example' 'private details here' $false 'normal' '<three@mail.example>')
    )
    $store=[pscustomobject]@{Dismissals=@()}
    $s=Get-PacketRatInboxSummaryGraph -MaxEmails 25 -DaysBack 3 -BodyPreviewChars 50 -Store $store
    Assert-Graph ($s.Provider -eq 'Graph') 'provider is Graph'
    Assert-Graph ($s.AnalyzedCount -eq 2 -and $s.SkippedCount -eq 1) 'sensitive mail is skipped, the rest analyzed'
    Assert-Graph ($script:GraphCall.Top -eq 25 -and $script:GraphCall.UserId -eq 'me' -and $script:GraphCall.OrderBy -eq 'receivedDateTime desc') 'query uses me, Top and newest-first ordering'
    Assert-Graph ($script:GraphCall.Property -match 'internetMessageId') 'internetMessageId is requested'
    Assert-Graph ($script:GraphCall.Filter -match '^receivedDateTime ge \d{4}-\d{2}-\d{2}T') 'filter carries an ISO cutoff'
    $cutoff=[datetime]::Parse(($script:GraphCall.Filter -replace '^receivedDateTime ge ',''),[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    Assert-Graph ([math]::Abs(((Get-Date).AddDays(-3)-$cutoff).TotalMinutes) -lt 5) 'cutoff is DaysBack days ago'

    $one=$s.Emails | Where-Object EntryID -eq 'g1'
    Assert-Graph ($one.IsDirect) 'mail addressed to the configured user is direct'
    Assert-Graph ($one.UnRead -and $one.Importance -eq 2) 'unread and high importance map across'
    Assert-Graph ($one.InternetMessageId -eq '<one@mail.example>') 'the Internet message id is kept for opening in Outlook'
    Assert-Graph ($one.FromEmail -eq 'lead@agency.example' -and $one.Received -eq '2026-10-29 14:30') 'sender and received time'
    Assert-Graph ($one.Fingerprint -eq 'id:g1') 'fingerprint is keyed on the Graph id'
    $two=$s.Emails | Where-Object EntryID -eq 'g2'
    Assert-Graph (-not $two.IsDirect -and -not $two.UnRead -and $two.Importance -eq 0) 'digest is not direct, is read, is low importance'
    Assert-Graph ($two.BodyPreview.Length -eq 53 -and $two.BodyPreview.EndsWith('...')) 'previews are truncated to BodyPreviewChars'
    $hr=$s.Skipped | Where-Object EntryID -eq 'g3'
    Assert-Graph ($hr.IsSensitive -and $hr.BodyPreview -eq '[REDACTED - PII heuristic]') 'sensitive subject redacts the preview'
    Assert-Graph (@($s.Emails | Where-Object EntryID -eq 'g3').Count -eq 0) 'sensitive mail never reaches the AI list'

    $store2=[pscustomobject]@{Dismissals=@([pscustomobject]@{Key='id:g2';Subject='Weekly digest';From='x';Reason='r'})}
    $s2=Get-PacketRatInboxSummaryGraph -Store $store2
    Assert-Graph (($s2.Emails | Where-Object EntryID -eq 'g2').UserDismissed) 'a dismissed message is flagged'
    Assert-Graph (-not ($s2.Emails | Where-Object EntryID -eq 'g1').UserDismissed) 'others are not'

    $script:GraphMessages=@()
    $s3=Get-PacketRatInboxSummaryGraph
    Assert-Graph ($s3.AnalyzedCount -eq 0 -and @($s3.Emails).Count -eq 0) 'an empty mailbox gives an empty summary'
}finally{ $env:PACKETRAT_USER_EMAIL=$savedMine }

# --- Internet message id filter -----------------------------------------------------------------------------------
$f=New-PacketRatInternetMessageIdFilter -InternetMessageId '  <a@b.example>  '
Assert-Graph ($f -eq '@SQL="http://schemas.microsoft.com/mapi/proptag/0x1035001F" = ''<a@b.example>''') 'filter targets PR_INTERNET_MESSAGE_ID with a trimmed id'
$f=New-PacketRatInternetMessageIdFilter -InternetMessageId "<o'brien@b.example>"
Assert-Graph ($f.EndsWith("= '<o''brien@b.example>'")) 'single quotes are doubled'
Assert-Throws { New-PacketRatInternetMessageIdFilter -InternetMessageId "<a@b>`r`nx" } 'usable' 'control characters are refused'
Assert-Throws { New-PacketRatInternetMessageIdFilter -InternetMessageId 'x' } 'usable' 'too-short ids are refused'

# --- Find the same message in classic Outlook ---------------------------------------------------------------------
function New-FakeFolder([string]$Name,[hashtable]$Messages=@{},[object[]]$Sub=@()){
    $folder=[pscustomobject]@{Name=$Name;Folders=@($Sub);Restricted=(New-Object System.Collections.ArrayList)}
    $items=[pscustomobject]@{}
    $items | Add-Member -MemberType ScriptMethod -Name Restrict -Value ({ param($flt) [void]$folder.Restricted.Add($flt); $hit=$null; foreach($k in $Messages.Keys){ if($flt.Contains("'"+$k+"'")){$hit=$Messages[$k]} }
        $r=[pscustomobject]@{Count=$(if($hit){1}else{0})}; $r | Add-Member -MemberType ScriptMethod -Name GetFirst -Value ({ $hit }.GetNewClosure()); $r }.GetNewClosure())
    $folder | Add-Member -NotePropertyName Items -NotePropertyValue $items
    return $folder
}
$script:FakeDefaults=@{}
function Connect-PacketRatOutlook {
    $ns=[pscustomobject]@{}
    $ns | Add-Member -MemberType ScriptMethod -Name GetDefaultFolder -Value { param($n) if(-not $script:FakeDefaults.ContainsKey([int]$n)){throw 'no such folder'}; $script:FakeDefaults[[int]$n] }
    [pscustomobject]@{Application=[pscustomobject]@{};Namespace=$ns}
}
$deep=New-FakeFolder 'Deep' @{'<deep@mail.example>'=[pscustomobject]@{EntryID='OUTLOOK-DEEP'}}
$projects=New-FakeFolder 'Projects' @{} @($deep)
$inbox=New-FakeFolder 'Inbox' @{'<in@mail.example>'=[pscustomobject]@{EntryID='OUTLOOK-IN'}} @($projects)
$archive=New-FakeFolder 'Archive' @{'<old@mail.example>'=[pscustomobject]@{EntryID='OUTLOOK-OLD'}}
$script:FakeDefaults=@{6=$inbox;23=$archive;5=(New-FakeFolder 'Sent')}
Assert-Graph ((Find-PacketRatOutlookEntryIdByInternetMessageId '<in@mail.example>') -eq 'OUTLOOK-IN') 'found in the Inbox'
Assert-Graph ((Find-PacketRatOutlookEntryIdByInternetMessageId '<deep@mail.example>') -eq 'OUTLOOK-DEEP') 'found in an Inbox subfolder of a subfolder'
Assert-Graph ((Find-PacketRatOutlookEntryIdByInternetMessageId '<old@mail.example>') -eq 'OUTLOOK-OLD') 'found in Archive'
Assert-Graph ($null -eq (Find-PacketRatOutlookEntryIdByInternetMessageId '<nobody@mail.example>')) 'a message classic Outlook does not have returns null'
$script:FakeDefaults.Remove(23)
Assert-Graph ((Find-PacketRatOutlookEntryIdByInternetMessageId '<in@mail.example>') -eq 'OUTLOOK-IN') 'a missing Archive folder does not stop the search'

# --- Resolve-PacketRatOutlookEntryId (what /api/open and /api/open-draft call) --------------------------------------
$script:LastResult=$null
Assert-Graph ((Resolve-PacketRatOutlookEntryId ([pscustomobject]@{EntryID='COM-ID'})) -eq 'COM-ID') 'COM items keep their own EntryID'
$script:LastResult=[pscustomobject]@{Provider='COM'}
Assert-Graph ((Resolve-PacketRatOutlookEntryId ([pscustomobject]@{EntryID='COM-ID'})) -eq 'COM-ID') 'COM analysis keeps the EntryID'

$script:LastResult=[pscustomobject]@{Provider='Graph';Summary=[pscustomobject]@{Emails=@(
    [pscustomobject]@{EntryID='g1';InternetMessageId='<in@mail.example>'},
    [pscustomobject]@{EntryID='g9';InternetMessageId='<nobody@mail.example>'},
    [pscustomobject]@{EntryID='g8';InternetMessageId=''})}}
Assert-Graph ((Resolve-PacketRatOutlookEntryId ([pscustomobject]@{EntryID='g1'})) -eq 'OUTLOOK-IN') 'a queue item (Graph id only) resolves through the analysis'
Assert-Graph ((Resolve-PacketRatOutlookEntryId ([pscustomobject]@{EntryID='g1';InternetMessageId='<deep@mail.example>'})) -eq 'OUTLOOK-DEEP') 'an item that carries its own message id is used directly'
Assert-Throws { Resolve-PacketRatOutlookEntryId ([pscustomobject]@{EntryID='g9'}) } 'not in the classic Outlook profile' 'a message missing from classic Outlook is explained'
Assert-Throws { Resolve-PacketRatOutlookEntryId ([pscustomobject]@{EntryID='g8'}) } 'no Internet message id' 'a message without an Internet id is explained'
Assert-Throws { Resolve-PacketRatOutlookEntryId ([pscustomobject]@{EntryID='unknown'}) } 'no Internet message id' 'an unknown Graph id is explained'

'PacketRat Graph tests passed.'
