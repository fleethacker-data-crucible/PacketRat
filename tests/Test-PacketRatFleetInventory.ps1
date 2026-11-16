#requires -Version 5.1
# Offline source inventory for docs\PATH-TO-FLEET.md: the statements a workstation reviewer relies on (where the network is
# used, what is started, what is loaded, where the server listens, that nothing sends or deletes mail) are checked against
# the code, so the page cannot quietly go stale. Only source files are read; nothing is run.
$ErrorActionPreference='Stop'
$Root=Split-Path $PSScriptRoot -Parent
function Assert-Fleet([bool]$Pass,[string]$Message){if(-not $Pass){throw ('Fleet inventory test failed: '+$Message)}}

# App source: Private, Public and the root scripts (tests and tools are not part of what a workstation runs).
$files=@(Get-ChildItem -Path (Join-Path $Root 'Private'),(Join-Path $Root 'Public') -Filter *.ps1 -File) + @(Get-ChildItem -Path $Root -Filter *.ps1 -File)
$src=@{}; foreach($f in $files){ $src[$f.Name]=[IO.File]::ReadAllText($f.FullName) }
function Get-FilesMatching([string]$Pattern){ @($src.Keys | Where-Object { [regex]::IsMatch($src[$_],$Pattern) } | Sort-Object) }

$page=[IO.File]::ReadAllText((Join-Path $Root 'docs\PATH-TO-FLEET.md'))

# --- The page keeps its structure ---------------------------------------------------------------------------------------------
foreach($h in 'What it needs','What it touches','Where data can go','What is proven and what is not','Before a managed workstation runs it','Tests'){
    Assert-Fleet ([regex]::IsMatch($page,'(?m)^## '+[regex]::Escape($h)+'\s*$')) "the page has the '$h' section"
}

# --- Network clients: only the AI client and the optional Graph provider ----------------------------------------------------------
$net=Get-FilesMatching '(?i)Invoke-RestMethod|Invoke-WebRequest|HttpWebRequest|WebClient|HttpClient|Net\.Http|Connect-MgGraph|Invoke-MgGraphRequest|Get-MgUserMessage'
Assert-Fleet (($net -join ',') -eq 'PacketRatGraph.ps1,PacketRatLlm.ps1') ("network clients appear only in PacketRatLlm.ps1 and PacketRatGraph.ps1 (found: $($net -join ', '))")
Assert-Fleet ($page.Contains('PacketRatLlm') -or ($page -match 'AI router' -and $page -match 'Microsoft Graph')) 'the page names the AI router and Microsoft Graph as the only destinations'
Assert-Fleet ($page -match 'Anywhere else \| Never') 'the page says nothing goes anywhere else'

# --- The documented AI addresses are the ones in the code ----------------------------------------------------------------------------
Assert-Fleet ($src['PacketRatLlm.ps1'].Contains('127.0.0.1:8776') -and -not $src['PacketRatLlm.ps1'].Contains('127.0.0.1:1234')) 'Fairlead on this PC is the only AI address in the code'
Assert-Fleet ($page.Contains('127.0.0.1:8776') -and -not $page.Contains('127.0.0.1:1234')) 'and the only one on the page'
foreach($v in 'PACKETRAT_FAIRLEAD_URL','PACKETRAT_FAIRLEAD_PRIVACY'){ Assert-Fleet ($page.Contains($v)) "the page names $v" }
Assert-Fleet ($src['PacketRatGraph.ps1'].Contains("'Mail.Read', 'Mail.ReadWrite', 'User.Read'") -and $page.Contains('Mail.Read, Mail.ReadWrite, User.Read')) 'the Graph scopes on the page are the ones requested'

