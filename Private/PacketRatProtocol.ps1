#requires -Version 5.1
# PacketRat Wire Protocol v1 -- ASCII markers, strict structure, no raw text fallback.
function ConvertTo-PacketRatWireReadableText {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)
    # The same conservative UTF-8/Windows-1252 repair is used for drafts,
    # structured report strings and derived report content.
    if(Get-Command ConvertTo-PacketRatReadableReport -ErrorAction SilentlyContinue){
        return (ConvertTo-PacketRatReadableReport -Text $Text)
    }
    return $Text
}
function Get-PacketRatDraftWirePrompt {
    return @'
PACKETRAT DRAFT V1. Return EXACTLY ONE email response. No alternative versions.
Write precisely this envelope. Markers must each be on their own line:
<<<PACKETRAT_DRAFT_V1>>>
<<<SUBJECT>>>
One suggested subject on one line
<<<END_SUBJECT>>>
<<<BODY>>>
One plain-text email message using normal paragraphs.
<<<END_BODY>>>
<<<END_PACKETRAT_DRAFT_V1>>>
Do not write anything outside the envelope. Never place a marker inside the body.
No Markdown, HTML, code fences, JSON, prefaces, commentary, duplicated drafts,
fabricated approvals or invented signature. No sign-off line such as "Best regards",
"Sincerely", "Respectfully" or "V/R"; Outlook handles the authentic signature.
'@
}
function ConvertFrom-PacketRatDraftV1 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if([string]::IsNullOrWhiteSpace($Text)){throw 'Draft protocol: empty AI response.'}
    if($Text.Length -gt 150000){throw 'Draft protocol: oversized response.'}
    $clean=$Text.Replace([string][char]0xFEFF,'') -replace "`r`n?","`n"
    $pattern='(?s)\A\s*<<<PACKETRAT_DRAFT_V1>>>\n<<<SUBJECT>>>\n(?<subject>[^\n]+)\n<<<END_SUBJECT>>>\n<<<BODY>>>\n(?<body>.*?)\n<<<END_BODY>>>\n<<<END_PACKETRAT_DRAFT_V1>>>\s*\z'
    $m=[regex]::Match($clean,$pattern)
    if(-not $m.Success){throw 'Draft protocol: expected exactly one envelope with SUBJECT and BODY fields.'}
    $subject=$m.Groups['subject'].Value.Trim()
    $body=$m.Groups['body'].Value.Trim()
    $subject=ConvertTo-PacketRatWireReadableText -Text $subject
    $body=ConvertTo-PacketRatWireReadableText -Text $body
    if($subject.Length -lt 1 -or $subject.Length -gt 240){throw 'Draft protocol: subject must have 1-240 characters.'}
    if($body.Length -lt 1 -or $body.Length -gt 30000){throw 'Draft protocol: body must have 1-30000 characters.'}
    if($subject -match '[\x00-\x1F\x7F]' -or $body -match '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'){
        throw 'Draft protocol: illegal control character.'
    }
    if([regex]::IsMatch($body,'(?m)^<<<(?:PACKETRAT_|END_|SUBJECT|BODY)[A-Z0-9_]*>>>')){
        throw 'Draft protocol: duplicate or nested markers.'
    }
    if([regex]::IsMatch($body,'(?im)^\s*(?:best\s+regards|kind\s+regards|warm\s+regards|sincerely|respectfully|v/r)\s*,?\s*$')){
        throw 'Draft protocol: sign-off detected; Outlook will provide the real signature.'
    }
    return [pscustomobject]@{Version='PACKETRAT_DRAFT_V1';Subject=$subject;Body=$body}
}
function Get-PacketRatReportWirePrompt {
    return @'
PACKETRAT REPORT V1. Return EXACTLY ONE JSON report wrapped in these ASCII markers:
<<<PACKETRAT_REPORT_V1>>>
{"version":"PACKETRAT_REPORT_V1","must_reply":[{"index":1,"urgency":"High","why":"Reason"}],"report_items":[{"index":1,"section":"Must Reply","reason":"Reason","recommended_action":"Proposed action","urgency":"High"}],"sections":[{"id":"categories","title":"Categories","summary":"Short plain-text summary","items":[{"email_index":1,"text":"Source-grounded finding"}]},{"id":"groups","title":"Groups","summary":"","items":[]},{"id":"must_reply","title":"Must Reply","summary":"","items":[]},{"id":"already_replied","title":"Already Replied / No Action Needed","summary":"","items":[]},{"id":"skipped","title":"Skipped / Caution","summary":"","items":[]},{"id":"quick_summary","title":"Quick Summary","summary":"","items":[]}]}
<<<END_PACKETRAT_REPORT_V1>>>
The contents above demonstrate SHAPE only. Write actual findings, not placeholders.
All six section ids are mandatory in exactly that order. Use [] for empty items.
Use only source Index numbers present in the supplied inbox snapshot; never invent IDs.
The summary and text fields are plain text, not Markdown or HTML. No tables,
Markdown headings, code fences, special decorations or extra text outside markers.
Never invent completed actions, approvals, deadlines or a signature.
'@
}
function ConvertFrom-PacketRatReportV1 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text,[int]$MaxSourceIndex=0)
    if([string]::IsNullOrWhiteSpace($Text)){throw 'Report protocol: empty response.'}
    if($Text.Length -gt 750000){throw 'Report protocol: oversized response.'}
    $clean=$Text.Replace([string][char]0xFEFF,'') -replace "`r`n?","`n"
    $pattern='(?s)\A\s*<<<PACKETRAT_REPORT_V1>>>\n(?<payload>\{.*\})\n<<<END_PACKETRAT_REPORT_V1>>>\s*\z'
    $m=[regex]::Match($clean,$pattern)
    if(-not $m.Success){throw 'Report protocol: expected exactly one REPORT_V1 JSON envelope.'}
    try{$data=ConvertFrom-Json -InputObject $m.Groups['payload'].Value -ErrorAction Stop}catch{
        throw ('Report protocol: invalid JSON: '+$_.Exception.Message)
    }
    if([string]$data.version -cne 'PACKETRAT_REPORT_V1'){throw 'Report protocol: unsupported version.'}
    if($null -eq $data.must_reply -or $null -eq $data.report_items -or $null -eq $data.sections){
        throw 'Report protocol: required arrays missing.'
    }
    $ids=@('categories','groups','must_reply','already_replied','skipped','quick_summary')
    $sections=@($data.sections)
    if($sections.Count -ne 6){throw 'Report protocol: six sections required.'}
    $safe=New-Object System.Collections.Generic.List[object]
    for($i=0;$i -lt 6;$i++){
        $section=$sections[$i]
        if([string]$section.id -cne $ids[$i]){throw ('Report protocol: wrong section '+$ids[$i])}
        # A model sometimes leaves out "items" on an empty section; the prompt says to use [], so treat a missing key as empty.
        $title=[string]$section.title;$summary=[string]$section.summary
        if($title.Length -gt 120 -or $summary.Length -gt 3500 -or @($section.items).Count -gt 175){
            throw 'Report protocol: section content exceeds limits.'
        }
        $entries=New-Object System.Collections.Generic.List[object]
        foreach($entry in @($section.items|Where-Object{$null -ne $_})){
            $v=[string]$entry.text;$index=0
            if([string]::IsNullOrWhiteSpace($v) -or $v.Length -gt 1200){throw 'Report protocol: invalid item text.'}
            if($null -ne $entry.email_index -and [string]$entry.email_index -ne ''){
                if(-not [int]::TryParse([string]$entry.email_index,[ref]$index) -or $index -lt 1){
                    throw 'Report protocol: invalid item source index.'
                }
            }
            [void]$entries.Add([pscustomobject]@{EmailIndex=$index;Text=$v.Trim()})
        }
        [void]$safe.Add([pscustomobject]@{Id=$ids[$i];Title=$title.Trim();Summary=$summary.Trim();Items=@($entries.ToArray())})
    }
    if(@($data.must_reply).Count -gt 200 -or @($data.report_items).Count -gt 250){throw 'Report protocol: too many email references.'}
    foreach($entry in @(@($data.must_reply)+@($data.report_items))){
        $idx=0
        if(-not [int]::TryParse([string]$entry.index,[ref]$idx) -or $idx -lt 1 -or ($MaxSourceIndex -gt 0 -and $idx -gt $MaxSourceIndex)){
            throw 'Report protocol: invalid or out-of-range email reference.'
        }
    }
    return [pscustomobject]@{Version='PACKETRAT_REPORT_V1';MustReply=@($data.must_reply);ReportItems=@($data.report_items);Sections=@($safe.ToArray())}
}
function ConvertTo-PacketRatProtocolPlainText {
    param([AllowEmptyString()][string]$Value)
    if(-not $Value){return ''}
    $Value=ConvertTo-PacketRatWireReadableText -Text $Value
    $clean=[regex]::Replace($Value,'[\x00-\x1F\x7F]',' ')
    $clean=[regex]::Replace($clean,'\s+',' ').Trim()
    $clean=$clean.TrimStart([char[]]@('#','>','*','|',' '))
    return $clean.Replace('|',' / ').Replace('[','(').Replace(']',')').Replace('*','').Trim()
}
function ConvertTo-PacketRatReportMarkdownV1 {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Envelope,[Parameter(Mandatory)][array]$VerifiedEmails)
    $eligible=@{}
    foreach($email in @($VerifiedEmails)){
        if(-not $email.IsSensitive -and -not $email.UserDismissed -and $email.Fingerprint){$eligible[[int]$email.Index]=$true}
    }
    $lines=New-Object System.Collections.Generic.List[string]
    foreach($section in @($Envelope.Sections)){
        [void]$lines.Add('## '+([string]$section.Title))
        if($section.Summary){[void]$lines.Add((ConvertTo-PacketRatProtocolPlainText ([string]$section.Summary)))}
        foreach($entry in @($section.Items)){
            $line=ConvertTo-PacketRatProtocolPlainText ([string]$entry.Text)
            $index=[int]$entry.EmailIndex
            if($index -gt 0 -and $eligible.ContainsKey($index)){$line="[Email #$index] "+$line}
            if($line){[void]$lines.Add('- '+$line)}
        }
        [void]$lines.Add('')
    }
    return (($lines -join "`n").Trim())
}

