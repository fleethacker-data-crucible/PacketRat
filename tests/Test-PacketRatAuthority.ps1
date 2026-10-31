#requires -Version 5.1
# Offline tests for the human-authority statement (docs\HUMAN-AUTHORITY.md, `app authority`, GET /api/authority): the page
# and the command both stay in step with the command registry, and the code keeps the promise that it never sends or
# deletes mail. No sockets, no Outlook, no LLM, no store: only the registry, the page and the source files are read.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Private/PacketRatApi.ps1')
. (Join-Path $root 'Private/PacketRatCommands.ps1')
function Assert-Authority([bool]$Pass,[string]$Message){if(-not $Pass){throw ('Authority test failed: '+$Message)}}
function Join-Names($Names){ (@($Names | Sort-Object) -join ', ') }

$list=@(Get-PacketRatCommandList)
$needsYes=@($list | Where-Object { $_.destructive } | ForEach-Object { $_.name -replace '^packetrat ','' })
Assert-Authority ($needsYes.Count -gt 0) 'the registry has commands that need --yes'

# --- The command is registered and routed like the others (parity is also checked by Test-PacketRatCommands.ps1) ---------
$cmd=Find-PacketRatCommand 'app authority'
Assert-Authority ($null -ne $cmd -and $cmd.Route -eq '/api/authority' -and $cmd.Method -eq 'GET' -and -not $cmd.Destructive) "'app authority' is a read-only GET command on /api/authority"
$apiSource=[IO.File]::ReadAllText((Join-Path $root 'Private/PacketRatApi.ps1'))
Assert-Authority ($apiSource.Contains("'/api/authority'")) 'the dispatcher knows /api/authority'
$webSource=[IO.File]::ReadAllText((Join-Path $root 'Start-PacketRat-Web.ps1'))
Assert-Authority ($webSource.Contains("'/api/authority'")) 'the browser server allows GET /api/authority'

# --- The route and the statement ------------------------------------------------------------------------------------
$r=Invoke-PacketRatApi -Route '/api/authority' -Data $null
Assert-Authority ($r.ok -eq $true -and $r.authority.schema -eq 'packetrat.authority/1') 'the route returns the statement with its schema'
$a=$r.authority
Assert-Authority ((Join-Names $a.needsYes) -eq (Join-Names $needsYes)) 'the statement lists exactly the commands that need --yes'
foreach($k in 'statement','approvalPoints','neverDoes','monitor','stop'){ Assert-Authority (@($a[$k]).Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]@($a[$k])[0])) "the statement has '$k'" }
Assert-Authority (@($a.neverDoes -match 'Send mail').Count -gt 0) 'the statement says PacketRat never sends mail'
foreach($m in @($a.monitor)+@($a.stop)){ if($m -match '^[a-z-]+ [a-z-]+$'){ Assert-Authority ($null -ne (Find-PacketRatCommand $m)) "the statement names a real command: $m" } }

# --- The page covers every command that overwrites data -------------------------------------------------------------------
$doc=[IO.File]::ReadAllText((Join-Path $root 'docs/HUMAN-AUTHORITY.md'))
foreach($h in 'Approval points','What PacketRat never does','How to monitor it','How to stop it'){
    Assert-Authority ([regex]::IsMatch($doc,'(?m)^## '+[regex]::Escape($h)+'\s*$')) "the page has the '$h' section"
}
$approval=[regex]::Match($doc,'(?ms)^## Approval points\s*$(.*?)(?=^## |\z)').Groups[1].Value
$documented=@([regex]::Matches($approval,'(?m)^\| `([a-z-]+ [a-z-]+)` \|') | ForEach-Object { $_.Groups[1].Value })
foreach($n in $needsYes){ Assert-Authority ($documented -contains $n) "the approval table covers '$n', which needs --yes" }
foreach($n in $documented){
    $c=Find-PacketRatCommand $n
    Assert-Authority ($null -ne $c) "the approval table names a real command: $n"
    Assert-Authority ([bool]$c.Destructive) "the approval table lists only commands that need --yes: $n does not"
}
Assert-Authority ($doc -match 'app authority' -and $doc -match '/api/authority') 'the page points at the command and the route'

# --- The promise that mail is never sent or deleted is checked in the source -------------------------------------------------
$files=@(Get-ChildItem -Path (Join-Path $root 'Private'),(Join-Path $root 'Public') -Filter *.ps1 -File) + @(Get-ChildItem -Path $root -Filter *.ps1 -File)
foreach($f in $files){
    $text=[IO.File]::ReadAllText($f.FullName)
    Assert-Authority (-not [regex]::IsMatch($text,'(?i)\.Send\s*\(|sendMail|/send\b|\.Delete\s*\(')) ("$($f.Name) has no call that sends or deletes mail (update docs\HUMAN-AUTHORITY.md before adding one)")
}

# --- The CLI, through Windows PowerShell 5.1 the way PacketRat-CLI.bat runs it (dry run, then the real offline command) ---------
$cli=Join-Path $root 'Invoke-PacketRatCli.ps1'
function Invoke-Cli([string[]]$CliArgs){
    $ErrorActionPreference='Continue'
    $out=& powershell.exe -NoProfile -NoLogo -ExecutionPolicy Bypass -File $cli @CliArgs 2>$null
    [pscustomobject]@{Code=$LASTEXITCODE;Text=($out -join "`n")}
}
$c=Invoke-Cli @('app','authority','--dry-run','--json')
Assert-Authority ($c.Code -eq 0 -and ($c.Text | ConvertFrom-Json).route -eq '/api/authority') 'app authority --dry-run shows its route'
$c=Invoke-Cli @('app','authority','--json')
Assert-Authority ($c.Code -eq 0) 'app authority exits 0'
$res=($c.Text | ConvertFrom-Json)
Assert-Authority ($res.schema -eq 'packetrat.result/1' -and $res.ok -and $res.result.authority.schema -eq 'packetrat.authority/1') 'app authority --json returns the statement'
Assert-Authority ((Join-Names $res.result.authority.needsYes) -eq (Join-Names $needsYes)) 'the CLI statement lists exactly the commands that need --yes'

'PacketRat authority tests passed ({0} commands that need --yes, all in docs/HUMAN-AUTHORITY.md).' -f $needsYes.Count
