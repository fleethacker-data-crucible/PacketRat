#requires -Version 5.1
# Offline tests for the measured-burden record: the once-entered baseline, runs, the comparison maths, input limits, what is
# stored, the routes and commands, and the documented fields. A temp root is used so the real Logs\ is never touched.
# Synthetic data only; nothing is timed and no Outlook, AI or network is involved.
$ErrorActionPreference='Stop'
$Root=Split-Path $PSScriptRoot -Parent
foreach($name in @('LazaretteBridge','PacketRatLogging','PacketRatLifecycle','PacketRatLlm','PacketRatStore','PacketRatUsage','PacketRatRules','PacketRatProtocol','PacketRatReport','Get-OutlookMailSummary','PacketRatGraph','PacketRatDraft','PacketRatBurden','PacketRatApi','PacketRatCommands')){
    . (Join-Path $Root "Private\$name.ps1")
}
. (Join-Path $Root 'Public\Invoke-PacketRatInboxAnalysis.ps1')
function Assert-Burden([bool]$Pass,[string]$Message){if(-not $Pass){throw ('Burden test failed: '+$Message)}}
# Invoke-PacketRatApi reads $Root from the caller's scope, so scope it here (the repo's own Logs is never touched).
function Invoke-ApiAt([string]$Dir,[string]$Route,$Data){ $Root=$Dir; Invoke-PacketRatApi -Route $Route -Data $Data }
function Assert-Throws([scriptblock]$Block,[string]$Pattern,[string]$Message){
    $msg=$null
    try{ & $Block }catch{ $msg=$_.Exception.Message }
    Assert-Burden ($null -ne $msg -and $msg -match $Pattern) $Message
}
function Get-Row($View,[string]$Task){ @($View.tasks | Where-Object { $_.task -ceq $Task })[0] }

