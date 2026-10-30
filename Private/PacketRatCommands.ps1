#requires -Version 5.1
# PacketRat command registry (Fleet CLI parity): every action a person can take in the browser UI has a named command
# "packetrat <noun> <verb>" that runs the same route of Invoke-PacketRatApi (Private\PacketRatApi.ps1). The browser,
# Invoke-PacketRatCli.ps1 (PacketRat-CLI.bat <noun> <verb>) and GET /api/commands all read this one list.
#
# Each input: Flag (CLI, kebab-case) -> Field (API JSON body), Type: string | int | bool | json-file | text-file | env.
#   json-file / text-file: the flag names a file whose content becomes the field (rules, draft body).
#   env: the flag names an environment variable that holds the value, so a secret never appears on a command line.
# Destructive: overwrites saved data; the CLI refuses it without --yes (the API's equivalent is the browser's confirm).
# NeedsAnalysis: uses the inbox analysis of the same run; in the CLI, add --analyze to run one first.
# Browser-session plumbing (/api/heartbeat, /api/session/stop) and /api/commands itself are not user actions.

$script:PacketRatSessionRoutes = @('/api/heartbeat', '/api/session/stop', '/api/commands')

function New-PacketRatInput([string]$Flag, [string]$Field, [string]$Type, [bool]$Required, [string]$Description, [object[]]$Allowed = @()) {
    return [pscustomobject]@{ Flag = $Flag; Field = $Field; Type = $Type; Required = $Required; Description = $Description; Allowed = @($Allowed) }
}

