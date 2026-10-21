# MailHawk - ARC bridge (integrator contract)
# - Discover ARC via ARC_PATH or sibling Projects\arc
# - Load pm.ps1 once only; never re-dot-source after unlock
# - Canonical LLM service names: genapi, advana-api
# - Do not use pm.bat / launch-arc.bat
#requires -Version 5.1

# Session flag: pm.ps1 loaded at most once per process
$script:MailHawkArcSessionState = @{
    Loaded = $false
    Root   = $null
}

function Find-MailHawkArcRoot {
    [CmdletBinding()]
    param()
    $candidates = New-Object System.Collections.Generic.List[string]

    # 1) Env overrides (prefer ARC_PATH)
    foreach ($e in @($env:ARC_PATH, $env:ARC_ROOT, $env:ARC_HOME)) {
        if ($e) { [void]$candidates.Add($e.Trim().Trim('"').Trim("'")) }
    }

    # 2) Config\mailhawk.env ARC_PATH=
    $repo = $null
    try { $repo = $PSScriptRoot } catch {}
    if ($repo) {
        $root = Split-Path $repo -Parent   # MailHawk\
        $envFile = Join-Path $root 'Config\mailhawk.env'
        if (Test-Path -LiteralPath $envFile) {
            Get-Content -LiteralPath $envFile -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_ -match '^\s*ARC_PATH\s*=\s*(.+)$') {
                    [void]$candidates.Add($Matches[1].Trim().Trim('"').Trim("'"))
                }
            }
        }
        # 3) Sibling: Projects\MailHawk + Projects\arc
        [void]$candidates.Add((Join-Path (Split-Path $root -Parent) 'arc'))
    }

    if ($env:USERPROFILE) {
        [void]$candidates.Add((Join-Path $env:USERPROFILE 'Projects\arc'))
    }

    foreach ($c in $candidates) {
        if (-not $c) { continue }
        try { $full = [IO.Path]::GetFullPath($c) } catch { continue }
        # Integrators use pm.ps1 only (not pm.bat / launch-arc.bat)
        if (Test-Path -LiteralPath (Join-Path $full 'pm.ps1')) { return $full }
    }
    return $null
}

function Test-MailHawkArcHelpersAvailable {
    return [bool](Get-Command Get-PmStarkApiKey -ErrorAction SilentlyContinue) -or
           [bool](Get-Command Get-LiveVault -ErrorAction SilentlyContinue) -or
           [bool](Get-Command Ensure-VaultUnlocked -ErrorAction SilentlyContinue)
}

function Import-MailHawkArcSession {
    <#
    .SYNOPSIS
      Load ARC pm.ps1 once. Safe to call repeatedly; will not re-dot-source after unlock.
    #>
    [CmdletBinding()]
    param([string]$ArcRoot, [switch]$Quiet)

    # Already have helpers (e.g. user session already unlocked ARC) — do not re-source
    if (Test-MailHawkArcHelpersAvailable) {
        $script:MailHawkArcSessionState.Loaded = $true
        if (-not $Quiet) { Write-Host '[*] ARC helpers already available' -ForegroundColor DarkGray }
        return $true
    }

    # We already attempted load this process — do not re-dot-source
    if ($script:MailHawkArcSessionState.Loaded) {
        return (Test-MailHawkArcHelpersAvailable)
    }

    if (-not $ArcRoot) { $ArcRoot = Find-MailHawkArcRoot }
    if (-not $ArcRoot) {
        if (-not $Quiet) {
            Write-Host '[!] ARC not found (set ARC_PATH or place Projects\arc next to MailHawk)' -ForegroundColor DarkGray
        }
        return $false
    }

    $pm = Join-Path $ArcRoot 'pm.ps1'
    if (-not (Test-Path -LiteralPath $pm)) {
        if (-not $Quiet) { Write-Host "[!] pm.ps1 missing under $ArcRoot" -ForegroundColor Yellow }
        return $false
    }

    if (-not $Quiet) {
        Write-Host "[*] Loading ARC from $ArcRoot (pm.ps1 once)" -ForegroundColor Cyan
    }

    # Mark loaded BEFORE sourcing so concurrent/re-entrant calls do not double-source
    $script:MailHawkArcSessionState.Loaded = $true
    $script:MailHawkArcSessionState.Root = $ArcRoot

    try {
        $existing = Get-Module -Name MailHawkArc -ErrorAction SilentlyContinue
        if (-not $existing) {
            $mailHawkArc = New-Module -Name MailHawkArc -ScriptBlock {
                param([string]$PmPath)
                $ErrorActionPreference = 'Continue'
                . $PmPath
                Export-ModuleMember -Function * -Alias * -ErrorAction SilentlyContinue
            } -ArgumentList $pm
            Import-Module -ModuleInfo $mailHawkArc -Global -Force -WarningAction SilentlyContinue
        }
    } catch {
        # Do not fall back to a second . $pm if anything partially loaded.
        # Contract: never re-dot-source after unlock / after first load attempt.
        if (-not $Quiet) {
            Write-Host "[x] ARC module load failed: $($_.Exception.Message)" -ForegroundColor Red
        }
        return (Test-MailHawkArcHelpersAvailable)
    }

    return (Test-MailHawkArcHelpersAvailable)
}

function Resolve-MailHawkArcServiceName {
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
        $keys = @(
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
        'MAILHAWK_ARC_ITEM_Grok',
        'CASCADE_ARC_ITEM_Grok'
    )
    foreach ($k in $keys) {
        $v = [Environment]::GetEnvironmentVariable($k)
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v.Trim() }
    }
    return 'advana-api'   # canonical
}

function Get-MailHawkArcSecretByName {
    <#
    .SYNOPSIS
      Resolve a vault secret by ARC service name. Never prints secret values.
    .NOTES
      Primary lookup uses exact ServiceName (canonical: genapi, advana-api).
      Matcher aliases for Grok path only: advana, databricks (vault row filter only).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServiceName
    )

    if ([string]::IsNullOrWhiteSpace($ServiceName)) { return $null }

    # 1) Exact helper lookup (canonical or env-overridden name)
    if (Get-Command Get-PmStarkApiKey -ErrorAction SilentlyContinue) {
        try {
            $v = Get-PmStarkApiKey -ServiceName $ServiceName -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace([string]$v)) { return [string]$v }
        } catch {}
    }

    # 2) Vault row match — exact Service/Name first
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
