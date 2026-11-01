# PacketRat - Lazarette bridge (integrator contract, docs/INTEGRATION.md in Lazarette)
# - Discover Lazarette: LAZARETTE_PATH, then a Lazarette folder next to this repo, then
#   %USERPROFILE%\Projects\Lazarette. A Lazarette folder contains lib\Lazarette.ps1.
# - Load the engine once per process (dot-sourced into a global dynamic module), unlock with
#   Unlock-LazaretteVaultInteractive and read with Get-LazaretteSecret.
# - Vault item names: ai-endpoint-api, grok-api (override: PACKETRAT_LAZARETTE_ITEM_<Profile>)
#requires -Version 5.1

# LLM vault items per profile:
#   Name    - item name
#   EnvKeys - item-name overrides (the first one set wins)
$script:PacketRatLlmVaultItems = @{
    AiEndpoint = @{
        Name    = 'ai-endpoint-api'
        EnvKeys = @('PACKETRAT_LAZARETTE_ITEM_AiEndpoint')
    }
    Grok = @{
        Name    = 'grok-api'
        EnvKeys = @('PACKETRAT_LAZARETTE_ITEM_Grok')
    }
}

# Session flag: the engine is loaded at most once per process
$script:PacketRatLazaretteSessionState = @{
    Loaded = $false
    Root   = $null
    Entry  = $null
}

function Get-PacketRatLazaretteCandidates {
    [CmdletBinding()]
    param()
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:LAZARETTE_PATH) { [void]$candidates.Add($env:LAZARETTE_PATH.Trim().Trim('"').Trim("'")) }
    $repo = $null
    try { $repo = $PSScriptRoot } catch {}
    if ($repo) {
        $parent = Split-Path (Split-Path $repo -Parent) -Parent   # the folder that holds the PacketRat folder
        [void]$candidates.Add((Join-Path $parent 'Lazarette'))
    }
    if ($env:USERPROFILE) { [void]$candidates.Add((Join-Path $env:USERPROFILE 'Projects\Lazarette')) }
    return $candidates.ToArray()
}

function Find-PacketRatLazaretteEntry {
    <#
    .SYNOPSIS
      Finds the Lazarette engine to load. Returns Root, Entry (lib\Lazarette.ps1) and Kind, or $null.
    #>
    [CmdletBinding()]
    param()
    $seen = New-Object System.Collections.Generic.List[string]
    foreach ($c in @(Get-PacketRatLazaretteCandidates)) {
        if (-not $c) { continue }
        try { $full = [IO.Path]::GetFullPath($c) } catch { continue }
        if ($seen.Contains($full)) { continue }
        [void]$seen.Add($full)
        $entry = Join-Path (Join-Path $full 'lib') 'Lazarette.ps1'
        if (Test-Path -LiteralPath $entry -PathType Leaf) {
            return [pscustomobject]@{ Root = $full; Entry = $entry; Kind = 'engine' }
        }
    }
    return $null
}

function Find-PacketRatLazaretteRoot {
    [CmdletBinding()]
    param()
    $found = Find-PacketRatLazaretteEntry
    if ($found) { return $found.Root }
    return $null
}

function Test-PacketRatLazaretteHelpersAvailable {
    return [bool](Get-Command Get-LazaretteSecret -ErrorAction SilentlyContinue)
}