# --- The server listens on loopback only ---------------------------------------------------------------------------------------------------
$listeners=Get-FilesMatching 'TcpListener|HttpListener'
Assert-Fleet (($listeners -join ',') -eq 'Start-PacketRat-Web.ps1') "only Start-PacketRat-Web.ps1 listens (found: $($listeners -join ', '))"
Assert-Fleet ($src['Start-PacketRat-Web.ps1'].Contains('[Net.IPAddress]::Loopback') -and $src['Start-PacketRat-Web.ps1'] -notmatch 'IPAddress\]::(Any|IPv6Any)|0\.0\.0\.0|\+\*:') 'the server binds to loopback and never to Any'
Assert-Fleet ($src['Start-PacketRat-Web.ps1'] -match '\[int\]\$Port=8766' -and $page.Contains('8766')) 'the default port on the page is the code''s'

# --- Programs started -------------------------------------------------------------------------------------------------------------------------
$started=Get-FilesMatching 'Start-Process'
Assert-Fleet ((($started | Sort-Object) -join ',') -eq ((@('Start-PacketRat-Web.ps1','Start-PacketRat.ps1') | Sort-Object) -join ',')) "Start-Process appears only in the web launcher and the console launcher (found: $($started -join ', '))"
Assert-Fleet ($src['PacketRatRouter.ps1'] -match 'Start-FleetService' -and $src['PacketRatRouter.ps1'] -match "Name 'fairlead'" -and $src['PacketRatRouter.ps1'] -notmatch '--console' -and $src['PacketRatRouter.ps1'] -notmatch '--no-tray') 'the router starts Fairlead with Start-FleetService and does not name the old console flags'
Assert-Fleet ($src['PacketRatRouter.ps1'] -notmatch "FilePath 'powershell\.exe'") 'the router does not launch its own powershell.exe for Fairlead'
Assert-Fleet ($page -match 'Start-FleetService' -and $page -match 'with its tray') 'the page says Fairlead is started through Start-FleetService with its tray'

# --- No prebuilt code loaded; C# only from source with framework assemblies --------------------------------------------------------------------
Assert-Fleet ((Get-FilesMatching '(?i)Add-Type\s+(-Path|-LiteralPath)|Assembly\]::(LoadFrom|LoadFile|Load)\(|\[Reflection\.Assembly\]::Load').Count -eq 0) 'no prebuilt DLL or assembly is loaded'
foreach($f in Get-FilesMatching 'Add-Type\s+-TypeDefinition'){
    $refs=@([regex]::Matches($src[$f],'-ReferencedAssemblies\s+([^\r\n]+)') | ForEach-Object { $_.Groups[1].Value })
    foreach($r in $refs){ Assert-Fleet ($r -notmatch '[\\/]') "$f references only framework assemblies by name ($r)" }
}
Assert-Fleet ((@(Get-ChildItem -Path $Root -Recurse -Include *.dll,*.exe -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\(\.git|node_modules|TechStack)\\' })).Count -eq 0) 'no DLL or EXE is in the repo'

# --- Mail is never sent or deleted ---------------------------------------------------------------------------------------------------------------
Assert-Fleet ((Get-FilesMatching '(?i)\.Send\s*\(|sendMail|/send\b|\.Delete\s*\(|Remove-MgUserMessage').Count -eq 0) 'no call sends or deletes mail'
Assert-Fleet ($page -match 'never sends mail' -and $page -match 'Nothing is sent or deleted') 'the page says so'

# --- Files written ------------------------------------------------------------------------------------------------------------------------------------
Assert-Fleet ($src['PacketRatStore.ps1'].Contains('packetrat-store.json') -and $src['PacketRatLogging.ps1'].Contains('packetrat.log') -and $page.Contains('packetrat-store.json') -and $page.Contains('packetrat.log')) 'the store and log file names on the page are the code''s'
Assert-Fleet ($src['Invoke-PacketRatInboxAnalysis.ps1'] -match "PACKETRAT_SAVE_RAW_AI -eq '1'" -and $page.Contains('PACKETRAT_SAVE_RAW_AI=1')) 'raw AI responses are opt-in, as the page says'
$gi=[IO.File]::ReadAllText((Join-Path $Root '.gitignore'))
Assert-Fleet ($gi -match '(?m)^Logs/') 'Logs/ is not committed'

Write-Host ('Fleet inventory tests passed ({0} source files scanned).' -f $files.Count)
