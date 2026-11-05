# PacketRat - hand a tracked mail to Halyard as a backlog item candidate (a plain file; nothing is sent anywhere)
#requires -Version 5.1
# Writes Logs\handoff\halyard-<ref>.json for one tracked action in the fleet-handoff v1 format that Halyard's Intake reads
# (docs/HANDOFF.md in Halyard): the subject as the title, PacketRat's recommended action as the body, the urgency as a label.
# It never carries the sender, the message body, the Outlook id or the item key (a short hash of the key names the file).
# A person reads the file before Halyard
# uses it; Halyard writes to its sandbox only after a human accepts.

$script:PacketRatHandoffFormat = 'fleet-handoff'

function Get-PacketRatHandoffHash([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) -replace '-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}

function ConvertTo-PacketRatHandoffSlug([string]$Text) {
    $slug = ([regex]::Replace($Text.ToLowerInvariant(), '[^a-z0-9]+', '-')).Trim('-')
    if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40).Trim('-') }
    if (-not $slug) { $slug = 'packetrat-item' }
    return $slug
}

function Limit-PacketRatHandoffText([string]$Text, [int]$Max) {
    $t = ([regex]::Replace([string]$Text, '\s+', ' ')).Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max - 1).TrimEnd() + [string][char]0x2026 }
    return $t
}

function New-PacketRatHalyardHandoff {
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)][string]$Key, [string]$Root)
    $item = @($Store.Checklist | Where-Object { $_.Key -ceq $Key } | Select-Object -First 1)[0]
    if (-not $item) { throw 'No tracked action has that key. Track the message first (report track), then hand it off.' }
    if ($item.Status -eq 'dismissed') { throw 'That action is dismissed. Restore it (item restore) before handing it off.' }
    if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }

    $ref = (Get-PacketRatHandoffHash $Key).Substring(0, 12)
    $name = Limit-PacketRatHandoffText ([string]$item.Subject) 120
    if (-not $name) { $name = 'Tracked message' }
    $why = Limit-PacketRatHandoffText ([string]$item.Why) 600
    $urgency = if (@('High', 'Medium', 'Low') -contains [string]$item.Urgency) { [string]$item.Urgency } else { 'Medium' }
    $closed = ([string]$item.Status -eq 'done')

    $body = $(if ($why) { $why } else { 'Follow up on a message tracked in PacketRat.' }) + "`n`nTracked in PacketRat (urgency: $urgency)" + $(if ($closed) { '; already done there' } else { '' }) + '. The message itself stays in the mailbox.'
    # fleet-handoff v1: the file Halyard's Intake reads (POST /api/intake/handoff/preview, docs/HANDOFF.md in Halyard).
    $doc = [ordered]@{
        format = $script:PacketRatHandoffFormat
        version = 1
        source = [ordered]@{ app = 'packetrat'; exportedAt = [DateTime]::UtcNow.ToString('o') }
        items = @([ordered]@{
            ref = 'packetrat-' + $ref
            title = $name
            body = $body
            labels = @('urgency::' + $urgency.ToLowerInvariant())
            kind = 'story'
        })
    }

    $dir = Join-Path (Join-Path $Root 'Logs') 'handoff'
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $file = Join-Path $dir ('halyard-' + $ref + '.json')
    [IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject $doc -Depth 8), (New-Object Text.UTF8Encoding $false))
    return [pscustomobject]@{ Document = $doc; File = ('Logs\handoff\halyard-' + $ref + '.json') }
}
