# MailHawk - Inbox Analysis (COM or Graph)
#requires -Version 5.1

function Write-MailHawkLogSafe {
    param([string]$Message, [string]$Level = 'INFO', [string]$Root)
    $cmd = Get-Command Write-MailHawkLog -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Name -eq 'Write-MailHawkLog') {
        & $cmd -Message $Message -Level $Level -Root $Root
        return
    }
    $color = 'DarkGray'
    if ($Level -eq 'ERROR') { $color = 'Red' }
    elseif ($Level -eq 'WARN') { $color = 'Yellow' }
    Write-Host ("[{0}] {1}" -f $Level, $Message) -ForegroundColor $color
}

function ConvertFrom-MailHawkMustReplyFallback {
    param([string]$ReportText, [array]$Emails)
    $items = @()
    if (-not $ReportText) { return $items }
    $seen = @{}

    # Shape A: | High | 9 | subject | why |
    $rxA = [regex]'(?im)^\s*\|\s*\**\s*(High|Medium|Low)\s*\**\s*\|\s*\#?\s*(\d+)\s*\|\s*([^|\r\n]+)\|\s*([^|\r\n]+)\|'
    foreach ($m in $rxA.Matches($ReportText)) {
        $idx = [int]$m.Groups[2].Value
        if ($seen.ContainsKey($idx)) { continue }
        $entry = $Emails | Where-Object { $_.Index -eq $idx } | Select-Object -First 1
        if (-not $entry) { continue }
        $seen[$idx] = $true
        $items += [pscustomobject]@{
            Index = $idx; Key = $entry.Fingerprint; EntryID = $entry.EntryID
            From = $entry.FromName; Subject = $entry.Subject
            Why = $m.Groups[4].Value.Trim(); Urgency = $m.Groups[1].Value.Trim()
        }
    }

    # Shape B: | 9 | 2026-10-19 | subject | why |  (index first - common model style)
    $rxB = [regex]'(?im)^\s*\|\s*\#?\s*(\d+)\s*\|\s*(\d{4}-\d{2}-\d{2}[^|]*)\|\s*([^|\r\n]+)\|\s*([^|\r\n]+)\|'
    foreach ($m in $rxB.Matches($ReportText)) {
        $idx = [int]$m.Groups[1].Value
        if ($seen.ContainsKey($idx)) { continue }
        $entry = $Emails | Where-Object { $_.Index -eq $idx } | Select-Object -First 1
        if (-not $entry) { continue }
        $subj = $m.Groups[3].Value.Trim()
        $why  = $m.Groups[4].Value.Trim()
        if ($subj -match '(?i)^(subject|email|title)$') { continue }
        if ($why -match '(?i)^(why|action|recommended|next step)') { continue }
        $seen[$idx] = $true
        $urg = 'Medium'
        if ($subj -match '(?i)dlp|security|mandatory|action required|urgent|violation|saar') { $urg = 'High' }
        $items += [pscustomobject]@{
            Index = $idx; Key = $entry.Fingerprint; EntryID = $entry.EntryID
            From = $entry.FromName; Subject = $entry.Subject; Why = $why; Urgency = $urg
        }
    }

    # Shape C: index-only rows - only clear action keywords, exclude "granted"/FYI
    $rxC = [regex]'(?im)^\s*\|\s*\#?\s*(\d+)\s*\|'
    foreach ($m in $rxC.Matches($ReportText)) {
        $idx = [int]$m.Groups[1].Value
        if ($seen.ContainsKey($idx)) { continue }
        $entry = $Emails | Where-Object { $_.Index -eq $idx } | Select-Object -First 1
        if (-not $entry) { continue }
        $subj = [string]$entry.Subject
        if ($subj -match '(?i)was granted|you''ve joined|newsletter|subscription|weekly siam|insights') { continue }
        if ($subj -notmatch '(?i)action required|dlp|mandatory|saar|wants to access|wants to share|please|urgent|violation|confirm offsite|gtcc') {
            continue
        }
        $seen[$idx] = $true
        $urg = 'Medium'
        if ($subj -match '(?i)dlp|violation|mandatory|action required') { $urg = 'High' }
        $items += [pscustomobject]@{
            Index = $idx; Key = $entry.Fingerprint; EntryID = $entry.EntryID
            From = $entry.FromName; Subject = $entry.Subject
            Why = 'Extracted from report table'; Urgency = $urg
        }
    }

    return $items
}

