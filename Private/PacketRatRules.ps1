#requires -Version 5.1
# Editable, deterministic mail triage policy. No model-generated rules are executed.
# Organization-domain rules use PACKETRAT_ORG_DOMAIN (Config\packetrat.env): one or more domains or
# domain suffixes, comma-separated, e.g. example.org. When it is unset those rules never match.

function Get-PacketRatOrgDomains {
    $raw = [string]$env:PACKETRAT_ORG_DOMAIN
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    return @($raw -split '[,;\s]+' | ForEach-Object { $_.Trim().TrimStart('@').TrimStart('.').ToLowerInvariant() } |
        Where-Object { $_ -match '^[a-z0-9.-]+$' })
}

function Test-PacketRatOrgSender {
    param([string]$Sender)
    $address = ([string]$Sender).ToLowerInvariant()
    foreach ($domain in @(Get-PacketRatOrgDomains)) {
        if ($address.EndsWith('@' + $domain) -or ($address.Contains('@') -and $address.EndsWith('.' + $domain))) { return $true }
    }
    return $false
}

function Get-PacketRatDefaultRules {
    return @(
        [pscustomobject]@{Id='security';Name='Security / mandatory action';Enabled=$true;Match='SecurityAction';Value='';Effect='High'},
        [pscustomobject]@{Id='directorg';Name='Direct request from your organization';Enabled=$true;Match='DirectOrgRequest';Value='';Effect='High'},
        [pscustomobject]@{Id='directask';Name='Direct request or question';Enabled=$true;Match='DirectRequest';Value='';Effect='Medium'},
        [pscustomobject]@{Id='replied';Name='Already replied, no new request';Enabled=$true;Match='AlreadyReplied';Value='';Effect='Skip'},
        [pscustomobject]@{Id='automated';Name='Routine automated digest';Enabled=$true;Match='AutomatedDigest';Value='';Effect='Skip'}
    )
}

function Initialize-PacketRatRules {
    param($Store)
    if($null -eq $Store.PSObject.Properties['Rules'] -or $null -eq $Store.Rules){
        $Store | Add-Member -NotePropertyName Rules -NotePropertyValue @(Get-PacketRatDefaultRules) -Force
    }
    foreach($rule in @($Store.Rules)){
        if($rule -and $rule.PSObject.Properties['Match']){$rule.Match=[string]$rule.Match}
    }
    return $Store
}

function Set-PacketRatRules {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Store,[Parameter(Mandatory)][array]$Rules,[string]$Root)
    if($Rules.Count -gt 30){throw 'Maximum 30 triage rules'}
    $allowed=@('SecurityAction','DirectOrgRequest','DirectRequest','AlreadyReplied','AutomatedDigest','SenderDomain','SenderContains','SubjectContains','BodyContains','OrgSender')
    $seen=@{};$validated=New-Object System.Collections.Generic.List[object]
    foreach($rule in $Rules){
        $id=[string]$rule.Id;$name=[string]$rule.Name
        $match=[string]$rule.Match;$effect=[string]$rule.Effect;$value=[string]$rule.Value
        if($id -notmatch '^[a-zA-Z0-9_-]{1,48}$' -or $seen.ContainsKey($id)){throw 'Invalid or duplicate rule ID'}
        if([string]::IsNullOrWhiteSpace($name) -or $name.Length -gt 90){throw 'Rule name must have 1–90 characters'}
        if($allowed -cnotcontains $match){throw ('Unsupported rule match: '+$match)}
        if(@('High','Medium','Low','Skip') -cnotcontains $effect){throw 'Invalid rule outcome'}
        if($value.Length -gt 160){throw 'Rule value too long'}
        if($match -in @('SenderDomain','SenderContains','SubjectContains','BodyContains') -and [string]::IsNullOrWhiteSpace($value)){throw 'Custom matches require a value'}
        if($match -eq 'SenderDomain' -and $value -notmatch '^[a-zA-Z0-9.-]+$'){throw 'Use a plain domain, such as example.org'}
        $seen[$id]=$true
        [void]$validated.Add([pscustomobject]@{
            Id=$id;Name=$name.Trim();Enabled=[bool]$rule.Enabled
            Match=$match;Value=$value.Trim();Effect=$effect
        })
    }
    $Store | Add-Member -NotePropertyName Rules -NotePropertyValue @($validated.ToArray()) -Force
    Save-PacketRatStore -Store $Store -Root $Root
    return $Store
}

