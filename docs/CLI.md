# PacketRat CLI and API

PacketRat follows the Fleet CLI parity proposal: every action in the browser has a named command, and scripts or agents can run it without the browser. The CLI goes through the same launcher as before (no new BAT file):

```bat
PacketRat-CLI.bat commands
PacketRat-CLI.bat <noun> <verb> [--option value ...] [--json] [--out <file>] [--yes] [--dry-run] [--analyze]
```

When the first argument is an option (`PacketRat-CLI.bat -Profile AiEndpoint`), or there is none, `PacketRat-CLI.bat` still runs the console inbox analysis as before.

## Commands

| Command | What it does | Options |
|---|---|---|
| `app health` | Check that PacketRat answers. | |
| `app authority` | The human-authority statement: approval points, what PacketRat never does, how to monitor and stop it. Same content as [HUMAN-AUTHORITY.md](HUMAN-AUTHORITY.md); the browser server answers it at `GET /api/authority`. | |
| `queue show` | The action queue, dismissals, rules, credential status and the last report. | |
| `inbox analyze` | Read recent Outlook mail (or exported `.eml`/`.msg` files) and build the report and action queue (no mail is changed or sent). | `--profile` `--provider` (COM, Graph or Files), `--folder` (Files: folder of `.eml`/`.msg` files, default `PACKETRAT_MAIL_FOLDER`), `--max-emails` `--days-back` (not used by Files), `--classification` (Single or Batch) |
| `report generate` | Ask the AI for a brief, actions, risks or an explanation of the current report. | `--mode` (required), `--section-id`, `--profile` |
| `report track` | Turn a verified report source message into an open action. | `--key` (required), `--urgency` |
| `item status` | Set an action to open, in progress or done. | `--key` `--status` (both required) |
| `item dismiss` | Dismiss an action (`item restore` brings it back). | `--key` (required), `--reason` |
| `item restore` | Restore a dismissed action. | `--key` (required) |
| `inbox cancel` | Cancel an AI generation that is streaming in a running PacketRat (needs `PACKETRAT_LLM_STREAM=1`). Run it from a second console. | none |
| `item open` | Open the original message in classic Outlook. | `--key` (required) |
| `item archive` | Move the original to the Outlook archive folder and dismiss it from the queue. Needs `--yes`. Classic Outlook (COM) only. | `--key` (required) |
| `item move` | Move the original to an existing Outlook folder (inbox subfolder or sibling). Needs `--yes`. COM only. | `--key`, `--folder` (both required) |
| `item categorize` | Add an Outlook category to the original (existing categories are kept). COM only. | `--key`, `--category` (both required) |
| `item mark-read` | Mark the original read, or unread with `--unread`. COM only. | `--key` (required), `--unread` |
| `item handoff` | Write a tracked action as a Halyard backlog item candidate in `Logs/handoff/` (subject, recommended action and urgency; no sender, body or Outlook id). Nothing is sent. See [HALYARD-HANDOFF.md](HALYARD-HANDOFF.md). | `--key` (required) |
| `priority set` | Override an action's priority. | `--key` `--urgency` (both required) |
| `priority reset` | Return an action to its triaged priority. | `--key` (required) |
| `rules set` | Replace the triage rules with the ones in a JSON file. **Needs `--yes`.** | `--file` (required) |
| `draft create` | Draft a reply with the AI for review (nothing is sent). | `--key` (required), `--instruction`, `--profile` |
| `draft open` | Open an Outlook reply with reviewed text above your signature (never sent). | `--key` `--body-file` (required), `--subject`, `--apply-subject` |
| `stats show` (or just `stats`) | Estimated minutes saved: a total and a per-action breakdown. An estimate, not a measurement and not a score for anyone. | |
| `stats export` | The raw action counts as JSON (`packetrat.usage-counts/1`) for another tool; add `--out file.json` to write it. Format: [COUNTS-EXPORT.md](COUNTS-EXPORT.md). | |
| `stats reset` | Zero the counters and start a new count. | needs `--yes` |
| `burden show` | The measured-burden record: per task, the baseline entered once and the times of later runs, with mean, median and change. A record only; see [BURDEN-RECORD.md](BURDEN-RECORD.md). | |
| `burden baseline` | Enter a task's before time in seconds. Entered once; a second entry is refused unless `--replace true`. | `--task` `--seconds` (both required), `--replace` |
| `burden record` | Record one timed run of a task, in seconds. | `--task` `--seconds` (both required) |
| `log show` | The newest lines of the tamper-evident action log (route, outcome, a short hash of the item key; never mail content) and the chain head. See [ACTION-LOG.md](ACTION-LOG.md). | |
| `log verify` | Check the action log hash chain. Exits 1 and names the first broken line if the log was edited, reordered or cut in the middle. | |
| `assist brief` | A short spoken-style briefing of the open actions, built from the queue with no AI call (the Bridge panel reads it aloud with a local voice). | |
| `assist ask` | Ask about the queue. The AI answers from the queue only and may propose actions (dismiss, status, priority); nothing is run, and each proposal comes with the exact command to confirm. | `--question` (required), `--profile` |
| `voice status` | Whether the local speech-input assets listed in `Config/voice-assets.json` are present and match their SHA-256. Nothing is downloaded or sent. | |
| `credentials status` | Which AI credential source is set (tokens are never shown). | |
| `credentials set` | Choose Lazarette or a manual session token. | `--source` `--profile` (required), `--token-env` |
| `credentials check` | Check locally that a credential resolves (no AI call, no mail read). | `--profile` |
| `credentials clear` | Forget manual session tokens. | |

`PacketRat-CLI.bat commands --json` prints the same list as JSON (schema `packetrat.commands/1`), with every option's type, whether it is required, and its allowed values. The browser server answers the same document at `GET /api/commands`.

## Flags and results

- `--json` prints one JSON document: `{"schema":"packetrat.result/1","command":...,"ok":...,"result":...}`, or `error` and `errorType` (`usage` or `failed`) when it fails.
- `--out FILE` writes that document to FILE as UTF-8 without a BOM.
- `--yes` is required by commands that overwrite or move saved data (`rules set`, `item archive`, `item move`, `stats reset`).
- `--dry-run` checks the command and its options and shows the route and body it would send, without running it. Tokens are never shown.
- `--analyze` runs `inbox analyze` first, for the commands that work on an analysis (`report generate`, `report track`, `draft create`). Each CLI run is its own process, so without it those commands report that there is no analysis yet.
- Exit codes: `0` success, `1` the command failed, `2` a usage error. Nothing waits on a dialog.

## Tokens

The CLI never takes a token on the command line, where it would land in shell history. `credentials set --source manual --token-env NAME` reads it from the environment variable `NAME`, and it lasts for that one run, the same as a manual token in the browser lasts for that session. Lazarette and approved environment variables work as they do in the browser.

## Safety

The CLI calls the same core (`Private/PacketRatApi.ps1`) as the browser, so it keeps the same safeguards: no mail is changed or sent, drafts open for review only, and manual tokens are never saved or returned. The browser server's API stays locked to the local user: a per-session nonce, Host and Origin checks, and no CORS.

## Tests

`tests/Test-PacketRatCommands.ps1` (in CI) fails if a browser or dispatcher route has no command, if a command names a route the dispatcher doesn't have, or if the CLI's schema, exit codes, `--yes` check or BOM-free `--out` change. `tests/Test-PacketRatAuthority.ps1` keeps [HUMAN-AUTHORITY.md](HUMAN-AUTHORITY.md) in step with the command list: every command that needs `--yes` must be in its approval table.
