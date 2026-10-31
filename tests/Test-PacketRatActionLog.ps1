#requires -Version 5.1
# Offline tests for the tamper-evident action log: the chain, every kind of tampering, what is (and is not) recorded, the
# API wrapper that records actions, and that a failing log never breaks an action. Temp roots only; synthetic data.
$ErrorActionPreference='Stop'
$Root=Split-Path $PSScriptRoot -Parent
foreach($name in @('LazaretteBridge','PacketRatLogging','PacketRatLifecycle','PacketRatLlm','PacketRatStore','PacketRatActionLog','PacketRatUsage','PacketRatAssistant','PacketRatVoiceAssets','PacketRatRules','PacketRatProtocol','PacketRatReport','Get-OutlookMailSummary','PacketRatGraph','PacketRatDraft','PacketRatApi','PacketRatCommands')){
    . (Join-Path $Root "Private\$name.ps1")
}
function Assert-Log([bool]$Pass,[string]$Message){if(-not $Pass){throw ('Action log test failed: '+$Message)}}
function Invoke-ApiAt([string]$Dir,[string]$Route,$Data){ $Root=$Dir; Invoke-PacketRatApi -Route $Route -Data $Data }
function New-Dir{ $d=Join-Path ([IO.Path]::GetTempPath()) ('packetrat-log-'+[guid]::NewGuid().ToString('N')); [void](New-Item -ItemType Directory -Path $d -Force); return $d }
function Fill([string]$dir,[int]$n){ for($i=1;$i -le $n;$i++){ $null=Write-PacketRatActionLog -Action ('item.test'+$i) -Key ('key-'+$i) -Result 'ok' -Root $dir } }
function Lines([string]$dir){ [IO.File]::ReadAllLines((Get-PacketRatActionLogPath -Root $dir)) }
function SaveLines([string]$dir,[string[]]$l){ [IO.File]::WriteAllText((Get-PacketRatActionLogPath -Root $dir),(($l -join "`n")+"`n"),(New-Object Text.UTF8Encoding $false)) }
$dirs=@()
try{
    # --- chain basics ---
    $d=New-Dir; $dirs+=$d
    Assert-Log ((Test-PacketRatActionLog -Root $d).ok -and (Test-PacketRatActionLog -Root $d).count -eq 0) 'an empty log is intact'
    Fill $d 5
    $v=Test-PacketRatActionLog -Root $d
    Assert-Log ($v.ok -and $v.count -eq 5 -and $v.tip.Length -eq 64) 'five entries chain correctly and give a tip hash'
    $e=@(Read-PacketRatActionLog -Root $d)
    Assert-Log ($e[0].seq -eq 1 -and $e[0].prev -eq ('0'*64) -and $e[1].prev -eq $e[0].hash -and $e[4].seq -eq 5) 'sequence and links are right'
    Assert-Log ((@($e[0].PSObject.Properties.Name) -join ',') -eq 'seq,time,action,key,result,prev,hash') 'an entry has exactly the documented fields'
    $bytes=[IO.File]::ReadAllBytes((Get-PacketRatActionLogPath -Root $d))
    Assert-Log (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) 'the log has no BOM'
    $null=Write-PacketRatActionLog -Action 'item.later' -Key 'k' -Root $d
    Assert-Log ((Test-PacketRatActionLog -Root $d).count -eq 6 -and @(Read-PacketRatActionLog -Root $d)[5].seq -eq 6) 'appending continues the chain (also after a restart: state is read from the file)'
    $null=Write-PacketRatActionLog -Action 'x' -Key ('k'*500) -Root $d
    Assert-Log (@(Read-PacketRatActionLog -Root $d)[6].key.Length -eq 200) 'a long key is cut to 200 characters'

    # --- tampering is caught, with the line ---
    $base=Lines $d
    $d2=New-Dir; $dirs+=$d2; Fill $d2 5; $good=Lines $d2
    $l=@($good); $l[2]=$l[2].Replace('item.test3','item.other'); SaveLines $d2 $l
    $v=Test-PacketRatActionLog -Root $d2
    Assert-Log (-not $v.ok -and $v.problemAtLine -eq 3 -and $v.reason -match 'edited') 'an edited line is found at its line number'
    SaveLines $d2 @($good[0],$good[1],$good[3],$good[4])
    $v=Test-PacketRatActionLog -Root $d2
    Assert-Log (-not $v.ok -and $v.problemAtLine -eq 3) 'a removed middle line is found'
    SaveLines $d2 @($good[0],$good[2],$good[1],$good[3],$good[4])
    Assert-Log (-not (Test-PacketRatActionLog -Root $d2).ok) 'reordered lines are found'
    SaveLines $d2 @($good[1],$good[2],$good[3],$good[4])
    Assert-Log ((Test-PacketRatActionLog -Root $d2).problemAtLine -eq 1) 'a removed first line is found'
    $forged=($good[4] | ConvertFrom-Json); $forged.seq=6; $forged.hash=('a'*64); $forged.prev=($good[4] | ConvertFrom-Json).hash
    SaveLines $d2 (@($good)+@($forged | ConvertTo-Json -Compress))
    $v=Test-PacketRatActionLog -Root $d2
    Assert-Log (-not $v.ok -and $v.problemAtLine -eq 6 -and $v.reason -match 'edited') 'a forged extra line with a made-up hash is found'
    SaveLines $d2 (@($good[0],$good[1],$good[2].Substring(0,30)))
    $v=Test-PacketRatActionLog -Root $d2
    Assert-Log (-not $v.ok -and $v.problemAtLine -eq 3 -and $v.reason -match 'not valid JSON') 'a cut-off line is found'
    SaveLines $d2 @($good[0],'{"seq":2,"time":"x"}')
    Assert-Log ((Test-PacketRatActionLog -Root $d2).reason -match "missing") 'a line with missing fields is found'
    # The known limit, stated honestly: dropping the newest lines is not detectable, but the tip changes.
    SaveLines $d2 @($good[0],$good[1],$good[2])
    $v=Test-PacketRatActionLog -Root $d2
    $tipFull=(Test-PacketRatActionLog -Root $d).tip
    Assert-Log ($v.ok -and $v.count -eq 3) 'removing only the newest lines leaves a valid shorter chain (documented limit)'
    SaveLines $d2 $good
    $tip5=(Test-PacketRatActionLog -Root $d2).tip
    SaveLines $d2 @($good[0],$good[1],$good[2])
    Assert-Log ((Test-PacketRatActionLog -Root $d2).tip -ne $tip5) 'but the tip hash changes, so a noted tip catches it'

    # --- the API wrapper records actions, not reads, and never mail text ---
    $d3=New-Dir; $dirs+=$d3
    Save-PacketRatStore -Store (Get-PacketRatStore -Root $d3) -Root $d3
    $null=Invoke-ApiAt $d3 '/api/stats' $null                      # a read: not recorded
    $null=Invoke-ApiAt $d3 '/api/stats/reset' ([pscustomobject]@{})  # an action: recorded
    $threw=$false; try{ $null=Invoke-ApiAt $d3 '/api/dismiss' ([pscustomobject]@{key='unknown-key';reason='SECRET REASON TEXT about a person'}) }catch{ $threw=$true }
    Assert-Log $threw 'a failing action still fails the way it did'
    $threw2=$false; try{ $null=Invoke-ApiAt $d3 '/api/credentials' ([pscustomobject]@{source='Manual';profile='AiEndpoint';token='TOKEN-VALUE-123'}) }catch{ $threw2=$true }
    $e=@(Read-PacketRatActionLog -Root $d3)
    Assert-Log (@($e | Where-Object action -eq 'stats.reset' | Where-Object result -eq 'ok').Count -eq 1) 'stats.reset is recorded as ok'
    Assert-Log (@($e | Where-Object action -eq 'item.dismiss' | Where-Object result -eq 'error' | Where-Object key -eq 'unknown-key').Count -eq 1) 'a failed dismiss is recorded as error with its key'
    Assert-Log (@($e | Where-Object action -eq 'stats').Count -eq 0 -and $e.Count -ge 2) 'reads are not recorded'
    $raw=[IO.File]::ReadAllText((Get-PacketRatActionLogPath -Root $d3))
    Assert-Log ($raw -notmatch 'SECRET REASON' -and $raw -notmatch 'TOKEN-VALUE') 'reasons and tokens never reach the log'
    Assert-Log ((Test-PacketRatActionLog -Root $d3).ok) 'the chain written through the API is intact'

    # --- a log that cannot be written never breaks the action ---
    $d4=New-Dir; $dirs+=$d4
    Save-PacketRatStore -Store (Get-PacketRatStore -Root $d4) -Root $d4
    [void](New-Item -ItemType Directory -Path (Get-PacketRatActionLogPath -Root $d4) -Force)   # a folder where the file should be
    $r=Invoke-ApiAt $d4 '/api/stats/reset' ([pscustomobject]@{}) 3>$null
    Assert-Log ($r.ok -eq $true) 'the action succeeds even though the log could not be written'

    # --- routes and commands ---
    $d5=New-Dir; $dirs+=$d5; Fill $d5 3
    $show=Invoke-ApiAt $d5 '/api/log' $null
    Assert-Log ($show.ok -and @($show.entries).Count -eq 3 -and $show.verify.ok) '/api/log returns entries and the verdict'
    $ver=Invoke-ApiAt $d5 '/api/log/verify' $null
    Assert-Log ($ver.ok -and $ver.message -match 'intact') '/api/log/verify says intact'
    SaveLines $d5 @((Lines $d5)[0],'garbage')
    $ver=Invoke-ApiAt $d5 '/api/log/verify' $null
    Assert-Log ($ver.ok -eq $false -and $ver.message -match 'BROKEN at line 2') '/api/log/verify fails (so the CLI exits 1) when the chain is broken'
    foreach($n in 'log show','log verify'){ $c=Find-PacketRatCommand $n; Assert-Log ($null -ne $c -and $c.Method -eq 'GET') "'$n' is a GET command" }
    foreach($f in 'Start-PacketRat-Web.ps1','Invoke-PacketRatCli.ps1'){ Assert-Log ([IO.File]::ReadAllText((Join-Path $Root $f)) -match "'PacketRatActionLog'") "$f loads the action log module" }
    $doc=[IO.File]::ReadAllText((Join-Path $Root 'docs\ACTION-LOG.md'))
    foreach($f in 'seq','time','action','key','result','prev','hash'){ Assert-Log ($doc -match ('`'+$f+'`')) "the doc names the field '$f'" }
    Assert-Log ($doc -match 'cannot detect' -and $doc -match 'tip') 'the doc states the limit and the tip hash'
    Write-Host 'Action log tests passed.'
}finally{ foreach($x in $dirs){ Remove-Item -LiteralPath $x -Recurse -Force -ErrorAction SilentlyContinue } }
