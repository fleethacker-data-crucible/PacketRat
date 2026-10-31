#requires -Version 5.1
# Offline tests that docs/DATA-SOURCES.md matches what PacketRat really exports, and that the CSV converter works.
# A temp root is used, so the real store is never touched. Synthetic data only.
$ErrorActionPreference='Stop'
$Root=Split-Path $PSScriptRoot -Parent
foreach($name in @('PacketRatLogging','PacketRatLifecycle','PacketRatLlm','PacketRatStore','PacketRatUsage','PacketRatRules')){
    . (Join-Path $Root "Private\$name.ps1")
}
function Assert-Data([bool]$Pass,[string]$Message){if(-not $Pass){throw ('Data source test failed: '+$Message)}}

$doc=[IO.File]::ReadAllText((Join-Path $Root 'docs\DATA-SOURCES.md'))
$m=[regex]::Match($doc,'(?s)```json\s*(\{.*?\})\s*```')
Assert-Data $m.Success 'the doc has a JSON example'
$example=$m.Groups[1].Value | ConvertFrom-Json

$tmp=Join-Path ([IO.Path]::GetTempPath()) ('packetrat-ds-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tmp -Force)
try{
    Save-PacketRatStore -Store (Get-PacketRatStore -Root $tmp) -Root $tmp
    $null=Add-PacketRatUsage -Action triaged -Count 5 -Root $tmp
    $null=Add-PacketRatUsage -Action markedRead -Count 2 -Root $tmp
    $real=Get-PacketRatUsageExport -Root $tmp | ConvertTo-Json -Depth 5 | ConvertFrom-Json

    # The documented example has the same fields and the same action ids as the real export.
    Assert-Data ($example.schema -eq 'packetrat.usage-counts/1' -and $real.schema -eq $example.schema) 'schema id matches'
    Assert-Data ($example.estimate -eq $true -and $real.estimate -eq $true) 'estimate flag matches'
    Assert-Data ((@($example.PSObject.Properties.Name | Sort-Object) -join ',') -eq (@($real.PSObject.Properties.Name | Sort-Object) -join ',')) 'top-level fields match'
    $docIds=@($example.counts.PSObject.Properties.Name | Sort-Object); $realIds=@($real.counts.PSObject.Properties.Name | Sort-Object)
    Assert-Data (($docIds -join ',') -eq ($realIds -join ',')) ("action ids match: doc [$($docIds -join ',')] vs export [$($realIds -join ',')]")
    foreach($id in $realIds){ Assert-Data ($doc -match ('`'+$id+'`')) "the doc names the action id '$id'" }
    Assert-Data ($real.counts.triaged -eq 5 -and $real.counts.markedRead -eq 2) 'the real export carries the counts'
    Assert-Data ($doc -match 'estimate' -and $doc -match 'not a performance score') 'the doc says it is an estimate and not a score'

    # The converter: bare export and CLI result envelope both work; output is flat, counts only.
    $bare=Join-Path $tmp 'bare.json'; $env=Join-Path $tmp 'envelope.json'; $csv=Join-Path $tmp 'out.csv'
    (Get-PacketRatUsageExport -Root $tmp | ConvertTo-Json -Depth 5) | Set-Content $bare -Encoding UTF8
    ([ordered]@{schema='packetrat.result/1';command='packetrat stats export';ok=$true;result=[ordered]@{ok=$true;usage=(Get-PacketRatUsageExport -Root $tmp)}} | ConvertTo-Json -Depth 8) | Set-Content $env -Encoding UTF8
    foreach($src in $bare,$env){
        Remove-Item $csv -ErrorAction SilentlyContinue
        $null=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'tools\Export-PacketRatCountsCsv.ps1') -Path $src -Out $csv 2>&1
        Assert-Data ($LASTEXITCODE -eq 0 -and (Test-Path $csv)) ("converter ran on "+(Split-Path $src -Leaf))
        $rows=@(Import-Csv $csv)
        Assert-Data ($rows.Count -eq 8) 'one row per action'
        Assert-Data ((($rows | Where-Object action -eq 'triaged').count) -eq '5') 'counts are carried over'
        Assert-Data ((@($rows[0].PSObject.Properties.Name) -join ',') -eq 'exportedAt,since,action,count') 'columns are exportedAt,since,action,count'
        $bytes=[IO.File]::ReadAllBytes($csv)
        Assert-Data (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) 'the CSV has no BOM'
    }
    ([ordered]@{schema='something.else/1'} | ConvertTo-Json) | Set-Content $bare -Encoding UTF8
    $threw=$false; try{ $null=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'tools\Export-PacketRatCountsCsv.ps1') -Path $bare -Out $csv 2>&1; if($LASTEXITCODE -ne 0){$threw=$true} }catch{$threw=$true}
    Assert-Data $threw 'a file that is not a counts export is refused'
    $global:LASTEXITCODE = 0   # the refused run above leaves 1 behind, and CI uses the last exit code as the step's result
    Write-Host 'Data source tests passed.'
}finally{ Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
