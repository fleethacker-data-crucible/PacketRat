#requires -Version 5.1
# Offline tests for the Outlook inbox actions (archive, move, categorize, mark read) and their API routes.
# A fake Outlook object model stands in for COM: no Outlook, no mailbox, no network, synthetic data only.
$ErrorActionPreference='Stop'
$Root=Split-Path $PSScriptRoot -Parent
foreach($name in @('LazaretteBridge','PacketRatLogging','PacketRatLifecycle','PacketRatLlm','PacketRatStore','PacketRatUsage','PacketRatRules','PacketRatProtocol','PacketRatReport','Get-OutlookMailSummary','PacketRatGraph','PacketRatDraft','PacketRatApi','PacketRatCommands')){
    . (Join-Path $Root "Private\$name.ps1")
}
function Assert-Inbox([bool]$Pass,[string]$Message){if(-not $Pass){throw ('Inbox action test failed: '+$Message)}}
function Assert-Throws([scriptblock]$Block,[string]$Pattern,[string]$Message){
    $threw=$null
    try{& $Block}catch{$threw=$_.Exception.Message}
    Assert-Inbox ($null -ne $threw) ($Message+' (expected an error)')
    Assert-Inbox ($threw -match $Pattern) ($Message+" (wrong error: $threw)")
}

# --- Fake Outlook object model ------------------------------------------------------------------------------------
function New-FakeFolder([string]$Name){
    $children=@{}
    $folders=[pscustomobject]@{}
    $folders | Add-Member -MemberType ScriptMethod -Name Item -Value ({ param($n) if(-not $children.ContainsKey($n)){throw "folder $n not found"}; $children[$n] }.GetNewClosure())
    return [pscustomobject]@{Name=$Name;Items=(New-Object System.Collections.ArrayList);Children=$children;Folders=$folders;Parent=$null}
}
function New-FakeMail([string]$Id,[string]$Categories='',[bool]$UnRead=$true){
    $m=[pscustomobject]@{EntryID=$Id;Categories=$Categories;UnRead=$UnRead;Saved=0;MovedTo=$null}
    $m | Add-Member -MemberType ScriptMethod -Name Save -Value { $this.Saved++ }
    $m | Add-Member -MemberType ScriptMethod -Name Move -Value { param($f) $this.MovedTo=$f.Name; [void]$f.Items.Add($this); $this }
    return $m
}
$script:Mailbox=@{}
$script:DefaultFolders=@{}
$script:ArchiveAvailable=$true
function Connect-PacketRatOutlook {
    $ns=[pscustomobject]@{}
    $ns | Add-Member -MemberType ScriptMethod -Name GetItemFromID -Value { param($id) if($script:Mailbox.ContainsKey($id)){$script:Mailbox[$id]}else{$null} }
    $ns | Add-Member -MemberType ScriptMethod -Name GetDefaultFolder -Value { param($n) if($n -eq 23 -and -not $script:ArchiveAvailable){throw 'no archive'}; $script:DefaultFolders[[int]$n] }
    [pscustomobject]@{Application=[pscustomobject]@{};Namespace=$ns}
}
function Reset-FakeOutlook{
    $root=New-FakeFolder 'Mailbox'
    $inbox=New-FakeFolder 'Inbox'; $inbox.Parent=$root
    $archive=New-FakeFolder 'Archive'
    $script:DefaultFolders=@{6=$inbox;23=$archive}
    $script:FakeInbox=$inbox; $script:FakeArchive=$archive; $script:FakeRoot=$root
    $script:ArchiveAvailable=$true
    $script:Mailbox=@{'A1'=(New-FakeMail 'A1');'A2'=(New-FakeMail 'A2' 'Blue category');'A3'=(New-FakeMail 'A3' '' $false)}
}

# --- COM provider functions ---------------------------------------------------------------------------------------
Reset-FakeOutlook
Assert-Inbox ([bool](Move-PacketRatMailToArchive -EntryID 'A1')) 'archive returns true'
Assert-Inbox ($script:Mailbox['A1'].MovedTo -eq 'Archive') 'archive moves to the default archive folder'
Assert-Inbox ($script:FakeArchive.Items.Count -eq 1) 'archive folder holds the message'