function Test-PacketRatRule {
    [CmdletBinding()]
    param($Rule,$Mail)
    $sender=[string]$Mail.FromEmail
    $subject=[string]$Mail.Subject
    $body=[string]$Mail.BodyPreview
    $direct=($Mail.PSObject.Properties['IsDirect'] -and [bool]$Mail.IsDirect)
    $hasAsk=("$subject $body" -match '(?i)(\?|action required|please\b|review\b|respond\b|approve\b|confirm\b|sign\b|submit\b|provide\b|request\b|by (monday|tuesday|wednesday|thursday|friday|tomorrow)|deadline\b|suspense\b)')
    switch([string]$Rule.Match){
        'SecurityAction' {return [bool]("$subject $body" -match '(?i)(dlp alert|security incident|policy violation|mandatory training|urgent action required|cybersecurity alert|saar.*(action|approve)|action required)')}
        'DirectOrgRequest' {return [bool]($direct -and (Test-PacketRatOrgSender $sender) -and $hasAsk)}
        'DirectRequest' {return [bool]($direct -and $hasAsk)}
        'AlreadyReplied' {return [bool]($Mail.AppearsReplied -and -not $hasAsk)}
        'AutomatedDigest' {
            if($hasAsk -or "$subject $body" -match '(?i)(suspense|mandatory|security incident|approval required)'){return $false}
            return [bool]("$sender $subject" -match '(?i)(no-?reply@|newsletter|digest|weekly roundup|automated notification|subscription)')
        }
        'SenderDomain' {
            $domain=([string]$Rule.Value).TrimStart('.').ToLowerInvariant()
            return [bool]($sender.ToLowerInvariant().EndsWith('@'+$domain) -or $sender.ToLowerInvariant().EndsWith('.'+$domain))
        }
        'OrgSender' {return [bool](Test-PacketRatOrgSender $sender)}
        'SenderContains' {return ($sender.IndexOf([string]$Rule.Value,[StringComparison]::OrdinalIgnoreCase) -ge 0)}
        'SubjectContains' {return ($subject.IndexOf([string]$Rule.Value,[StringComparison]::OrdinalIgnoreCase) -ge 0)}
        'BodyContains' {return ($body.IndexOf([string]$Rule.Value,[StringComparison]::OrdinalIgnoreCase) -ge 0)}
    }
    return $false
}

function Invoke-PacketRatRuleTriage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][array]$Emails,[Parameter(Mandatory)][AllowEmptyCollection()][array]$Suggested,[Parameter(Mandatory)]$Store)
    $null=Initialize-PacketRatRules -Store $Store
    $items=@{}
    foreach($item in $Suggested){
        if($item.Key){$items[[string]$item.Key]=$item}
    }
    $suppressed=New-Object System.Collections.Generic.List[string]
    $suppressedReasons=@{}
    $matched=0
    foreach($mail in $Emails){
        if($mail.UserDismissed -or $mail.IsSensitive -or -not $mail.Fingerprint){continue}
        $key=[string]$mail.Fingerprint
        foreach($rule in @($Store.Rules)){
            if(-not [bool]$rule.Enabled){continue}
            if(-not (Test-PacketRatRule -Rule $rule -Mail $mail)){continue}
            $matched++
            if($rule.Effect -eq 'Skip'){
                if($items.ContainsKey($key)){$items.Remove($key)}
                [void]$suppressed.Add($key)
                $suppressedReasons[$key]=[string]$rule.Name
                break
            }
            if($items.ContainsKey($key)){
                $candidate=$items[$key]
            }else{
                $candidate=[pscustomobject]@{
                    Index=[int]$mail.Index; Key=$key; EntryID=[string]$mail.EntryID
                    From=[string]$mail.FromName;FromEmail=[string]$mail.FromEmail
                    Subject=[string]$mail.Subject;Why='Matched triage rule';Urgency='Medium'
                }
                $items[$key]=$candidate
            }
            # The built-in "direct request" rule means "at least Medium": it must not pull down a High the model already gave.
            if($rule.Id -eq 'directask' -and $items.ContainsKey($key) -and [string]$candidate.Urgency -eq 'High'){break}
            $candidate | Add-Member -NotePropertyName Urgency -NotePropertyValue ([string]$rule.Effect) -Force
            $candidate | Add-Member -NotePropertyName TriageSource -NotePropertyValue 'Rule' -Force
            $candidate | Add-Member -NotePropertyName RuleName -NotePropertyValue ([string]$rule.Name) -Force
            if([string]$candidate.Why -eq 'Matched triage rule'){
                $candidate.Why='Rule: '+[string]$rule.Name
            }
            break
        }
    }
    return [pscustomobject]@{Items=@($items.Values | Sort-Object Index);Matched=$matched;SuppressedKeys=@($suppressed.ToArray());SuppressedReasons=$suppressedReasons}
}
