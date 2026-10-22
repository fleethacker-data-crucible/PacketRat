# MailHawk - Safe mail summary for AI analysis (COM provider)
#requires -Version 5.1

function Connect-MailHawkOutlook {
    [CmdletBinding()]
    param()

    try {
        $outlook = New-Object -ComObject Outlook.Application
        $ns = $outlook.GetNamespace('MAPI')
        try { $ns.Logon() } catch {}
        return [pscustomobject]@{
            Application = $outlook
            Namespace   = $ns
        }
    } catch {
        throw "Failed to connect to Outlook COM. Is Outlook installed and configured? $($_.Exception.Message)"
    }
}

function Test-MailHawkSensitiveMail {
    param($MailItem)

    if ($MailItem.Sensitivity -ge 2) { return $true }

    try {
        $msgClass = [string]$MailItem.MessageClass
        if ($msgClass -match 'IPM\.Note\.Secure|IPM\.Note\.IRM') { return $true }
    } catch {}

    $body = ''
    try { $body = [string]$MailItem.Body } catch { $body = '' }
    if ([string]::IsNullOrWhiteSpace($body) -and $MailItem.Subject -match '(?i)encrypt|secure|confidential|restricted') {
        return $true
    }

    $subj = [string]$MailItem.Subject
    if ($subj -match '(?i)\b(ssn|social security|dob|date of birth|medical record|phi|hipaa|passport|credit card)\b') {
        return $true
    }

    return $false
}

function Get-MailHawkSentReplyMap {
    param(
        $Namespace,
        [int]$DaysBack = 21,
        [int]$MaxScan = 300
    )

    $map = @{}
    try {
        $sent = $Namespace.GetDefaultFolder(5)  # olFolderSentMail
        $items = $sent.Items
        $items.Sort('[SentOn]', $true)
        $cutoff = (Get-Date).AddDays(-$DaysBack)
        $n = 0
        foreach ($it in $items) {
            if ($n -ge $MaxScan) { break }
            $n++
            if ($it.Class -ne 43) { continue }
            try {
                $sentOn = [datetime]$it.SentOn
            } catch { continue }
            if ($sentOn -lt $cutoff) { break }

            $topic = ''
            try { $topic = [string]$it.ConversationTopic } catch {}
            if (-not $topic) {
                try { $topic = [string]$it.Subject } catch { $topic = '' }
            }
            $norm = ($topic -replace '^(?i)\s*((re|fw|fwd)\s*:\s*)+', '').Trim()
            if (-not $norm) { continue }

            $key = $norm.ToLowerInvariant()
            if (-not $map.ContainsKey($key) -or $sentOn -gt $map[$key]) {
                $map[$key] = $sentOn
            }
        }
        try {
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($items) | Out-Null
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($sent) | Out-Null
        } catch {}
    } catch {
        Write-Verbose "Sent Items scan failed: $($_.Exception.Message)"
    }
    return $map
}