# Follow-up generation from an existing report uses the same strict envelope strategy.
function Get-PacketRatInsightWirePrompt {
    return @'
PACKETRAT INSIGHT V1. Return precisely one JSON envelope:
<<<PACKETRAT_INSIGHT_V1>>>
{"version":"PACKETRAT_INSIGHT_V1","title":"Clear short title","summary":"Plain-text summary","items":[{"email_index":0,"text":"An evidence-grounded next step or finding"}]}
<<<END_PACKETRAT_INSIGHT_V1>>>
The object above demonstrates SHAPE only, not facts. Use only verified report email indices.
Use email_index 0 for general recommendations with no specific message.
Return no Markdown, HTML, quotes around the envelope, prefaces or extra text.
No made-up facts, completed tasks, permission grants or artificial signature.
'@
}
function ConvertFrom-PacketRatInsightV1 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt 180000){throw 'Insight protocol: empty or oversized output.'}
    $clean=$Text.Replace([string][char]0xFEFF,'') -replace "`r`n?","`n"
    $pattern='(?s)\A\s*<<<PACKETRAT_INSIGHT_V1>>>\n(?<json>\{.*\})\n<<<END_PACKETRAT_INSIGHT_V1>>>\s*\z'
    $m=[regex]::Match($clean,$pattern)
    if(-not $m.Success){throw 'Insight protocol: expected one INSIGHT_V1 envelope.'}
    try{$data=ConvertFrom-Json -InputObject $m.Groups['json'].Value -ErrorAction Stop}catch{
        throw ('Insight protocol: invalid JSON: '+$_.Exception.Message)
    }
    if([string]$data.version -cne 'PACKETRAT_INSIGHT_V1' -or $null -eq $data.items){
        throw 'Insight protocol: incompatible version or missing items.'
    }
    $title=[string]$data.title;$summary=[string]$data.summary
    if($title.Length -gt 150 -or $summary.Length -gt 5000 -or @($data.items).Count -gt 90){
        throw 'Insight protocol: content exceeds limits.'
    }
    $items=New-Object System.Collections.Generic.List[object]
    foreach($item in @($data.items)){
        $text=[string]$item.text
        $index=0
        if(-not [int]::TryParse([string]$item.email_index,[ref]$index) -or $index -lt 0){
            throw 'Insight protocol: invalid email index.'
        }
        if([string]::IsNullOrWhiteSpace($text) -or $text.Length -gt 1200){throw 'Insight protocol: invalid item text.'}
        [void]$items.Add([pscustomobject]@{EmailIndex=$index;Text=$text})
    }
    return [pscustomobject]@{Version='PACKETRAT_INSIGHT_V1';Title=$title.Trim();Summary=$summary.Trim();Items=@($items.ToArray())}
}
function ConvertTo-PacketRatInsightMarkdownV1 {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Insight,[array]$VerifiedSources=@())
    $allowed=@{}
    foreach($source in @($VerifiedSources)){if($source.SourceVerified){$allowed[[int]$source.Index]=$true}}
    $lines=New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('## '+(ConvertTo-PacketRatProtocolPlainText ([string]$Insight.Title)))
    [void]$lines.Add((ConvertTo-PacketRatProtocolPlainText ([string]$Insight.Summary)))
    [void]$lines.Add('')
    foreach($item in @($Insight.Items)){
        $n=[int]$item.EmailIndex
        $text=ConvertTo-PacketRatProtocolPlainText ([string]$item.Text)
        if($n -gt 0 -and $allowed.ContainsKey($n)){$text="[Email #$n] "+$text}
        [void]$lines.Add('- '+$text)
    }
    return (($lines -join "`n").Trim())
}

