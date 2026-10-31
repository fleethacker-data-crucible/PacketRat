# Action log

PacketRat keeps a local, append-only log of the actions it ran for a person, so anyone reviewing its work can see what it did and can tell if the record was altered. It is a hash chain: each line holds the SHA-256 of the line before it.

The log is a file on this PC (`Logs/packetrat-actions.jsonl`, not committed, never sent anywhere). It stores **no mail content**: no subjects, senders, bodies, reply text, rule text or tokens.

## Commands

```bat
PacketRat-CLI.bat log show
PacketRat-CLI.bat log verify
```

| Command | API route | What it does |
|---|---|---|
| `log show` | `GET /api/log` | The newest 100 lines, the total count and the chain head. |
| `log verify` | `GET /api/log/verify` | Walks the whole chain. Exit code 0 if it is intact, 1 with the first broken line number and the reason if not. |

Both only read. Reading the log is not logged.

## What a line holds

One JSON object per line, UTF-8 without a BOM:

| Field | Meaning |
|---|---|
| `seq` | Line number, starting at 1 with no gaps. |
| `at` | When it ran (UTC, ISO 8601). |
| `route` | The API route that ran, such as `/api/item/archive`. |
| `outcome` | `ok` or `failed`. A failed action is logged too. |
| `keyRef` | The first 12 hex characters of the SHA-256 of the item key, or empty. It lets a reviewer match lines about the same item without the key or any message text being stored. |
| `prev` | The `hash` of the previous line (64 zeros for line 1). |
| `hash` | SHA-256 of `seq`, `at`, `route`, `outcome`, `keyRef` and `prev` joined with `\|`. |

Example:

```json
{"seq":2,"at":"2026-10-31T13:02:11.0000000Z","route":"/api/item/archive","outcome":"ok","keyRef":"<first 12 hex characters of the key hash>","prev":"<hash of line 1>","hash":"<hash of this line>"}
```

## What is logged

Every route that does something: analysis, reports, drafts, status and priority changes, dismissals, rules, the inbox actions (archive, move, categorize, mark read), opening Outlook items, counter reset, assistant questions, credential changes and cancel. Routes that only read are not logged. The set is the same as the POST commands in `commands --json`, and a test keeps them equal.

## What it does and does not prove

- Editing, deleting, inserting or reordering a line **before the end** of the log breaks the chain, and `log verify` names the first line that no longer fits.
- Cutting lines off the **end**, or rewriting the whole file with a rebuilt chain, cannot be detected by the file alone. To prove the log was not cut or rewritten, write down the `head` hash that `log show` prints (for example in a turnover note) and compare it later.
- It is tamper-evident, not tamper-proof: anyone with write access to `Logs/` can delete the file. It records what PacketRat did, not who asked.
- Logging is best effort and never blocks an action. If a line cannot be written, PacketRat warns and carries on.

## Tests

`tests/Test-PacketRatActionLog.ps1` (in CI) checks the chain, that an edit, a removed line and a reorder are each caught, that no key or message text is stored, that the line fields match this page, and that the logged routes equal the POST commands.
