#requires -Version 5.1
# Offline tests for the Halyard hand-off: a tracked action becomes a candidate backlog item file. A temp root is used so the
# real Logs\ is never touched. No Outlook, mailbox, Halyard or network; synthetic data only.
$ErrorActionPreference='Stop'
$Root=Split-Path $PSScriptRoot -Parent
foreach($name in @('PacketRatLogging','PacketRatLifecycle','PacketRatLlm','PacketRatStore','PacketRatUsage','PacketRatRules','PacketRatProtocol','PacketRatReport','Get-OutlookMailSummary','PacketRatGraph','PacketRatDraft','PacketRatHandoff','PacketRatApi','PacketRatCommands')){
    . (Join-Path $Root "Private\$name.ps1")
}
. (Join-Path $Root 'Public\Invoke-PacketRatInboxAnalysis.ps1')
function Assert-Handoff([bool]$Pass,[string]$Message){if(-not $Pass){throw ('Handoff test failed: '+$Message)}}
function Assert-Throws([scriptblock]$Block,[string]$Pattern,[string]$Message){
    $msg=$null
    try{ & $Block }catch{ $msg=$_.Exception.Message }
    Assert-Handoff ($null -ne $msg -and $msg -match $Pattern) $Message
}
# Invoke-PacketRatApi reads $Root from the caller's scope, so scope it here.
function Invoke-ApiAt([string]$Dir,[string]$Route,$Data){ $Root=$Dir; Invoke-PacketRatApi -Route $Route -Data $Data }

