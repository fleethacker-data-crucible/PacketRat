#requires -Version 5.1
# Offline Fleet CLI parity tests: every browser action has a named command, and the CLI keeps its contract.
# No sockets, no Outlook, no LLM: only --dry-run, commands and usage errors are run.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Private/PacketRatApi.ps1')
. (Join-Path $root 'Private/PacketRatCommands.ps1')
function Assert-Commands([bool]$Pass,[string]$Message){if(-not $Pass){throw ('Command test failed: '+$Message)}}

$list=@(Get-PacketRatCommandList)
$commandRoutes=@($list | ForEach-Object { $_.route })
$apiSource=[IO.File]::ReadAllText((Join-Path $root 'Private/PacketRatApi.ps1'))
$appSource=[IO.File]::ReadAllText((Join-Path $root 'Web/app.js'))
$dispatcherRoutes=@([regex]::Matches($apiSource,"'(/api/[a-z/-]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$uiRoutes=@([regex]::Matches($appSource,"api\('([a-z/-]+)'") | ForEach-Object { '/api/'+$_.Groups[1].Value } | Sort-Object -Unique)

# Parity: every route the browser or the dispatcher knows has a command, and every command has a route.
foreach($r in $uiRoutes){Assert-Commands ($commandRoutes -contains $r) ("browser route $r has no command")}
foreach($r in $dispatcherRoutes){if($script:PacketRatSessionRoutes -notcontains $r){Assert-Commands ($commandRoutes -contains $r) ("dispatcher route $r has no command")}}
foreach($r in $commandRoutes){Assert-Commands ($dispatcherRoutes -contains $r) ("command route $r is not in the dispatcher")}

# Names, uniqueness, and destructive marking.
foreach($c in $list){Assert-Commands ($c.name -cmatch '^packetrat [a-z-]+ [a-z-]+$') ("bad command name '$($c.name)'")}
Assert-Commands (@($list.name | Sort-Object -Unique).Count -eq $list.Count) 'command names are unique'
Assert-Commands ((Find-PacketRatCommand 'rules set').Destructive) 'rules set is destructive'

# The CLI itself, through Windows PowerShell 5.1 the way PacketRat-CLI.bat runs it.
$cli=Join-Path $root 'Invoke-PacketRatCli.ps1'
function Invoke-Cli([string[]]$CliArgs){
    # Usage errors go to stderr; Windows PowerShell 5.1 would turn that into a terminating error under Stop.
    $ErrorActionPreference='Continue'
    $out=& powershell.exe -NoProfile -NoLogo -ExecutionPolicy Bypass -File $cli @CliArgs 2>$null
    [pscustomobject]@{Code=$LASTEXITCODE;Text=($out -join "`n")}
}
$r=Invoke-Cli @('commands','--json')
Assert-Commands ($r.Code -eq 0) 'commands --json exits 0'
$doc=$r.Text | ConvertFrom-Json
Assert-Commands ($doc.schema -eq 'packetrat.commands/1') 'commands --json carries its schema'
Assert-Commands (@($doc.commands).Count -eq $list.Count) 'commands --json lists every command'

$r=Invoke-Cli @('rules','set','--file','nothing.json')
Assert-Commands ($r.Code -eq 2) 'a destructive command refuses without --yes (exit 2)'
$r=Invoke-Cli @('no','such','--json')
Assert-Commands ($r.Code -eq 2) 'an unknown command is a usage error (exit 2)'
$r=Invoke-Cli @('item','status','--json')
Assert-Commands ($r.Code -eq 2) 'a missing required option is a usage error (exit 2)'

$tmp=Join-Path ([IO.Path]::GetTempPath()) ('packetrat-cli-'+[guid]::NewGuid().ToString('N')+'.json')
try{
    $r=Invoke-Cli @('app','health','--dry-run','--out',$tmp)
    Assert-Commands ($r.Code -eq 0) '--dry-run --out exits 0'
    $bytes=[IO.File]::ReadAllBytes($tmp)
    Assert-Commands (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) '--out writes UTF-8 without a BOM'
    $saved=[IO.File]::ReadAllText($tmp) | ConvertFrom-Json
    Assert-Commands ($saved.schema -eq 'packetrat.result/1' -and $saved.dryRun) '--out holds the dry-run result'
}finally{Remove-Item $tmp -ErrorAction SilentlyContinue}

'PacketRat command tests passed ({0} commands, {1} browser routes).' -f $list.Count,$uiRoutes.Count
