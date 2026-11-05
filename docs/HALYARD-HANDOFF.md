# Hand a tracked mail to Halyard

A mail you tracked in PacketRat can become a backlog item in Halyard. PacketRat writes one plain JSON file; a person reads it; Halyard picks it up. Nothing is sent over a network, and nothing is written to any backlog by this step.

**Status.** Halyard reads this file: on its Intake page (or `POST /api/intake/handoff/preview`, then `/run`) it previews the drafts, then copies them into the backlog it may write to through the normal write gateway, with a `source::packetrat` label and a link back to the ref. Importing the same ref again is recognised as already copied. The format is `fleet-handoff` version 1, defined by Halyard's `docs/HANDOFF.md`; PacketRat is one of its two exporters.

## Command

```bat
PacketRat-CLI.bat item handoff --key <action key>
```

The key is that of a tracked action in the queue (`queue show`), not a dismissed one. The command writes `Logs/handoff/halyard-<ref>.json` (not committed), where `<ref>` is the first 12 hex characters of the SHA-256 of the key. Running it again for the same action rewrites the same file. The browser server answers the same thing at `POST /api/item/handoff`.

## What the file holds, and what it never holds

It holds the subject (cut to 120 characters) as the title, PacketRat's recommended action (cut to 600) as the narrative, and the urgency as a label. It **never** holds the sender, the sender's address, the message body, the Outlook id or the item key.

Because the subject is mail content, treat the file like the mail: it stays in `Logs/` on this PC until a person moves it, and a person reads it before Halyard uses it. Halyard writes to the backlog it may write to only after a human accepts, and to the source backlog only after that.

## Format

Format `fleet-handoff`, version 1.

| Field | Meaning |
|---|---|
| `format` | Always `fleet-handoff`. |
| `version` | Always `1`. |
| `source` | `app` is `packetrat`; `exportedAt` is when the file was written (UTC, ISO 8601). |
| `items` | A list with one item (a list so a later version can carry several). |

Each item:

| Field | Meaning |
|---|---|
| `ref` | `packetrat-` and the 12-character reference. Stable for one action; it is not the message id. |
| `title` | The subject, cleaned of line breaks and cut to 120 characters. |
| `body` | PacketRat's recommended action (cut to 600), then a line saying it was tracked in PacketRat with its urgency, and that the message itself stays in the mailbox. |
| `labels` | `urgency::` high, medium or low. |
| `kind` | Always `story`: a tracked mail is one piece of work, and Halyard decides where it belongs. |

Example:

```json
{
  "format": "fleet-handoff",
  "version": 1,
  "source": { "app": "packetrat", "exportedAt": "2026-10-31T18:00:00.0000000Z" },
  "items": [
    {
      "ref": "packetrat-3f9a1c07be52",
      "title": "Renew the building badge",
      "body": "Reply by Friday.

Tracked in PacketRat (urgency: High). The message itself stays in the mailbox.",
      "labels": ["urgency::high"],
      "kind": "story"
    }
  ]
}
```

## Tests

`tests/Test-PacketRatHandoff.ps1` (in CI) checks the export of a synthetic tracked action against this page's fields, that the sender, address, body, Outlook id and key never appear in the file, the refusals (unknown or dismissed action), the title and id patterns, the API route and the command.
