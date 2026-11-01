#requires -Version 5.1
# Offline tests for the data-folder option (PACKETRAT_DATA_DIR) and the demo walkthrough that relies on it. Temp folders only:
# the repo's own Logs\ is never written (one check proves that for a real CLI run). No Outlook, AI or network; synthetic data.
$ErrorActionPreference='Stop'
$Root=Split-Path $PSScriptRoot -Parent
foreach($name in @('PacketRatLogging','PacketRatLifecycle','PacketRatLlm','PacketRatStore','PacketRatUsage','PacketRatRules','PacketRatProtocol','PacketRatReport','Get-OutlookMailSummary','PacketRatGraph','PacketRatDraft','PacketRatApi','PacketRatCommands')){
    . (Join-Path $Root "Private\$name.ps1")
}
. (Join-Path $Root 'Public\Invoke-PacketRatInboxAnalysis.ps1')
function Assert-DataDir([bool]$Pass,[string]$Message){if(-not $Pass){throw ('Data folder test failed: '+$Message)}}
function Assert-Throws([scriptblock]$Block,[string]$Pattern,[string]$Message){
    $msg=$null
    try{ & $Block }catch{ $msg=$_.Exception.Message }
    Assert-DataDir ($null -ne $msg -and $msg -match $Pattern) $Message
}

