# PacketRat - Bridge: the spoken/written assistant layer (read-only; it never changes or sends mail)
#requires -Version 5.1
# Step 1 (this file): a deterministic spoken briefing built from the action queue, with no AI call. Plain sentences, no
# Markdown, so a local voice can read it as written.

function ConvertTo-PacketRatSpokenText([string]$Text, [int]$Max = 160) {
    $t = [regex]::Replace([string]$Text, 'https?://\S+', ' link ')
    $t = [regex]::Replace($t, '[\*_`#>|\[\]{}<]', ' ')
    $t = ([regex]::Replace($t, '\s+', ' ')).Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max).TrimEnd() + '...' }
    return $t
}

function Get-PacketRatSpokenBriefing {
    param($Store, [int]$Top = 3)
    $open = @($Store.Checklist | Where-Object { $_.Status -eq 'open' -or $_.Status -eq 'in_progress' -or -not $_.Status })
    if ($open.Count -eq 0) {
        return [ordered]@{ schema = 'packetrat.briefing/1'; openCount = 0; highCount = 0; items = @(); say = 'Bridge, all quiet. No open actions in the queue.' }
    }
    $rank = @{ High = 0; Medium = 1; Low = 2 }
    $sorted = @($open | Sort-Object { if ($rank.ContainsKey([string]$_.Urgency)) { $rank[[string]$_.Urgency] } else { 3 } }, { [string]$_.Subject })
    $high = @($sorted | Where-Object { $_.Urgency -eq 'High' }).Count
    $lead = @($sorted | Select-Object -First $Top)
    $parts = New-Object System.Collections.Generic.List[string]
    [void]$parts.Add(('Bridge, you have {0} open {1}, {2} high priority.' -f $open.Count, $(if ($open.Count -eq 1) { 'action' } else { 'actions' }), $high))
    $n = 0
    $items = foreach ($i in $lead) {
        $n++
        $who = ConvertTo-PacketRatSpokenText ([string]$(if ($i.PSObject.Properties['From'] -and $i.From) { $i.From } else { $i.FromEmail })) 60
        $subj = ConvertTo-PacketRatSpokenText ([string]$i.Subject) 90
        $line = if ($who) { 'Number {0}, {1} priority, from {2}: {3}.' -f $n, ([string]$i.Urgency).ToLowerInvariant(), $who, $subj } else { 'Number {0}, {1} priority: {2}.' -f $n, ([string]$i.Urgency).ToLowerInvariant(), $subj }
        [void]$parts.Add($line)
        [ordered]@{ key = [string]$i.Key; urgency = [string]$i.Urgency; subject = [string]$i.Subject }
    }
    if ($open.Count -gt $Top) { [void]$parts.Add(('{0} more in the queue.' -f ($open.Count - $Top))) }
    return [ordered]@{ schema = 'packetrat.briefing/1'; openCount = $open.Count; highCount = $high; items = @($items); say = ($parts -join ' ') }
}
