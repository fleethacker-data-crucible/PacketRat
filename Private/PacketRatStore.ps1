# PacketRat - local persistent store (checklist + false-positive dismissals)
#requires -Version 5.1

function Get-PacketRatStorePath {
    param([string]$Root)
    if (-not $Root) { $Root = $PSScriptRoot }
    # Private\ -> project root
    if ((Split-Path $Root -Leaf) -eq 'Private') {
        $Root = Split-Path $Root -Parent
    }
    $dir = Join-Path $Root 'Logs'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir 'packetrat-store.json'
    return $path
}

function Get-PacketRatStore {
    [CmdletBinding()]
    param([string]$Root)

    $path = Get-PacketRatStorePath -Root $Root
    if (-not (Test-Path $path)) {
        return [pscustomobject]@{
            Version     = 1
            UpdatedAt   = (Get-Date).ToString('o')
            Dismissals  = @()   # EntryID or fingerprint -> reason
            Checklist   = @()   # tracked must-reply items
            Rules       = @(Get-PacketRatDefaultRules)  # editable deterministic triage policy
        }
    }
    try {
        $raw = Get-Content -Path $path -Raw -Encoding UTF8
        $obj = $raw | ConvertFrom-Json
        if (-not $obj.Dismissals) { $obj | Add-Member -NotePropertyName Dismissals -NotePropertyValue @() -Force }
        if (-not $obj.Checklist)  { $obj | Add-Member -NotePropertyName Checklist  -NotePropertyValue @() -Force }
        $null=Initialize-PacketRatRules -Store $obj
        return $obj
    } catch {
        Write-Warning "PacketRat store unreadable, starting fresh: $($_.Exception.Message)"
        return [pscustomobject]@{
            Version     = 1
            UpdatedAt   = (Get-Date).ToString('o')
            Dismissals  = @()
            Checklist   = @()
            Rules       = @(Get-PacketRatDefaultRules)
        }
    }
}

function Save-PacketRatStore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Store,
        [string]$Root
    )
    $path = Get-PacketRatStorePath -Root $Root
    $Store.UpdatedAt = (Get-Date).ToString('o')
    $json = $Store | ConvertTo-Json -Depth 8
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($path, $json, $utf8NoBom)
}

function Get-PacketRatMailFingerprint {
    <#
    .SYNOPSIS
      Stable-ish key when EntryID is missing or changes across profiles.
    #>
    param(
        [string]$EntryID,
        [string]$Subject,
        [string]$FromEmail,
        [string]$Received
    )
    if ($EntryID) { return "id:$EntryID" }
    $raw = "$FromEmail|$Subject|$Received"
    $bytes = [Text.Encoding]::UTF8.GetBytes($raw.ToLowerInvariant())
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
        return "fp:$($hash.Substring(0,24))"
    } finally { $sha.Dispose() }
}

function Test-PacketRatDismissed {
    param($Store, [string]$Key)
    if (-not $Store -or -not $Store.Dismissals) { return $false }
    foreach ($d in @($Store.Dismissals)) {
        if ($d.Key -eq $Key) { return $true }
    }
    return $false
}

function Add-PacketRatDismissal {
    <#
    .SYNOPSIS
      Mark an email as false-positive / no-action. Persists across runs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Store,
        [Parameter(Mandatory)][string]$Key,
        [string]$Subject,
        [string]$From,
        [string]$Reason = 'false positive / no action needed',
        [string]$Root
    )

    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($d in @($Store.Dismissals)) {
        if ($d.Key -ne $Key) { [void]$list.Add($d) }
    }
    [void]$list.Add([pscustomobject]@{
        Key       = $Key
        Subject   = $Subject
        From      = $From
        Reason    = $Reason
        DismissedAt = (Get-Date).ToString('o')
    })
    $Store.Dismissals = $list.ToArray()
    Save-PacketRatStore -Store $Store -Root $Root
    return $Store
}

function Remove-PacketRatDismissal {
    param($Store, [string]$Key, [string]$Root)
    $Store.Dismissals = @($Store.Dismissals | Where-Object { $_.Key -ne $Key })
    Save-PacketRatStore -Store $Store -Root $Root
    return $Store
}