# --- Schema-first batch classification (PACKETRAT_CLASSIFY_V1) --------------------------------------------------
# Opt-in alternative to the one-shot report: the model only fills one typed record per message, a batch at a time
# (small outputs, so nothing is truncated), and PacketRat compiles the report from the reconciled records with no
# further model call. See docs/AI_WIRE_PROTOCOL_V1.md.
$script:PacketRatClassifyCategories = @('must_reply', 'already_replied', 'no_action', 'caution')

function Get-PacketRatClassifyWirePrompt {
    return @'
PACKETRAT CLASSIFY V1. Return EXACTLY ONE JSON object wrapped in these ASCII markers:
<<<PACKETRAT_CLASSIFY_V1>>>
{"version":"PACKETRAT_CLASSIFY_V1","records":[{"index":1,"category":"must_reply","urgency":"High","reason":"Why","requested_action":"What is asked of the user","deadline":"2026-11-05","evidence":"Short phrase copied from the message","confidence":"medium"}]}
<<<END_PACKETRAT_CLASSIFY_V1>>>
The contents above demonstrate SHAPE only. Write actual findings, not placeholders.
One record per message you can classify, using only the Index numbers in the supplied batch; never invent IDs.
category is one of: must_reply (the user must act or reply), already_replied (the thread shows a reply), no_action (information only), caution (suspicious, unclear or needs care).
urgency is High, Medium or Low. confidence is low, medium or high: say low when the preview is thin.
deadline is "" unless the message states a date; then write it as YYYY-MM-DD. Never guess a deadline.
evidence is a short phrase quoted from the message preview that supports the category, or "".
All fields are plain text: no Markdown, HTML, tables or code fences, and no text outside the markers.
'@
}