Reset-FakeOutlook
$script:ArchiveAvailable=$false
Assert-Throws { Move-PacketRatMailToArchive -EntryID 'A1' } 'No archive folder found' 'archive without an Archive folder explains itself'
Assert-Inbox ($null -eq $script:Mailbox['A1'].MovedTo) 'a failed archive moves nothing'
$script:FakeRoot.Children['Archive']=$script:FakeArchive
Assert-Inbox ([bool](Move-PacketRatMailToArchive -EntryID 'A1')) 'archive falls back to a sibling Archive folder'
Assert-Inbox ($script:Mailbox['A1'].MovedTo -eq 'Archive') 'fallback archive moved the message'

Assert-Throws { Move-PacketRatMailToArchive -EntryID 'missing' } 'Mail item not found' 'unknown EntryID is reported'

Reset-FakeOutlook
$projects=New-FakeFolder 'Projects'
$script:FakeInbox.Children['Projects']=$projects
Assert-Inbox ([bool](Move-PacketRatMailToFolder -EntryID 'A2' -FolderName 'Projects')) 'move to an inbox subfolder'
Assert-Inbox ($script:Mailbox['A2'].MovedTo -eq 'Projects') 'message landed in the named folder'
Assert-Throws { Move-PacketRatMailToFolder -EntryID 'A1' -FolderName 'Nope' } "Folder 'Nope' not found" 'move to a missing folder reports it'
Assert-Inbox ($null -eq $script:Mailbox['A1'].MovedTo) 'a failed move moves nothing'

Reset-FakeOutlook
Assert-Inbox ([bool](Set-PacketRatMailCategory -EntryID 'A2' -Category 'PacketRat')) 'categorize returns true'
Assert-Inbox ($script:Mailbox['A2'].Categories -eq 'Blue category; PacketRat') 'category is appended to existing ones'
Assert-Inbox ($script:Mailbox['A2'].Saved -eq 1) 'categorize saves once'
$null=Set-PacketRatMailCategory -EntryID 'A2' -Category 'PacketRat'
Assert-Inbox ($script:Mailbox['A2'].Saved -eq 1 -and $script:Mailbox['A2'].Categories -eq 'Blue category; PacketRat') 'an existing category is not duplicated or re-saved'
$null=Set-PacketRatMailCategory -EntryID 'A1' -Category 'First'
Assert-Inbox ($script:Mailbox['A1'].Categories -eq 'First') 'category on an uncategorized message'
Assert-Throws { Set-PacketRatMailCategory -EntryID 'A1' -Category 'a;b' } 'semicolons' 'semicolons are refused'
Assert-Throws { Set-PacketRatMailCategory -EntryID 'A1' -Category ('x'*256) } '255' 'over-long categories are refused'

Reset-FakeOutlook
$null=Set-PacketRatMailRead -EntryID 'A1'
Assert-Inbox ($script:Mailbox['A1'].UnRead -eq $false -and $script:Mailbox['A1'].Saved -eq 1) 'mark read'
$null=Set-PacketRatMailRead -EntryID 'A3' -Unread
Assert-Inbox ($script:Mailbox['A3'].UnRead -eq $true) 'mark unread'

