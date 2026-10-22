#requires -Version 5.1
# MailHawk structured draft options. All outputs require human review.

function ConvertTo-MailHawkCleanDraft {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)
    if(-not $Text){return ''}
    $clean=$Text -replace '\r\n?', "`n"
    $clean=[regex]::Replace($clean,'(?m)^\s*>\s?','')
    $clean=[regex]::Replace($clean,'(?m)^\s*#{1,5}\s+(?:Draft|Response|Option|Version)\s+[AB12]\s*[:.\-]?\s*$','')
    $clean=[regex]::Replace($clean,'(?m)^\s*```(?:json|text|markdown)?\s*$','')
    $clean=[regex]::Replace($clean,'(?m)^\s*\*\*(.+?)\*\*\s*$','$1')
    $clean=[regex]::Replace($clean,'\*\*(.*?)\*\*','$1')
    $clean=$clean -replace '(?m)^\s*[-*]\s+(?=[^-])','• '
    $clean=[regex]::Replace($clean,"`n{3,}","`n`n")
    return $clean.Trim()
}

function ConvertFrom-MailHawkDraftAlternatives {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)
    if([string]::IsNullOrWhiteSpace($Text)){throw 'AI returned no draft content.'}
    $raw=$Text.Trim()
    $parsed=$null
    $json=$raw
    $fence=[regex]::Match($raw,'(?s)^\s*'+'```'+'(?:json)?\s*(.*?)\s*'+'```'+'\s*$')
    if($fence.Success){$json=$fence.Groups[1].Value}
    try{$parsed=ConvertFrom-Json -InputObject $json -ErrorAction Stop}catch{}
    $options=New-Object System.Collections.Generic.List[object]
    if($parsed){
        $items=@()
        if($parsed.responses){$items=@($parsed.responses)}
        elseif($parsed.options){$items=@($parsed.options)}
        elseif($parsed.drafts){$items=@($parsed.drafts)}
        elseif($parsed.body -or $parsed.draft){$items=@($parsed)}
        foreach($item in $items){
            if($options.Count -ge 3){break}
            $body=if($item -is [string]){[string]$item}elseif($item.body){[string]$item.body}elseif($item.text){[string]$item.text}else{[string]$item.draft}
            $body=ConvertTo-MailHawkCleanDraft -Text $body
            if(-not $body){continue}
            $label=if($item.label){[string]$item.label}elseif($item.tone){[string]$item.tone}else{'Response '+[char](65+$options.Count)}
            [void]$options.Add([pscustomobject]@{Id=[string][char](65+$options.Count);Label=$label.Substring(0,[Math]::Min($label.Length,80));Body=$body})
        }
    }
    if($options.Count -eq 0){
        # GenAI markdown, e.g. "### Option A", "**Response B:**", "Draft 1:".
        $header='(?im)^\s*(?:#{1,5}\s*)?(?:\*\*)?\s*(?:option|response|draft|version)\s*([AB12])\s*(?:\*\*)?\s*[:.)\-–]?\s*(.*)$'
        $matches=[regex]::Matches($raw,$header)
        if($matches.Count -ge 2){
            for($i=0;$i -lt [Math]::Min($matches.Count,3);$i++){
                $start=$matches[$i].Index+$matches[$i].Length
                $end=if($i -lt $matches.Count-1){$matches[$i+1].Index}else{$raw.Length}
                $body=ConvertTo-MailHawkCleanDraft -Text $raw.Substring($start,$end-$start)
                if(-not $body){continue}
                $headerText=[string]$matches[$i].Groups[2].Value
                $label=if($headerText.Trim()){$headerText.Trim(' ',':','*','-')}else{if($i -eq 0){'Concise'}else{'Collaborative'}}
                [void]$options.Add([pscustomobject]@{Id=[string][char](65+$options.Count);Label=$label.Substring(0,[Math]::Min($label.Length,80));Body=$body})
            }
        }
    }
    if($options.Count -eq 0){
        $clean=ConvertTo-MailHawkCleanDraft -Text $raw
        [void]$options.Add([pscustomobject]@{Id='A';Label='Suggested response';Body=$clean})
    }
    return @($options.ToArray())
}

function New-MailHawkDraftReply {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Email,
        [ValidateSet('Auto','Grok','GenAi')][string]$Profile='Auto',
        [string]$Model,
        [string]$ExtraInstruction,
        [ValidateRange(20000,32768)][int]$MaxTokens=20000
    )
    # 20k is an OUTPUT ceiling, not a request for a 20k-token email.
    # The provider may impose a lower maximum; surface that error to the user.
    $system=@'
You are MailHawk's email drafting assistant. Draft human-reviewed professional government-workplace replies.
Respond ONLY with valid JSON, no markdown fences, no preface:
{"responses":[{"label":"Concise","body":"Full ready-to-edit reply text"},{"label":"Collaborative","body":"A different ready-to-edit reply text"}]}
Write exactly two distinctly useful alternatives, approximately 70-230 words each.
Never fabricate completed actions, approvals, dates, authorizations or facts absent from the email.
Do not echo sensitive personal data. Do not produce a fake signature.
Respond to the actual request. If facts are missing, ask a sensible clarifying question.
Use readable paragraphs; no markdown quote markers (>), bullet nesting or decorative symbols.
No email headers or analysis commentary outside the JSON.
'@
    $user=@"
Sender: $($Email.FromName) <$($Email.FromEmail)>
Received: $($Email.Received)
Subject: $($Email.Subject)
Email preview:
$($Email.BodyPreview)

Additional writing guidance:
$ExtraInstruction
"@
    $messages=@(@{role='system';content=$system},@{role='user';content=$user})
    $ai=Invoke-MailHawkChat -Messages $messages -Profile $Profile -Model $Model -MaxTokens $MaxTokens -Temperature 0.3
    $options=@(ConvertFrom-MailHawkDraftAlternatives -Text ([string]$ai.Text))
    if($options.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$options[0].Body)){throw 'AI did not produce a usable draft.'}
    return [pscustomobject]@{
        EntryID=$Email.EntryID;Subject=$Email.Subject
        Draft=$options[0].Body;Options=$options
        Profile=$ai.Profile;Model=$ai.Model
        OutputTokenBudget=$MaxTokens
    }
}
