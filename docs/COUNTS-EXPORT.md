# Counts export (`counts.json`) as a data source

PacketRat keeps a plain count of the actions it performed or prepared. `stats export` hands those raw counts to another tool, such as a Semaphore dashboard. This page describes the file so a dashboard can read it. It covers the file format only: nothing here connects to Semaphore, and the export never sends anything anywhere.

The counts are an **estimate** of work PacketRat did, not a measurement and not a score for any person. The export holds no minutes, no message text, no senders and no subjects.

## Getting the file

```bat
PacketRat-CLI.bat stats export --out counts.json
```

The browser server answers the same data at `GET /api/stats/export` (loopback only). Both come from `Get-PacketRatUsageExport` in `Private/PacketRatUsage.ps1`.

The export document has the schema `packetrat.usage-counts/1`. The two routes wrap it differently:

| Source | Where the export document sits |
|---|---|
| `GET /api/stats/export` | `usage` in `{"ok":true,"usage":{...}}` |
| `stats export --out counts.json` | `result.usage`, inside the `packetrat.result/1` envelope that `--out` always writes |

A reader should look for `usage` (API) or `result.usage` (file) and then check that `schema` is `packetrat.usage-counts/1`.

## Example

The document, as `result.usage` holds it:

```json
{
  "schema": "packetrat.usage-counts/1",
  "estimate": true,
  "since": "2026-10-01T08:00:00.0000000-04:00",
  "exportedAt": "2026-10-31T09:30:00.0000000-04:00",
  "counts": {
    "triaged": 212,
    "drafts": 9,
    "reports": 14,
    "archived": 31,
    "moved": 12,
    "categorized": 40,
    "markedRead": 57,
    "dismissed": 18
  }
}
```

## Fields

| Field | Type | Meaning |
|---|---|---|
| `schema` | string | Always `packetrat.usage-counts/1`. A change that is not backward compatible gets a new version number. |
| `estimate` | boolean | Always `true`. The counts are an estimate of work done. |
| `since` | string | When the current count started (ISO 8601 with offset), or an empty string if nothing has been counted yet. `stats reset` starts a new count. |
| `exportedAt` | string | When the export was made (ISO 8601 with offset). |
| `counts` | object | One whole number per action below, each 0 or more. Every action is always present. |

## Counts

| Action | Counts |
|---|---|
| `triaged` | Messages triaged |
| `drafts` | Reply drafts generated |
| `reports` | Reports generated |
| `archived` | Messages archived |
| `moved` | Messages moved to a folder |
| `categorized` | Messages categorized |
| `markedRead` | Messages marked read or unread |
| `dismissed` | Items dismissed |

A reader should ignore action names it does not know: new actions may be added within version 1. Names are never renamed or removed within version 1.

## Using it as a data source

Each export is one row of totals since `since`. To chart change over time, save each export under its `exportedAt` time and compare files; PacketRat itself keeps no history. The counts stay in the local store (`Logs/`) until a person runs `stats export`.

## Tests

`tests/Test-PacketRatUsage.ps1` (in CI) reads the example and the two tables above and fails if the real export drifts from them: a field or action added, removed or renamed, a wrong type, or an example that no longer parses.
