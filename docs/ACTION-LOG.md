# Action log

PacketRat keeps a local record of the things it does, so a person can see what happened and when. It is for audit and
trust, not for scoring anyone.

## What is recorded

One line per action in `Logs/packetrat-actions.jsonl`:

```json
{"seq":3,"time":"2026-10-31T13:05:44.1200000Z","action":"item.archive","key":"id:0000ABCD","result":"ok","prev":"<hash of line 2>","hash":"<hash of this line>"}
```

| Field | Meaning |
|---|---|
| `seq` | 1, 2, 3, ... with no gaps. |
| `time` | UTC. |
| `action` | What was done, such as `inbox.analyze`, `item.archive`, `item.move`, `item.categorize`, `item.mark-read`, `item.dismiss`, `draft.create`, `draft.open`, `rules.set`, `stats.reset`, `assist.ask`, `credentials.set`, `session.stop`. |
| `key` | The message key (an Outlook id or a fingerprint), up to 200 characters. Empty for actions that are not about one message. |
| `result` | `ok` or `error`. |
| `prev`, `hash` | The chain: `hash` is SHA-256 of the previous hash and this line's own fields. |

**Never recorded:** mail text, subjects, sender addresses, folder or category names, dismissal reasons, AI prompts or
answers, and tokens. Reading things (the queue, the report, stats, this log) is not recorded.

## Check it

- `PacketRat-CLI.bat log show`: the last 100 actions and whether the chain is intact.
- `PacketRat-CLI.bat log verify`: walks the whole chain. A line that was edited, removed, added or reordered is reported
  with its line number and the reason, and the command exits with an error.
- Configuration > **Action log** shows the last 10 and has a Verify button.

## What it can and cannot catch

- It **detects** an edit to any line, and removing, adding or reordering a line anywhere except the very end.
- It **cannot detect** deleting only the newest lines: what is left is still a valid, shorter chain. To catch that, note
  the `tip` hash that `log verify` prints somewhere off this PC (a ticket, an email to yourself) and compare later.
- Someone with write access to the folder could rebuild the whole chain from scratch. This is evidence that the log was
  not casually edited, not protection against a determined person. Ship's Log is the planned hardened version.
- Writing the log never stops an action. If the log cannot be written, the action still happens and a warning is shown.
