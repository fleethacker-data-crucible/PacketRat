# PacketRat - Lazarette bridge (integrator contract; Lazarette was formerly ARC)
# - Discover Lazarette: LAZARETTE_PATH/ROOT/HOME, then ARC_PATH/ROOT/HOME, then config, then
#   %LOCALAPPDATA%\Lazarette, %LOCALAPPDATA%\ARC, then sibling/Projects folders (lazarette before arc)
# - A Lazarette folder is one that contains lib\Lazarette.ps1 or lib\Arc.ps1 (Lazarette / ARC 5).
#   pm.ps1 is only a last-resort ARC 3/4 fallback: in ARC 5 it is a stub that throws.
# - Load the engine once per process (dot-sourced into a global dynamic module), unlock with
#   Unlock-LazaretteVaultInteractive if defined, else Unlock-ArcVaultInteractive, and read with
#   Get-LazaretteSecret if defined, else Get-ArcSecret. ARC 3/4 pm.ps1 helpers stay as a fallback.
# - Canonical LLM vault item names (unchanged): genapi, advana-api
# - Do not use pm.bat / launch-arc.bat
#requires -Version 5.1

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

    # 1) Env overrides: LAZARETTE_* first, then the former ARC_* names
    foreach ($e in @($env:LAZARETTE_PATH, $env:LAZARETTE_ROOT, $env:LAZARETTE_HOME,
                     $env:ARC_PATH, $env:ARC_ROOT, $env:ARC_HOME)) {
        if ($e) { [void]$candidates.Add($e.Trim().Trim('"').Trim("'")) }
    }

    # 2) Config\packetrat.env (or legacy Config\mailhawk.env): LAZARETTE_PATH= first, then ARC_PATH=
    $repo = $null
    try { $repo = $PSScriptRoot } catch {}
    $root = $null
    if ($repo) {
        $root = Split-Path $repo -Parent   # PacketRat\
        foreach ($envName in @('packetrat.env', 'mailhawk.env')) {
            $envFile = Join-Path $root ('Config\' + $envName)
            if (-not (Test-Path -LiteralPath $envFile)) { continue }
            $lines = @(Get-Content -LiteralPath $envFile -ErrorAction SilentlyContinue)
            foreach ($key in @('LAZARETTE_PATH', 'ARC_PATH')) {
                foreach ($line in $lines) {
                    if ($line -match ('^\s*' + $key + '\s*=\s*(.+)$')) {
                        [void]$candidates.Add($Matches[1].Trim().Trim('"').Trim("'"))
                    }
                }
            }
            break   # packetrat.env wins when present
        }
    }

    # 3) Per-user install folders: Lazarette first, then the former ARC folder
    if ($env:LOCALAPPDATA) {
        [void]$candidates.Add((Join-Path $env:LOCALAPPDATA 'Lazarette'))
        [void]$candidates.Add((Join-Path $env:LOCALAPPDATA 'ARC'))
    }

    # 4) Sibling clone next to this repo, then %USERPROFILE%\Projects (lazarette before arc)
    if ($root) {
        $parent = Split-Path $root -Parent
        foreach ($n in @('Lazarette', 'lazarette', 'arc')) { [void]$candidates.Add((Join-Path $parent $n)) }
    }
    if ($env:USERPROFILE) {
        foreach ($n in @('Lazarette', 'lazarette', 'arc')) { [void]$candidates.Add((Join-Path $env:USERPROFILE ('Projects\' + $n))) }
    }

    return $candidates.ToArray()
}

function Find-PacketRatLazaretteEntry {
    <#
    .SYNOPSIS
      Finds the Lazarette engine to load. Returns Root, Entry (file to dot-source) and Kind, or $null.
      Pass 1 (every candidate): lib\Lazarette.ps1, then lib\Arc.ps1 (Lazarette / ARC 5).
      Pass 2 (last resort, ARC 3/4 only): pm.ps1.
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
    foreach ($full in $folders) {
        # ARC 3/4 only (not pm.bat / launch-arc.bat). ARC 5 folders were already matched above.
        $entry = Join-Path $full 'pm.ps1'
        if (Test-Path -LiteralPath $entry -PathType Leaf) {
            return [pscustomobject]@{ Root = $full; Entry = $entry; Kind = 'pm' }
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
           [bool](Get-Command Get-PmStarkApiKey -ErrorAction SilentlyContinue) -or
           [bool](Get-Command Get-LiveVault -ErrorAction SilentlyContinue) -or
           [bool](Get-Command Ensure-VaultUnlocked -ErrorAction SilentlyContinue)
}

function Import-PacketRatLazaretteSession {
    <#
    .SYNOPSIS
      Load the Lazarette engine once (lib\Lazarette.ps1 or lib\Arc.ps1; pm.ps1 only for ARC 3/4).
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
        foreach ($entry in @((Join-Path $libDir 'Lazarette.ps1'), (Join-Path $libDir 'Arc.ps1'), (Join-Path $LazaretteRoot 'pm.ps1'))) {
            if (Test-Path -LiteralPath $entry -PathType Leaf) {
                $found = [pscustomobject]@{ Root = $LazaretteRoot; Entry = $entry; Kind = $(if ((Split-Path $entry -Leaf) -eq 'pm.ps1') { 'pm' } else { 'engine' }) }
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
        # Do not try a second load if anything partially loaded (e.g. the ARC 5 pm.ps1 stub threw).
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
      Lazarette / ARC 5: if the vault is locked, unlock it in this console with
      Unlock-LazaretteVaultInteractive (or Unlock-ArcVaultInteractive). Returns $true when open.
      Unlocking is interactive by design; nothing is unlocked silently.
    #>
    [CmdletBinding()]
    param()
    $test = Get-PacketRatFirstCommand @('Test-LazaretteVaultUnlocked', 'Test-ArcVaultUnlocked')
    if ($test -and (& $test)) { return $true }
    $unlock = Get-PacketRatFirstCommand @('Unlock-LazaretteVaultInteractive', 'Unlock-ArcVaultInteractive')
    if (-not $unlock) { return [bool]($null -eq $test) }   # no lock concept (ARC 3/4 helpers)
    Write-Host '[*] Lazarette is locked. Unlock it in this console window to continue.' -ForegroundColor Yellow
    return [bool](& $unlock)
}

function Resolve-PacketRatLazaretteServiceName {
    <#
    .SYNOPSIS
      Resolve vault lookup names. Canonical hard-coded fallbacks only.
      Aliases (advana, databricks) are for matchers only, not as primary ServiceName.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GenAi', 'Grok')]
        [string]$Profile
    )

    if ($Profile -eq 'GenAi') {
        # PacketRat name first, then the former MailHawk name, then Halyard's shared names
        # (HALYARD_LAZARETTE_ITEM_*, then its former CASCADE_ARC_ITEM_* names, which Halyard still reads).
        $keys = @(
            'PACKETRAT_LAZARETTE_ITEM_GenAi',
            'MAILHAWK_ARC_ITEM_GenAi',
            'HALYARD_LAZARETTE_ITEM_GenAi',
            'HALYARD_LAZARETTE_ITEM_Llm',
            'CASCADE_ARC_ITEM_GenAi',
            'CASCADE_ARC_ITEM_Llm'
        )
        foreach ($k in $keys) {
            $v = [Environment]::GetEnvironmentVariable($k)
            if (-not [string]::IsNullOrWhiteSpace($v)) { return $v.Trim() }
        }
        return 'genapi'   # canonical
    }

    $keys = @(
        'PACKETRAT_LAZARETTE_ITEM_Grok',
        'MAILHAWK_ARC_ITEM_Grok',
        'HALYARD_LAZARETTE_ITEM_Grok',
        'CASCADE_ARC_ITEM_Grok'
    )
    foreach ($k in $keys) {
        $v = [Environment]::GetEnvironmentVariable($k)
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v.Trim() }
    }
    return 'advana-api'   # canonical
}

function Get-PacketRatLazaretteSecretByName {
    <#
    .SYNOPSIS
      Resolve a vault secret by Lazarette item (service) name. Never prints secret values.
    .NOTES
      Primary lookup uses exact ServiceName (canonical: genapi, advana-api).
      Matcher aliases for Grok path only: advana, databricks (vault row filter only).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServiceName
    )

    if ([string]::IsNullOrWhiteSpace($ServiceName)) { return $null }

    # 1) Lazarette / ARC 5: Get-LazaretteSecret if defined, else Get-ArcSecret (exactly one match or it throws)
    $get = Get-PacketRatFirstCommand @('Get-LazaretteSecret', 'Get-ArcSecret')
    if ($get) {
        if (-not (Assert-PacketRatLazaretteUnlocked)) {
            Write-Host '[!] Lazarette stayed locked; no managed token read.' -ForegroundColor Yellow
            return $null
        }
        $names = @($ServiceName)
        # Matcher aliases only when the primary name is the Grok canonical item
        if ($ServiceName -eq 'advana-api') {
            $list = Get-PacketRatFirstCommand @('Get-LazaretteItemNames', 'Get-ArcItemNames')
            if ($list) {
                try {
                    $names += @(& $list | ForEach-Object { [string]$_.Service } |
                        Where-Object { $_ -and $_ -ne $ServiceName -and ($_ -eq 'advana' -or $_ -eq 'databricks' -or $_ -like '*advana*') } |
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

    # 2) ARC 3/4 pm.ps1 helper lookup (canonical or env-overridden name)
    if (Get-Command Get-PmStarkApiKey -ErrorAction SilentlyContinue) {
        try {
            $v = Get-PmStarkApiKey -ServiceName $ServiceName -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace([string]$v)) { return [string]$v }
        } catch {}
    }

    # 3) Vault row match - exact Service/Name first
    if (Get-Command Get-LiveVault -ErrorAction SilentlyContinue) {
        try {
            $vault = Get-LiveVault
            if ($vault) {
                $row = $vault | Where-Object {
                    $_.Service -eq $ServiceName -or $_.Name -eq $ServiceName
                } | Select-Object -First 1

                # Matcher aliases only when primary name is the Grok canonical item
                if (-not $row -and $ServiceName -eq 'advana-api') {
                    $row = $vault | Where-Object {
                        $s = [string]$_.Service
                        $n = [string]$_.Name
                        $s -eq 'advana' -or $n -eq 'advana' -or
                        $s -eq 'databricks' -or $n -eq 'databricks' -or
                        $s -like '*advana*' -or $n -like '*advana*'
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
