#requires -Version 5.1
# Offline tests for the tamper-evident action log: the chain, tamper detection, no mail content, the routes and commands,
# and the documented line fields. Outlook and the AI are not touched; a temp root is used so the real Logs\ is never written.
# Synthetic data only.
$ErrorActionPreference='Stop'
$Root=Split-Path $PSScriptRoot -Parent
foreach($name in @('PacketRatLogging','PacketRatLifecycle','PacketRatLlm','PacketRatStore','PacketRatUsage','PacketRatRules','PacketRatProtocol','PacketRatReport','Get-OutlookMailSummary','PacketRatGraph','PacketRatDraft','PacketRatActionLog','PacketRatApi','PacketRatCommands')){
    . (Join-Path $Root "Private\$name.ps1")
}
. (Join-Path $Root 'Public\Invoke-PacketRatInboxAnalysis.ps1')
function Assert-Log([bool]$Pass,[string]$Message){if(-not $Pass){throw ('Action log test failed: '+$Message)}}
# Invoke-PacketRatApi reads $Root from the caller's scope, so scope it here (the repo's own Logs is never touched).
function Invoke-ApiAt([string]$Dir,[string]$Route,$Data){ $Root=$Dir; Invoke-PacketRatApi -Route $Route -Data $Data }
function Get-LogFile([string]$Dir){ Join-Path $Dir 'Logs\packetrat-actions.jsonl' }
function Write-LogLines([string]$Dir,[string[]]$Lines){ [IO.File]::WriteAllText((Get-LogFile $Dir),(($Lines -join "`n")+"`n"),(New-Object Text.UTF8Encoding $false)) }

