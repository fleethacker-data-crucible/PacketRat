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
| `queue show` | The action queue, dismissals, rules, credential status and the last report. | |
| `inbox analyze` | Read recent Outlook mail and build the report and action queue (no mail is changed or sent). | `--profile` `--provider` `--max-emails` `--days-back` |
| `report generate` | Ask the AI for a brief, actions, risks or an explanation of the current report. | `--mode` (required), `--section-id`, `--profile` |
| `report track` | Turn a verified report source message into an open action. | `--key` (required), `--urgency` |
| `item status` | Set an action to open, in progress or done. | `--key` `--status` (both required) |
| `item dismiss` | Dismiss an action (`item restore` brings it back). | `--key` (required), `--reason` |
| `item restore` | Restore a dismissed action. | `--key` (required) |
| `item open` | Open the original message in classic Outlook. | `--key` (required) |
| `item archive` | Move the original to the Outlook archive folder and dismiss it from the queue. Needs `--yes`. Classic Outlook (COM) only. | `--key` (required) |
| `item move` | Move the original to an existing Outlook folder (inbox subfolder or sibling). Needs `--yes`. COM only. | `--key`, `--folder` (both required) |
| `item categorize` | Add an Outlook category to the original (existing categories are kept). COM only. | `--key`, `--category` (both required) |
| `item mark-read` | Mark the original read, or unread with `--unread`. COM only. | `--key` (required), `--unread` |
| `priority set` | Override an action's priority. | `--key` `--urgency` (both required) |
| `priority reset` | Return an action to its triaged priority. | `--key` (required) |
| `rules set` | Replace the triage rules with the ones in a JSON file. **Needs `--yes`.** | `--file` (required) |
| `draft create` | Draft a reply with the AI for review (nothing is sent). | `--key` (required), `--instruction`, `--profile` |
| `draft open` | Open an Outlook reply with reviewed text above your signature (never sent). | `--key` `--body-file` (required), `--subject`, `--apply-subject` |
| `credentials status` | Which AI credential source is set (tokens are never shown). | |
| `credentials set` | Choose Lazarette or a manual session token. | `--source` `--profile` (required), `--token-env` |
| `credentials check` | Check locally that a credential resolves (no AI call, no mail read). | `--profile` |
| `credentials clear` | Forget manual session tokens. | |

`PacketRat-CLI.bat commands --json` prints the same list as JSON (schema `packetrat.commands/1`), with every option's type, whether it is required, and its allowed values. The browser server answers the same document at `GET /api/commands`.

## Flags and results

- `--json` prints one JSON document: `{"schema":"packetrat.result/1","command":...,"ok":...,"result":...}`, or `error` and `errorType` (`usage` or `failed`) when it fails.
- `--out FILE` writes that document to FILE as UTF-8 without a BOM.
- `--yes` is required by commands that overwrite saved data (`rules set`).
- `--dry-run` checks the command and its options and shows the route and body it would send, without running it. Tokens are never shown.
- `--analyze` runs `inbox analyze` first, for the commands that work on an analysis (`report generate`, `report track`, `draft create`). Each CLI run is its own process, so without it those commands report that there is no analysis yet.
- Exit codes: `0` success, `1` the command failed, `2` a usage error. Nothing waits on a dialog.

## Tokens

The CLI never takes a token on the command line, where it would land in shell history. `credentials set --source manual --token-env NAME` reads it from the environment variable `NAME`, and it lasts for that one run, the same as a manual token in the browser lasts for that session. Lazarette and approved environment variables work as they do in the browser.

## Safety

The CLI calls the same core (`Private/PacketRatApi.ps1`) as the browser, so it keeps the same safeguards: no mail is changed or sent, drafts open for review only, and manual tokens are never saved or returned. The browser server's API stays locked to the local user: a per-session nonce, Host and Origin checks, and no CORS.

## Tests

`tests/Test-PacketRatCommands.ps1` (in CI) fails if a browser or dispatcher route has no command, if a command names a route the dispatcher doesn't have, or if the CLI's schema, exit codes, `--yes` check or BOM-free `--out` change.