$script:PacketRatCommands = @(
    [pscustomobject]@{ Name = 'packetrat app health'; Route = '/api/health'; Method = 'GET'; Destructive = $false; NeedsAnalysis = $false
        Summary = 'Check that PacketRat answers.'; Inputs = @() }
    [pscustomobject]@{ Name = 'packetrat queue show'; Route = '/api/state'; Method = 'GET'; Destructive = $false; NeedsAnalysis = $false
        Summary = 'The action queue, dismissals, rules, credential status and the last report.'; Inputs = @() }
    [pscustomobject]@{ Name = 'packetrat inbox analyze'; Route = '/api/analyze'; Method = 'POST'; Destructive = $false; NeedsAnalysis = $false
        Summary = 'Read recent Outlook mail and build the report and action queue (no mail is changed or sent).'
        Inputs = @(
            (New-PacketRatInput 'profile' 'profile' 'string' $false 'AI profile: Auto, AiEndpoint or Grok (default Auto).' @('Auto', 'AiEndpoint', 'Grok'))
            (New-PacketRatInput 'provider' 'provider' 'string' $false 'Mail source: COM (classic Outlook) or Graph (default COM).' @('COM', 'Graph'))
            (New-PacketRatInput 'max-emails' 'maxEmails' 'int' $false 'Most messages to read, 1-150 (default 40).')
            (New-PacketRatInput 'days-back' 'daysBack' 'int' $false 'How many days back, 1-90 (default 14).')) }
    [pscustomobject]@{ Name = 'packetrat inbox cancel'; Route = '/api/cancel'; Method = 'POST'; Destructive = $false; NeedsAnalysis = $false
        Summary = 'Cancel an AI generation that is streaming in a running PacketRat (needs streaming on: PACKETRAT_LLM_STREAM=1). Run it from a second console.'; Inputs = @() }
    [pscustomobject]@{ Name = 'packetrat report generate'; Route = '/api/report/generate'; Method = 'POST'; Destructive = $false; NeedsAnalysis = $true
        Summary = 'Ask the AI for a brief, actions, risks or an explanation of the current report.'
        Inputs = @(
            (New-PacketRatInput 'mode' 'mode' 'string' $true 'What to generate.' @('Brief', 'Actions', 'Risks', 'Explain'))
            (New-PacketRatInput 'section-id' 'sectionId' 'string' $false 'all (default) or section-N.')
            (New-PacketRatInput 'profile' 'profile' 'string' $false 'AI profile (default Auto).' @('Auto', 'AiEndpoint', 'Grok'))) }
    [pscustomobject]@{ Name = 'packetrat report track'; Route = '/api/report/track'; Method = 'POST'; Destructive = $false; NeedsAnalysis = $true
        Summary = 'Turn a verified report source message into an open action.'
        Inputs = @(
            (New-PacketRatInput 'key' 'key' 'string' $true 'The message key from the report.')
            (New-PacketRatInput 'urgency' 'urgency' 'string' $false 'High, Medium (default) or Low.' @('High', 'Medium', 'Low'))) }
    [pscustomobject]@{ Name = 'packetrat item status'; Route = '/api/status'; Method = 'POST'; Destructive = $false; NeedsAnalysis = $false
        Summary = 'Set an action to open, in progress or done.'
        Inputs = @(
            (New-PacketRatInput 'key' 'key' 'string' $true 'The action key.')
            (New-PacketRatInput 'status' 'status' 'string' $true 'New status.' @('open', 'in_progress', 'done'))) }
    [pscustomobject]@{ Name = 'packetrat priority set'; Route = '/api/priority'; Method = 'POST'; Destructive = $false; NeedsAnalysis = $false
        Summary = 'Override an action''s priority.'
        Inputs = @(
            (New-PacketRatInput 'key' 'key' 'string' $true 'The action key.')
            (New-PacketRatInput 'urgency' 'urgency' 'string' $true 'High, Medium or Low.' @('High', 'Medium', 'Low'))) }
    [pscustomobject]@{ Name = 'packetrat priority reset'; Route = '/api/priority/reset'; Method = 'POST'; Destructive = $false; NeedsAnalysis = $false
        Summary = 'Return an action to its triaged priority.'
        Inputs = @((New-PacketRatInput 'key' 'key' 'string' $true 'The action key.')) }
    [pscustomobject]@{ Name = 'packetrat rules set'; Route = '/api/rules'; Method = 'POST'; Destructive = $true; NeedsAnalysis = $false
        Summary = 'Replace the triage rules with the ones in a JSON file (an array of rules, as in queue show).'
        Inputs = @((New-PacketRatInput 'file' 'rules' 'json-file' $true 'JSON file holding the rules array.')) }
    [pscustomobject]@{ Name = 'packetrat item dismiss'; Route = '/api/dismiss'; Method = 'POST'; Destructive = $false; NeedsAnalysis = $false
        Summary = 'Dismiss an action (item restore brings it back).'
        Inputs = @(
            (New-PacketRatInput 'key' 'key' 'string' $true 'The action key.')
            (New-PacketRatInput 'reason' 'reason' 'string' $false 'Why, up to 300 characters.')) }
    [pscustomobject]@{ Name = 'packetrat item restore'; Route = '/api/restore'; Method = 'POST'; Destructive = $false; NeedsAnalysis = $false
        Summary = 'Restore a dismissed action.'
        Inputs = @((New-PacketRatInput 'key' 'key' 'string' $true 'The dismissal key.')) }
    [pscustomobject]@{ Name = 'packetrat item open'; Route = '/api/open'; Method = 'POST'; Destructive = $false; NeedsAnalysis = $false
        Summary = 'Open the original message in classic Outlook.'
        Inputs = @((New-PacketRatInput 'key' 'key' 'string' $true 'The action or report message key.')) }
    [pscustomobject]@{ Name = 'packetrat draft create'; Route = '/api/draft'; Method = 'POST'; Destructive = $false; NeedsAnalysis = $true
        Summary = 'Draft a reply with the AI for review (nothing is sent).'
        Inputs = @(
            (New-PacketRatInput 'key' 'key' 'string' $true 'The report message key.')
            (New-PacketRatInput 'instruction' 'instruction' 'string' $false 'Extra instruction, up to 2000 characters.')
            (New-PacketRatInput 'profile' 'profile' 'string' $false 'AI profile (default Auto).' @('Auto', 'AiEndpoint', 'Grok'))) }
    [pscustomobject]@{ Name = 'packetrat draft open'; Route = '/api/open-draft'; Method = 'POST'; Destructive = $false; NeedsAnalysis = $false
        Summary = 'Open an Outlook reply with reviewed text above your signature (never sent automatically).'
        Inputs = @(
            (New-PacketRatInput 'key' 'key' 'string' $true 'The action or report message key.')
            (New-PacketRatInput 'body-file' 'body' 'text-file' $true 'Text file with the reviewed reply.')
            (New-PacketRatInput 'subject' 'subject' 'string' $false 'Suggested subject (used only with --apply-subject).')
            (New-PacketRatInput 'apply-subject' 'applySubject' 'bool' $false 'Replace the reply subject with --subject.')) }
    [pscustomobject]@{ Name = 'packetrat item archive'; Route = '/api/item/archive'; Method = 'POST'; Destructive = $true; NeedsAnalysis = $false
        Summary = 'Move the original email to the Outlook archive folder and dismiss it from the queue (reversible in Outlook).'
        Inputs = @((New-PacketRatInput 'key' 'key' 'string' $true 'The action key.')) }
    [pscustomobject]@{ Name = 'packetrat item move'; Route = '/api/item/move'; Method = 'POST'; Destructive = $true; NeedsAnalysis = $false
        Summary = 'Move the original email to a named Outlook folder (must exist; reversible in Outlook).'
        Inputs = @(
            (New-PacketRatInput 'key' 'key' 'string' $true 'The action key.')
            (New-PacketRatInput 'folder' 'folder' 'string' $true 'Target Outlook folder name (inbox subfolder or sibling), up to 256 characters.')) }
    [pscustomobject]@{ Name = 'packetrat item categorize'; Route = '/api/item/categorize'; Method = 'POST'; Destructive = $false; NeedsAnalysis = $false
        Summary = 'Apply an Outlook category tag to the original email (adds to existing categories; reversible in Outlook).'
        Inputs = @(
            (New-PacketRatInput 'key' 'key' 'string' $true 'The action key.')
            (New-PacketRatInput 'category' 'category' 'string' $true 'Outlook category name, up to 255 characters (no semicolons).')) }
    [pscustomobject]@{ Name = 'packetrat item mark-read'; Route = '/api/item/mark-read'; Method = 'POST'; Destructive = $false; NeedsAnalysis = $false
        Summary = 'Mark the original email as read (or unread with --unread) in Outlook.'
        Inputs = @(
            (New-PacketRatInput 'key' 'key' 'string' $true 'The action key.')
            (New-PacketRatInput 'unread' 'unread' 'bool' $false 'Pass true to mark unread instead.')) }
    [pscustomobject]@{ Name = 'packetrat credentials status'; Route = '/api/credentials/status'; Method = 'GET'; Destructive = $false; NeedsAnalysis = $false
        Summary = 'Which AI credential source is set (tokens are never shown).'; Inputs = @() }
    [pscustomobject]@{ Name = 'packetrat credentials set'; Route = '/api/credentials'; Method = 'POST'; Destructive = $false; NeedsAnalysis = $false
        Summary = 'Choose Lazarette or a manual session token (never saved; in the CLI it lasts for this one run).'
        Inputs = @(
            (New-PacketRatInput 'source' 'source' 'string' $true 'Lazarette or Manual.' @('Lazarette', 'Manual'))
            (New-PacketRatInput 'profile' 'profile' 'string' $true 'AiEndpoint or Grok.' @('AiEndpoint', 'Grok'))
            (New-PacketRatInput 'token-env' 'token' 'env' $false 'Name of an environment variable holding the manual token.')) }
    [pscustomobject]@{ Name = 'packetrat credentials check'; Route = '/api/credentials/check'; Method = 'POST'; Destructive = $false; NeedsAnalysis = $false
        Summary = 'Check locally that a credential resolves (no AI call, no mail read).'
        Inputs = @((New-PacketRatInput 'profile' 'profile' 'string' $false 'AI profile (default AiEndpoint).' @('Auto', 'AiEndpoint', 'Grok'))) }
    [pscustomobject]@{ Name = 'packetrat credentials clear'; Route = '/api/credentials/clear'; Method = 'POST'; Destructive = $false; NeedsAnalysis = $false
        Summary = 'Forget manual session tokens.'; Inputs = @() }
)

