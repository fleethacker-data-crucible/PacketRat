# Demo walkthrough (for a screen recording)

A script for recording PacketRat in about four minutes using **synthetic data only**. Nothing in it touches a real mailbox, a real model key or real queue data, so it is safe to record, repeat and share. For the written user guide, see [walkthrough/README.md](walkthrough/README.md).

## Ground rules

- **Synthetic mail only.** The browser demo (`Launch-PacketRat.bat demo`) shows hard-coded sample messages and never connects to Outlook or an AI endpoint. The only other mail used here is the three `.eml` files in `tests/fixtures/mail`, which are invented.
- **A fresh data folder for every take.** PacketRat keeps its queue, rules, dismissals, counts and log in `Logs/`. Point it at a new empty folder with `PACKETRAT_DATA_DIR` (a full path) so the recording never shows, reads or changes real data, and so every take starts from zero. Process files (the running server's runtime file) stay in `Logs/`.
- **No keys on screen.** Do not open `Config/packetrat.env`, and do not enter a token in demo mode.
- **Nothing is sent.** Say it and show it: drafts open for review in Outlook, and a person sends them.

## Before each take

```powershell
# A new, empty data folder for this take (any full path works).
$env:PACKETRAT_DATA_DIR = Join-Path $env:TEMP ('PacketRatDemo-' + (Get-Date -Format 'HHmmss'))
.\PacketRat-CLI.bat stats show
```

`stats show` should report zero actions and no minutes: that is the proof the folder is fresh. Close other windows, turn off notifications and use the browser at 100 percent zoom.

## Part A: the browser demo (about 2 minutes 30)

Start it with `Launch-PacketRat.bat demo`. A banner says only sample data is used. Check the button names on screen against this script before recording; the wording of the UI is the source of truth.

| Time | On screen | Do | Say |
|---|---|---|---|
| 0:00 | Overview with the demo banner | Hold for a few seconds. | "PacketRat turns an inbox into a short list of actions, on this PC, without sending anything." |
| 0:15 | Overview signals | Click the title of the first signal. | "Each signal opens the original message in Outlook. In the demo it just says so." |
| 0:35 | Action queue | Open the queue from the sidebar. | "Every follow-up sorted by urgency, with where the priority came from: a rule, or the AI's suggestion." |
| 0:55 | Priority selector on one item | Change one item's priority. | "A person can override any priority, and the choice survives the next scan." |
| 1:15 | Draft on one item | Open the draft dialog and generate. | "Drafts are text to review. PacketRat opens an Outlook reply with the text above your signature. It never sends." |
| 1:40 | Dismiss on another item | Dismiss it with a reason, then open Dismissal memory and restore it. | "Dismissals are remembered, with the reason, and can be undone." |
| 2:05 | Overview, time saved | Show the minutes-saved card. | "This is an estimate of time saved, from counts of what PacketRat did. It is not a measurement and not a score for anyone." |
| 2:25 | End session | Choose End session. | "One click stops the local service." |

Reloading the page or closing the tab resets the demo, so you can retake Part A without touching the data folder.

## Part B: the command line on the fresh folder (about 1 minute 30)

Same `PACKETRAT_DATA_DIR` as above. Every action in the browser has a named command.

```powershell
.\PacketRat-CLI.bat commands
.\PacketRat-CLI.bat queue show
.\PacketRat-CLI.bat credentials status
.\PacketRat-CLI.bat stats show
.\PacketRat-CLI.bat stats export --out "$env:PACKETRAT_DATA_DIR\counts.json"
.\PacketRat-CLI.bat stats reset --dry-run
```

| Command | Say |
|---|---|
| `commands` | "Anything you can click, a script or an agent can run: noun, verb, options." |
| `queue show` | "The queue is empty because this folder is new." |
| `credentials status` | "Which credential source is set. Tokens are never shown." |
| `stats show` | "Counts start at zero." |
| `stats export` | "The raw counts as a JSON file for a dashboard. No mail content in it." |
| `stats reset --dry-run` | "Commands that overwrite data need --yes, and --dry-run shows what would happen without doing it." |

## Part C (optional): the Files provider

If the recording can use a local model, show mail read with no Outlook at all, from the invented sample files:

```powershell
.\PacketRat-CLI.bat inbox analyze --provider Files --folder tests\fixtures\mail
```

This sends the sample messages' text to whichever AI endpoint is configured, so use it only with a local model. Without one, skip Part C: Part A already shows an analysis from the demo's built-in sample.

## After the take

```powershell
.\Stop-PacketRat.ps1
Remove-Item -LiteralPath $env:PACKETRAT_DATA_DIR -Recurse -Force
Remove-Item Env:\PACKETRAT_DATA_DIR
```

The folder holds only what this take created. Delete it so the next take starts clean.

## Checklist before publishing the video

- The demo banner or the fresh-folder `stats show` is visible early, so a viewer can see no real data is used.
- No real name, address, subject, token, path to a real mailbox export or `Config/packetrat.env` appears in any frame.
- The words "estimate" (time saved) and "nothing is sent" are said once each.
- Features that need a running service or a real mailbox are not shown as working: Outlook actions (archive, move, categorize, mark read), Microsoft Graph, and a live model run are not part of this recording.

## Commands from other open pull requests

These exist only once their pull requests are merged, so the checked script above does not use them. Add them to Part B when they land.

| Command | Where it comes from |
|---|---|
| `app authority` | Human-authority statement: where PacketRat waits for a person, what it never does, how to stop it. |
| `log show`, `log verify` | The tamper-evident action log. |
| `burden show` | The measured-burden record (the real before/after timing still needs a person). |
| `item handoff` | A tracked mail as a Halyard backlog item candidate file. |

## Tests

`tests/Test-PacketRatDataDir.ps1` (in CI) checks that `PACKETRAT_DATA_DIR` moves the data and the log to a fresh folder and leaves `Logs/` alone, that a relative path is refused, and that every `PacketRat-CLI.bat` command in this script exists and every repo path it names is real.
