# MailHawk - file logging
#requires -Version 5.1

function Get-MailHawkLogDir {
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

function Write-MailHawkLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','DEBUG')]
        [string]$Level = 'INFO',
        [string]$Root
    )
    try {
        $dir = Get-MailHawkLogDir -Root $Root
        $path = Join-Path $dir 'mailhawk.log'
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

function Write-MailHawkError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ErrorRecord,
        [string]$Context = '',
        [string]$Root
    )
    try {
        $dir = Get-MailHawkLogDir -Root $Root
        $path = Join-Path $dir 'mailhawk-error.log'
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
        Write-MailHawkLog -Level ERROR -Message ("{0}: {1}" -f $Context, $msg) -Root $Root
    } catch {
        Write-Host "ERROR-LOG-FAIL: $($ErrorRecord.Exception.Message)" -ForegroundColor Red
    }
}
