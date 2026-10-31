#requires -Version 5.1
# Offline tests for the human-authority statement: it is built from the command list, the promises in it are checked
# against the code, the doc stays in sync, and the API route works. No Outlook, no AI, a temp root.
$ErrorActionPreference='Stop'
$Root=Split-Path $PSScriptRoot -Parent
foreach($name in @('LazaretteBridge','PacketRatLogging','PacketRatLifecycle','PacketRatLlm','PacketRatStore','PacketRatAuthority','PacketRatUsage','PacketRatAssistant','PacketRatVoiceAssets','PacketRatRules','PacketRatProtocol','PacketRatReport','Get-OutlookMailSummary','PacketRatGraph','PacketRatDraft','PacketRatApi','PacketRatCommands')){
    . (Join-Path $Root "Private\$name.ps1")
}
function Assert-Auth([bool]$Pass,[string]$Message){if(-not $Pass){throw ('Authority test failed: '+$Message)}}
function Invoke-ApiAt([string]$Dir,[string]$Route,$Data){ $Root=$Dir; Invoke-PacketRatApi -Route $Route -Data $Data }

$a=Get-PacketRatAuthority -Root $Root
Assert-Auth ($a.schema -eq 'packetrat.authority/1' -and $a.principle -match 'person decides') 'schema and principle'

# Approval points come from the command registry.
$names=@($a.approvalPoints | ForEach-Object { $_.command })
foreach($c in @(Get-PacketRatCommandList)){
    if($c.destructive){ Assert-Auth ($names -contains $c.name.Substring(10)) ("destructive command '$($c.name)' is listed as an approval point") }
}
foreach($n in 'item archive','item move','item categorize','item mark-read','draft open','item open','rules set','stats reset','assist ask'){ Assert-Auth ($names -contains $n) "'$n' is an approval point" }
Assert-Auth (@($a.approvalPoints | Where-Object { $_.command -eq 'item archive' })[0].how -match '--yes') 'archive says it needs --yes'
Assert-Auth (@($a.neverDoes).Count -ge 5 -and (@($a.neverDoes) -join ' ') -match 'Send, forward or reply') 'the never-list is present'
Assert-Auth ((@($a.stop) -join ' ') -match 'Stop-PacketRat\.ps1' -and (@($a.stop) -join ' ') -match 'End session') 'there is a way to stop it'
Assert-Auth (@($a.monitoring).Count -ge 3) 'there is a way to watch it'

# Where mail text goes.
$saved=@{};foreach($n in 'LLM_URL','LLM_MODEL','PACKETRAT_ROUTER','PACKETRAT_FAIRLEAD_URL','PACKETRAT_AI_ENDPOINT_URL'){$saved[$n]=[Environment]::GetEnvironmentVariable($n);[Environment]::SetEnvironmentVariable($n,$null)}
try{
    $env:LLM_URL='http://127.0.0.1:1234/v1/chat/completions'
    $d=(Get-PacketRatAuthority -Root $Root).aiDestination
    Assert-Auth ($d.where -eq 'this PC') 'a loopback endpoint stays on this PC'
    $env:LLM_URL='https://ai.example.test/secret/path/v1/chat/completions'
    $d=(Get-PacketRatAuthority -Root $Root).aiDestination
    Assert-Auth ($d.where -eq 'outside this PC' -and $d.host -eq 'ai.example.test') 'a remote endpoint is called out, by host'
    Assert-Auth ((($d | ConvertTo-Json) -notmatch 'secret/path')) 'only the host is shown, not the path'
    $env:LLM_URL=$null; $env:PACKETRAT_ROUTER='fairlead'
    $d=(Get-PacketRatAuthority -Root $Root).aiDestination
    Assert-Auth ($d.where -eq 'this PC' -and $d.router -eq 'Fairlead') 'the Fairlead router on this PC is reported'
}finally{ foreach($n in $saved.Keys){[Environment]::SetEnvironmentVariable($n,$saved[$n])} }

# The promises hold in the code: no send path, no delete path.
$files=@(Get-ChildItem (Join-Path $Root 'Private'),(Join-Path $Root 'Public') -Filter *.ps1 -Recurse) + @(Get-ChildItem $Root -Filter *.ps1 -File)
$bad=@()
foreach($f in $files){
    if($f.Name -eq 'PacketRatAuthority.ps1'){ continue }
    $t=[IO.File]::ReadAllText($f.FullName)
    if($t -match '\.Send\s*\(' -or $t -match 'Send-MailMessage' -or $t -match '\.Delete\s*\(' -or $t -match 'DeletedItems' -or $t -match '\.ReplyAll\s*\(' -or $t -match '\.Forward\s*\('){ $bad+=$f.Name }
}
Assert-Auth ($bad.Count -eq 0) ("no code path sends or deletes mail (found in: $($bad -join ', '))")
$cmdNames=@(Get-PacketRatCommandList | ForEach-Object { $_.name })
Assert-Auth (@($cmdNames | Where-Object { $_ -match '\b(send|delete|forward)\b' }).Count -eq 0) 'no command is named send, delete or forward'

# The doc names every approval point and has the same never-list.
$doc=[IO.File]::ReadAllText((Join-Path $Root 'docs\HUMAN-AUTHORITY.md'))
foreach($n in $names){ Assert-Auth ($doc -match ('`'+[regex]::Escape($n)+'`')) "the doc names '$n'" }
$neverBlock=[regex]::Match($doc,'(?s)## What PacketRat never does\s*(.*?)\s*(?:These are enforced|##)').Groups[1].Value
$docNever=@($neverBlock -split "`n" | Where-Object { $_ -match '^\s*-\s' })
Assert-Auth ($docNever.Count -eq @($a.neverDoes).Count) ("the doc's never-list has the same number of items ($($docNever.Count) vs $(@($a.neverDoes).Count))")
Assert-Auth ($doc -match 'Test-PacketRatAuthority') 'the doc says a test enforces it'

# Command and API route.
$cmd=Find-PacketRatCommand 'app authority'
Assert-Auth ($null -ne $cmd -and $cmd.Method -eq 'GET' -and $cmd.Route -eq '/api/authority') 'app authority is a GET command'
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('packetrat-auth-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory $tmp)
try{
    $r=Invoke-ApiAt $tmp '/api/authority' $null
    Assert-Auth ($r.ok -and $r.authority.schema -eq 'packetrat.authority/1') 'the API route returns the statement'
}finally{ Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host 'Authority tests passed.'