function Get-MailHawkInboxSummary {
    [CmdletBinding()]
    param(
        [int]$MaxEmails = 40,
        [int]$BodyPreviewChars = 280,
        [int]$DaysBack = 14,
        $Store = $null
    )

    $conn = Connect-MailHawkOutlook
    $ns   = $conn.Namespace
    $inbox = $ns.GetDefaultFolder(6)

    Write-Host '[*] Scanning Sent Items for reply detection...' -ForegroundColor DarkGray
    $sentMap = Get-MailHawkSentReplyMap -Namespace $ns -DaysBack ([Math]::Max($DaysBack, 21))

    $items = $inbox.Items
    $items.Sort('[ReceivedTime]', $true)

    $cutoff = (Get-Date).AddDays(-$DaysBack)
    $results = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    $count = 0

    foreach ($item in $items) {
        if ($count -ge $MaxEmails) { break }
        if ($item.Class -ne 43) { continue }

        try { $received = [datetime]$item.ReceivedTime } catch { continue }
        if ($received -lt $cutoff) { break }

        $isSensitive = Test-MailHawkSensitiveMail -MailItem $item

        $entryId = $null
        try { $entryId = [string]$item.EntryID } catch {}

        $fromName  = ''; $fromEmail = ''
        try {
            $fromName  = [string]$item.SenderName
            $fromEmail = [string]$item.SenderEmailAddress
        } catch {}

        # Resolve Exchange senders to SMTP; otherwise .mil domain rules may miss them.
        if ($fromEmail -notmatch '@' -and $item.Sender) {
            try {
                $exchangeSender = $item.Sender.GetExchangeUser()
                if ($exchangeSender -and $exchangeSender.PrimarySmtpAddress) {
                    $fromEmail = [string]$exchangeSender.PrimarySmtpAddress
                }
            } catch {}
        }
        # IsDirect is true only when the recipient can be verified from the
        # current Outlook identity or explicit operator-provided email address.
        $isDirect=$false
        try {
            $toLine=[string]$item.To
            $userEmail=[string]$env:MAILHAWK_USER_EMAIL
            $userName=''
            try {$userName=[string]$ns.CurrentUser.Name} catch {}
            try {
                $exchangeUser=$ns.CurrentUser.AddressEntry.GetExchangeUser()
                if($exchangeUser -and $exchangeUser.PrimarySmtpAddress){$userEmail=[string]$exchangeUser.PrimarySmtpAddress}
            }catch{}
            if($userEmail -and $toLine.IndexOf($userEmail,[StringComparison]::OrdinalIgnoreCase) -ge 0){$isDirect=$true}
            elseif($userName -and $toLine.IndexOf($userName,[StringComparison]::OrdinalIgnoreCase) -ge 0){$isDirect=$true}
        }catch{}
        $subject = ''
        try { $subject = [string]$item.Subject } catch {}

        $unread = $false
        try { $unread = [bool]$item.UnRead } catch {}

        $importance = 1
        try { $importance = [int]$item.Importance } catch {}

        $convTopic = ''
        $convId = ''
        try { $convTopic = [string]$item.ConversationTopic } catch {}
        try { $convId = [string]$item.ConversationID } catch {}

        $preview = ''
        if (-not $isSensitive) {
            try {
                $rawBody = [string]$item.Body
                if ($rawBody.Length -gt $BodyPreviewChars) {
                    $preview = $rawBody.Substring(0, $BodyPreviewChars) + '...'
                } else {
                    $preview = $rawBody
                }
                $preview = ($preview -replace '\s+', ' ').Trim()
            } catch { $preview = '[body unavailable]' }
        } else {
            $preview = '[REDACTED - sensitive/encrypted/PII heuristic]'
        }

        $appearsReplied = $false
        $replyEvidence  = ''

        $normTopic = ($convTopic -replace '^(?i)\s*((re|fw|fwd)\s*:\s*)+', '').Trim()
        if (-not $normTopic) {
            $normTopic = ($subject -replace '^(?i)\s*((re|fw|fwd)\s*:\s*)+', '').Trim()
        }
        $normKey = $normTopic.ToLowerInvariant()

        if ($normKey -and $sentMap.ContainsKey($normKey)) {
            $lastSent = $sentMap[$normKey]
            if ($lastSent -gt $received) {
                $appearsReplied = $true
                $replyEvidence = "Sent reply after receive ($($lastSent.ToString('yyyy-MM-dd HH:mm')))"
            }
        }
        if (-not $appearsReplied -and $subject -match '^(?i)re\s*:' -and -not $unread) {
            $appearsReplied = $true
            $replyEvidence = 'Subject is RE: and message is read'
        }

        $fp = Get-MailHawkMailFingerprint -EntryID $entryId -Subject $subject -FromEmail $fromEmail -Received $received.ToString('yyyy-MM-dd HH:mm')

        $userDismissed = $false
        if ($Store) {
            $userDismissed = Test-MailHawkDismissed -Store $Store -Key $fp
            if (-not $userDismissed -and $entryId) {
                $userDismissed = Test-MailHawkDismissed -Store $Store -Key "id:$entryId"
            }
        }

        $obj = [pscustomobject]@{
            Index             = $count + 1
            EntryID           = $entryId
            Fingerprint       = $fp
            Received          = $received.ToString('yyyy-MM-dd HH:mm')
            FromName          = $fromName
            FromEmail         = $fromEmail
            IsDirect          = $isDirect
            Subject           = $subject
            UnRead            = $unread
            Importance        = $importance
            ConversationTopic = $convTopic
            ConversationID    = $convId
            AppearsReplied    = $appearsReplied
            ReplyEvidence     = $replyEvidence
            UserDismissed     = $userDismissed
            IsSensitive       = $isSensitive
            BodyPreview       = $preview
        }

        if ($isSensitive) {
            [void]$skipped.Add($obj)
        } else {
            [void]$results.Add($obj)
            $count++
        }
    }

    try {
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($items) | Out-Null
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($inbox) | Out-Null
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ns) | Out-Null
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($conn.Application) | Out-Null
    } catch {}

    return [pscustomobject]@{
        Provider      = 'COM'
        AnalyzedCount = $results.Count
        SkippedCount  = $skipped.Count
        Emails        = $results.ToArray()
        Skipped       = $skipped.ToArray()
        GeneratedAt   = (Get-Date).ToString('o')
    }
}