# --- API routes ---------------------------------------------------------------------------------------------------
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('packetrat-inbox-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testRoot -Force)
$savedRoot=$Root
try{
    $Root=$testRoot
    Reset-FakeOutlook
    $script:FakeInbox.Children['Projects']=(New-FakeFolder 'Projects')
    $script:LastResult=$null
    $script:Presence=$null
    $store=Get-PacketRatStore -Root $Root
    $store.Checklist=@(
        [pscustomobject]@{Key='k-one';EntryID='A1';Subject='Synthetic request one';From='Reviewer';Why='Needs a reply';Urgency='High';Status='open';LastSeen='';Notes=''},
        [pscustomobject]@{Key='k-two';EntryID='';Subject='No Outlook id';From='Digest';Why='n/a';Urgency='Low';Status='open';LastSeen='';Notes=''}
    )
    Save-PacketRatStore -Store $store -Root $Root

    $r=Invoke-PacketRatApi -Route '/api/item/mark-read' -Data ([pscustomobject]@{key='k-one'})
    Assert-Inbox ($r.ok -and $script:Mailbox['A1'].UnRead -eq $false) 'mark-read route marks read'
    $r=Invoke-PacketRatApi -Route '/api/item/mark-read' -Data ([pscustomobject]@{key='k-one';unread=$true})
    Assert-Inbox ($script:Mailbox['A1'].UnRead -eq $true) 'mark-read route with unread=true'

    $r=Invoke-PacketRatApi -Route '/api/item/categorize' -Data ([pscustomobject]@{key='k-one';category='Follow up'})
    Assert-Inbox ($r.ok -and $script:Mailbox['A1'].Categories -eq 'Follow up') 'categorize route'
    Assert-Throws { Invoke-PacketRatApi -Route '/api/item/categorize' -Data ([pscustomobject]@{key='k-one';category='a;b'}) } 'no semicolons' 'categorize route rejects semicolons'
    Assert-Throws { Invoke-PacketRatApi -Route '/api/item/categorize' -Data ([pscustomobject]@{key='k-one';category=''}) } '1-255' 'categorize route rejects an empty name'

    $r=Invoke-PacketRatApi -Route '/api/item/move' -Data ([pscustomobject]@{key='k-one';folder='Projects'})
    Assert-Inbox ($r.ok -and $script:Mailbox['A1'].MovedTo -eq 'Projects') 'move route'
    Assert-Throws { Invoke-PacketRatApi -Route '/api/item/move' -Data ([pscustomobject]@{key='k-one';folder=''}) } '1-256' 'move route rejects an empty folder'

    Reset-FakeOutlook
    $r=Invoke-PacketRatApi -Route '/api/item/archive' -Data ([pscustomobject]@{key='k-one'})
    Assert-Inbox ($r.ok -and $script:Mailbox['A1'].MovedTo -eq 'Archive') 'archive route moves the message'
    $after=Get-PacketRatStore -Root $Root
    Assert-Inbox (@($after.Dismissals | Where-Object {$_.Key -ceq 'k-one' -and $_.Reason -eq 'Archived'}).Count -eq 1) 'archive records an Archived dismissal'
    Assert-Inbox ((@($after.Checklist | Where-Object Key -ceq 'k-one')[0]).Status -eq 'dismissed') 'archived item leaves the open queue'

    Assert-Throws { Invoke-PacketRatApi -Route '/api/item/archive' -Data ([pscustomobject]@{key='k-two'}) } 'unavailable' 'an item without an EntryID is refused'
    Assert-Throws { Invoke-PacketRatApi -Route '/api/item/archive' -Data ([pscustomobject]@{key='unknown'}) } 'unavailable' 'an unknown key is refused'

    $script:LastResult=[pscustomobject]@{Provider='Graph'}
    foreach($route in '/api/item/archive','/api/item/move','/api/item/categorize','/api/item/mark-read'){
        Assert-Throws { Invoke-PacketRatApi -Route $route -Data ([pscustomobject]@{key='k-one';folder='Projects';category='x'}) } 'classic Outlook' "$route refuses Graph messages"
    }
}finally{
    $Root=$savedRoot
    Remove-Item -Recurse -Force $testRoot -ErrorAction SilentlyContinue
}

# --- Commands -----------------------------------------------------------------------------------------------------
foreach($n in 'packetrat item archive','packetrat item move','packetrat item categorize','packetrat item mark-read'){
    Assert-Inbox ($null -ne (Find-PacketRatCommand $n)) "$n is registered"
}
Assert-Inbox ((Find-PacketRatCommand 'packetrat item archive').Destructive) 'archive needs --yes'
Assert-Inbox ((Find-PacketRatCommand 'packetrat item move').Destructive) 'move needs --yes'

'PacketRat inbox action tests passed.'
