# Measured-burden record

The minutes-saved counter (`stats`) is an **estimate**: counts times assumed minutes. This record is its measured counterpart, and it is only the **data half**. It keeps, per task, a "before" time entered once and the elapsed times of later runs, and shows how they compare.

**What still needs a person.** PacketRat does not time anything. The real before and after timing has to be done by a person: time the task done by hand (the baseline), then time it again with PacketRat, several times, and enter the numbers. Until someone does that, this record is empty and proves nothing. One baseline and a few runs are not a study, and the numbers are never a score for anyone.

## Commands

```bat
PacketRat-CLI.bat burden baseline --task triage-inbox --seconds 1800
PacketRat-CLI.bat burden record   --task triage-inbox --seconds 420
PacketRat-CLI.bat burden show
```

| Command | API route | What it does |
|---|---|---|
| `burden baseline` | `POST /api/burden/baseline` | Enters the before time of a task, in whole seconds. It is entered once: a second entry for the same task is refused unless `--replace true`, and then the old value is kept in the record. |
| `burden record` | `POST /api/burden/record` | Records one timed run of a task, in whole seconds. |
| `burden show` | `GET /api/burden` | The comparison below. |

A task id is a short name: lowercase letters, digits and hyphens, starting with a letter (up to 40 characters). Seconds are whole numbers from 1 to 86400. The record keeps at most 5000 runs.

## What is stored

`Logs/packetrat-burden.json` (not committed, never sent anywhere) holds task ids, seconds and UTC times. No names, no mail content, no notes.

## What `burden show` returns

Schema `packetrat.burden/1`.

| Field | Meaning |
|---|---|
| `schema` | Always `packetrat.burden/1`. |
| `note` | The reminder that this is a record only and that real timing needs a person. |
| `totalRuns` | Runs recorded across all tasks. |
| `tasks` | One row per task that has a baseline or a run, sorted by task id. |

Each row of `tasks`:

| Field | Meaning |
|---|---|
| `task` | The task id. |
| `baselineSeconds` | The entered before time, or null if none was entered. |
| `runs` | How many runs were recorded. |
| `meanSeconds` | Mean of the runs, or null if there are none. |
| `medianSeconds` | Median of the runs, or null if there are none. |
| `changeSeconds` | Mean minus baseline (negative means faster), or null without both. |
| `changePercent` | The change as a percent of the baseline, or null without both. |

## Tests

`tests/Test-PacketRatBurden.ps1` (in CI) checks the once-only baseline and its correction, the mean, median and change maths, input limits, that only task ids and seconds are stored, that the commands and routes are registered, that this page lists the fields `burden show` returns, and that it says real timing still needs a person.
