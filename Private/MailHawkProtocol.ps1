#requires -Version 5.1
# MailHawk Wire Protocol v1 -- ASCII markers, strict structure, no raw text fallback.
function Get-MailHawkDraftWirePrompt {
    return @'
MAILHAWK DRAFT V1. Return EXACTLY ONE email response. No alternative versions.
Write precisely this envelope. Markers must each be on their own line:
<<<MAILHAWK_DRAFT_V1>>>
<<<SUBJECT>>>
One suggested subject on one line
<<<END_SUBJECT>>>
<<<BODY>>>
One plain-text email message using normal paragraphs.
<<<END_BODY>>>
<<<END_MAILHAWK_DRAFT_V1>>>
Do not write anything outside the envelope. Never place a marker inside the body.
No Markdown, HTML, code fences, JSON, prefaces, commentary, duplicated drafts,
fabricated approvals or invented signature. Outlook manages the real signature.
'@
}
function ConvertFrom-MailHawkDraftV1 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if([string]::IsNullOrWhiteSpace($Text)){throw 'Draft protocol: empty AI response.'}
    if($Text.Length -gt 150000){throw 'Draft protocol: oversized response.'}
    $clean=$Text.Replace([string][char]0xFEFF,'') -replace "`r`n?","`n"
    $pattern='(?s)\A\s*<<<MAILHAWK_DRAFT_V1>>>\n<<<SUBJECT>>>\n(?<subject>[^\n]+)\n<<<END_SUBJECT>>>\n<<<BODY>>>\n(?<body>.*?)\n<<<END_BODY>>>\n<<<END_MAILHAWK_DRAFT_V1>>>\s*\z'
    $m=[regex]::Match($clean,$pattern)
    if(-not $m.Success){throw 'Draft protocol: expected exactly one envelope with SUBJECT and BODY fields.'}
    $subject=$m.Groups['subject'].Value.Trim()
    $body=$m.Groups['body'].Value.Trim()
    if($subject.Length -lt 1 -or $subject.Length -gt 240){throw 'Draft protocol: subject must have 1-240 characters.'}
    if($body.Length -lt 1 -or $body.Length -gt 30000){throw 'Draft protocol: body must have 1-30000 characters.'}
    if($subject -match '[\x00-\x1F\x7F]' -or $body -match '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'){
        throw 'Draft protocol: illegal control character.'
    }
    if([regex]::IsMatch($body,'(?m)^<<<(?:MAILHAWK_|END_|SUBJECT|BODY)[A-Z0-9_]*>>>')){
        throw 'Draft protocol: duplicate or nested markers.'
    }
    return [pscustomobject]@{Version='MAILHAWK_DRAFT_V1';Subject=$subject;Body=$body}
}
function Get-MailHawkReportWirePrompt {
    return @'
MAILHAWK REPORT V1. Return EXACTLY ONE JSON report wrapped in these ASCII markers:
<<<MAILHAWK_REPORT_V1>>>
{"version":"MAILHAWK_REPORT_V1","must_reply":[{"index":1,"urgency":"High","why":"Reason"}],"report_items":[{"index":1,"section":"Must Reply","reason":"Reason","recommended_action":"Proposed action","urgency":"High"}],"sections":[{"id":"categories","title":"Categories","summary":"Short plain-text summary","items":[{"email_index":1,"text":"Source-grounded finding"}]},{"id":"groups","title":"Groups","summary":"","items":[]},{"id":"must_reply","title":"Must Reply","summary":"","items":[]},{"id":"already_replied","title":"Already Replied / No Action Needed","summary":"","items":[]},{"id":"skipped","title":"Skipped / Caution","summary":"","items":[]},{"id":"quick_summary","title":"Quick Summary","summary":"","items":[]}]}
<<<END_MAILHAWK_REPORT_V1>>>
The contents above demonstrate SHAPE only. Write actual findings, not placeholders.
All six section ids are mandatory in exactly that order. Use [] for empty items.
Use only source Index numbers present in the supplied inbox snapshot; never invent IDs.
The summary and text fields are plain text, not Markdown or HTML. No tables,
Markdown headings, code fences, special decorations or extra text outside markers.
Never invent completed actions, approvals, deadlines or a signature.
'@
}
function ConvertFrom-MailHawkReportV1 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text,[int]$MaxSourceIndex=0)
    if([string]::IsNullOrWhiteSpace($Text)){throw 'Report protocol: empty response.'}
    if($Text.Length -gt 750000){throw 'Report protocol: oversized response.'}
    $clean=$Text.Replace([string][char]0xFEFF,'') -replace "`r`n?","`n"
    $pattern='(?s)\A\s*<<<MAILHAWK_REPORT_V1>>>\n(?<payload>\{.*\})\n<<<END_MAILHAWK_REPORT_V1>>>\s*\z'
    $m=[regex]::Match($clean,$pattern)
    if(-not $m.Success){throw 'Report protocol: expected exactly one REPORT_V1 JSON envelope.'}
    try{$data=ConvertFrom-Json -InputObject $m.Groups['payload'].Value -ErrorAction Stop}catch{
        throw ('Report protocol: invalid JSON: '+$_.Exception.Message)
    }
    if([string]$data.version -cne 'MAILHAWK_REPORT_V1'){throw 'Report protocol: unsupported version.'}
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
        if($null -eq $section.items){throw 'Report protocol: section items missing.'}
        $title=[string]$section.title;$summary=[string]$section.summary
        if($title.Length -gt 120 -or $summary.Length -gt 3500 -or @($section.items).Count -gt 175){
            throw 'Report protocol: section content exceeds limits.'
        }
        $entries=New-Object System.Collections.Generic.List[object]
        foreach($entry in @($section.items)){
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
    return [pscustomobject]@{Version='MAILHAWK_REPORT_V1';MustReply=@($data.must_reply);ReportItems=@($data.report_items);Sections=@($safe.ToArray())}
}
function ConvertTo-MailHawkProtocolPlainText {
    param([AllowEmptyString()][string]$Value)
    if(-not $Value){return ''}
    $clean=[regex]::Replace($Value,'[\x00-\x1F\x7F]',' ')
    $clean=[regex]::Replace($clean,'\s+',' ').Trim()
    $clean=$clean.TrimStart([char[]]@('#','>','*','|',' '))
    return $clean.Replace('|',' / ').Replace('[','(').Replace(']',')').Replace('*','').Trim()
}
function ConvertTo-MailHawkReportMarkdownV1 {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Envelope,[Parameter(Mandatory)][array]$VerifiedEmails)
    $eligible=@{}
    foreach($email in @($VerifiedEmails)){
        if(-not $email.IsSensitive -and -not $email.UserDismissed -and $email.Fingerprint){$eligible[[int]$email.Index]=$true}
    }
    $lines=New-Object System.Collections.Generic.List[string]
    foreach($section in @($Envelope.Sections)){
        [void]$lines.Add('## '+([string]$section.Title))
        if($section.Summary){[void]$lines.Add((ConvertTo-MailHawkProtocolPlainText ([string]$section.Summary)))}
        foreach($entry in @($section.Items)){
            $line=ConvertTo-MailHawkProtocolPlainText ([string]$entry.Text)
            $index=[int]$entry.EmailIndex
            if($index -gt 0 -and $eligible.ContainsKey($index)){$line="[Email #$index] "+$line}
            if($line){[void]$lines.Add('- '+$line)}
        }
        [void]$lines.Add('')
    }
    return (($lines -join "`n").Trim())
}

