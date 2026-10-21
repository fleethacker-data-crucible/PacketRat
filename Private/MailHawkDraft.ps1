# MailHawk - AI draft reply generation (human-in-the-loop)
#requires -Version 5.1

function New-MailHawkDraftReply {
    <#
    .SYNOPSIS
      Ask the AI for a short professional draft reply to a specific email.
      Does NOT send. Caller decides whether to open in Outlook or copy.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Email,   # object from inbox summary
        [ValidateSet('Auto', 'Grok', 'GenAi')]
        [string]$Profile = 'Auto',
        [string]$Model,
        [string]$ExtraInstruction
    )

    $sys = @"
You are MailHawk drafting assistant for a professional / government environment.
Write a concise, professional reply body only (no subject line, no greeting signature block unless natural).
Rules:
- Do not invent facts not present in the email preview.
- Do not include or request PII (SSN, medical, passwords, etc.).
- If the email is a security/DLP alert that may be a false positive, draft a calm clarification request or acknowledgement, not an admission of wrongdoing.
- Keep it under 150 words.
- Plain ASCII only. No emoji.
- Output ONLY the reply body text.
"@

    $user = @"
Draft a reply to this email:

From: $($Email.FromName) <$($Email.FromEmail)>
Received: $($Email.Received)
Subject: $($Email.Subject)
Preview: $($Email.BodyPreview)

$ExtraInstruction
"@

    $messages = @(
        @{ role = 'system'; content = $sys }
        @{ role = 'user';   content = $user }
    )

    $ai = Invoke-MailHawkChat -Messages $messages -Profile $Profile -Model $Model -MaxTokens 1024 -Temperature 0.3
    $text = [regex]::Replace([string]$ai.Text, '[^\x09\x0A\x0D\x20-\x7E]', '').Trim()
    return [pscustomobject]@{
        EntryID = $Email.EntryID
        Subject = $Email.Subject
        Draft   = $text
        Profile = $ai.Profile
        Model   = $ai.Model
    }
}
