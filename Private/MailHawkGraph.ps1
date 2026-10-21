# MailHawk - optional Microsoft Graph provider
#requires -Version 5.1
# Only used when -Provider Graph is selected and Microsoft.Graph modules are available.

function Test-MailHawkGraphAvailable {
    return [bool](Get-Module -ListAvailable -Name Microsoft.Graph.Authentication, Microsoft.Graph.Mail -ErrorAction SilentlyContinue)
}

function Connect-MailHawkGraph {
    [CmdletBinding()]
    param(
        [string[]]$Scopes = @('Mail.Read', 'Mail.ReadWrite', 'User.Read')
    )
    if (-not (Test-MailHawkGraphAvailable)) {
        throw "Microsoft.Graph modules not installed. Install-Module Microsoft.Graph.Mail, Microsoft.Graph.Authentication"
    }
    Import-Module Microsoft.Graph.Authentication, Microsoft.Graph.Mail -ErrorAction Stop
    $ctx = Get-MgContext -ErrorAction SilentlyContinue
    if (-not $ctx) {
        Connect-MgGraph -Scopes $Scopes -NoWelcome
    }
    return $true
}

function Get-MailHawkInboxSummaryGraph {
    [CmdletBinding()]
    param(
        [int]$MaxEmails = 40,
        [int]$BodyPreviewChars = 280,
        [int]$DaysBack = 14,
        $Store = $null
    )

    $null = Connect-MailHawkGraph

    $cutoff = (Get-Date).AddDays(-$DaysBack).ToString('o')
    $filter = "receivedDateTime ge $cutoff"
    $msgs = Get-MgUserMessage -UserId 'me' -Filter $filter -Top $MaxEmails `
        -OrderBy 'receivedDateTime desc' `
        -Property 'id,subject,from,receivedDateTime,isRead,importance,bodyPreview,body,conversationId,inferenceClassification' `
        -ErrorAction Stop

    $results = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    $i = 0

    foreach ($m in @($msgs)) {
        $i++
        $subject = [string]$m.Subject
        $fromName = ''; $fromEmail = ''
        try {
            $fromName  = [string]$m.From.EmailAddress.Name
            $fromEmail = [string]$m.From.EmailAddress.Address
        } catch {}

        $received = ''
        try { $received = ([datetime]$m.ReceivedDateTime).ToString('yyyy-MM-dd HH:mm') } catch {}

        $unread = -not [bool]$m.IsRead
        $importance = 1
        if ($m.Importance -eq 'high') { $importance = 2 }
        elseif ($m.Importance -eq 'low') { $importance = 0 }

        $preview = [string]$m.BodyPreview
        if ($preview.Length -gt $BodyPreviewChars) {
            $preview = $preview.Substring(0, $BodyPreviewChars) + '...'
        }

        # Graph sensitivity is limited without extra permissions; basic keyword filter
        $isSensitive = $false
        if ($subject -match '(?i)\b(ssn|social security|phi|hipaa|passport|credit card)\b') {
            $isSensitive = $true
            $preview = '[REDACTED - PII heuristic]'
        }

        $fp = Get-MailHawkMailFingerprint -EntryID $m.Id -Subject $subject -FromEmail $fromEmail -Received $received

        $userDismissed = $false
        if ($Store) {
            $userDismissed = Test-MailHawkDismissed -Store $Store -Key $fp
            if (-not $userDismissed) {
                $userDismissed = Test-MailHawkDismissed -Store $Store -Key "id:$($m.Id)"
            }
        }

        $obj = [pscustomobject]@{
            Index             = $i
            EntryID           = [string]$m.Id
            Fingerprint       = $fp
            Received          = $received
            FromName          = $fromName
            FromEmail         = $fromEmail
            Subject           = $subject
            UnRead            = $unread
            Importance        = $importance
            ConversationTopic = $subject
            ConversationID    = [string]$m.ConversationId
            AppearsReplied    = $false
            ReplyEvidence     = ''
            UserDismissed     = $userDismissed
            IsSensitive       = $isSensitive
            BodyPreview       = $preview
        }

        if ($isSensitive) { [void]$skipped.Add($obj) }
        else { [void]$results.Add($obj) }
    }

    return [pscustomobject]@{
        Provider      = 'Graph'
        AnalyzedCount = $results.Count
        SkippedCount  = $skipped.Count
        Emails        = $results.ToArray()
        Skipped       = $skipped.ToArray()
        GeneratedAt   = (Get-Date).ToString('o')
    }
}
