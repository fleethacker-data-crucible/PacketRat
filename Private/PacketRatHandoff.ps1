# PacketRat - hand a tracked mail to Halyard as a backlog item candidate (a plain file; nothing is sent anywhere)
#requires -Version 5.1
# Writes Logs\handoff\halyard-<ref>.json for one tracked action: the subject as the title, PacketRat's recommended action
# as the narrative, the urgency as a label, and the list of things Halyard still has to decide (parent, theme, points,
# sprint, area). The shape follows the work-item JSON Halyard's own fixtures use. It never carries the sender, the message
# body, the Outlook id or the item key (a short hash of the key names the file). A person reads the file before Halyard
# uses it; Halyard writes to its sandbox only after a human accepts.

$script:PacketRatHandoffSchema = 'packetrat.halyard-handoff/1'
$script:PacketRatHandoffNote = 'A candidate backlog item from one mail a person tracked in PacketRat. It holds the subject, the recommended action and the urgency; no sender, no message body, no Outlook id. Halyard still has to place it (parent, theme, points, sprint, area), and a person reviews it before anything is written to a backlog.'

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
    $id = 'STORY-' + (ConvertTo-PacketRatHandoffSlug $name)
    $narrative = "## Purpose`n" + $(if ($why) { $why } else { 'Follow up on a message tracked in PacketRat.' }) + "`n`n## Source`nTracked in PacketRat (urgency: $urgency). The message itself stays in Outlook."

    $doc = [ordered]@{
        schema = $script:PacketRatHandoffSchema
        exportedAt = [DateTime]::UtcNow.ToString('o')
        source = 'packetrat'
        note = $script:PacketRatHandoffNote
        items = @([ordered]@{
            sourceKey = 'packetrat:' + $ref
            sourceRepository = 'packetrat'
            sourceTitle = $name
            id = $id
            type = 'STORY'
            title = 'STORY :: ' + $name
            labels = @('halyard', 'source::packetrat', 'type::story', ('urgency::' + $urgency.ToLowerInvariant()))
            closed = $closed
            meta = [ordered]@{ type = 'STORY'; id = $id; parent = $null; theme = $null; state = $(if ($closed) { 'closed' } else { 'open' }); area = $null; points = $null; sprint = $null }
            narrative = $narrative
            confidence = 'low'
            reason = 'A person tracked this message in PacketRat; Halyard has not placed it in the hierarchy yet.'
            gaps = @('parent', 'theme', 'area', 'points', 'sprint')
        })
    }

    $dir = Join-Path (Join-Path $Root 'Logs') 'handoff'
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $file = Join-Path $dir ('halyard-' + $ref + '.json')
    [IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject $doc -Depth 8), (New-Object Text.UTF8Encoding $false))
    return [pscustomobject]@{ Document = $doc; File = ('Logs\handoff\halyard-' + $ref + '.json') }
}
