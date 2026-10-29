# PacketRat - Safe mail summary for AI analysis (COM provider)
#requires -Version 5.1

function Get-PacketRatOutlookProfileProblem {
    # Classic Outlook started with no usable mail profile shows a Choose Profile or setup dialog and never
    # returns to COM, so PacketRat would wait forever. Read-only registry check; $null when it looks usable
    # or cannot be told (then COM is tried as before).
    [CmdletBinding()]
    param()

    $titles = @(Get-Process OUTLOOK -ErrorAction SilentlyContinue | ForEach-Object { $_.MainWindowTitle })
    if ($titles -contains 'Choose Profile') { return 'Classic Outlook is waiting on its Choose Profile dialog. Pick a profile there (or close it), then try again.' }
    if ($titles.Count -gt 0) { return $null }
    foreach ($version in @('16.0', '15.0')) {
        $key = "HKCU:\Software\Microsoft\Office\$version\Outlook"
        if (-not (Test-Path $key)) { continue }
        $profilesKey = Join-Path $key 'Profiles'
        $profiles = @(Get-ChildItem $profilesKey -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName })
        if ($profiles.Count -eq 0) { return 'Classic Outlook has no mail profile on this PC. Open classic Outlook once and add your mail account (the new Outlook app is not used by PacketRat), then try again.' }
        $default = [string](Get-ItemProperty $key -ErrorAction SilentlyContinue).DefaultProfile
        if (-not $default -or $profiles -notcontains $default) { return $null }
        $accounts = @(Get-ChildItem (Join-Path $profilesKey "$default\9375CFF0413111d3B88A00104B2A6676") -ErrorAction SilentlyContinue)
        if ($accounts.Count -eq 0) { return "Classic Outlook's profile '$default' has no mail account, so Outlook would stop on a setup dialog. Open classic Outlook once and add your mail account (the new Outlook app is not used by PacketRat), then try again." }
        return $null
    }
    return $null
}

function Connect-PacketRatOutlook {
    [CmdletBinding()]
    param()

    $problem = Get-PacketRatOutlookProfileProblem
    if ($problem) { throw $problem }
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

function Test-PacketRatSensitiveMail {
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

function Get-PacketRatSentReplyMap {
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

function Get-PacketRatInboxSummary {
    [CmdletBinding()]
    param(
        [int]$MaxEmails = 40,
        [int]$BodyPreviewChars = 280,
        [int]$DaysBack = 14,
        $Store = $null
    )

    $conn = Connect-PacketRatOutlook
    $ns   = $conn.Namespace
    $inbox = $ns.GetDefaultFolder(6)

    Write-Host '[*] Scanning Sent Items for reply detection...' -ForegroundColor DarkGray
    $sentMap = Get-PacketRatSentReplyMap -Namespace $ns -DaysBack ([Math]::Max($DaysBack, 21))

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

        $isSensitive = Test-PacketRatSensitiveMail -MailItem $item

        $entryId = $null
        try { $entryId = [string]$item.EntryID } catch {}

        $fromName  = ''; $fromEmail = ''
        try {
            $fromName  = [string]$item.SenderName
            $fromEmail = [string]$item.SenderEmailAddress
        } catch {}

        # Resolve Exchange senders to SMTP; otherwise organization-domain rules may miss them.
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
            $userEmail=[string]$env:PACKETRAT_USER_EMAIL
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

        $fp = Get-PacketRatMailFingerprint -EntryID $entryId -Subject $subject -FromEmail $fromEmail -Received $received.ToString('yyyy-MM-dd HH:mm')

        $userDismissed = $false
        if ($Store) {
            $userDismissed = Test-PacketRatDismissed -Store $Store -Key $fp
            if (-not $userDismissed -and $entryId) {
                $userDismissed = Test-PacketRatDismissed -Store $Store -Key "id:$entryId"
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

function Open-PacketRatMailItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EntryID
    )
    $conn = Connect-PacketRatOutlook
    try {
        $item = $conn.Namespace.GetItemFromID($EntryID)
        if ($null -eq $item) { throw "No item found for EntryID." }
        $item.Display()
        return $true
    } catch {
        throw "Could not open mail item: $($_.Exception.Message)"
    }
}

function Join-PacketRatReplyHtml {
    param([string]$ExistingHtml,[string]$DraftText)
    if(-not $DraftText.Trim()){throw 'Empty reply.'}
    $match=[regex]::Match($ExistingHtml,'(?is)<body\b[^>]*>')
    if(-not $match.Success){throw 'Outlook HTML body unavailable.'}
    $encoded=[System.Net.WebUtility]::HtmlEncode($DraftText)
    $encoded=$encoded.Replace("`r`n","`n").Replace("`r","`n").Replace("`n",'<br />')
    $offset=$match.Index+$match.Length
    return $ExistingHtml.Substring(0,$offset)+'<div>'+$encoded+'</div><div><br /></div>'+$ExistingHtml.Substring($offset)
}
function New-PacketRatOutlookReplyDraft {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$EntryID,[Parameter(Mandatory)][string]$Body,
          [string]$SuggestedSubject,[switch]$ApplySuggestedSubject,[switch]$SaveOnly)
    if(-not $Body.Trim()){throw 'Empty draft.'}
    $conn=Connect-PacketRatOutlook
    $item=$conn.Namespace.GetItemFromID($EntryID)
    if(-not $item){throw 'Original email unavailable.'}
    $reply=$item.Reply()
    $reply.Display()
    $html=[string]$reply.HTMLBody
    $format=[int]$reply.BodyFormat
    if($format -eq 2){
        if($html -notmatch '(?is)<body\b'){throw 'Outlook HTML editor is missing a body element; no signature was overwritten.'}
        $reply.HTMLBody=Join-PacketRatReplyHtml -ExistingHtml $html -DraftText $Body
    }elseif($format -eq 3){
        # For Outlook rich-text/Word format insert via WordEditor so its
        # rich-text signature and inline formatting remain untouched.
        $inspector=$reply.GetInspector
        $editor=$inspector.WordEditor
        if(-not $editor){throw 'Cannot safely edit Outlook rich-text reply.'}
        $start=$editor.Range(0,0)
        $start.InsertBefore($Body+"`r`n`r`n")
    }else{
        # Plain-text reply: keep whatever default text signature Outlook added.
        $reply.Body=$Body+"`r`n`r`n"+[string]$reply.Body
    }
    if($ApplySuggestedSubject){
        if(-not $SuggestedSubject.Trim() -or $SuggestedSubject.Length -gt 240 -or $SuggestedSubject -match '[`r`n]'){throw 'Invalid suggested subject.'}
        $reply.Subject=$SuggestedSubject.Trim()
    }
    if($SaveOnly){$reply.Save()}
    return $reply
}
