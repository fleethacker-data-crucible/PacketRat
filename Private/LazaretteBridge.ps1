# PacketRat - Lazarette bridge (integrator contract)
# - Discover Lazarette: LAZARETTE_PATH/ROOT/HOME, then LAZARETTE_PATH= in Config\packetrat.env, then
#   %LOCALAPPDATA%\Lazarette, then a sibling or %USERPROFILE%\Projects\Lazarette clone
# - A Lazarette folder is one that contains lib\Lazarette.ps1 or lib\Arc.ps1 (the engine entry file)
# - Load the engine once per process (dot-sourced into a global dynamic module), unlock with
#   Unlock-LazaretteVaultInteractive if defined, else Unlock-ArcVaultInteractive, and read with
#   Get-LazaretteSecret if defined, else Get-ArcSecret (the engine's own function names)
# - Canonical LLM vault item names: ai-endpoint-api, grok-api
# - Do not use pm.bat / launch-arc.bat
#requires -Version 5.1

# LLM vault items per profile. One place for every name PacketRat looks up:
#   Name    - canonical item name (emitted and documented)
#   Match   - extra vault-row names accepted when the canonical item is absent
#   EnvKeys - item-name overrides (the first one set wins)
$script:PacketRatLlmVaultItems = @{
    AiEndpoint = @{
        Name    = 'ai-endpoint-api'
        Match   = @()
        EnvKeys = @('PACKETRAT_LAZARETTE_ITEM_AiEndpoint')
    }
    Grok = @{
        Name    = 'grok-api'
        Match   = @('databricks')
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

    # 1) Env overrides
    foreach ($e in @($env:LAZARETTE_PATH, $env:LAZARETTE_ROOT, $env:LAZARETTE_HOME)) {
        if ($e) { [void]$candidates.Add($e.Trim().Trim('"').Trim("'")) }
    }

    # 2) Config\packetrat.env: LAZARETTE_PATH=
    $repo = $null
    try { $repo = $PSScriptRoot } catch {}
    $root = $null
    if ($repo) {
        $root = Split-Path $repo -Parent   # PacketRat\
        $envFile = Join-Path $root 'Config\packetrat.env'
        if (Test-Path -LiteralPath $envFile) {
            foreach ($line in @(Get-Content -LiteralPath $envFile -ErrorAction SilentlyContinue)) {
                if ($line -match '^\s*LAZARETTE_PATH\s*=\s*(.+)$') {
                    [void]$candidates.Add($Matches[1].Trim().Trim('"').Trim("'"))
                }
            }
        }
    }

    # 3) Per-user install folder
    if ($env:LOCALAPPDATA) {
        [void]$candidates.Add((Join-Path $env:LOCALAPPDATA 'Lazarette'))
    }

    # 4) Sibling clone next to this repo, then %USERPROFILE%\Projects
    if ($root) {
        $parent = Split-Path $root -Parent
        foreach ($n in @('Lazarette', 'lazarette')) { [void]$candidates.Add((Join-Path $parent $n)) }
    }
    if ($env:USERPROFILE) {
        foreach ($n in @('Lazarette', 'lazarette')) { [void]$candidates.Add((Join-Path $env:USERPROFILE ('Projects\' + $n))) }
    }

    return $candidates.ToArray()
}

function Find-PacketRatLazaretteEntry {
    <#
    .SYNOPSIS
      Finds the Lazarette engine to load. Returns Root, Entry (file to dot-source) and Kind, or $null.
      Looks in every candidate folder for lib\Lazarette.ps1, then lib\Arc.ps1.
    #>
    [CmdletBinding()]
    param()
    $folders = New-Object System.Collections.Generic.List[string]
    foreach ($c in @(Get-PacketRatLazaretteCandidates)) {
        if (-not $c) { continue }
        try { $full = [IO.Path]::GetFullPath($c) } catch { continue }
        if (-not $folders.Contains($full)) { [void]$folders.Add($full) }
    }
    foreach ($full in $folders) {
        foreach ($leaf in @('Lazarette.ps1', 'Arc.ps1')) {
            $entry = Join-Path (Join-Path $full 'lib') $leaf
            if (Test-Path -LiteralPath $entry -PathType Leaf) {
                return [pscustomobject]@{ Root = $full; Entry = $entry; Kind = 'engine' }
            }
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

function Get-PacketRatFirstCommand {
    param([string[]]$Names)
    foreach ($n in $Names) { if (Get-Command $n -ErrorAction SilentlyContinue) { return $n } }
    return $null
}

function Test-PacketRatLazaretteHelpersAvailable {
    return [bool](Get-Command Get-LazaretteSecret -ErrorAction SilentlyContinue) -or
           [bool](Get-Command Get-ArcSecret -ErrorAction SilentlyContinue) -or
           [bool](Get-Command Get-LiveVault -ErrorAction SilentlyContinue) -or
           [bool](Get-Command Ensure-VaultUnlocked -ErrorAction SilentlyContinue)
}

function Import-PacketRatLazaretteSession {
    <#
    .SYNOPSIS
      Load the Lazarette engine once (lib\Lazarette.ps1 or lib\Arc.ps1).
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
        foreach ($entry in @((Join-Path $libDir 'Lazarette.ps1'), (Join-Path $libDir 'Arc.ps1'))) {
            if (Test-Path -LiteralPath $entry -PathType Leaf) {
                $found = [pscustomobject]@{ Root = $LazaretteRoot; Entry = $entry; Kind = 'engine' }
                break
            }
        }
    } else {
        $found = Find-PacketRatLazaretteEntry
    }
    if (-not $found) {
        if (-not $Quiet) {
            Write-Host '[!] Lazarette not found (set LAZARETTE_PATH, or place a Lazarette clone next to PacketRat)' -ForegroundColor DarkGray
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
      If the vault is locked, unlock it in this console with
      Unlock-LazaretteVaultInteractive (or Unlock-ArcVaultInteractive). Returns $true when open.
      Unlocking is interactive by design; nothing is unlocked silently.
    #>
    [CmdletBinding()]
    param()
    $test = Get-PacketRatFirstCommand @('Test-LazaretteVaultUnlocked', 'Test-ArcVaultUnlocked')
    if ($test -and (& $test)) { return $true }
    $unlock = Get-PacketRatFirstCommand @('Unlock-LazaretteVaultInteractive', 'Unlock-ArcVaultInteractive')
    if (-not $unlock) { return [bool]($null -eq $test) }   # no lock concept
    Write-Host '[*] Lazarette is locked. Unlock it in this console window to continue.' -ForegroundColor Yellow
    return [bool](& $unlock)
}

function Resolve-PacketRatLazaretteServiceName {
    <#
    .SYNOPSIS
      Resolve the vault lookup name for a profile: an item-name env override if set, else the canonical name.
      Matchers are only used by Get-PacketRatLazaretteSecretByName, never returned here.
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
    return $spec.Name   # canonical
}

function Get-PacketRatLlmVaultSpec {
    # The vault-item spec whose canonical name is $ServiceName; $null for a custom name.
    param([string]$ServiceName)
    foreach ($spec in $script:PacketRatLlmVaultItems.Values) {
        if ($spec.Name -eq $ServiceName) { return $spec }
    }
    return $null
}

function Test-PacketRatLlmVaultAlias {
    # True when a vault service/name is a spec's canonical name or one of its matchers.
    param($Spec, [string]$Value)
    if (-not $Spec -or [string]::IsNullOrWhiteSpace($Value)) { return $false }
    return ($Value -eq $Spec.Name -or @($Spec.Match) -contains $Value)
}

function Get-PacketRatLazaretteSecretByName {
    <#
    .SYNOPSIS
      Resolve a vault secret by Lazarette item (service) name. Never prints secret values.
    .NOTES
      Primary lookup uses exact ServiceName (canonical: ai-endpoint-api, grok-api).
      When ServiceName is a canonical name, the matchers from $script:PacketRatLlmVaultItems are tried next.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServiceName
    )

    if ([string]::IsNullOrWhiteSpace($ServiceName)) { return $null }

    # 1) Get-LazaretteSecret if defined, else Get-ArcSecret (exactly one match or it throws)
    $get = Get-PacketRatFirstCommand @('Get-LazaretteSecret', 'Get-ArcSecret')
    if ($get) {
        if (-not (Assert-PacketRatLazaretteUnlocked)) {
            Write-Host '[!] Lazarette stayed locked; no managed token read.' -ForegroundColor Yellow
            return $null
        }
        $names = @($ServiceName)
        # Matchers only when the primary name is a canonical item
        $spec = Get-PacketRatLlmVaultSpec -ServiceName $ServiceName
        if ($spec) {
            $list = Get-PacketRatFirstCommand @('Get-LazaretteItemNames', 'Get-ArcItemNames')
            if ($list -and @($spec.Match).Count -gt 0) {
                try {
                    $names += @(& $list | ForEach-Object { [string]$_.Service } |
                        Where-Object { $_ -and $names -notcontains $_ -and (Test-PacketRatLlmVaultAlias -Spec $spec -Value $_) } |
                        Select-Object -Unique)
                } catch {}
            }
        }
        foreach ($name in $names) {
            try {
                $v = & $get -Service $name -ErrorAction Stop
                if (-not [string]::IsNullOrWhiteSpace([string]$v)) { return [string]$v }
            } catch {}
        }
        return $null
    }

    # 2) Vault row match - exact Service/Name first
    if (Get-Command Get-LiveVault -ErrorAction SilentlyContinue) {
        try {
            $vault = Get-LiveVault
            if ($vault) {
                $row = $vault | Where-Object {
                    $_.Service -eq $ServiceName -or $_.Name -eq $ServiceName
                } | Select-Object -First 1

                # Matchers only when the primary name is a canonical item
                $rowSpec = Get-PacketRatLlmVaultSpec -ServiceName $ServiceName
                if (-not $row -and $rowSpec) {
                    $row = $vault | Where-Object {
                        (Test-PacketRatLlmVaultAlias -Spec $rowSpec -Value ([string]$_.Service)) -or
                        (Test-PacketRatLlmVaultAlias -Spec $rowSpec -Value ([string]$_.Name))
                    } | Select-Object -First 1
                }

                if ($row) {
                    if ($row.Secret)   { return [string]$row.Secret }
                    if ($row.Password) { return [string]$row.Password }
                }
            }
        } catch {}
    }

    return $null
}