function Open-MailHawkMailItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EntryID
    )
    $conn = Connect-MailHawkOutlook
    try {
        $item = $conn.Namespace.GetItemFromID($EntryID)
        if ($null -eq $item) { throw "No item found for EntryID." }
        $item.Display()
        return $true
    } catch {
        throw "Could not open mail item: $($_.Exception.Message)"
    }
}

function Join-MailHawkReplyHtml {
    param([string]$ExistingHtml,[string]$DraftText)
    if(-not $DraftText.Trim()){throw 'Empty reply.'}
    $match=[regex]::Match($ExistingHtml,'(?is)<body`b[^>]*>')
    if(-not $match.Success){throw 'Outlook HTML body unavailable.'}
    $encoded=[System.Net.WebUtility]::HtmlEncode($DraftText)
    $encoded=$encoded.Replace("`r`n","`n").Replace("`r","`n").Replace("`n",'<br />')
    $offset=$match.Index+$match.Length
    return $ExistingHtml.Substring(0,$offset)+'<div>'+$encoded+'</div><div><br /></div>'+$ExistingHtml.Substring($offset)
}
function New-MailHawkOutlookReplyDraft {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$EntryID,[Parameter(Mandatory)][string]$Body,
          [string]$SuggestedSubject,[switch]$ApplySuggestedSubject,[switch]$SaveOnly)
    if(-not $Body.Trim()){throw 'Empty draft.'}
    $conn=Connect-MailHawkOutlook
    $item=$conn.Namespace.GetItemFromID($EntryID)
    if(-not $item){throw 'Original email unavailable.'}
    $reply=$item.Reply()
    $reply.Display()
    $html=[string]$reply.HTMLBody
    if([int]$reply.BodyFormat -eq 2 -and $html -match '(?is)<body`b'){
        $reply.HTMLBody=Join-MailHawkReplyHtml -ExistingHtml $html -DraftText $Body
    }else{
        $reply.Body=$Body+"`r`n`r`n"+[string]$reply.Body
    }
    if($ApplySuggestedSubject){
        if(-not $SuggestedSubject.Trim() -or $SuggestedSubject.Length -gt 240 -or $SuggestedSubject -match '[`r`n]'){throw 'Invalid suggested subject.'}
        $reply.Subject=$SuggestedSubject.Trim()
    }
    if($SaveOnly){$reply.Save()}
    return $reply
}
