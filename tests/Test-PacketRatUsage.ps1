#requires -Version 5.1
# Offline tests for the minutes-saved counter: counting, the editable minutes config, stats, raw export, reset, and the
# API routes. Outlook and the AI are faked; a temp root is used so the real store is never touched. Synthetic data only.
$ErrorActionPreference='Stop'
$Root=Split-Path $PSScriptRoot -Parent
foreach($name in @('LazaretteBridge','PacketRatLogging','PacketRatLifecycle','PacketRatLlm','PacketRatStore','PacketRatUsage','PacketRatRules','PacketRatProtocol','PacketRatReport','Get-OutlookMailSummary','PacketRatGraph','PacketRatDraft','PacketRatApi','PacketRatCommands')){
    . (Join-Path $Root "Private\$name.ps1")
}
. (Join-Path $Root 'Public\Invoke-PacketRatInboxAnalysis.ps1')
function Assert-Usage([bool]$Pass,[string]$Message){if(-not $Pass){throw ('Usage test failed: '+$Message)}}
# Invoke-PacketRatApi has no -Root parameter: it reads $Root from the caller's scope, so scope it here (the repo's own Logs store is never touched).
function Invoke-ApiAt([string]$Dir,[string]$Route,$Data){ $Root=$Dir; Invoke-PacketRatApi -Route $Route -Data $Data }

# The counts export is documented in docs\COUNTS-EXPORT.md; the real export is checked against that page (fields, types, actions).
$exportDoc=[IO.File]::ReadAllText((Join-Path $Root 'docs\COUNTS-EXPORT.md'))
function Get-DocTableRows([string]$Heading){
    $m=[regex]::Match($exportDoc,'(?ms)^## '+[regex]::Escape($Heading)+'\s*$(.*?)(?=^## |\z)')
    Assert-Usage $m.Success "docs\COUNTS-EXPORT.md has a '$Heading' section"
    @([regex]::Matches($m.Groups[1].Value,'(?m)^\| `([A-Za-z]+)` \| (.+?) \|\s*$') | ForEach-Object { [pscustomobject]@{Name=$_.Groups[1].Value;Text=$_.Groups[2].Value} })
}
function Assert-ExportMatchesDoc($Export,[string]$Where){
    $fields=Get-DocTableRows 'Fields'
    Assert-Usage ($fields.Count -eq 5) 'the documented fields are listed'
    $keys=@($Export.Keys)
    Assert-Usage ((@($keys | Sort-Object) -join ',') -eq (@($fields.Name | Sort-Object) -join ',')) "$Where has exactly the documented fields"
    foreach($f in $fields){
        $type=($f.Text -split ' \| ')[0]
        $v=$Export[$f.Name]
        $ok=switch($type){ 'string'{$v -is [string]} 'boolean'{$v -is [bool]} 'object'{$v -is [System.Collections.IDictionary] -or $v -is [pscustomobject]} default{$false} }
        Assert-Usage $ok "$Where field '$($f.Name)' is documented as $type"
    }
    Assert-Usage ($Export.schema -eq 'packetrat.usage-counts/1' -and $Export.estimate -eq $true) "$Where carries the documented schema and estimate flag"
    foreach($t in 'since','exportedAt'){
        $d=[datetimeoffset]::MinValue
        Assert-Usage (($t -eq 'since' -and $Export.since -eq '') -or [datetimeoffset]::TryParse([string]$Export[$t],[ref]$d)) "$Where $t is an ISO 8601 time"
    }
    $actions=Get-DocTableRows 'Counts'
    $names=@($Export.counts.Keys); if(-not $names){$names=@($Export.counts.PSObject.Properties.Name)}
    Assert-Usage ((@($names | Sort-Object) -join ',') -eq (@($actions.Name | Sort-Object) -join ',')) "$Where counts hold exactly the documented actions"
    foreach($a in $actions){
        Assert-Usage ($script:PacketRatUsageActions[$a.Name] -eq $a.Text) "documented label for '$($a.Name)' matches the app"
        $n=$Export.counts[$a.Name]; if($null -eq $n){$n=$Export.counts.PSObject.Properties[$a.Name].Value}
        Assert-Usage (($n -is [int]) -and $n -ge 0) "$Where count '$($a.Name)' is a whole number of 0 or more"
    }
}