# Follow-up generation from an existing report uses the same strict envelope strategy.
function Get-MailHawkInsightWirePrompt {
    return @'
MAILHAWK INSIGHT V1. Return precisely one JSON envelope:
<<<MAILHAWK_INSIGHT_V1>>>
{"version":"MAILHAWK_INSIGHT_V1","title":"Clear short title","summary":"Plain-text summary","items":[{"email_index":0,"text":"An evidence-grounded next step or finding"}]}
<<<END_MAILHAWK_INSIGHT_V1>>>
The object above demonstrates SHAPE only, not facts. Use only verified report email indices.
Use email_index 0 for general recommendations with no specific message.
Return no Markdown, HTML, quotes around the envelope, prefaces or extra text.
No made-up facts, completed tasks, permission grants or artificial signature.
'@
}
function ConvertFrom-MailHawkInsightV1 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt 180000){throw 'Insight protocol: empty or oversized output.'}
    $clean=$Text.Replace([string][char]0xFEFF,'') -replace "`r`n?","`n"
    $pattern='(?s)\A\s*<<<MAILHAWK_INSIGHT_V1>>>\n(?<json>\{.*\})\n<<<END_MAILHAWK_INSIGHT_V1>>>\s*\z'
    $m=[regex]::Match($clean,$pattern)
    if(-not $m.Success){throw 'Insight protocol: expected one INSIGHT_V1 envelope.'}
    try{$data=ConvertFrom-Json -InputObject $m.Groups['json'].Value -ErrorAction Stop}catch{
        throw ('Insight protocol: invalid JSON: '+$_.Exception.Message)
    }
    if([string]$data.version -cne 'MAILHAWK_INSIGHT_V1' -or $null -eq $data.items){
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
    return [pscustomobject]@{Version='MAILHAWK_INSIGHT_V1';Title=$title.Trim();Summary=$summary.Trim();Items=@($items.ToArray())}
}
function ConvertTo-MailHawkInsightMarkdownV1 {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Insight,[array]$VerifiedSources=@())
    $allowed=@{}
    foreach($source in @($VerifiedSources)){if($source.SourceVerified){$allowed[[int]$source.Index]=$true}}
    $lines=New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('## '+(ConvertTo-MailHawkProtocolPlainText ([string]$Insight.Title)))
    [void]$lines.Add((ConvertTo-MailHawkProtocolPlainText ([string]$Insight.Summary)))
    [void]$lines.Add('')
    foreach($item in @($Insight.Items)){
        $n=[int]$item.EmailIndex
        $text=ConvertTo-MailHawkProtocolPlainText ([string]$item.Text)
        if($n -gt 0 -and $allowed.ContainsKey($n)){$text="[Email #$n] "+$text}
        [void]$lines.Add('- '+$text)
    }
    return (($lines -join "`n").Trim())
}