function Invoke-MailHawkInboxAnalysis {
    [CmdletBinding()]
    param(
        [ValidateSet('Auto', 'Grok', 'GenAi')]
        [string]$Profile = 'Auto',
        [ValidateSet('COM', 'Graph')]
        [string]$Provider = 'COM',
        [int]$MaxEmails = 40,
        [int]$BodyPreviewChars = 280,
        [int]$DaysBack = 14,
        [string]$Model,
        [string]$Root
    )

    if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
    $store = Get-MailHawkStore -Root $Root

    Write-MailHawkLogSafe -Level INFO -Message ("Collecting Inbox summary via {0}" -f $Provider) -Root $Root
    Write-Host "[*] Collecting Inbox summary via $Provider..." -ForegroundColor Cyan

    if ($Provider -eq 'Graph') {
        $summary = Get-MailHawkInboxSummaryGraph -MaxEmails $MaxEmails -BodyPreviewChars $BodyPreviewChars -DaysBack $DaysBack -Store $store
    } else {
        $summary = Get-MailHawkInboxSummary -MaxEmails $MaxEmails -BodyPreviewChars $BodyPreviewChars -DaysBack $DaysBack -Store $store
    }

    $dismissedCount = @($summary.Emails | Where-Object { $_.UserDismissed }).Count
    Write-Host ("    Analyzed: {0}  |  Skipped (sensitive): {1}  |  User-dismissed: {2}" -f `
        $summary.AnalyzedCount, $summary.SkippedCount, $dismissedCount) -ForegroundColor DarkGray

    if ($summary.AnalyzedCount -eq 0) {
        return [pscustomobject]@{
            Success = $false
            Message = 'No suitable emails found in the look-back window (or all were filtered).'
            Summary = $summary; Report = $null; MustReply = @(); Store = $store
        }
    }

    $emailPayload = $summary.Emails | ForEach-Object {
        [pscustomobject]@{
            Index = $_.Index; Fingerprint = $_.Fingerprint; EntryID = $_.EntryID
            Received = $_.Received; FromName = $_.FromName; FromEmail = $_.FromEmail; IsDirect = [bool]$_.IsDirect
            Subject = $_.Subject; UnRead = $_.UnRead; Importance = $_.Importance
            AppearsReplied = $_.AppearsReplied; ReplyEvidence = $_.ReplyEvidence
            UserDismissed = $_.UserDismissed; BodyPreview = $_.BodyPreview
        }
    }
    $emailJson = $emailPayload | ConvertTo-Json -Depth 6 -Compress
    $priorDismissals = @($store.Dismissals | Select-Object -First 30 Key, Subject, From, Reason) | ConvertTo-Json -Depth 4 -Compress
    if (-not $priorDismissals) { $priorDismissals = '[]' }

    $systemPrompt = @'
You are MailHawk, a careful email triage assistant for a professional / government environment.

CRITICAL: Output the JSON block FIRST (required for the checklist UI), then the Markdown report.

RULES:
1. Never invent email content. Only use the data provided.
2. Treat UserDismissed=true as already handled - do NOT put them in must_reply.
3. Treat AppearsReplied=true as handled unless there is a clear new ask.
4. No PII requests. Prefer caution on ambiguous items.
5. Plain ASCII only. No emoji.

OUTPUT PART 1 - JSON (must appear first):

@@@MAILHAWK_JSON_BEGIN@@@
{
  "must_reply": [
    {
      "index": 9,
      "why": "why a response is needed",
      "urgency": "High"
    }
  ],
  "report_items": [
    {
      "index": 9,
      "section": "Must Reply",
      "reason": "Evidence-grounded rationale",
      "recommended_action": "Suggested next action for a human to review",
      "urgency": "High"
    }
  ]
}
@@@MAILHAWK_JSON_END@@@

Include in must_reply: security/DLP alerts, mandatory training, SAAR/access requests, direct questions, tasking that still needs action.
For report_items use only Index values present in the input. Include each email discussed in the Markdown at most once; never fabricate email IDs. Valid section names: Categories, Groups, Must Reply, Already Replied, No Action Needed, Skipped / Caution, Quick Summary. Do not invent exact delivery dates or authority.
Explicit user rules are applied separately after classification; don't fabricate rule decisions. A .mil sender alone does not imply a task.
Exclude: newsletters, automated digests, user-dismissed, solidly replied threads.

OUTPUT PART 2 - Markdown with these headings:
## 1. Categories
## 2. Groups
## 3. Must Reply
## 4. Already Appears Replied / No Action Needed
## 5. Skipped / Caution
## 6. Quick Summary
Use normal Markdown headings, bullets, and tables where helpful. Do not wrap the report in Markdown blockquotes (>), code fences, or duplicate response alternatives.
When mentioning a specific email in report prose or tables, put [Email #N] (the literal numeric input Index) at the beginning. All clickable links are validated against the original scan. Avoid HTML, escaped Unicode literals, ANSI color codes and unusual quote characters.
'@

    $userPrompt = @"
Inbox snapshot: $($summary.GeneratedAt)
Provider: $($summary.Provider)
Analyzed: $($summary.AnalyzedCount)  Skipped: $($summary.SkippedCount)  User-dismissed: $dismissedCount

CURRENT EDITABLE TRIAGE RULES (for context; local rules are enforced after you answer):
$(@($store.Rules|Where-Object Enabled|Select-Object Name,Match,Value,Effect)|ConvertTo-Json -Depth 4 -Compress)

PRIOR USER DISMISSALS (do not re-recommend):
$priorDismissals

EMAIL DATA (JSON):
$emailJson
"@

    $messages = @(
        @{ role = 'system'; content = $systemPrompt }
        @{ role = 'user';   content = $userPrompt }
    )

    Write-MailHawkLogSafe -Level INFO -Message 'Calling AI endpoint' -Root $Root
    Write-Host '[*] Calling AI endpoint...' -ForegroundColor Cyan
    $ai = Invoke-MailHawkChat -Messages $messages -Profile $Profile -Model $Model -MaxTokens 8192 -Temperature 0.1
    $rawText = [string]$ai.Text

    # Raw model responses may contain mail content; do not write them unless explicitly opted in.
    if ($env:MAILHAWK_SAVE_RAW_AI -eq '1') {
    try {
        $logDir = Join-Path $Root 'Logs'
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $rawPath = Join-Path $logDir ('mailhawk-ai-raw_{0}.txt' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($rawPath, $rawText, $utf8NoBom)
        Write-MailHawkLogSafe -Level INFO -Message ("Raw AI response saved: {0} ({1} chars)" -f $rawPath, $rawText.Length) -Root $Root
    } catch {}
    }

    $mustReply = @()
    $structuredReportItems = @()
    if ($rawText -match '(?s)@@@MAILHAWK_JSON_BEGIN@@@(.*)@@@MAILHAWK_JSON_END@@@') {
        $jsonPart = $Matches[1].Trim()
        try {
            $parsed = $jsonPart | ConvertFrom-Json
            if($parsed.report_items){$structuredReportItems=@($parsed.report_items)}
            foreach ($m in @($parsed.must_reply)) {
                # The LLM is untrusted: validate the index and use original mailbox identity.
                # Never allow a fabricated fingerprint/EntryID to target another message.
                $entry = $summary.Emails | Where-Object { $_.Index -eq [int]$m.index } | Select-Object -First 1
                if (-not $entry -or -not $entry.Fingerprint -or $entry.UserDismissed) { continue }
                $urgency = if (@('High','Medium','Low') -contains [string]$m.urgency) { [string]$m.urgency } else { 'Medium' }
                $mustReply += [pscustomobject]@{
                    Index = [int]$entry.Index; Key = [string]$entry.Fingerprint; EntryID = [string]$entry.EntryID
                    From = [string]$entry.FromName; Subject = [string]$entry.Subject
                    Why = ([string]$m.why).Substring(0,[Math]::Min(400,([string]$m.why).Length)); Urgency = $urgency
                }
            }
            Write-MailHawkLogSafe -Level INFO -Message ("JSON must_reply count={0}" -f $mustReply.Count) -Root $Root
        } catch {
            Write-MailHawkLogSafe -Level WARN -Message ("JSON parse failed: {0}" -f $_.Exception.Message) -Root $Root
        }
    }

    $reportMd = [regex]::Replace($rawText, '(?s)@@@MAILHAWK_JSON_BEGIN@@@.*?@@@MAILHAWK_JSON_END@@@', '').Trim()
    $reportMd = ConvertTo-MailHawkReadableReport -Text $reportMd
    # Preserve readable punctuation, Unicode and report structure; the browser escapes HTML.

    if ($mustReply.Count -eq 0) {
        Write-MailHawkLogSafe -Level WARN -Message 'No structured JSON must_reply; trying markdown fallback parser' -Root $Root
        $mustReply = @(ConvertFrom-MailHawkMustReplyFallback -ReportText $reportMd -Emails @($summary.Emails | Where-Object { -not $_.UserDismissed }))
        Write-MailHawkLogSafe -Level INFO -Message ("Fallback extracted {0} must-reply items" -f $mustReply.Count) -Root $Root
    }

    # Rule matches use real mailbox identity, never LLM-generated EntryIDs.
    $ruleResult=Invoke-MailHawkRuleTriage -Emails @($summary.Emails) -Suggested @($mustReply) -Store $store
    $mustReply=@($ruleResult.Items)
    # Keep rule exclusions reversible. Never overwrite a user's manual priority.
    $currentKeys=@{}
    foreach($mail in @($summary.Emails)){if($mail.Fingerprint){$currentKeys[[string]$mail.Fingerprint]=$true}}
    $excluded=@{}
    foreach($key in @($ruleResult.SuppressedKeys)){$excluded[[string]$key]=$true}
    foreach($item in @($store.Checklist)){
        $key=[string]$item.Key
        if(-not $currentKeys.ContainsKey($key)){continue}
        $skip=$excluded.ContainsKey($key) -and -not [bool]$item.PriorityOverride
        $item | Add-Member -NotePropertyName RuleSuppressed -NotePropertyValue ([bool]$skip) -Force
        $item | Add-Member -NotePropertyName RuleSuppressedBy -NotePropertyValue $(if($skip){[string]$ruleResult.SuppressedReasons[$key]}else{''}) -Force
    }
    Save-MailHawkStore -Store $store -Root $Root

    if($ruleResult.Matched -gt 0){
        $reportMd += "`n`n## Applied triage policy`n"
        $reportMd += ("{0} rule matches evaluated. Review Rules to change defaults or add rules. Manual priority overrides persist." -f $ruleResult.Matched)
    }
    if ($mustReply.Count -gt 0) {
        $store = Merge-MailHawkChecklist -Store $store -Items $mustReply -Root $Root
        Write-MailHawkLogSafe -Level INFO -Message ("Checklist merged with {0} items" -f $mustReply.Count) -Root $Root
    } else {
        Write-MailHawkLogSafe -Level WARN -Message 'MustReply list is empty after JSON + fallback' -Root $Root
    }

    # Reconcile all report references to real scan data. AI-supplied fingerprints and EntryIDs
    # are never accepted. The verified source list can also surface legacy reports with
    # no report_items, without guessing a message identity from arbitrary text.
    $verifiedItems=@(Get-MailHawkVerifiedReportItems -Emails @($summary.Emails) -ModelItems @($structuredReportItems) -MustReply @($mustReply))
    $trackedKeys=@{}
    foreach($action in @($store.Checklist)){if($action.Key){$trackedKeys[[string]$action.Key]=$action}}
    foreach($source in $verifiedItems){
        if($trackedKeys.ContainsKey([string]$source.Key)){
            $source.Tracked=$true
            $action=$trackedKeys[[string]$source.Key]
            $source.Urgency=[string]$action.Urgency
        }
    }
    $reportSections=@(Get-MailHawkReportSections -Report $reportMd)
    $reportQuality=Get-MailHawkReportQuality -Report $reportMd -Items @($verifiedItems) -StructuredPresent ($structuredReportItems.Count -gt 0)

    return [pscustomobject]@{
        Success        = $true
        GeneratedAt    = Get-Date -Format 'o'
        Profile        = $ai.Profile
        Model          = $ai.Model
        Provider       = $summary.Provider
        AnalyzedCount  = $summary.AnalyzedCount
        SkippedCount   = $summary.SkippedCount
        DismissedCount = $dismissedCount
        Summary        = $summary
        Report         = $reportMd
        ReportItems    = @($verifiedItems)
        ReportSections = @($reportSections)
        ReportQuality  = $reportQuality
        MustReply      = $mustReply
        Store          = $store
    }
}