$tmp=Join-Path ([IO.Path]::GetTempPath()) ('packetrat-actionlog-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path (Join-Path $tmp 'Config') -Force)
try{
    # --- An empty log is intact ------------------------------------------------------------------------------------------
    $v=Test-PacketRatActionLog -Root $tmp
    Assert-Log ($v.Valid -and $v.Entries -eq 0 -and $v.Head -eq ('0'*64)) 'a missing log verifies as empty'
    Assert-Log ((Get-PacketRatActionLogView -Root $tmp).total -eq 0) 'log show on an empty log reports zero'

    # --- Routes write lines; reads do not -----------------------------------------------------------------------------------
    $secret='id:Synthetic subject: payroll secret'
    $null=Invoke-ApiAt $tmp '/api/stats/reset' ([pscustomobject]@{})
    $null=Invoke-ApiAt $tmp '/api/stats/reset' ([pscustomobject]@{})
    $failed=$false
    try{ $null=Invoke-ApiAt $tmp '/api/item/mark-read' ([pscustomobject]@{key=$secret}) }catch{ $failed=$true }
    Assert-Log $failed 'an unknown item still fails as before'
    $null=Invoke-ApiAt $tmp '/api/stats' $null
    $null=Invoke-ApiAt $tmp '/api/health' $null
    $view=(Invoke-ApiAt $tmp '/api/log' $null).log
    Assert-Log ($view.total -eq 3) 'three actions are logged and the reads (stats, health, log show) are not'
    $e=@($view.entries)
    Assert-Log ($e[0].route -eq '/api/stats/reset' -and $e[0].outcome -eq 'ok' -and $e[0].seq -eq 1) 'line 1 is the counter reset'
    Assert-Log ($e[2].route -eq '/api/item/mark-read' -and $e[2].outcome -eq 'failed') 'a failed action is logged as failed'
    Assert-Log ($e[0].prev -eq ('0'*64) -and $e[1].prev -eq $e[0].hash -and $e[2].prev -eq $e[1].hash) 'each line links to the one before'
    Assert-Log ($view.head -eq $e[2].hash) 'the head is the last line''s hash'
    $r=Invoke-ApiAt $tmp '/api/log/verify' $null
    Assert-Log ($r.ok -eq $true -and $r.verify.Valid -and $r.verify.Entries -eq 3) 'verify passes on an intact log'

    # --- No mail content ----------------------------------------------------------------------------------------------------
    $raw=[IO.File]::ReadAllText((Get-LogFile $tmp))
    Assert-Log ($raw -notmatch 'payroll' -and $raw -notmatch 'Synthetic' -and $raw -notmatch [regex]::Escape($secret)) 'the item key and any message text are not stored'
    $keyRef=(Get-PacketRatActionLogHash $secret).Substring(0,12)
    Assert-Log ($e[2].keyRef -eq $keyRef -and $e[0].keyRef -eq '') 'only a short hash of the key is kept, and none when there is no key'
    $bytes=[IO.File]::ReadAllBytes((Get-LogFile $tmp))
    Assert-Log (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) 'the log is UTF-8 without a BOM'

    # --- Tampering is caught -------------------------------------------------------------------------------------------------
    $good=@([IO.File]::ReadAllLines((Get-LogFile $tmp)))
    Write-LogLines $tmp @($good[0],$good[1].Replace('"ok"','"failed"'),$good[2])
    $t=Test-PacketRatActionLog -Root $tmp
    Assert-Log (-not $t.Valid -and $t.BrokenAt -eq 2 -and $t.Reason -match 'edited') 'an edited line is caught and located'
    Write-LogLines $tmp @($good[0],$good[2])
    $t=Test-PacketRatActionLog -Root $tmp
    Assert-Log (-not $t.Valid -and $t.BrokenAt -eq 2) 'a removed middle line is caught'
    Write-LogLines $tmp @($good[1],$good[0],$good[2])
    $t=Test-PacketRatActionLog -Root $tmp
    Assert-Log (-not $t.Valid -and $t.BrokenAt -eq 1) 'a reordered log is caught'
    Write-LogLines $tmp @($good[0],'not json',$good[2])
    Assert-Log (-not (Test-PacketRatActionLog -Root $tmp).Valid) 'a damaged line is caught'
    $r=Invoke-ApiAt $tmp '/api/log/verify' $null
    Assert-Log ($r.ok -eq $false -and $r.verify.BrokenAt -eq 2) 'the verify route reports not ok and the broken line'
    # The documented limit: a cut tail still verifies, but the head no longer matches the one a person noted.
    Write-LogLines $tmp @($good[0],$good[1])
    $t=Test-PacketRatActionLog -Root $tmp
    Assert-Log ($t.Valid -and $t.Head -ne $view.head) 'a cut tail is not caught by the chain, but the head differs from the noted one'
    Write-LogLines $tmp $good
    Assert-Log ((Test-PacketRatActionLog -Root $tmp).Valid) 'the restored log verifies again'

    # --- Logging never breaks the action ---------------------------------------------------------------------------------------
    $null=Invoke-ApiAt $tmp '/api/stats/reset' ([pscustomobject]@{})
    Assert-Log ((Get-PacketRatActionLogView -Root $tmp).total -eq 4) 'appending continues the chain'
    Assert-Log ((Test-PacketRatActionLog -Root $tmp).Valid) 'the chain is intact after appending'
    $blocked=Join-Path $tmp 'blocked'; [void](New-Item -ItemType Directory -Path (Join-Path $blocked 'Logs\packetrat-actions.jsonl') -Force)   # a folder where the log file should be
    Assert-Log (-not (Add-PacketRatActionLog -Route '/api/stats/reset' -Root $blocked 3>$null)) 'a log that cannot be written returns false instead of throwing'
    $res=Invoke-ApiAt $blocked '/api/stats/reset' ([pscustomobject]@{}) 3>$null
    Assert-Log ($res.ok -eq $true) 'an action still succeeds when its log line cannot be written'

    # --- Routes and commands --------------------------------------------------------------------------------------------------
    $list=@(Get-PacketRatCommandList)
    foreach($n in 'log show','log verify'){
        $c=Find-PacketRatCommand $n
        Assert-Log ($null -ne $c -and $c.Method -eq 'GET' -and -not $c.Destructive) "command '$n' is a read-only GET command"
    }
    Assert-Log ((Find-PacketRatCommand 'log show').Route -eq '/api/log' -and (Find-PacketRatCommand 'log verify').Route -eq '/api/log/verify') 'the log commands use /api/log and /api/log/verify'
    $post=@($list | Where-Object { $_.method -eq 'POST' } | ForEach-Object { $_.route } | Sort-Object)
    $logged=@($script:PacketRatLoggedRoutes | Sort-Object)
    Assert-Log (($post -join ',') -eq ($logged -join ',')) ('the logged routes equal the POST commands (missing from log: ' + ((@($post | Where-Object { $logged -notcontains $_ })) -join ' ') + '; extra: ' + ((@($logged | Where-Object { $post -notcontains $_ })) -join ' ') + ')')
    $web=[IO.File]::ReadAllText((Join-Path $Root 'Start-PacketRat-Web.ps1'))
    Assert-Log ($web.Contains("'/api/log'") -and $web.Contains("'/api/log/verify'")) 'the browser server allows GET on both log routes'
    foreach($f in 'Start-PacketRat-Web.ps1','Invoke-PacketRatCli.ps1'){ Assert-Log ([IO.File]::ReadAllText((Join-Path $Root $f)).Contains("'PacketRatActionLog'")) "$f loads the action log" }

    # --- The page documents the real line fields ----------------------------------------------------------------------------------
    $doc=[IO.File]::ReadAllText((Join-Path $Root 'docs\ACTION-LOG.md'))
    $section=[regex]::Match($doc,'(?ms)^## What a line holds\s*$(.*?)(?=^## |\z)').Groups[1].Value
    $documented=@([regex]::Matches($section,'(?m)^\| `([A-Za-z]+)` \|') | ForEach-Object { $_.Groups[1].Value })
    $actual=@(([IO.File]::ReadAllLines((Get-LogFile $tmp))[0] | ConvertFrom-Json).PSObject.Properties.Name)
    Assert-Log ((($documented | Sort-Object) -join ',') -eq (($actual | Sort-Object) -join ',')) 'docs\ACTION-LOG.md documents exactly the fields a line holds'

    # --- The CLI, through Windows PowerShell 5.1 (dry run only: the real log is not touched) -------------------------------------
    $cli=Join-Path $Root 'Invoke-PacketRatCli.ps1'
    $ErrorActionPreference='Continue'
    $out=& powershell.exe -NoProfile -NoLogo -ExecutionPolicy Bypass -File $cli log verify --dry-run --json 2>$null
    $code=$LASTEXITCODE
    $ErrorActionPreference='Stop'
    Assert-Log ($code -eq 0 -and (($out -join "`n") | ConvertFrom-Json).route -eq '/api/log/verify') 'log verify --dry-run shows its route'
    Write-Host 'Action log tests passed.'
}finally{
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