function Merge-PacketRatChecklist {
    <#
    .SYNOPSIS
      Upsert must-reply items from an analysis run into the persistent checklist.
      Preserves user status (done / dismissed) for existing keys.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Store,
        [Parameter(Mandatory)][array]$Items,  # from AI structured output
        [string]$Root
    )

    $byKey = @{}
    foreach ($c in @($Store.Checklist)) {
        if ($c.Key) { $byKey[$c.Key] = $c }
    }

    foreach ($item in $Items) {
        $key = $item.Key
        if (-not $key) { continue }

        if ($byKey.ContainsKey($key)) {
            $existing = $byKey[$key]
            # Keep user-driven status; refresh metadata
            $existing.Subject   = $item.Subject
            $existing.From      = $item.From
            $existing.Why       = $item.Why
            $existing | Add-Member -NotePropertyName SuggestedUrgency -NotePropertyValue ([string]$item.Urgency) -Force
            if (-not $existing.PriorityOverride) { $existing.Urgency = $item.Urgency }
            $existing | Add-Member -NotePropertyName TriageSource -NotePropertyValue ([string]$item.TriageSource) -Force
            $existing | Add-Member -NotePropertyName RuleName -NotePropertyValue ([string]$item.RuleName) -Force
            if ($existing.PriorityOverride) {
                $existing.TriageSource = 'Manual'
            }
            $existing.EntryID   = $item.EntryID
            $existing | Add-Member -NotePropertyName RuleSuppressed -NotePropertyValue $false -Force
            $existing.LastSeen  = (Get-Date).ToString('o')
            if ($existing.Status -eq 'open' -or -not $existing.Status) {
                $existing.Status = 'open'
            }
        } else {
            $byKey[$key] = [pscustomobject]@{
                Key       = $key
                EntryID   = $item.EntryID
                Subject   = $item.Subject
                From      = $item.From
                Why       = $item.Why
                Urgency   = $item.Urgency
                PriorityOverride = $false
                RuleSuppressed = $false
                SuggestedUrgency = [string]$item.Urgency
                TriageSource = $(if($item.TriageSource){[string]$item.TriageSource}else{'AI'})
                RuleName = [string]$item.RuleName
                FromEmail = [string]$item.FromEmail
                Status    = 'open'   # open | in_progress | done | dismissed
                CreatedAt = (Get-Date).ToString('o')
                LastSeen  = (Get-Date).ToString('o')
                Notes     = ''
            }
        }
    }

    $Store.Checklist = @($byKey.Values | Sort-Object {
        switch ($_.Urgency) { 'High' { 0 } 'Medium' { 1 } 'Low' { 2 } default { 3 } }
    }, Subject)

    Save-PacketRatStore -Store $Store -Root $Root
    return $Store
}

function Set-PacketRatChecklistStatus {
    param(
        [Parameter(Mandatory)]$Store,
        [Parameter(Mandatory)][string]$Key,
        [ValidateSet('open','in_progress','done','dismissed')]
        [string]$Status,
        [string]$Notes,
        [string]$Root
    )
    foreach ($c in @($Store.Checklist)) {
        if ($c.Key -eq $Key) {
            $c.Status = $Status
            $c.LastSeen = (Get-Date).ToString('o')
            if ($PSBoundParameters.ContainsKey('Notes')) { $c.Notes = $Notes }
            break
        }
    }
    Save-PacketRatStore -Store $Store -Root $Root
    return $Store
}


function Set-PacketRatChecklistPriority {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Store,
        [Parameter(Mandatory)][string]$Key,
        [ValidateSet('High','Medium','Low')][string]$Urgency,
        [string]$Root
    )
    $found=$false
    foreach($item in @($Store.Checklist)){
        if([string]$item.Key -cne $Key){continue}
        $item.Urgency=$Urgency
        $item | Add-Member -NotePropertyName PriorityOverride -NotePropertyValue $true -Force
        $item | Add-Member -NotePropertyName RuleSuppressed -NotePropertyValue $false -Force
        $item | Add-Member -NotePropertyName TriageSource -NotePropertyValue 'Manual' -Force
        $item | Add-Member -NotePropertyName RuleName -NotePropertyValue '' -Force
        $item.LastSeen=(Get-Date).ToString('o')
        $found=$true
        break
    }
    if(-not $found){throw 'Unknown checklist item'}
    Save-PacketRatStore -Store $Store -Root $Root
    return $Store
}

function Clear-PacketRatChecklistPriorityOverride {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Store,[Parameter(Mandatory)][string]$Key,[string]$Root)
    $found=$false
    foreach($item in @($Store.Checklist)){
        if([string]$item.Key -cne $Key){continue}
        $item | Add-Member -NotePropertyName PriorityOverride -NotePropertyValue $false -Force
        if(@('High','Medium','Low') -contains [string]$item.SuggestedUrgency){$item.Urgency=[string]$item.SuggestedUrgency}
        $item | Add-Member -NotePropertyName TriageSource -NotePropertyValue 'AI' -Force
        $item | Add-Member -NotePropertyName RuleName -NotePropertyValue '' -Force
        $found=$true
        break
    }
    if(-not $found){throw 'Unknown checklist item'}
    Save-PacketRatStore -Store $Store -Root $Root
    return $Store
}