$saved=[Environment]::GetEnvironmentVariable('PACKETRAT_DATA_DIR')
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('packetrat-datadir-'+[guid]::NewGuid().ToString('N'))
$appRoot=Join-Path $tmp 'app'; $fresh=Join-Path $tmp 'fresh data'
[void](New-Item -ItemType Directory -Path (Join-Path $appRoot 'Config') -Force)
try{
    # --- Not set: Logs under the app folder, as before ---------------------------------------------------------------------------
    [Environment]::SetEnvironmentVariable('PACKETRAT_DATA_DIR',$null)
    Assert-DataDir ((Get-PacketRatDataDir -Root $appRoot) -eq (Join-Path $appRoot 'Logs')) 'unset means Logs under the app folder'
    Assert-DataDir ((Get-PacketRatStorePath -Root $appRoot) -eq (Join-Path (Join-Path $appRoot 'Logs') 'packetrat-store.json')) 'the store is in Logs by default'
    [Environment]::SetEnvironmentVariable('PACKETRAT_DATA_DIR','   ')
    Assert-DataDir ((Get-PacketRatDataDir -Root $appRoot) -eq (Join-Path $appRoot 'Logs')) 'a blank value counts as unset'

    # --- Set: a fresh folder (created on demand, spaces are fine) ---------------------------------------------------------------------
    $env:PACKETRAT_DATA_DIR=$fresh
    Assert-DataDir (-not (Test-Path -LiteralPath $fresh)) 'the folder does not exist yet'
    Assert-DataDir ((Get-PacketRatDataDir -Root $appRoot) -eq $fresh -and (Test-Path -LiteralPath $fresh)) 'the folder is created and used'
    $store=Get-PacketRatStore -Root $appRoot
    Save-PacketRatStore -Store $store -Root $appRoot
    Assert-DataDir (Test-Path -LiteralPath (Join-Path $fresh 'packetrat-store.json')) 'the store is written to the fresh folder'
    Write-PacketRatLog -Level INFO -Message 'Synthetic demo line' -Root $appRoot 6>$null
    Assert-DataDir (Test-Path -LiteralPath (Join-Path $fresh 'packetrat.log')) 'packetrat.log is written to the fresh folder'
    Assert-DataDir (@(Get-ChildItem -LiteralPath (Join-Path $appRoot 'Logs') -File -ErrorAction SilentlyContinue).Count -eq 0) 'nothing is written to the app folder''s Logs'
    $null=Add-PacketRatUsage -Action triaged -Count 3 -Root $appRoot
    Assert-DataDir ((Get-PacketRatUsageExport -Root $appRoot).counts.triaged -eq 3) 'counts live in the fresh folder''s store'

    # --- A new folder starts from zero ------------------------------------------------------------------------------------------------
    $env:PACKETRAT_DATA_DIR=Join-Path $tmp 'second take'
    Assert-DataDir ((Get-PacketRatUsageExport -Root $appRoot).counts.triaged -eq 0 -and @((Get-PacketRatStore -Root $appRoot).Checklist).Count -eq 0) 'a new folder shows zero counts and an empty queue'

    # --- A relative path is refused ------------------------------------------------------------------------------------------------------
    $env:PACKETRAT_DATA_DIR='demo-data'
    Assert-Throws { Get-PacketRatDataDir -Root $appRoot } 'full path' 'a relative path is refused by the data folder lookup'
    Assert-Throws { Get-PacketRatStorePath -Root $appRoot } 'full path' 'a relative path is refused by the store'
    Assert-Throws { Get-PacketRatLogDir -Root $appRoot } 'full path' 'a relative path is refused by the log'

    # --- A real CLI run (Windows PowerShell 5.1) uses the fresh folder and leaves the repo's Logs alone ------------------------------------
    $repoStore=Join-Path $Root 'Logs\packetrat-store.json'
    $before=if(Test-Path -LiteralPath $repoStore){(Get-Item -LiteralPath $repoStore).LastWriteTimeUtc.Ticks}else{0}
    $cliData=Join-Path $tmp 'cli data'
    $env:PACKETRAT_DATA_DIR=$cliData
    $cli=Join-Path $Root 'Invoke-PacketRatCli.ps1'
    $ErrorActionPreference='Continue'
    $out=& powershell.exe -NoProfile -NoLogo -ExecutionPolicy Bypass -File $cli stats reset --yes --json 2>$null
    $code=$LASTEXITCODE
    $ErrorActionPreference='Stop'
    Assert-DataDir ($code -eq 0 -and (($out -join "`n") | ConvertFrom-Json).ok) 'stats reset --yes runs against the fresh folder'
    Assert-DataDir (Test-Path -LiteralPath (Join-Path $cliData 'packetrat-store.json')) 'the CLI wrote its store to the fresh folder'
    $after=if(Test-Path -LiteralPath $repoStore){(Get-Item -LiteralPath $repoStore).LastWriteTimeUtc.Ticks}else{0}
    Assert-DataDir ($before -eq $after) 'the repo''s own store was not touched by that run'

    # --- The demo walkthrough ------------------------------------------------------------------------------------------------------------------
    $doc=[IO.File]::ReadAllText((Join-Path $Root 'docs\DEMO-WALKTHROUGH.md'))
    Assert-DataDir ($doc -match 'synthetic data only' -and $doc -match 'PACKETRAT_DATA_DIR' -and $doc -match 'Nothing is sent') 'the script says synthetic only, names the data folder setting and says nothing is sent'
    $fences=@([regex]::Matches($doc,'(?ms)^```powershell\r?\n(.*?)^```') | ForEach-Object { $_.Groups[1].Value })
    Assert-DataDir ($fences.Count -ge 3) 'the script has its command blocks'
    $checked=0
    foreach($line in ($fences -join "`n") -split '\r?\n'){
        $m=[regex]::Match($line,'PacketRat-CLI\.bat\s+(?<words>[a-z]+(?:\s+[a-z-]+)?)')
        if(-not $m.Success){continue}
        $words=$m.Groups['words'].Value
        if($words -eq 'commands'){$checked++;continue}
        Assert-DataDir ($null -ne (Find-PacketRatCommand $words)) "the script's command '$words' exists"
        $checked++
    }
    Assert-DataDir ($checked -ge 6) "the script's commands were checked ($checked)"
    foreach($p in @([regex]::Matches($doc,'`((?:tests/fixtures/mail|Launch-PacketRat\.bat|Stop-PacketRat\.ps1)[^`\s]*)`') | ForEach-Object { $_.Groups[1].Value })){
        Assert-DataDir (Test-Path -LiteralPath (Join-Path $Root ($p -replace '/','\'))) "the script names a real path: $p"
    }
    foreach($f in Get-ChildItem -LiteralPath (Join-Path $Root 'tests\fixtures\mail') -Filter *.eml){ Assert-DataDir ($f.Length -gt 0) "sample mail $($f.Name) exists" }
    $env:PACKETRAT_DATA_DIR=$null
    $global:LASTEXITCODE=0
    Write-Host 'Data folder and demo walkthrough tests passed.'
}finally{
    [Environment]::SetEnvironmentVariable('PACKETRAT_DATA_DIR',$saved)
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