$tmp=Join-Path ([IO.Path]::GetTempPath()) ('packetrat-handoff-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path (Join-Path $tmp 'Config') -Force)
try{
    $key='id:syn-badge-1'
    $item=[pscustomobject]@{Key=$key;Index=1;EntryID='ENTRY-ID-SYNTHETIC-123';Subject="Renew   the building`r`nbadge";From='Alice Example';FromEmail='alice@example.test';Why='Reply by Friday.';Urgency='High';TriageSource='Manual';RuleName=''}
    $store=Get-PacketRatStore -Root $tmp
    $store=Merge-PacketRatChecklist -Store $store -Items @($item) -Root $tmp
    $store=Get-PacketRatStore -Root $tmp

    # --- The export -----------------------------------------------------------------------------------------------------------
    $r=New-PacketRatHalyardHandoff -Store $store -Key $key -Root $tmp
    $ref=(Get-PacketRatHandoffHash $key).Substring(0,12)
    Assert-Handoff ($r.File -eq ('Logs\handoff\halyard-'+$ref+'.json')) 'the file is named from a short hash of the key'
    $path=Join-Path $tmp $r.File
    Assert-Handoff (Test-Path -LiteralPath $path) 'the file is written under Logs\handoff'
    $raw=[IO.File]::ReadAllText($path)
    $bytes=[IO.File]::ReadAllBytes($path)
    Assert-Handoff (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) 'the file is UTF-8 without a BOM'
    $doc=$raw | ConvertFrom-Json
    $it=$doc.items[0]
    Assert-Handoff ($doc.schema -eq 'packetrat.halyard-handoff/1' -and $doc.source -eq 'packetrat' -and @($doc.items).Count -eq 1) 'schema, source and one item'
    Assert-Handoff ($it.sourceTitle -eq 'Renew the building badge' -and $it.title -eq 'STORY :: Renew the building badge') 'the subject is cleaned of line breaks and used in Halyard''s title pattern'
    Assert-Handoff ($it.id -eq 'STORY-renew-the-building-badge' -and $it.meta.id -eq $it.id -and $it.type -eq 'STORY') 'the id follows Halyard''s STORY-slug pattern'
    Assert-Handoff ($it.sourceKey -eq ('packetrat:'+$ref) -and $it.sourceRepository -eq 'packetrat') 'the source key is the short reference, not the message id'
    Assert-Handoff ((@($it.labels) -join ',') -eq 'halyard,source::packetrat,type::story,urgency::high') 'labels carry the urgency'
    Assert-Handoff ($it.narrative -match '## Purpose\s+Reply by Friday\.' -and $it.narrative -match '## Source') 'the narrative holds the recommended action'
    Assert-Handoff ($it.closed -eq $false -and $it.meta.state -eq 'open' -and $null -eq $it.meta.parent -and $null -eq $it.meta.points -and $null -eq $it.meta.sprint) 'open, with the hierarchy fields left null'
    Assert-Handoff ((@($it.gaps) -join ',') -eq 'parent,theme,area,points,sprint' -and $it.confidence -eq 'low') 'the gaps and low confidence say Halyard must still place it'

    # --- What never leaves -------------------------------------------------------------------------------------------------------
    foreach($forbidden in 'Alice','alice@','example.test','ENTRY-ID-SYNTHETIC',$key){
        Assert-Handoff (-not $raw.Contains($forbidden)) "the file does not contain '$forbidden'"
    }
    $long=[pscustomobject]@{Key='id:long';Index=2;EntryID='E2';Subject=('S'*300);From='B';FromEmail='b@example.test';Why=('W'*900);Urgency='Low';TriageSource='Manual';RuleName=''}
    $store=Merge-PacketRatChecklist -Store (Get-PacketRatStore -Root $tmp) -Items @($long) -Root $tmp
    $l=(New-PacketRatHalyardHandoff -Store (Get-PacketRatStore -Root $tmp) -Key 'id:long' -Root $tmp).Document.items[0]
    Assert-Handoff ($l.sourceTitle.Length -le 120 -and $l.narrative.Length -lt 800 -and $l.id.Length -le 46) 'long subjects and actions are cut'

    # --- Same action, same file; status carries over ----------------------------------------------------------------------------------
    $null=Set-PacketRatChecklistStatus -Store (Get-PacketRatStore -Root $tmp) -Key $key -Status done -Root $tmp
    $r2=New-PacketRatHalyardHandoff -Store (Get-PacketRatStore -Root $tmp) -Key $key -Root $tmp
    Assert-Handoff ($r2.File -eq $r.File -and $r2.Document.items[0].closed -eq $true -and $r2.Document.items[0].meta.state -eq 'closed') 'rewriting uses the same file and a done action is closed'
    $null=Set-PacketRatChecklistStatus -Store (Get-PacketRatStore -Root $tmp) -Key $key -Status open -Root $tmp

    # --- Refusals ---------------------------------------------------------------------------------------------------------------------
    Assert-Throws { New-PacketRatHalyardHandoff -Store (Get-PacketRatStore -Root $tmp) -Key 'id:nothing' -Root $tmp } 'No tracked action' 'an unknown key is refused'
    $null=Set-PacketRatChecklistStatus -Store (Get-PacketRatStore -Root $tmp) -Key $key -Status dismissed -Root $tmp
    Assert-Throws { New-PacketRatHalyardHandoff -Store (Get-PacketRatStore -Root $tmp) -Key $key -Root $tmp } 'dismissed' 'a dismissed action is refused'
    $null=Set-PacketRatChecklistStatus -Store (Get-PacketRatStore -Root $tmp) -Key $key -Status open -Root $tmp

    # --- The page documents the real fields ----------------------------------------------------------------------------------------------
    $page=[IO.File]::ReadAllText((Join-Path $Root 'docs\HALYARD-HANDOFF.md'))
    $top=@([regex]::Matches([regex]::Match($page,'(?ms)^Schema `packetrat\.halyard-handoff/1`\.(.*?)^Each item:').Groups[1].Value,'(?m)^\| `([A-Za-z]+)` \|') | ForEach-Object { $_.Groups[1].Value })
    $per=@([regex]::Matches([regex]::Match($page,'(?ms)^Each item:(.*?)^Example:').Groups[1].Value,'(?m)^\| `([A-Za-z]+)` \|') | ForEach-Object { $_.Groups[1].Value })
    Assert-Handoff ((($top | Sort-Object) -join ',') -eq ((@($doc.PSObject.Properties.Name) | Sort-Object) -join ',')) 'the page lists exactly the top-level fields'
    Assert-Handoff ((($per | Sort-Object) -join ',') -eq ((@($it.PSObject.Properties.Name) | Sort-Object) -join ',')) 'the page lists exactly the fields of an item'
    $ex=[regex]::Match($page,'(?s)```json\r?\n(.*?)```').Groups[1].Value | ConvertFrom-Json
    Assert-Handoff ((@($ex.items[0].PSObject.Properties.Name) -join ',') -eq (@($it.PSObject.Properties.Name) -join ',') -and (@($ex.PSObject.Properties.Name) -join ',') -eq (@($doc.PSObject.Properties.Name) -join ',')) 'the documented example has the same fields in the same order'
    Assert-Handoff ($page -match 'no reader for the file yet' -and $page -match 'never.*holds the sender') 'the page says Halyard has no reader yet and what is never included'

    # --- API route and command --------------------------------------------------------------------------------------------------------------
    $api=Invoke-ApiAt $tmp '/api/item/handoff' ([pscustomobject]@{key=$key})
    Assert-Handoff ($api.ok -eq $true -and $api.file -eq $r.File -and $api.handoff.schema -eq 'packetrat.halyard-handoff/1') 'the route returns the document and the file'
    Assert-Throws { Invoke-ApiAt $tmp '/api/item/handoff' ([pscustomobject]@{key='id:nothing'}) } 'No tracked action' 'the route refuses an unknown key'
    $c=Find-PacketRatCommand 'item handoff'
    Assert-Handoff ($null -ne $c -and $c.Route -eq '/api/item/handoff' -and $c.Method -eq 'POST' -and -not $c.Destructive -and @($c.Inputs | Where-Object { $_.Required -and $_.Flag -eq 'key' }).Count -eq 1) 'item handoff is a registered command that needs --key'
    foreach($f in 'Start-PacketRat-Web.ps1','Invoke-PacketRatCli.ps1'){ Assert-Handoff ([IO.File]::ReadAllText((Join-Path $Root $f)).Contains("'PacketRatHandoff'")) "$f loads the hand-off" }

    # --- The CLI, through Windows PowerShell 5.1 (dry run only) ----------------------------------------------------------------------------------
    $cli=Join-Path $Root 'Invoke-PacketRatCli.ps1'
    $ErrorActionPreference='Continue'
    $out=& powershell.exe -NoProfile -NoLogo -ExecutionPolicy Bypass -File $cli item handoff --key 'id:x' --dry-run --json 2>$null
    $code=$LASTEXITCODE
    $out2=& powershell.exe -NoProfile -NoLogo -ExecutionPolicy Bypass -File $cli item handoff --dry-run --json 2>$null
    $code2=$LASTEXITCODE
    $ErrorActionPreference='Stop'
    Assert-Handoff ($code -eq 0 -and (($out -join "`n") | ConvertFrom-Json).route -eq '/api/item/handoff') 'item handoff --dry-run shows its route'
    Assert-Handoff ($code2 -eq 2) 'item handoff without --key is a usage error (exit 2)'
    $global:LASTEXITCODE=0   # the usage-error check leaves 2 behind, which a CI step would report as a failure
    Write-Host 'Handoff tests passed.'
}finally{
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
