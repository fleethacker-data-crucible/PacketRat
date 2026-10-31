# Hand a tracked mail to Halyard

A mail you tracked in PacketRat can become a backlog item in Halyard. PacketRat writes one plain JSON file; a person reads it; Halyard picks it up. Nothing is sent over a network, and nothing is written to any backlog by this step.

**Status.** This is PacketRat's half. Halyard has no reader for the file yet (Halyard issue #31, "accept items from PacketRat", is still open). The shape follows the work-item JSON that Halyard's fixtures use (`id`, `type`, `title`, `labels`, `closed`, `meta`, `narrative`), plus the intake fields Halyard keeps for a source item (`sourceKey`, `sourceRepository`, `sourceTitle`, `confidence`, `reason`, `gaps`). When Halyard adds its reader, the two sides should be checked against this page.

## Command

```bat
PacketRat-CLI.bat item handoff --key <action key>
```

The key is that of a tracked action in the queue (`queue show`), not a dismissed one. The command writes `Logs/handoff/halyard-<ref>.json` (not committed), where `<ref>` is the first 12 hex characters of the SHA-256 of the key. Running it again for the same action rewrites the same file. The browser server answers the same thing at `POST /api/item/handoff`.

## What the file holds, and what it never holds

It holds the subject (cut to 120 characters) as the title, PacketRat's recommended action (cut to 600) as the narrative, and the urgency as a label. It **never** holds the sender, the sender's address, the message body, the Outlook id or the item key.

Because the subject is mail content, treat the file like the mail: it stays in `Logs/` on this PC until a person moves it, and a person reads it before Halyard uses it. Halyard writes to its sandbox only after a human accepts, and the source backlog only after that.

## Format

Schema `packetrat.halyard-handoff/1`.

| Field | Meaning |
|---|---|
| `schema` | Always `packetrat.halyard-handoff/1`. |
| `exportedAt` | When the file was written (UTC, ISO 8601). |
| `source` | Always `packetrat`. |
| `note` | What the file is and that a person reviews it. |
| `items` | A list with one item (a list so a later version can carry several). |

Each item:

| Field | Meaning |
|---|---|
| `sourceKey` | `packetrat:` and the 12-character reference. Stable for one action; it is not the message id. |
| `sourceRepository` | Always `packetrat`. |
| `sourceTitle` | The subject, cleaned of line breaks. |
| `id` | `STORY-` and a slug of the subject (Halyard's id pattern). |
| `type` | Always `STORY`: a tracked mail is one piece of work, and Halyard decides where it belongs. |
| `title` | `STORY :: ` and the subject (Halyard's title pattern). |
| `labels` | `halyard`, `source::packetrat`, `type::story` and `urgency::` high, medium or low. |
| `closed` | True only if the action is done in PacketRat. |
| `meta` | Halyard's metadata block: `type`, `id`, `state` (`open` or `closed`), and `parent`, `theme`, `area`, `points`, `sprint` as null. |
| `narrative` | A Purpose section with the recommended action and a Source section. |
| `confidence` | Always `low`: PacketRat does not know where it fits. |
| `reason` | Why the item exists. |
| `gaps` | What Halyard still has to decide: `parent`, `theme`, `area`, `points`, `sprint`. |

Example:

```json
{
  "schema": "packetrat.halyard-handoff/1",
  "exportedAt": "2026-10-31T18:00:00.0000000Z",
  "source": "packetrat",
  "note": "A candidate backlog item from one mail a person tracked in PacketRat. ...",
  "items": [
    {
      "sourceKey": "packetrat:3f9a1c07be52",
      "sourceRepository": "packetrat",
      "sourceTitle": "Renew the building badge",
      "id": "STORY-renew-the-building-badge",
      "type": "STORY",
      "title": "STORY :: Renew the building badge",
      "labels": ["halyard", "source::packetrat", "type::story", "urgency::high"],
      "closed": false,
      "meta": { "type": "STORY", "id": "STORY-renew-the-building-badge", "parent": null, "theme": null, "state": "open", "area": null, "points": null, "sprint": null },
      "narrative": "## Purpose\nReply by Friday.\n\n## Source\nTracked in PacketRat (urgency: High). The message itself stays in Outlook.",
      "confidence": "low",
      "reason": "A person tracked this message in PacketRat; Halyard has not placed it in the hierarchy yet.",
      "gaps": ["parent", "theme", "area", "points", "sprint"]
    }
  ]
}
```

## Tests

`tests/Test-PacketRatHandoff.ps1` (in CI) checks the export of a synthetic tracked action against this page's fields, that the sender, address, body, Outlook id and key never appear in the file, the refusals (unknown or dismissed action), the title and id patterns, the API route and the command.