$tmp=Join-Path ([IO.Path]::GetTempPath()) ('packetrat-burden-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path (Join-Path $tmp 'Config') -Force)
try{
    # --- Empty record -----------------------------------------------------------------------------------------------------
    $v=Get-PacketRatBurdenView -Root $tmp
    Assert-Burden ($v.schema -eq 'packetrat.burden/1' -and $v.totalRuns -eq 0 -and @($v.tasks).Count -eq 0) 'an empty record shows nothing'
    Assert-Burden ($v.note -match 'does not time anything' -and $v.note -match 'still needs a person' -and $v.note -match 'Not a performance score') 'the note says it is a record only and real timing needs a person'

    # --- Baseline: entered once ----------------------------------------------------------------------------------------------
    $v=Set-PacketRatBurdenBaseline -Task 'triage-inbox' -Seconds '1800' -Root $tmp
    Assert-Burden ((Get-Row $v 'triage-inbox').baselineSeconds -eq 1800 -and (Get-Row $v 'triage-inbox').runs -eq 0 -and $null -eq (Get-Row $v 'triage-inbox').meanSeconds) 'a baseline shows with no runs and no mean'
    Assert-Throws { Set-PacketRatBurdenBaseline -Task 'triage-inbox' -Seconds '900' -Root $tmp } 'already entered' 'a second baseline is refused'
    Assert-Burden ((Get-Row (Get-PacketRatBurdenView -Root $tmp) 'triage-inbox').baselineSeconds -eq 1800) 'the refused entry changed nothing'
    $null=Set-PacketRatBurdenBaseline -Task 'triage-inbox' -Seconds '1500' -Replace -Root $tmp
    Assert-Burden ((Get-Row (Get-PacketRatBurdenView -Root $tmp) 'triage-inbox').baselineSeconds -eq 1500) '--replace corrects the baseline'
    $stored=[IO.File]::ReadAllText((Join-Path $tmp 'Logs\packetrat-burden.json')) | ConvertFrom-Json
    Assert-Burden (@($stored.baseline.'triage-inbox'.replaced).Count -eq 1 -and $stored.baseline.'triage-inbox'.replaced[0].seconds -eq 1800) 'the replaced value is kept in the record'
    $null=Set-PacketRatBurdenBaseline -Task 'triage-inbox' -Seconds '1800' -Replace -Root $tmp

    # --- Runs and the maths ----------------------------------------------------------------------------------------------------
    foreach($s in '600','1200','900'){ $null=Add-PacketRatBurdenRun -Task 'triage-inbox' -Seconds $s -Root $tmp }
    $null=Add-PacketRatBurdenRun -Task 'draft-reply' -Seconds '300' -Root $tmp
    $v=Get-PacketRatBurdenView -Root $tmp
    $row=Get-Row $v 'triage-inbox'
    Assert-Burden ($v.totalRuns -eq 4 -and $row.runs -eq 3) 'runs are counted per task'
    Assert-Burden ($row.meanSeconds -eq 900 -and $row.medianSeconds -eq 900) 'mean and median of 600, 900, 1200'
    Assert-Burden ($row.changeSeconds -eq -900 -and $row.changePercent -eq -50) 'change against the 1800 s baseline is -900 s, -50 percent'
    $d=Get-Row $v 'draft-reply'
    Assert-Burden ($null -eq $d.baselineSeconds -and $d.runs -eq 1 -and $null -eq $d.changeSeconds -and $null -eq $d.changePercent) 'a task with runs but no baseline has no change'
    $null=Add-PacketRatBurdenRun -Task 'draft-reply' -Seconds '500' -Root $tmp
    Assert-Burden ((Get-Row (Get-PacketRatBurdenView -Root $tmp) 'draft-reply').medianSeconds -eq 400) 'the median of an even count is the middle pair''s mean'
    Assert-Burden ((@((Get-PacketRatBurdenView -Root $tmp).tasks.task) -join ',') -eq 'draft-reply,triage-inbox') 'tasks are sorted by id'

    # --- Input limits ------------------------------------------------------------------------------------------------------------
    Assert-Throws { Add-PacketRatBurdenRun -Task 'Triage Inbox' -Seconds '10' -Root $tmp } 'short id' 'a task id with capitals or spaces is refused'
    Assert-Throws { Add-PacketRatBurdenRun -Task '1abc' -Seconds '10' -Root $tmp } 'short id' 'a task id must start with a letter'
    Assert-Throws { Add-PacketRatBurdenRun -Task ('a'*41) -Seconds '10' -Root $tmp } 'short id' 'a task id is at most 40 characters'
    foreach($bad in '0','-5','86401','abc','1.5','',' 3'){ Assert-Throws { Add-PacketRatBurdenRun -Task 'triage-inbox' -Seconds $bad -Root $tmp } 'whole number' "seconds '$bad' is refused" }
    Assert-Burden ((Get-PacketRatBurdenView -Root $tmp).totalRuns -eq 5) 'refused entries are not stored'

    # --- PACKETRAT_DATA_DIR moves the record with the rest of the data ----------------------------------------------------------
    $savedDir=[Environment]::GetEnvironmentVariable('PACKETRAT_DATA_DIR')
    try{
        $env:PACKETRAT_DATA_DIR=Join-Path $tmp 'fresh data'
        $null=Add-PacketRatBurdenRun -Task 'moved-task' -Seconds '5' -Root $tmp
        Assert-Burden (Test-Path -LiteralPath (Join-Path $env:PACKETRAT_DATA_DIR 'packetrat-burden.json')) 'the record is written to the data folder when one is set'
        Assert-Burden ((Get-PacketRatBurdenView -Root $tmp).totalRuns -eq 1) 'a fresh data folder starts with an empty record'
    }finally{ [Environment]::SetEnvironmentVariable('PACKETRAT_DATA_DIR',$savedDir) }
    Assert-Burden ((Get-PacketRatBurdenView -Root $tmp).totalRuns -eq 5) 'and the default record is untouched'

    # --- What is stored: ids and seconds only ------------------------------------------------------------------------------------
    $path=Join-Path $tmp 'Logs\packetrat-burden.json'
    $bytes=[IO.File]::ReadAllBytes($path)
    Assert-Burden (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) 'the record is UTF-8 without a BOM'
    $raw=[IO.File]::ReadAllText($path)
    $doc=$raw | ConvertFrom-Json
    Assert-Burden ($doc.schema -eq 'packetrat.burden/1') 'the file carries its schema'
    foreach($r in @($doc.runs)){ Assert-Burden ((@($r.PSObject.Properties.Name | Sort-Object) -join ',') -eq 'recordedAt,seconds,task') 'a run holds only task, seconds and time' }
    Assert-Burden ($raw -notmatch '@' -and $raw -notmatch '(?i)subject|sender|token') 'no mail content, names or tokens'

    # --- API routes (the same core the CLI and browser use) ----------------------------------------------------------------------
    $tmp2=Join-Path $tmp 'api'; [void](New-Item -ItemType Directory -Path (Join-Path $tmp2 'Config') -Force)
    $r=Invoke-ApiAt $tmp2 '/api/burden/baseline' ([pscustomobject]@{task='api-task';seconds=600})
    Assert-Burden ($r.ok -eq $true -and (Get-Row $r.burden 'api-task').baselineSeconds -eq 600) 'the baseline route works with a numeric seconds value'
    $r=Invoke-ApiAt $tmp2 '/api/burden/record' ([pscustomobject]@{task='api-task';seconds=300})
    Assert-Burden ((Get-Row $r.burden 'api-task').changePercent -eq -50) 'the record route works'
    Assert-Throws { Invoke-ApiAt $tmp2 '/api/burden/baseline' ([pscustomobject]@{task='api-task';seconds=1}) } 'already entered' 'the baseline route refuses a second entry'
    $r=Invoke-ApiAt $tmp2 '/api/burden/baseline' ([pscustomobject]@{task='api-task';seconds=900;replace=$true})
    Assert-Burden ((Get-Row $r.burden 'api-task').baselineSeconds -eq 900) 'the baseline route accepts replace'
    Assert-Throws { Invoke-ApiAt $tmp2 '/api/burden/record' ([pscustomobject]@{task='api-task'}) } 'whole number' 'a missing seconds value is refused'
    Assert-Burden ((Invoke-ApiAt $tmp2 '/api/burden' $null).burden.totalRuns -eq 1) 'the show route returns the record'

    # --- Commands ----------------------------------------------------------------------------------------------------------------
    foreach($n in 'burden show','burden baseline','burden record'){ Assert-Burden ($null -ne (Find-PacketRatCommand $n)) "command '$n' exists" }
    Assert-Burden ((Find-PacketRatCommand 'burden show').Method -eq 'GET' -and (Find-PacketRatCommand 'burden baseline').Method -eq 'POST') 'show reads and baseline writes'
    $in=@((Find-PacketRatCommand 'burden record').Inputs | Where-Object { $_.Required } | ForEach-Object { $_.Flag })
    Assert-Burden ((($in | Sort-Object) -join ',') -eq 'seconds,task') 'record requires --task and --seconds'
    $web=[IO.File]::ReadAllText((Join-Path $Root 'Start-PacketRat-Web.ps1'))
    Assert-Burden ($web.Contains("'/api/burden'")) 'the browser server allows GET /api/burden'
    foreach($f in 'Start-PacketRat-Web.ps1','Invoke-PacketRatCli.ps1'){ Assert-Burden ([IO.File]::ReadAllText((Join-Path $Root $f)).Contains("'PacketRatBurden'")) "$f loads the burden record" }

    # --- The page documents the real fields and the limit of this record -------------------------------------------------------------
    $page=[IO.File]::ReadAllText((Join-Path $Root 'docs\BURDEN-RECORD.md'))
    Assert-Burden ($page -match 'still needs a person' -and $page -match 'does not time anything') 'the page says real before/after timing still needs a person'
    $topDoc=@([regex]::Matches([regex]::Match($page,'(?ms)^Schema `packetrat\.burden/1`\.(.*?)^Each row').Groups[1].Value,'(?m)^\| `([A-Za-z]+)` \|') | ForEach-Object { $_.Groups[1].Value })
    $rowDoc=@([regex]::Matches([regex]::Match($page,'(?ms)^Each row of `tasks`:(.*?)^## ').Groups[1].Value,'(?m)^\| `([A-Za-z]+)` \|') | ForEach-Object { $_.Groups[1].Value })
    $view=Get-PacketRatBurdenView -Root $tmp
    Assert-Burden ((($topDoc | Sort-Object) -join ',') -eq ((@($view.Keys) | Sort-Object) -join ',')) 'the page lists exactly the top-level fields of burden show'
    Assert-Burden ((($rowDoc | Sort-Object) -join ',') -eq ((@((Get-Row $view 'triage-inbox').Keys) | Sort-Object) -join ',')) 'the page lists exactly the fields of a task row'

    # --- The CLI, through Windows PowerShell 5.1 (dry runs only: the real record is not touched) -----------------------------------
    $cli=Join-Path $Root 'Invoke-PacketRatCli.ps1'
    function Invoke-Cli([string[]]$CliArgs){
        $ErrorActionPreference='Continue'
        $out=& powershell.exe -NoProfile -NoLogo -ExecutionPolicy Bypass -File $cli @CliArgs 2>$null
        [pscustomobject]@{Code=$LASTEXITCODE;Text=($out -join "`n")}
    }
    $c=Invoke-Cli @('burden','baseline','--task','triage-inbox','--seconds','1800','--dry-run','--json')
    $j=$c.Text | ConvertFrom-Json
    Assert-Burden ($c.Code -eq 0 -and $j.route -eq '/api/burden/baseline' -and $j.body.seconds -eq 1800 -and $j.body.task -eq 'triage-inbox') 'burden baseline --dry-run shows its route and body'
    $c=Invoke-Cli @('burden','record','--task','triage-inbox','--seconds','soon','--dry-run','--json')
    Assert-Burden ($c.Code -eq 2) 'a non-numeric --seconds is a usage error (exit 2)'
    $c=Invoke-Cli @('burden','record','--task','triage-inbox','--dry-run','--json')
    Assert-Burden ($c.Code -eq 2) 'a missing --seconds is a usage error (exit 2)'
    # The usage-error checks above leave exit code 2 in $LASTEXITCODE, which the CI step would report as a failure.
    $global:LASTEXITCODE=0
    Write-Host 'Burden record tests passed.'
}finally{
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
