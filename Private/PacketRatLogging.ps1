# PacketRat - file logging
#requires -Version 5.1

function Get-PacketRatLogDir {
    param([string]$Root)
    if (-not $Root) {
        $Root = $PSScriptRoot
        if ((Split-Path $Root -Leaf) -eq 'Private') {
            $Root = Split-Path $Root -Parent
        }
    }
    $dir = Join-Path $Root 'Logs'
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Write-PacketRatLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','DEBUG')]
        [string]$Level = 'INFO',
        [string]$Root
    )
    try {
        $dir = Get-PacketRatLogDir -Root $Root
        $path = Join-Path $dir 'packetrat.log'
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::AppendAllText($path, $line + [Environment]::NewLine, $utf8NoBom)

        switch ($Level) {
            'ERROR' { Write-Host $line -ForegroundColor Red }
            'WARN'  { Write-Host $line -ForegroundColor Yellow }
            'DEBUG' { Write-Verbose $line }
            default { Write-Host $line -ForegroundColor DarkGray }
        }
    } catch {
        Write-Host "LOG-FAIL: $Message" -ForegroundColor DarkYellow
    }
}

function Write-PacketRatError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ErrorRecord,
        [string]$Context = '',
        [string]$Root
    )
    try {
        $dir = Get-PacketRatLogDir -Root $Root
        $path = Join-Path $dir 'packetrat-error.log'
        $msg = ''
        $type = ''
        $stack = ''
        $pos = ''
        try {
            if ($null -ne $ErrorRecord -and $null -ne $ErrorRecord.Exception) {
                $msg = [string]$ErrorRecord.Exception.Message
                $type = [string]$ErrorRecord.Exception.GetType().FullName
            } elseif ($null -ne $ErrorRecord) {
                $msg = [string]$ErrorRecord
            }
        } catch { $msg = 'unknown' }
        try { if ($null -ne $ErrorRecord) { $stack = [string]$ErrorRecord.ScriptStackTrace } } catch {}
        try { if ($null -ne $ErrorRecord -and $null -ne $ErrorRecord.InvocationInfo) { $pos = [string]$ErrorRecord.InvocationInfo.PositionMessage } } catch {}

        $block = @"
================================================================================
TIME     : $(Get-Date -Format 'o')
CONTEXT  : $Context
TYPE     : $type
MESSAGE  : $msg
POSITION :
$pos
STACK:
$stack
================================================================================

"@
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::AppendAllText($path, $block, $utf8NoBom)
        Write-PacketRatLog -Level ERROR -Message ("{0}: {1}" -f $Context, $msg) -Root $Root
    } catch {
        Write-Host "ERROR-LOG-FAIL: $($ErrorRecord.Exception.Message)" -ForegroundColor Red
    }
}

function Initialize-PacketRatLegacyEnvironment {
    <#
    .SYNOPSIS
      Rename compatibility (MailHawk -> PacketRat). For each setting, PACKETRAT_* is read first;
      when it is unset and the former MAILHAWK_* name is set, the old value is copied into the
      new name for this process only. The old variables are never removed or changed.
    #>
    [CmdletBinding()]
    param()
    foreach ($suffix in @('LLM_PROFILE', 'PROVIDER', 'USER_EMAIL', 'SAVE_RAW_AI', 'MAX_EMAILS', 'BODY_PREVIEW_CHARS', 'AUTO_STOP')) {
        $new = [Environment]::GetEnvironmentVariable('PACKETRAT_' + $suffix)
        if (-not [string]::IsNullOrWhiteSpace($new)) { continue }
        $old = [Environment]::GetEnvironmentVariable('MAILHAWK_' + $suffix)
        if (-not [string]::IsNullOrWhiteSpace($old)) {
            [Environment]::SetEnvironmentVariable('PACKETRAT_' + $suffix, $old, 'Process')
        }
    }
}
