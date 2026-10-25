# PacketRat - Lazarette bridge (integrator contract; Lazarette was formerly ARC)
# - Discover Lazarette: LAZARETTE_PATH/ROOT/HOME, then ARC_PATH/ROOT/HOME, then config, then
#   %LOCALAPPDATA%\Lazarette, %LOCALAPPDATA%\ARC, then sibling/Projects folders (lazarette before arc)
# - Load pm.ps1 once only; never re-dot-source after unlock
# - Secrets: Get-LazaretteSecret if present, else Get-ArcSecret, then the pm.ps1 helpers
# - Canonical LLM vault item names (unchanged): genapi, advana-api
# - Do not use pm.bat / launch-arc.bat
#requires -Version 5.1

# Session flag: pm.ps1 loaded at most once per process
$script:PacketRatLazaretteSessionState = @{
    Loaded = $false
    Root   = $null
}

function Find-PacketRatLazaretteRoot {
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

    foreach ($c in $candidates) {
        if (-not $c) { continue }
        try { $full = [IO.Path]::GetFullPath($c) } catch { continue }
        # Integrators use pm.ps1 only (not pm.bat / launch-arc.bat)
        if (Test-Path -LiteralPath (Join-Path $full 'pm.ps1')) { return $full }
    }
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
      Load Lazarette pm.ps1 once. Safe to call repeatedly; will not re-dot-source after unlock.
    #>
    [CmdletBinding()]
    param([Alias('ArcRoot')][string]$LazaretteRoot, [switch]$Quiet)

    # Already have helpers (e.g. user session already unlocked Lazarette) — do not re-source
    if (Test-PacketRatLazaretteHelpersAvailable) {
        $script:PacketRatLazaretteSessionState.Loaded = $true
        if (-not $Quiet) { Write-Host '[*] Lazarette helpers already available' -ForegroundColor DarkGray }
        return $true
    }

    # We already attempted load this process — do not re-dot-source
    if ($script:PacketRatLazaretteSessionState.Loaded) {
        return (Test-PacketRatLazaretteHelpersAvailable)
    }

    if (-not $LazaretteRoot) { $LazaretteRoot = Find-PacketRatLazaretteRoot }
    if (-not $LazaretteRoot) {
        if (-not $Quiet) {
            Write-Host '[!] Lazarette not found (set LAZARETTE_PATH, or place a Lazarette clone next to PacketRat)' -ForegroundColor DarkGray
        }
        return $false
    }

    $pm = Join-Path $LazaretteRoot 'pm.ps1'
    if (-not (Test-Path -LiteralPath $pm)) {
        if (-not $Quiet) { Write-Host "[!] pm.ps1 missing under $LazaretteRoot" -ForegroundColor Yellow }
        return $false
    }

    if (-not $Quiet) {
        Write-Host "[*] Loading Lazarette from $LazaretteRoot (pm.ps1 once)" -ForegroundColor Cyan
    }

    # Mark loaded BEFORE sourcing so concurrent/re-entrant calls do not double-source
    $script:PacketRatLazaretteSessionState.Loaded = $true
    $script:PacketRatLazaretteSessionState.Root = $LazaretteRoot

    try {
        $existing = Get-Module -Name PacketRatLazarette -ErrorAction SilentlyContinue
        if (-not $existing) {
            $packetRatLazarette = New-Module -Name PacketRatLazarette -ScriptBlock {
                param([string]$PmPath)
                $ErrorActionPreference = 'Continue'
                . $PmPath
                Export-ModuleMember -Function * -Alias * -ErrorAction SilentlyContinue
            } -ArgumentList $pm
            Import-Module -ModuleInfo $packetRatLazarette -Global -Force -WarningAction SilentlyContinue
        }
    } catch {
        # Do not fall back to a second . $pm if anything partially loaded.
        # Contract: never re-dot-source after unlock / after first load attempt.
        if (-not $Quiet) {
            Write-Host "[x] Lazarette module load failed: $($_.Exception.Message)" -ForegroundColor Red
        }
        return (Test-PacketRatLazaretteHelpersAvailable)
    }

    return (Test-PacketRatLazaretteHelpersAvailable)
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
        # New PacketRat name first; former MailHawk and Cascade (now Halyard) names stay as fallbacks.
        $keys = @(
            'PACKETRAT_LAZARETTE_ITEM_GenAi',
            'MAILHAWK_ARC_ITEM_GenAi',
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

    # 1) Documented Lazarette command first, then the former ARC name (kept by Lazarette as an alias)
    foreach ($cmd in @('Get-LazaretteSecret', 'Get-ArcSecret')) {
        if (Get-Command $cmd -ErrorAction SilentlyContinue) {
            try {
                $v = & $cmd -Service $ServiceName -ErrorAction Stop
                if (-not [string]::IsNullOrWhiteSpace([string]$v)) { return [string]$v }
            } catch {}
            break   # only one of the two is needed; Get-ArcSecret is an alias when both exist
        }
    }

    # 2) pm.ps1 helper lookup (canonical or env-overridden name)
    if (Get-Command Get-PmStarkApiKey -ErrorAction SilentlyContinue) {
        try {
            $v = Get-PmStarkApiKey -ServiceName $ServiceName -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace([string]$v)) { return [string]$v }
        } catch {}
    }

    # 3) Vault row match — exact Service/Name first
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