# The registry as plain data, for commands --json and GET /api/commands.
function Get-PacketRatCommandList {
    foreach ($c in $script:PacketRatCommands) {
        [ordered]@{
            name          = $c.Name
            summary       = $c.Summary
            route         = $c.Route
            method        = $c.Method
            destructive   = [bool]$c.Destructive
            needsAnalysis = [bool]$c.NeedsAnalysis
            inputs        = @($c.Inputs | ForEach-Object { [ordered]@{ flag = '--' + $_.Flag; field = $_.Field; type = $_.Type; required = [bool]$_.Required; description = $_.Description; allowed = @($_.Allowed) } })
        }
    }
}

function Find-PacketRatCommand([string]$Name) {
    $full = if ($Name -like 'packetrat *') { $Name } else { 'packetrat ' + $Name }
    return @($script:PacketRatCommands | Where-Object { $_.Name -ceq $full } | Select-Object -First 1)[0]
}

# Builds the API body for a command from CLI options (hashtable flag -> string value; switches -> $true).
# Throws [System.ArgumentException] for usage errors.
function ConvertTo-PacketRatCommandBody($Command, [hashtable]$Options) {
    $body = [ordered]@{}
    $known = @($Command.Inputs | ForEach-Object { $_.Flag })
    foreach ($flag in $Options.Keys) {
        if ($known -cnotcontains $flag) { throw [System.ArgumentException]::new("Unknown option --$flag for '$($Command.Name)'. Run: commands") }
    }
    foreach ($in in $Command.Inputs) {
        if (-not $Options.ContainsKey($in.Flag)) {
            if ($in.Required) { throw [System.ArgumentException]::new("--$($in.Flag) is required for '$($Command.Name)'.") }
            continue
        }
        $raw = $Options[$in.Flag]
        switch ($in.Type) {
            'int' {
                $n = 0
                if (-not [int]::TryParse([string]$raw, [ref]$n)) { throw [System.ArgumentException]::new("--$($in.Flag) must be a whole number.") }
                $value = $n
            }
            'bool' { $value = ($raw -eq $true -or [string]$raw -match '^(1|true|yes)$') }
            'json-file' {
                if (-not (Test-Path -LiteralPath ([string]$raw) -PathType Leaf)) { throw [System.ArgumentException]::new("--$($in.Flag): no file at $raw") }
                $text = [IO.File]::ReadAllText([string]$raw)
                $parsed = ConvertFrom-Json $text
                # Keep a JSON array an array (Windows PowerShell 5.1 unrolls an empty or one-item array otherwise).
                $value = if ($text.TrimStart().StartsWith('[')) { , @($parsed) } else { $parsed }
            }
            'text-file' {
                if (-not (Test-Path -LiteralPath ([string]$raw) -PathType Leaf)) { throw [System.ArgumentException]::new("--$($in.Flag): no file at $raw") }
                $value = [IO.File]::ReadAllText([string]$raw)
            }
            'env' {
                $value = [Environment]::GetEnvironmentVariable([string]$raw, 'Process')
                if ($null -eq $value) { throw [System.ArgumentException]::new("--$($in.Flag): environment variable $raw is not set.") }
            }
            default { $value = [string]$raw }
        }
        if ($in.Allowed.Count -gt 0 -and $in.Allowed -cnotcontains [string]$value) {
            throw [System.ArgumentException]::new("--$($in.Flag) must be one of: $($in.Allowed -join ', ').")
        }
        $body[$in.Field] = $value
    }
    return [pscustomobject]$body
}