function Import-PacketRatLazaretteSession {
    <#
    .SYNOPSIS
      Load the Lazarette engine once (its entry file under lib\).
      Safe to call repeatedly; never re-dot-sources after the first attempt. Does not unlock.
    #>
    [CmdletBinding()]
    param([string]$LazaretteRoot, [switch]$Quiet)

    # Already have helpers (e.g. this session already loaded Lazarette) - do not re-source
    if (Test-PacketRatLazaretteHelpersAvailable) {
        $script:PacketRatLazaretteSessionState.Loaded = $true
        if (-not $Quiet) { Write-Host '[*] Lazarette helpers already available' -ForegroundColor DarkGray }
        return $true
    }

    # We already attempted load this process - do not re-dot-source
    if ($script:PacketRatLazaretteSessionState.Loaded) {
        return (Test-PacketRatLazaretteHelpersAvailable)
    }

    $found = $null
    if ($LazaretteRoot) {
        $libDir = Join-Path $LazaretteRoot 'lib'
        $entry = Join-Path $libDir 'Lazarette.ps1'
        if (Test-Path -LiteralPath $entry -PathType Leaf) {
            $found = [pscustomobject]@{ Root = $LazaretteRoot; Entry = $entry; Kind = 'engine' }
        }
    } else {
        $found = Find-PacketRatLazaretteEntry
    }
    if (-not $found) {
        if (-not $Quiet) {
            Write-Host '[!] Lazarette not found (set LAZARETTE_PATH, or place a Lazarette folder next to PacketRat)' -ForegroundColor DarkGray
        }
        return $false
    }

    if (-not $Quiet) {
        Write-Host ("[*] Loading Lazarette from {0} ({1})" -f $found.Root, (Split-Path $found.Entry -Leaf)) -ForegroundColor Cyan
    }

    # Mark loaded BEFORE sourcing so concurrent/re-entrant calls do not double-source
    $script:PacketRatLazaretteSessionState.Loaded = $true
    $script:PacketRatLazaretteSessionState.Root = $found.Root
    $script:PacketRatLazaretteSessionState.Entry = $found.Entry

    try {
        $existing = Get-Module -Name PacketRatLazarette -ErrorAction SilentlyContinue
        if (-not $existing) {
            # A dynamic module keeps the engine's script-scoped state together and exports its
            # functions globally, so they outlive this function call.
            $packetRatLazarette = New-Module -Name PacketRatLazarette -ScriptBlock {
                param([string]$EntryPath)
                $ErrorActionPreference = 'Continue'
                . $EntryPath
                Export-ModuleMember -Function * -Alias * -ErrorAction SilentlyContinue
            } -ArgumentList $found.Entry
            Import-Module -ModuleInfo $packetRatLazarette -Global -Force -WarningAction SilentlyContinue
        }
    } catch {
        # Do not try a second load if anything partially loaded.
        if (-not $Quiet) {
            Write-Host "[x] Lazarette load failed: $($_.Exception.Message)" -ForegroundColor Red
        }
        return (Test-PacketRatLazaretteHelpersAvailable)
    }

    return (Test-PacketRatLazaretteHelpersAvailable)
}

function Assert-PacketRatLazaretteUnlocked {
    <#
    .SYNOPSIS
      If the vault is locked, unlock it in this console with Unlock-LazaretteVaultInteractive.
      Returns $true when open. Unlocking is interactive by design; nothing is unlocked silently.
    #>
    [CmdletBinding()]
    param()
    $hasTest = [bool](Get-Command Test-LazaretteVaultUnlocked -ErrorAction SilentlyContinue)
    if ($hasTest -and (Test-LazaretteVaultUnlocked)) { return $true }
    if (-not (Get-Command Unlock-LazaretteVaultInteractive -ErrorAction SilentlyContinue)) { return (-not $hasTest) }
    Write-Host '[*] Lazarette is locked. Unlock it in this console window to continue.' -ForegroundColor Yellow
    return [bool](Unlock-LazaretteVaultInteractive)
}

function Resolve-PacketRatLazaretteServiceName {
    <#
    .SYNOPSIS
      Resolve the vault lookup name for a profile: an item-name env override if set, else the default name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Profile
    )
    if (Get-Command ConvertTo-PacketRatLlmProfile -ErrorAction SilentlyContinue) {
        $Profile = ConvertTo-PacketRatLlmProfile -Profile $Profile
    }
    if (-not $script:PacketRatLlmVaultItems.ContainsKey($Profile)) {
        throw ("Unknown AI profile for vault lookup: {0}" -f $Profile)
    }
    $spec = $script:PacketRatLlmVaultItems[$Profile]
    foreach ($k in $spec.EnvKeys) {
        $v = [Environment]::GetEnvironmentVariable($k)
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v.Trim() }
    }
    return $spec.Name
}

function Get-PacketRatLazaretteSecretByName {
    <#
    .SYNOPSIS
      Resolve a vault secret by Lazarette item (service) name. Never prints secret values.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServiceName
    )

    if ([string]::IsNullOrWhiteSpace($ServiceName)) { return $null }
    if (-not (Get-Command Get-LazaretteSecret -ErrorAction SilentlyContinue)) { return $null }
    if (-not (Assert-PacketRatLazaretteUnlocked)) {
        Write-Host '[!] Lazarette stayed locked; no managed token read.' -ForegroundColor Yellow
        return $null
    }
    try {
        # Exactly one matching item, or it throws.
        $v = Get-LazaretteSecret -Service $ServiceName -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace([string]$v)) { return [string]$v }
    } catch {}
    return $null
}