$tmp=Join-Path ([IO.Path]::GetTempPath()) ('packetrat-usage-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path (Join-Path $tmp 'Config') -Force)
try{
    # --- Shipped config ---------------------------------------------------------------------------------------------
    $shipped=[IO.File]::ReadAllText((Join-Path $Root 'Config\minutes-saved.json')) | ConvertFrom-Json
    Assert-Usage ($shipped.note -match 'ESTIMATE') 'the shipped config says it is an estimate'
    $mins=Get-PacketRatUsageMinutes -Root $Root
    Assert-Usage ($mins.drafts -eq 6 -and $mins.triaged -eq 0.5) 'the shipped file supplies the default minutes'

    # --- Empty store ------------------------------------------------------------------------------------------------
    $s0=Get-PacketRatUsageStats -Root $tmp
    Assert-Usage ($s0.schema -eq 'packetrat.stats/1' -and $s0.estimate -eq $true -and $s0.totalMinutes -eq 0 -and $s0.totalActions -eq 0) 'a fresh store reports zero'
    Assert-Usage (@($s0.actions).Count -eq 8 -and $s0.note -match 'Estimate, not a measurement' -and $s0.note -match 'not a performance score') 'every action is listed and the estimate is labelled'

    # --- Counting and the minutes math -------------------------------------------------------------------------------
    [IO.File]::WriteAllText((Join-Path $tmp 'Config\minutes-saved.json'),'{"minutesPerAction":{"triaged":1,"drafts":10,"reports":20,"archived":2,"moved":2,"categorized":1,"markedRead":0.5,"dismissed":1}}')
    $store=Get-PacketRatStore -Root $tmp
    Save-PacketRatStore -Store $store -Root $tmp
    Assert-Usage (Add-PacketRatUsage -Action triaged -Count 12 -Root $tmp) 'triaged is counted'
    $null=Add-PacketRatUsage -Action drafts -Root $tmp; $null=Add-PacketRatUsage -Action drafts -Root $tmp
    $null=Add-PacketRatUsage -Action reports -Root $tmp
    $null=Add-PacketRatUsage -Action markedRead -Count 4 -Root $tmp
    Assert-Usage (-not (Add-PacketRatUsage -Action nonsense -Root $tmp)) 'an unknown action is refused, not stored'
    Assert-Usage (-not (Add-PacketRatUsage -Action triaged -Count 0 -Root $tmp)) 'a zero count is ignored'
    $s=Get-PacketRatUsageStats -Root $tmp
    Assert-Usage ($s.totalActions -eq 19) 'total actions'
    Assert-Usage ($s.totalMinutes -eq (12*1+2*10+1*20+4*0.5)) 'total minutes use the edited config (12 + 20 + 20 + 2 = 54)'
    $row=$s.actions | Where-Object id -eq 'drafts'
    Assert-Usage ($row.count -eq 2 -and $row.minutesEach -eq 10 -and $row.minutes -eq 20) 'per-action breakdown'
    $store=Get-PacketRatStore -Root $tmp
    Assert-Usage (@($store.Rules).Count -gt 0 -and $store.Usage.Counts.triaged -eq 12) 'counts live in the existing store beside the rules'

    # --- Config hardening ------------------------------------------------------------------------------------------
    [IO.File]::WriteAllText((Join-Path $tmp 'Config\minutes-saved.json'),'{"minutesPerAction":{"triaged":-5,"drafts":99999,"reports":"abc"}}')
    $m=Get-PacketRatUsageMinutes -Root $tmp
    Assert-Usage ($m.triaged -eq 0 -and $m.drafts -eq 240 -and $m.reports -eq 10) 'values are clamped to 0-240 and bad ones fall back to the default'
    [IO.File]::WriteAllText((Join-Path $tmp 'Config\minutes-saved.json'),'{not json')
    $m=Get-PacketRatUsageMinutes -Root $tmp 3>$null
    Assert-Usage ($m.drafts -eq 6) 'a broken config falls back to defaults instead of failing'
    Remove-Item (Join-Path $tmp 'Config\minutes-saved.json')
    Assert-Usage ((Get-PacketRatUsageMinutes -Root $tmp).drafts -eq 6) 'a missing config falls back to defaults'

    # --- Raw export: counts only --------------------------------------------------------------------------------------
    $x=Get-PacketRatUsageExport -Root $tmp
    $json=$x | ConvertTo-Json -Depth 5
    Assert-Usage ($x.schema -eq 'packetrat.usage-counts/1' -and $x.counts.triaged -eq 12 -and $x.counts.markedRead -eq 4) 'export carries the raw counts'
    Assert-Usage ($json -notmatch 'minutes' -and $json -notmatch '@') 'export holds no minutes and no message data'

    # --- The export matches the documented format ------------------------------------------------------------------------
    Assert-ExportMatchesDoc $x 'the export'
    $ex=[regex]::Match($exportDoc,'(?s)```json
?
(.*?)```').Groups[1].Value | ConvertFrom-Json
    Assert-Usage ($null -ne $ex.counts) 'the documented example parses'
    Assert-ExportMatchesDoc ([ordered]@{schema=$ex.schema;estimate=$ex.estimate;since=$ex.since;exportedAt=$ex.exportedAt;counts=$ex.counts}) 'the documented example'
    $fresh=Join-Path $tmp 'fresh'; [void](New-Item -ItemType Directory -Path $fresh -Force)
    $x0=Get-PacketRatUsageExport -Root $fresh
    Assert-Usage ($x0.since -eq '') 'an export before anything is counted has an empty since'
    Assert-ExportMatchesDoc $x0 'a fresh-store export'

    # --- Corrupt counts do not break stats -------------------------------------------------------------------------------
    $store=Get-PacketRatStore -Root $tmp; $store.Usage.Counts.triaged=-7; Save-PacketRatStore -Store $store -Root $tmp
    Assert-Usage ((Get-PacketRatUsageStats -Root $tmp).actions[0].count -eq 0) 'a negative stored count reads as zero'

    # --- API routes: counting happens where the action happens ---------------------------------------------------------------
    $null=Invoke-ApiAt $tmp '/api/stats/reset' ([pscustomobject]@{})
    $mail=[pscustomobject]@{Index=1;Fingerprint='id:e1';EntryID='E1';Subject='Synthetic';FromName='A';FromEmail='a@example.test';UserDismissed=$false;IsSensitive=$false;InternetMessageId=''}
    function Invoke-PacketRatInboxAnalysis { param($Profile,$Provider,$MaxEmails,$DaysBack,$Root,$Classification)
        [pscustomobject]@{Success=$true;AnalyzedCount=7;Provider='COM';Report='r';Summary=[pscustomobject]@{Emails=@($mail)};ReportItems=@([pscustomobject]@{Key="id:e1"});MustReply=@();ResponseProtocol='X'} }
    function Get-PacketRatLlmAuthToken { param($Config) return '' }
    function Invoke-PacketRatReportFollowup { param($Analysis,$Mode,$SectionId,$Profile) return [pscustomobject]@{Text='generated'} }
    function New-PacketRatDraftReply { param($Email,$Profile,$ExtraInstruction) return [pscustomobject]@{Subject='s';Body='b'} }
    function Set-PacketRatMailRead { param($EntryID,[switch]$Unread) }
    function Set-PacketRatMailCategory { param($EntryID,$Category) }
    function Move-PacketRatMailToFolder { param($EntryID,$FolderName) }
    function Move-PacketRatMailToArchive { param($EntryID) }
    $call={param($route,$data) Invoke-ApiAt $tmp $route ([pscustomobject]$data)}
    $null=& $call '/api/analyze' @{provider='COM';maxEmails=40;daysBack=14;profile='AiEndpoint'}
    $null=& $call '/api/report/generate' @{mode='Brief'}
    $null=& $call '/api/draft' @{key='id:e1'}
    $null=& $call '/api/item/mark-read' @{key='id:e1'}
    $null=& $call '/api/item/categorize' @{key='id:e1';category='Follow up'}
    $null=& $call '/api/item/move' @{key='id:e1';folder='Done'}
    $null=& $call '/api/item/archive' @{key='id:e1'}
    $c=(& $call '/api/stats/export' @{}).usage.counts
    Assert-Usage ($c.triaged -eq 7) 'analysis counts the messages triaged'
    Assert-Usage ($c.reports -eq 2) 'the analysis report and a generated brief are both counted'
    Assert-Usage ($c.drafts -eq 1 -and $c.markedRead -eq 1 -and $c.categorized -eq 1 -and $c.moved -eq 1 -and $c.archived -eq 1) 'draft and each inbox action are counted once'
    Assert-ExportMatchesDoc (& $call '/api/stats/export' @{}).usage 'the API route'
    $failed=$false
    try{ $null=& $call '/api/item/mark-read' @{key='id:unknown'} }catch{ $failed=$true }
    Assert-Usage ($failed -and (& $call '/api/stats/export' @{}).usage.counts.markedRead -eq 1) 'an action that fails is not counted'
    $st=(& $call '/api/stats' @{}).stats
    Assert-Usage ($st.estimate -eq $true -and $st.totalActions -eq 14) '/api/stats returns the estimate'
    $null=& $call '/api/stats/reset' @{}
    Assert-Usage ((& $call '/api/stats' @{}).stats.totalActions -eq 0) 'reset zeroes the counters'

    # --- CLI parity --------------------------------------------------------------------------------------------------
    foreach($n in 'stats show','stats export','stats reset'){ Assert-Usage ($null -ne (Find-PacketRatCommand $n)) "command '$n' exists" }
    Assert-Usage ((Find-PacketRatCommand 'stats reset').Destructive) 'stats reset needs --yes'
    $cli=Join-Path $PSScriptRoot '..' | Join-Path -ChildPath 'Invoke-PacketRatCli.ps1'
    $ErrorActionPreference='Continue'
    $out=& powershell.exe -NoProfile -NoLogo -ExecutionPolicy Bypass -File $cli stats --dry-run --json 2>$null
    $ErrorActionPreference='Stop'
    Assert-Usage ($LASTEXITCODE -eq 0 -and (($out -join "`n") | ConvertFrom-Json).route -eq '/api/stats') 'bare "stats" runs stats show'
    Write-Host 'Usage tests passed.'
}finally{
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
