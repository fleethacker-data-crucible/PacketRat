#requires -Version 5.1
# Offline tests for the Bridge spoken briefing (no AI, no Outlook). Synthetic queue only.
$ErrorActionPreference='Stop'
$Root=Split-Path $PSScriptRoot -Parent
foreach($name in @('LazaretteBridge','PacketRatLogging','PacketRatLifecycle','PacketRatLlm','PacketRatStore','PacketRatUsage','PacketRatAssistant','PacketRatRules','PacketRatProtocol','PacketRatReport','Get-OutlookMailSummary','PacketRatGraph','PacketRatDraft','PacketRatApi','PacketRatCommands')){
    . (Join-Path $Root "Private\$name.ps1")
}
function Assert-Bridge([bool]$Pass,[string]$Message){if(-not $Pass){throw ('Bridge test failed: '+$Message)}}
# Invoke-PacketRatApi has no -Root parameter: it reads $Root from the caller's scope, so scope it here (the repo's own Logs store is never touched).
function Invoke-ApiAt([string]$Dir,[string]$Route,$Data){ $Root=$Dir; Invoke-PacketRatApi -Route $Route -Data $Data }
function New-Item1([string]$Key,[string]$Urgency,[string]$Subject,[string]$From,[string]$Status='open'){[pscustomobject]@{Key=$Key;Urgency=$Urgency;Subject=$Subject;From=$From;Status=$Status}}

$empty=Get-PacketRatSpokenBriefing -Store ([pscustomobject]@{Checklist=@()})
Assert-Bridge ($empty.openCount -eq 0 -and $empty.say -match 'all quiet') 'an empty queue is reported calmly'

$store=[pscustomobject]@{Checklist=@(
    (New-Item1 'k1' 'Low' 'Newsletter sign-off' 'Pat Example')
    (New-Item1 'k2' 'High' 'Approve **budget** https://example.test/x by Nov 5' 'Dana Example')
    (New-Item1 'k3' 'Medium' 'Send figures' 'Riley Sample')
    (New-Item1 'k4' 'High' 'Sign the form' 'Sam Sample')
    (New-Item1 'k5' 'High' 'Done already' 'Zed Example' 'done')
    (New-Item1 'k6' 'High' 'Dismissed one' 'Zed Example' 'dismissed')
)}
$b=Get-PacketRatSpokenBriefing -Store $store
Assert-Bridge ($b.schema -eq 'packetrat.briefing/1' -and $b.openCount -eq 4 -and $b.highCount -eq 2) 'only open items count'
Assert-Bridge (@($b.items).Count -eq 3 -and $b.items[0].urgency -eq 'High' -and $b.items[2].key -eq 'k3') 'top three, high first'
Assert-Bridge ($b.say -match '^Bridge, you have 4 open actions, 2 high priority\.' -and $b.say -match '1 more in the queue') 'opening line and the rest'
Assert-Bridge ($b.say -notmatch '[\*|<>\[\]]' -and $b.say -notmatch 'https?:' -and $b.say -match 'Approve budget link by Nov 5') 'spoken text has no Markdown or raw links'
$one=Get-PacketRatSpokenBriefing -Store ([pscustomobject]@{Checklist=@((New-Item1 'a' 'Low' 'Only one' ''))})
Assert-Bridge ($one.say -match '1 open action,' -and $one.say -match 'Number 1, low priority: Only one\.') 'singular and a missing sender'

Assert-Bridge ($null -ne (Find-PacketRatCommand 'assist brief')) 'assist brief is a command'
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('packetrat-bridge-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory $tmp)
try{
    Save-PacketRatStore -Store (Get-PacketRatStore -Root $tmp) -Root $tmp
    $r=Invoke-ApiAt $tmp '/api/assist/brief' $null
    Assert-Bridge ($r.ok -and $r.briefing.say -match 'all quiet') 'the API route returns the briefing'
}finally{Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue}
'Bridge tests passed.'
