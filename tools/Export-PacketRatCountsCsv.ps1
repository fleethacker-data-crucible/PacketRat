#requires -Version 5.1
<#
.SYNOPSIS
  Turns a PacketRat counts export (JSON) into a flat CSV that Semaphore, a spreadsheet or any other tool can load.
.DESCRIPTION
  Input is the file written by  PacketRat-CLI.bat stats export --out counts.json  (or the bare "usage" object of
  GET /api/stats/export). Output has one row per action:  exportedAt,since,action,count
  Only the raw counts are carried over: no minutes, no mail data. The counts are what PacketRat did or prepared; the
  minutes-saved total built from them is an estimate (see docs/DATA-SOURCES.md).
.EXAMPLE
  .\tools\Export-PacketRatCountsCsv.ps1 -Path counts.json -Out counts.csv
#>
param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Out
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "No file at $Path" }
$doc = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
# Accept the CLI result envelope or the bare export object.
$usage = if ($doc.PSObject.Properties['result'] -and $doc.result.PSObject.Properties['usage']) { $doc.result.usage } else { $doc }
if ([string]$usage.schema -ne 'packetrat.usage-counts/1') { throw "Not a PacketRat counts export (schema '$($usage.schema)', expected packetrat.usage-counts/1)." }
$rows = foreach ($p in $usage.counts.PSObject.Properties) {
    [pscustomobject]@{ exportedAt = [string]$usage.exportedAt; since = [string]$usage.since; action = $p.Name; count = [int]$p.Value }
}
$csv = ($rows | ConvertTo-Csv -NoTypeInformation) -join "`r`n"
[IO.File]::WriteAllText([IO.Path]::GetFullPath($Out), $csv + "`r`n", (New-Object Text.UTF8Encoding $false))
Write-Host ("Wrote {0} rows to {1}" -f @($rows).Count, [IO.Path]::GetFullPath($Out))