function ConvertFrom-PacketRatClassifyV1 {
    <#
    .SYNOPSIS
      Strict parser for one batch. Throws on anything malformed (a truncated or invented answer is rejected, never
      guessed at). AllowedIndexes is the set of Index numbers that were in the batch.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][int[]]$AllowedIndexes)
    if ([string]::IsNullOrWhiteSpace($Text)) { throw 'Classify protocol: empty response.' }
    if ($Text.Length -gt 200000) { throw 'Classify protocol: oversized response.' }
    $clean = $Text.Replace([string][char]0xFEFF, '') -replace "`r`n?", "`n"
    $m = [regex]::Match($clean, '(?s)\A\s*<<<PACKETRAT_CLASSIFY_V1>>>\n(?<payload>\{.*\})\n<<<END_PACKETRAT_CLASSIFY_V1>>>\s*\z')
    if (-not $m.Success) { throw 'Classify protocol: expected exactly one CLASSIFY_V1 JSON envelope.' }
    try { $data = ConvertFrom-Json -InputObject $m.Groups['payload'].Value -ErrorAction Stop }
    catch { throw ('Classify protocol: invalid JSON: ' + $_.Exception.Message) }
    if ([string]$data.version -cne 'PACKETRAT_CLASSIFY_V1') { throw 'Classify protocol: unsupported version.' }
    if ($null -eq $data.records) { throw 'Classify protocol: records missing.' }
    $records = @($data.records)
    if ($records.Count -gt 200) { throw 'Classify protocol: too many records.' }
    $allowed = @{}; foreach ($i in $AllowedIndexes) { $allowed[[int]$i] = $true }
    $seen = @{}
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in $records) {
        $idx = 0
        if (-not [int]::TryParse([string]$r.index, [ref]$idx) -or -not $allowed.ContainsKey($idx)) { throw 'Classify protocol: invalid or out-of-range email reference.' }
        if ($seen.ContainsKey($idx)) { throw "Classify protocol: duplicate record for email $idx." }
        $seen[$idx] = $true
        $category = [string]$r.category
        if ($script:PacketRatClassifyCategories -cnotcontains $category) { throw "Classify protocol: unknown category for email $idx." }
        $urgency = [string]$r.urgency
        if (@('High', 'Medium', 'Low') -cnotcontains $urgency) { throw "Classify protocol: unknown urgency for email $idx." }
        $confidence = [string]$r.confidence
        if (@('low', 'medium', 'high') -cnotcontains $confidence) { throw "Classify protocol: unknown confidence for email $idx." }
        $reason = [string]$r.reason; $action = [string]$r.requested_action; $evidence = [string]$r.evidence
        if ([string]::IsNullOrWhiteSpace($reason) -or $reason.Length -gt 400) { throw "Classify protocol: invalid reason for email $idx." }
        if ($action.Length -gt 260 -or $evidence.Length -gt 240) { throw "Classify protocol: field too long for email $idx." }
        $deadline = [string]$r.deadline
        if ($deadline) {
            $parsed = [datetime]::MinValue
            if ($deadline -notmatch '^\d{4}-\d{2}-\d{2}$' -or -not [datetime]::TryParseExact($deadline, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
                throw "Classify protocol: deadline for email $idx is not YYYY-MM-DD."
            }
        }
        [void]$out.Add([pscustomobject]@{
            Index = $idx; Category = $category; Urgency = $urgency; Confidence = $confidence
            Reason = (ConvertTo-PacketRatProtocolPlainText $reason); RequestedAction = (ConvertTo-PacketRatProtocolPlainText $action)
            Deadline = $deadline; Evidence = (ConvertTo-PacketRatProtocolPlainText $evidence); ClassificationSource = 'batch-ai'
        })
    }
    return , @($out.ToArray())
}

