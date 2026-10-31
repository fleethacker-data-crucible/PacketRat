#requires -Version 5.1
<#
.SYNOPSIS
  PacketRat commands from the command line (Fleet CLI parity): the same actions as the browser UI, by name.
.DESCRIPTION
  Started by PacketRat-CLI.bat when its first argument is a command word:
    PacketRat-CLI.bat <noun> <verb> [--option value ...] [--json] [--out <file>] [--yes] [--dry-run] [--analyze]
    PacketRat-CLI.bat commands [--json]
  Every command runs the same route of Invoke-PacketRatApi (Private\PacketRatApi.ps1) that the browser calls.
  --json      print one JSON document (schema packetrat.result/1, or packetrat.commands/1 for commands)
  --out FILE  write that JSON to FILE as UTF-8 without a BOM (Windows PowerShell 5.1's > would write UTF-16)
  --yes       required for commands that overwrite saved data (rules set)
  --dry-run   check the command and its options and show what it would do, without doing it
  --analyze   for commands that use an inbox analysis (report generate, report track, draft create): run one first
  Exit codes: 0 success, 1 the command failed, 2 a usage error. Nothing waits on a dialog.
#>
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$cliArgs = @($args | ForEach-Object { [string]$_ })

foreach ($name in @('LazaretteBridge', 'PacketRatLogging', 'PacketRatLifecycle', 'PacketRatLlm','PacketRatRouter', 'PacketRatStore','PacketRatAssistant','PacketRatVoiceAssets','PacketRatUsage', 'PacketRatRules', 'PacketRatProtocol', 'PacketRatReport', 'Get-OutlookMailSummary', 'PacketRatGraph','PacketRatMailFiles', 'PacketRatDraft', 'PacketRatApi', 'PacketRatCommands')) {
    . (Join-Path $Root "Private\$name.ps1")
}
. (Join-Path $Root 'Public\Invoke-PacketRatInboxAnalysis.ps1')

$utf8 = New-Object System.Text.UTF8Encoding $false
$script:Presence = $null
$script:StopReason = ''
$script:LastResult = $null

# ---- parse: command words, then --options ----
$words = New-Object System.Collections.Generic.List[string]
$i = 0
while ($i -lt $cliArgs.Count -and -not $cliArgs[$i].StartsWith('--')) { $words.Add($cliArgs[$i].ToLowerInvariant()); $i++ }
$global = @{ json = $false; yes = $false; 'dry-run' = $false; analyze = $false; out = $null; help = $false }
$options = @{}
$rest = @($cliArgs[$i..($cliArgs.Count - 1)] | Where-Object { $null -ne $_ })
if ($i -ge $cliArgs.Count) { $rest = @() }

function Write-PacketRatCliOutput([object]$Document, [int]$Code, [string]$Text) {
    $json = ConvertTo-Json -InputObject $Document -Depth 15 -Compress
    if ($global.out) {
        [IO.File]::WriteAllText([IO.Path]::GetFullPath([string]$global.out), $json, $utf8)
        if (-not $global.json) { Write-Host ('Wrote ' + [IO.Path]::GetFullPath([string]$global.out)) }
    }
    if ($global.json -and -not $global.out) { [Console]::Out.WriteLine($json) }
    elseif (-not $global.json -and $Text) { Write-Host $Text }
    exit $Code
}
function Exit-PacketRatUsage([string]$Message) {
    if ($global.json -or $global.out) { Write-PacketRatCliOutput ([ordered]@{ schema = 'packetrat.result/1'; command = ($words -join ' '); ok = $false; error = $Message; errorType = 'usage' }) 2 '' }
    [Console]::Error.WriteLine($Message)
    [Console]::Error.WriteLine('Run: PacketRat-CLI.bat commands')
    exit 2
}

if ($words.Count -eq 1 -and $words[0] -eq 'stats') { $words.Add('show') }   # bare 'stats' is 'stats show'
$commandName = 'packetrat ' + ($words -join ' ')
$command = if ($words.Count -gt 0 -and $words[0] -ne 'commands' -and $words[0] -ne 'help') { Find-PacketRatCommand ($words -join ' ') } else { $null }
$boolFlags = @('json', 'yes', 'dry-run', 'analyze', 'help')
if ($command) { $boolFlags += @($command.Inputs | Where-Object { $_.Type -eq 'bool' } | ForEach-Object { $_.Flag }) }
for ($j = 0; $j -lt $rest.Count; $j++) {
    $tok = $rest[$j]
    if (-not $tok.StartsWith('--')) { Exit-PacketRatUsage "Unexpected argument '$tok'. Options look like --name value." }
    $key = $tok.Substring(2); $val = $null
    $eq = $key.IndexOf('=')
    if ($eq -ge 0) { $val = $key.Substring($eq + 1); $key = $key.Substring(0, $eq) }
    elseif ($boolFlags -contains $key) { $val = $true }
    else {
        if ($j + 1 -ge $rest.Count) { Exit-PacketRatUsage "--$key needs a value." }
        $j++; $val = $rest[$j]
    }
    if ($global.ContainsKey($key)) { $global[$key] = $val } else { $options[$key] = $val }
}
foreach ($k in @('json', 'yes', 'dry-run', 'analyze', 'help')) { $global[$k] = ($global[$k] -eq $true -or [string]$global[$k] -match '^(1|true|yes)$') }

# ---- commands / help ----
if ($words.Count -eq 0 -or $words[0] -eq 'help' -or $words[0] -eq 'commands') {
    $list = @(Get-PacketRatCommandList)
    $text = ($list | ForEach-Object {
            $flags = ($_.inputs | ForEach-Object { if ($_.required) { $_.flag + ' <' + $_.type + '>' } else { '[' + $_.flag + ']' } }) -join ' '
            '  ' + $_.name.Substring(10).PadRight(22) + $_.summary + $(if ($flags) { "`r`n" + (' ' * 26) + $flags } else { '' }) + $(if ($_.destructive) { '  (needs --yes)' } else { '' })
        }) -join "`r`n"
    Write-PacketRatCliOutput ([ordered]@{ schema = 'packetrat.commands/1'; commands = $list }) 0 ("PacketRat commands (PacketRat-CLI.bat <noun> <verb> [options]):`r`n" + $text + "`r`n`r`nAlso: --json, --out <file>, --yes, --dry-run, --analyze. Exit codes: 0 ok, 1 failed, 2 usage.")
}
if (-not $command) { Exit-PacketRatUsage "Unknown command '$($words -join ' ')'." }

# ---- build and check ----
try { $body = ConvertTo-PacketRatCommandBody -Command $command -Options $options }
catch [System.ArgumentException] { Exit-PacketRatUsage $_.Exception.Message }
if ($command.Destructive -and -not $global.yes -and -not $global['dry-run']) {
    Exit-PacketRatUsage "'$($command.Name)' overwrites saved data. Add --yes to go ahead, or --dry-run to see what it would do."
}
if ($global['dry-run']) {
    $shown = [ordered]@{}
    foreach ($p in $body.PSObject.Properties) { $shown[$p.Name] = if ($p.Name -eq 'token') { '(from environment, not shown)' } else { $p.Value } }
    Write-PacketRatCliOutput ([ordered]@{ schema = 'packetrat.result/1'; command = $command.Name; ok = $true; dryRun = $true; route = $command.Route; body = $shown; destructive = [bool]$command.Destructive }) 0 ("Dry run: '$($command.Name)' would call $($command.Route); nothing was changed.")
}

# ---- run: the same environment and core as the browser server ----
$envFile = Join-Path $Root 'Config\packetrat.env'
if (Test-Path $envFile) {
    foreach ($line in Get-Content $envFile) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2].Trim().Trim('"').Trim("'"), 'Process') }
    }
}
# Commands that call the AI make sure Fairlead is running when it is the router (no dialog; the previous setup is used).
if (@('packetrat inbox analyze', 'packetrat report generate', 'packetrat draft create', 'packetrat assist ask') -contains $command.Name -and (Test-PacketRatFairleadEnabled)) {
    $fl = Ensure-PacketRatFairlead -Root $Root
    if ($fl.State -ne 'Skipped' -and $fl.State -ne 'AlreadyRunning') { [Console]::Error.WriteLine('Fairlead: ' + $fl.Message) }
}
try {
    if ($command.NeedsAnalysis -and $global.analyze) {
        $prof = if ($body.PSObject.Properties['profile']) { $body.profile } else { 'Auto' }
        $null = Invoke-PacketRatApi -Route '/api/analyze' -Data ([pscustomobject]@{ profile = $prof; provider = 'COM'; maxEmails = 40; daysBack = 14 })
    }
    $data = if ($command.Method -eq 'GET') { $null } else { $body }
    $result = Invoke-PacketRatApi -Route $command.Route -Data $data
    $ok = $true
    if ($result -is [System.Collections.IDictionary] -and $result.Contains('ok')) { $ok = [bool]$result['ok'] }
    $message = if ($result -is [System.Collections.IDictionary] -and $result.Contains('message')) { [string]$result['message'] } else { '' }
    $text = if ($message) { $message } else { ConvertTo-Json -InputObject $result -Depth 6 }
    Write-PacketRatCliOutput ([ordered]@{ schema = 'packetrat.result/1'; command = $command.Name; ok = $ok; result = $result }) $(if ($ok) { 0 } else { 1 }) $text
} catch {
    $err = $_.Exception.Message
    if ($global.json -or $global.out) { Write-PacketRatCliOutput ([ordered]@{ schema = 'packetrat.result/1'; command = $command.Name; ok = $false; error = $err; errorType = 'failed' }) 1 '' }
    [Console]::Error.WriteLine("PacketRat: $err")
    exit 1
}
