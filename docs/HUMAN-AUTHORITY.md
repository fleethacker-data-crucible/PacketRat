# Human authority

PacketRat reads mail and proposes work. A person decides. This page says where PacketRat stops and waits, what it never does, how to watch it and how to stop it. `PacketRat-CLI.bat app authority` prints the same statement, and the browser server answers it at `GET /api/authority` (loopback only).

## Approval points

PacketRat changes mail or saved data only when a person asks for it by name. These commands overwrite or move something, so the CLI refuses them without `--yes`:

| Command | What it changes |
|---|---|
| `rules set` | Replaces the saved triage rules with the ones in a file. |
| `item archive` | Moves the original message to the Outlook archive folder and dismisses it from the queue. Classic Outlook only. Reversible in Outlook. |
| `item move` | Moves the original message to a folder you name. Classic Outlook only. Reversible in Outlook. |
| `stats reset` | Zeroes the minutes-saved counters. |

The browser asks before archiving. Other points where a person stays in charge:

- Replies are drafts. `draft create` writes text for review and `draft open` opens an Outlook reply window with that text above your signature. You read it and send it yourself, or close it.
- `assist ask` may propose actions. A proposal is a suggestion with the exact command to confirm; nothing runs until you run it.
- Analysis, reports and drafts run only when you start them. There is no schedule and nothing runs in the background.
- Mail read from files or Graph cannot be changed by PacketRat at all.
- AI credentials are chosen by you. A manual token lives for one session and is never saved.

Everything above can be checked in the command list: `PacketRat-CLI.bat commands --json` marks each command that needs `--yes` as `destructive`.

## What PacketRat never does

- It never sends mail. Nothing in the code calls a send function.
- It never deletes mail. Archive and move keep the message in Outlook.
- It never runs an AI proposal by itself.
- It never accepts a token on a command line or returns one from an API.
- It never sends usage data or counts anywhere. The only message text that leaves this PC goes to the AI endpoint you configured, when you run an analysis, report or draft.
- It never changes a message it has not been asked about by key.

## How to monitor it

- `PacketRat-CLI.bat queue show`: the action queue, dismissals, rules and the last report.
- `PacketRat-CLI.bat stats show`: counts of what PacketRat did (an estimate, not a score for anyone).
- `PacketRat-CLI.bat credentials status`: which credential source is set. Tokens are never shown.
- `PacketRat-CLI.bat log show` and `log verify`: the tamper-evident action log of what PacketRat ran, and a check that no line was edited, removed or reordered (see [ACTION-LOG.md](ACTION-LOG.md)).
- `Logs/packetrat.log`: a plain text log of what the app did and any errors.
- Outlook itself: archived and moved messages are in the folder you chose.
- `--dry-run` on any command shows the route and body it would send without running it.

## How to stop it

- Close the browser tab, or choose End session. The local server stops itself shortly after the last tab closes (unless `PACKETRAT_AUTO_STOP=0`).
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Stop-PacketRat.ps1` stops every PacketRat server on the PC.
- `PacketRat-CLI.bat inbox cancel` cancels an AI generation that is streaming, from a second console.
- Press Ctrl+C in a console run.
- To undo a change, move the message back in Outlook, or restore a dismissed item with `item restore`.

## Tests

`tests/Test-PacketRatAuthority.ps1` (in CI) fails if a command that needs `--yes` is missing from the approval table, if the table names a command that does not exist, if `app authority` and this page stop matching the command list, or if the code gains a call that sends or deletes mail.