function ConvertTo-PacketRatReportEnvelopeFromClassification {
    <#
    .SYNOPSIS
      Deterministic report compiler: reconciled classification records -> the same envelope object that
      ConvertFrom-PacketRatReportV1 returns, so everything downstream (rules, verification, markdown, UI) is unchanged.
      Emails the model did not classify are listed under Skipped / Caution as "not classified", never guessed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Records,
        [Parameter(Mandatory)][array]$Emails,
        [AllowEmptyCollection()][int[]]$UnclassifiedIndexes = @(),
        [AllowEmptyCollection()][string[]]$Warnings = @()
    )
    $rank = @{ High = 0; Medium = 1; Low = 2 }
    $byIndex = @{}; foreach ($e in @($Emails)) { $byIndex[[int]$e.Index] = $e }
    $sorted = @($Records | Sort-Object @{ Expression = { $rank[[string]$_.Urgency] } }, Index)
    $sectionOf = @{ must_reply = 'Must Reply'; already_replied = 'Already Replied'; no_action = 'No Action Needed'; caution = 'Skipped / Caution' }

    $mustReply = @($sorted | Where-Object Category -ceq 'must_reply' | ForEach-Object { [pscustomobject]@{ index = $_.Index; urgency = $_.Urgency; why = $_.Reason } })
    $items = @($sorted | ForEach-Object {
        [pscustomobject]@{
            index = $_.Index; section = $sectionOf[$_.Category]; reason = $_.Reason; recommended_action = $_.RequestedAction; urgency = $_.Urgency
            deadline = $_.Deadline; evidence = $_.Evidence; confidence = $_.Confidence; classification_source = $_.ClassificationSource
        }
    })

    function New-Entry([int]$Index, [string]$Text) {
        $t = $Text.Trim(); if ($t.Length -gt 1100) { $t = $t.Substring(0, 1100) }
        [pscustomobject]@{ EmailIndex = $Index; Text = $t }
    }
    function Get-Subject([int]$Index) { if ($byIndex.ContainsKey($Index)) { return (ConvertTo-PacketRatProtocolPlainText ([string]$byIndex[$Index].Subject)) } return "Email $Index" }
    function Get-Line($r) {
        $parts = New-Object System.Collections.Generic.List[string]
        [void]$parts.Add((Get-Subject $r.Index) + ': ' + $r.Reason)
        if ($r.RequestedAction) { [void]$parts.Add('Action: ' + $r.RequestedAction) }
        if ($r.Deadline) { [void]$parts.Add('Deadline stated: ' + $r.Deadline) }
        [void]$parts.Add('Urgency ' + $r.Urgency + ', confidence ' + $r.Confidence)
        return ($parts -join '. ')
    }

    $count = @{}; foreach ($c in $script:PacketRatClassifyCategories) { $count[$c] = @($Records | Where-Object Category -ceq $c).Count }
    $label = @{ must_reply = 'Must reply'; already_replied = 'Already replied'; no_action = 'No action needed'; caution = 'Caution' }
    $catItems = @($script:PacketRatClassifyCategories | Where-Object { $count[$_] -gt 0 } | ForEach-Object { New-Entry 0 ("{0}: {1}" -f $label[$_], $count[$_]) })

    $groupItems = New-Object System.Collections.Generic.List[object]
    $groups = @($Records | Where-Object { $byIndex.ContainsKey([int]$_.Index) } | Group-Object { [string]$byIndex[[int]$_.Index].FromEmail } | Where-Object { $_.Name -and $_.Count -ge 2 } | Sort-Object Count -Descending | Select-Object -First 10)
    foreach ($g in $groups) {
        $ids = (@($g.Group | Sort-Object Index | ForEach-Object { '#' + $_.Index }) -join ', ')
        [void]$groupItems.Add((New-Entry 0 ("{0}: {1} messages ({2})" -f (ConvertTo-PacketRatProtocolPlainText $g.Name), $g.Count, $ids)))
    }

    $mustItems = @($sorted | Where-Object Category -ceq 'must_reply' | ForEach-Object { New-Entry $_.Index (Get-Line $_) })
    $doneItems = @($sorted | Where-Object { $_.Category -ceq 'already_replied' -or $_.Category -ceq 'no_action' } | ForEach-Object { New-Entry $_.Index (Get-Line $_) })
    $cautionItems = New-Object System.Collections.Generic.List[object]
    foreach ($r in @($sorted | Where-Object Category -ceq 'caution')) { [void]$cautionItems.Add((New-Entry $r.Index (Get-Line $r))) }
    foreach ($i in @($UnclassifiedIndexes | Sort-Object)) { [void]$cautionItems.Add((New-Entry $i ((Get-Subject $i) + ': not classified (the AI did not return a usable record for this message). Review it yourself.'))) }

    $deadlines = @($sorted | Where-Object { $_.Deadline } | Sort-Object Deadline | Select-Object -First 5)
    $quick = New-Object System.Collections.Generic.List[object]
    foreach ($r in $deadlines) { [void]$quick.Add((New-Entry $r.Index ("Deadline stated {0}: {1}" -f $r.Deadline, (Get-Subject $r.Index)))) }
    foreach ($w in @($Warnings)) { [void]$quick.Add((New-Entry 0 ('Note: ' + (ConvertTo-PacketRatProtocolPlainText $w)))) }

    $summary = ('{0} messages classified by record, {1} need a reply, {2} not classified.' -f @($Records).Count, $count['must_reply'], @($UnclassifiedIndexes).Count)
    $sections = @(
        [pscustomobject]@{ Id = 'categories'; Title = 'Categories'; Summary = $summary; Items = @($catItems) }
        [pscustomobject]@{ Id = 'groups'; Title = 'Groups'; Summary = ''; Items = @($groupItems.ToArray()) }
        [pscustomobject]@{ Id = 'must_reply'; Title = 'Must Reply'; Summary = ''; Items = @($mustItems) }
        [pscustomobject]@{ Id = 'already_replied'; Title = 'Already Replied / No Action Needed'; Summary = ''; Items = @($doneItems) }
        [pscustomobject]@{ Id = 'skipped'; Title = 'Skipped / Caution'; Summary = ''; Items = @($cautionItems.ToArray()) }
        [pscustomobject]@{ Id = 'quick_summary'; Title = 'Quick Summary'; Summary = ('{0} to reply to. Compiled from typed records; no narrative was written by the AI.' -f $count['must_reply']); Items = @($quick.ToArray()) }
    )
    return [pscustomobject]@{ Version = 'PACKETRAT_REPORT_V1'; MustReply = @($mustReply); ReportItems = @($items); Sections = @($sections) }
}
