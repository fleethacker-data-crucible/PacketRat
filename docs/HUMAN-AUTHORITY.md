# Human authority in PacketRat

**A person decides. PacketRat reads, proposes and prepares; it does not act on your mail for you.**
`PacketRat-CLI.bat app authority` and the Configuration page show the live version of this page. They are built from the
command list, so a new command that changes data appears there on its own.

## Where a person must approve

| Action | What it does | How you approve |
|---|---|---|
| `item archive` | Moves the original message to your Outlook archive and removes it from the queue. | CLI: needs `--yes`. Browser: a confirm. Reversible in Outlook. |
| `item move` | Moves the original message to a folder you name. | CLI: needs `--yes`. Browser: a confirm. Reversible in Outlook. |
| `rules set` | Replaces the triage rules with the ones you give it. | CLI: needs `--yes`. Browser: Save rules. |
| `stats reset` | Zeros the minutes-saved counters. | CLI: needs `--yes`. |
| `item categorize` | Adds an Outlook category to one message. | One message, when you press it. Reversible. |
| `item mark-read` | Marks one message read or unread. | One message, when you press it. Reversible. |
| `item open` | Opens the original message in classic Outlook. | One message, when you press it. |
| `draft open` | Opens a reply in Outlook with the reviewed text above your signature. | One message, when you press it. You send it, or you don't. |
| `assist ask` | Bridge may suggest a change (dismiss, status, priority). | It is only a suggestion. It runs when you press Confirm, or when you run the printed command. |

## What PacketRat never does

- Send, forward or reply to mail by itself. A reply is opened in Outlook for you to review; it is sent only if you press Send there.
- Delete mail. Archive and move are reversible in Outlook.
- Write an AI token to disk, the browser or a log. A manual token lasts only for the session. (A key you put in your own settings file is yours to protect.)
- Act on instructions it finds inside an email. Message text is treated as untrusted data.
- Run a change the AI suggested without your confirmation.
- Change mail on the Files or Graph providers; those are read-only here.

These are enforced by a test: `tests/Test-PacketRatAuthority.ps1` fails if the code gains a send or delete call.

## Where your data goes

When an AI call is made, the sender, subject and text of the mail being triaged go to the AI address you configured. By
default that is a model on this PC. If it is somewhere else, the Configuration page says so and names the host. Use only
an endpoint your organization has approved for email content.

## How to watch it

- `stats show`: how many things it did or prepared (an estimate of time saved, not a score for anyone).
- `commands --json`: every action it can take.
- `Logs/packetrat.log`: what the service did.

## How to stop it

- **End session** in the browser.
- `Stop-PacketRat.ps1`.
- Close its console window, or press Ctrl+C in it.
- It stops itself about 20 seconds after the last PacketRat tab closes, unless it was started with `--stay`.
