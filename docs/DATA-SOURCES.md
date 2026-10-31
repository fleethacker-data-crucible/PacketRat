# PacketRat as a data source

PacketRat keeps a local count of the actions it performed or prepared (messages triaged, drafts and reports generated,
inbox actions, dismissals). Another tool, such as Semaphore, can read those counts. This page is the contract for that
file. The counts never leave this PC unless you copy the file somewhere yourself.

**The counts are real tallies. Minutes saved is an estimate**: the minutes-saved total multiplies these counts by the
per-action minutes in `Config/minutes-saved.json`, which are assumptions, not measurements. The export below holds only
the raw counts. It is not a performance score for any person and holds no mail content.

## Get the file

```bash
PacketRat-CLI.bat stats export --out counts.json
```

This writes the standard command result (`packetrat.result/1`). The export itself is `result.usage`. The same object is
returned by `GET /api/stats/export` as `usage`.

## Format: `packetrat.usage-counts/1`

```json
{
  "schema": "packetrat.usage-counts/1",
  "estimate": true,
  "since": "2026-10-30T12:00:00.0000000-04:00",
  "exportedAt": "2026-10-31T09:30:00.0000000-04:00",
  "counts": {
    "triaged": 120,
    "drafts": 9,
    "reports": 14,
    "archived": 31,
    "moved": 6,
    "categorized": 12,
    "markedRead": 48,
    "dismissed": 22
  }
}
```

| Field | Meaning |
|---|---|
| `schema` | Always `packetrat.usage-counts/1`. A change that breaks readers gets a new number. |
| `estimate` | Always `true`: the counts feed an estimate; do not present them as measured time. |
| `since` | When counting started (or was last reset with `stats reset --yes`). Empty before the first count. |
| `exportedAt` | When this file was written. |
| `counts` | One whole number per action id below, never negative. New action ids may be added; readers should ignore ids they do not know. |

Action ids: `triaged` (messages triaged), `drafts` (reply drafts generated), `reports` (reports generated),
`archived`, `moved`, `categorized`, `markedRead` (inbox actions run on the original message) and `dismissed`.

## Use it in Semaphore

Semaphore loads CSV, so convert the file first:

```bash
powershell -File tools\Export-PacketRatCountsCsv.ps1 -Path counts.json -Out counts.csv
```

The CSV has one row per action (`exportedAt,since,action,count`). In Semaphore, use **Data, then Import a CSV file** and
choose `counts.csv`. Export on a schedule (or before each review) and append the rows to track change over time.
Any other tool that reads JSON or CSV can use either file the same way.
