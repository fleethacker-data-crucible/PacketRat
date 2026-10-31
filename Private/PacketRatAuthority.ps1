# PacketRat - the human-authority statement (Fleet Rule 6): what needs a person, what PacketRat never does, how to watch it, how to stop it
#requires -Version 5.1
# The approval points are derived from the command registry, so a new command that changes data or acts on a message
# shows up here without anyone remembering to list it. The "never" list is a promise: tests/Test-PacketRatAuthority.ps1
# fails if the code gains a path that would break it.

# Commands that act on the person's original Outlook message but are not "destructive" (all are reversible in Outlook).
$script:PacketRatMailActionCommands = @('packetrat item categorize', 'packetrat item mark-read', 'packetrat draft open', 'packetrat item open')

function Get-PacketRatAuthority {
    param([string]$Root)
    $list = @(Get-PacketRatCommandList)
    $approval = New-Object System.Collections.Generic.List[object]
    foreach ($c in $list) {
        if ($c.destructive) {
            [void]$approval.Add([ordered]@{ command = $c.name.Substring(10); what = $c.summary; how = 'CLI: refused without --yes (or --dry-run to preview). Browser: a button you click; archive and move also ask you to confirm.' })
        } elseif ($script:PacketRatMailActionCommands -contains $c.name) {
            [void]$approval.Add([ordered]@{ command = $c.name.Substring(10); what = $c.summary; how = 'One message at a time, only when you press it. Reversible in Outlook.' })
        }
    }
    [void]$approval.Add([ordered]@{ command = 'assist ask'; what = 'Bridge may suggest a change (dismiss, status, priority).'; how = 'A suggestion only: it runs when you press Confirm in the browser, or when you run the printed command yourself.' })

    $where = 'unknown'; $hostName = ''
    try {
        $cfg = Get-PacketRatLlmConfig -Profile 'Auto'
        $u = [Uri]$cfg.Url
        $hostName = $u.Host
        $where = if ($u.IsLoopback) { 'this PC' } else { 'outside this PC' }
        $router = [string]$cfg.Router
    } catch { $router = '' }

    return [ordered]@{
        schema     = 'packetrat.authority/1'
        principle  = 'A person decides. PacketRat reads, proposes and prepares; it does not act on your mail for you.'
        approvalPoints = @($approval.ToArray())
        neverDoes  = @(
            'Send, forward or reply to mail by itself. A reply is opened in Outlook for you to review; it is sent only if you press Send there.'
            'Delete mail. Archive and move are reversible in Outlook.'
            'Write an AI token to disk, the browser or a log. A manual token lasts only for the session. (A key you put in your own settings file is yours to protect.)'
            'Act on instructions it finds inside an email. Message text is treated as untrusted data.'
            'Run a change the AI suggested without your confirmation.'
            'Change mail on the Files or Graph providers; those are read-only here.'
        )
        aiDestination = [ordered]@{ where = $where; host = $hostName; router = $router; note = 'The sender, subject and text of the mail being triaged are sent to this address when an AI call is made. Use only an endpoint your organization has approved.' }
        monitoring = @(
            'stats show: how many things it did or prepared (an estimate of time saved, not a score).'
            'commands --json: every action it can take.'
            'Logs/packetrat.log: what the service did.'
        )
        stop = @(
            'End session in the browser.'
            'Stop-PacketRat.ps1.'
            'Close its console window, or press Ctrl+C in it.'
            'It stops itself about 20 seconds after the last PacketRat tab closes, unless it was started with --stay.'
        )
    }
}
