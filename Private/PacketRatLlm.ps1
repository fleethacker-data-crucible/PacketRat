# PacketRat - AI client. Every AI call goes to Fairlead (the Fleet model router) and nowhere else.
#requires -Version 5.1

# Fairlead answers on this PC at http://127.0.0.1:8776 and owns the endpoints, models and provider keys.
#   PACKETRAT_FAIRLEAD_URL      another loopback address for Fairlead (a different port); anything not on this PC is refused.
#   PACKETRAT_FAIRLEAD_MODEL    the route name to ask for (default 'auto').
#   PACKETRAT_FAIRLEAD_PRIVACY  'local' adds X-Fairlead-Privacy: local so prompts stay on local models.
# The key PacketRat sends is the Windows Credential Manager generic credential Fairlead/PacketRat when that is
# installed (Fairlead writes it from its Clients page). Otherwise it is the first line of
# %LOCALAPPDATA%\Fairlead\local-token, the token Fairlead creates for this Windows account (FAIRLEAD_LOCAL_TOKEN=off
# skips that file; FAIRLEAD_LOCAL_TOKEN_FILE moves it). The key is placed on a request only after
# GET /__fleethacker/id on that loopback address names fairlead and the reported process holds the port.
# There is no environment-variable or vault fallback. The key is never printed or logged.
$script:PacketRatFairleadDefaults = @{
    Url     = 'http://127.0.0.1:8776/v1/chat/completions'
    Model   = 'auto'
    AppName = 'PacketRat'
}

function Get-PacketRatFairleadTarget { return ('Fairlead/' + $script:PacketRatFairleadDefaults.AppName) }

function Test-PacketRatLoopbackUrl {
    <#
    .SYNOPSIS
      True when the URL points at this PC (127.0.0.0/8, ::1 or localhost).
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Url)
    $u = $null
    if ([string]::IsNullOrWhiteSpace($Url) -or -not [Uri]::TryCreate($Url.Trim(), [UriKind]::Absolute, [ref]$u)) { return $false }
    return [bool]$u.IsLoopback
}

function Get-PacketRatFairleadConfig {
    <#
    .SYNOPSIS
      @{ Url; Model; Privacy } for the Fairlead call. Throws when PACKETRAT_FAIRLEAD_URL is not an address on this PC.
    #>
    [CmdletBinding()]
    param()
    $url = [Environment]::GetEnvironmentVariable('PACKETRAT_FAIRLEAD_URL')
    if ([string]::IsNullOrWhiteSpace($url)) { $url = $script:PacketRatFairleadDefaults.Url }
    $url = $url.Trim().TrimEnd('/')
    if (-not (Test-PacketRatLoopbackUrl -Url $url)) {
        throw 'PACKETRAT_FAIRLEAD_URL must be an address on this PC (127.0.0.1 or localhost). PacketRat only talks to Fairlead on this computer.'
    }
    $model = [Environment]::GetEnvironmentVariable('PACKETRAT_FAIRLEAD_MODEL')
    if ([string]::IsNullOrWhiteSpace($model)) { $model = $script:PacketRatFairleadDefaults.Model }
    $privacy = ([string][Environment]::GetEnvironmentVariable('PACKETRAT_FAIRLEAD_PRIVACY')).Trim()
    return [pscustomobject]@{ Url = $url; Model = $model.Trim(); Privacy = $(if ($privacy -ieq 'local') { 'local' } else { '' }) }
}

# --- The Fairlead key (Windows Credential Manager) ----------------------------------------------------------------
if (-not ('PacketRatCredReader' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PacketRatCredReader
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL
    {
        public int Flags;
        public int Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public int Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }
    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredRead(string target, int type, int flags, out IntPtr credential);
    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr buffer);

    public static byte[] ReadBlob(string target)
    {
        IntPtr p;
        if (!CredRead(target, 1, 0, out p)) return null;
        try
        {
            CREDENTIAL c = (CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL));
            byte[] blob = new byte[c.CredentialBlobSize];
            if (c.CredentialBlobSize > 0) Marshal.Copy(c.CredentialBlob, blob, 0, c.CredentialBlobSize);
            return blob;
        }
        finally { CredFree(p); }
    }
}
'@
}

function ConvertFrom-PacketRatCredentialBlob {
    # Fairlead stores the key as UTF-16 text; UTF-8 text is accepted as well. Returns '' when the blob holds no printable text.
    param([byte[]]$Blob)
    if ($null -eq $Blob -or $Blob.Length -eq 0) { return '' }
    foreach ($enc in @([Text.Encoding]::Unicode, (New-Object System.Text.UTF8Encoding $false))) {
        $t = $enc.GetString($Blob).Trim([char]0).Trim()
        if ($t.Length -gt 0 -and $t -notmatch '[^\x21-\x7E]') { return $t }
    }
    return ''
}

# Replaceable so tests never read the real Credential Manager: { param($Target) -> key text or $null }.
$script:PacketRatCredentialReader = {
    param([string]$Target)
    $blob = [PacketRatCredReader]::ReadBlob($Target)
    return (ConvertFrom-PacketRatCredentialBlob -Blob $blob)
}

function Set-PacketRatCredentialReader {
    param([scriptblock]$Reader)
    if ($Reader) { $script:PacketRatCredentialReader = $Reader }
}

function Get-PacketRatFairleadLocalTokenPath {
    <#
    .SYNOPSIS
      The local-token file, or $null when FAIRLEAD_LOCAL_TOKEN=off or this account has no LocalAppData.
    #>
    $off = [Environment]::GetEnvironmentVariable('FAIRLEAD_LOCAL_TOKEN')
    if ($off -and $off.Trim() -match '^(?i:off|0|false|no)$') { return $null }
    $moved = [Environment]::GetEnvironmentVariable('FAIRLEAD_LOCAL_TOKEN_FILE')
    if ($moved -and $moved.Trim()) { return $moved.Trim() }
    $base = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    if ([string]::IsNullOrWhiteSpace($base)) {
        try { $base = [Environment]::GetFolderPath('LocalApplicationData') } catch { $base = '' }
    }
    if ([string]::IsNullOrWhiteSpace($base)) { return $null }
    return (Join-Path (Join-Path $base 'Fairlead') 'local-token')
}

function Read-PacketRatLocalTokenFile {
    <#
    .SYNOPSIS
      The first line of a local-token file, or ''. Refuses a file over 4 KB, a blank line, or a line that is not
      printable ASCII. Never logs the text.
    #>
    param([string]$Path)
    try {
        if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.File]::Exists($Path)) { return '' }
        if ((New-Object IO.FileInfo $Path).Length -gt 4096) { return '' }
        $text = [IO.File]::ReadAllText($Path)
        $parts = $text -split "`r?`n", 2
        $line = $parts[0]
        if ($null -eq $line) { return '' }
        $line = $line.Trim().TrimStart([char]0xFEFF)
        if ($line.Length -eq 0 -or $line -match '[^\x21-\x7E]') { return '' }
        return $line
    } catch { return '' }
}

function Resolve-PacketRatFairleadKey {
    <#
    .SYNOPSIS
      @{ Key; Source } where Source is credential, local-token or ''. Credential Manager wins. Never logs the key.
    #>
    $key = ''
    try { $key = [string](& $script:PacketRatCredentialReader (Get-PacketRatFairleadTarget)) } catch { $key = '' }
    if ($null -eq $key) { $key = '' }
    $key = $key.Trim()
    if (-not [string]::IsNullOrWhiteSpace($key)) { return @{ Key = $key; Source = 'credential' } }
    $token = Read-PacketRatLocalTokenFile -Path (Get-PacketRatFairleadLocalTokenPath)
    if (-not [string]::IsNullOrWhiteSpace($token)) { return @{ Key = $token; Source = 'local-token' } }
    return @{ Key = ''; Source = '' }
}

function Get-PacketRatFairleadKey {
    <#
    .SYNOPSIS
      The Fairlead client key for PacketRat, or a clear error. Never printed or logged.
    #>
    [CmdletBinding()]
    param()
    $found = Resolve-PacketRatFairleadKey
    if ([string]::IsNullOrWhiteSpace([string]$found.Key)) {
        throw ('Open Fairlead and install a key for {0}.' -f $script:PacketRatFairleadDefaults.AppName)
    }
    return [string]$found.Key
}

function Get-PacketRatCredentialStatus {
    <#
    .SYNOPSIS
      Where PacketRat sends AI calls and whether a Fairlead key is available. Never returns the key.
    #>
    [CmdletBinding()]
    param()
    $cfg = Get-PacketRatFairleadConfig
    $found = Resolve-PacketRatFairleadKey
    $installed = -not [string]::IsNullOrWhiteSpace([string]$found.Key)
    $message = $(if ($found.Source -eq 'local-token') {
            'Fairlead local token found for this Windows account.'
        } elseif ($installed) {
            'Fairlead key found for PacketRat.'
        } else {
            ('Open Fairlead and install a key for {0}.' -f $script:PacketRatFairleadDefaults.AppName)
        })
    return @{
        router       = 'Fairlead'
        url          = $cfg.Url
        model        = $cfg.Model
        privacy      = $cfg.Privacy
        target       = (Get-PacketRatFairleadTarget)
        keyInstalled = $installed
        keySource    = [string]$found.Source
        message      = $message
    }
}

function ConvertTo-PacketRatLlmText {
    <#
     .SYNOPSIS
       Extract text from strings, typed content block arrays, or nested provider content.
       Never cast an object or an array to [string] (System.Object[]).
    #>
    [CmdletBinding()]
    param($Value,[int]$Depth=0)
    if($null -eq $Value -or $Depth -gt 6){return ''}
    if($Value -is [string]){return [string]$Value}
    if($Value -is [System.Collections.IEnumerable] -and $Value -isnot [System.Collections.IDictionary] -and $Value -isnot [string]){
        $pieces=New-Object System.Collections.Generic.List[string]
        foreach($piece in $Value){
            $t=ConvertTo-PacketRatLlmText -Value $piece -Depth ($Depth+1)
            if(-not [string]::IsNullOrWhiteSpace($t)){[void]$pieces.Add($t)}
        }
        return ($pieces -join "`n")
    }
    foreach($prop in @('text','content','parts','output_text','message')){
        $part=$null
        if($Value -is [System.Collections.IDictionary]){
            if($Value.Contains($prop)){$part=$Value[$prop]}
        }elseif($Value.PSObject.Properties[$prop]){
            $part=$Value.$prop
        }
        if($null -eq $part){continue}
        $t=ConvertTo-PacketRatLlmText -Value $part -Depth ($Depth+1)
        if(-not [string]::IsNullOrWhiteSpace($t)){return $t}
    }
    return ''
}

# --- Streaming and cancel ---------------------------------------------------------------------------------------
# Streaming is opt-in: -Stream on Invoke-PacketRatChat, or PACKETRAT_LLM_STREAM=1 for every call. It reads the
# endpoint's server-sent events (OpenAI "stream": true) so a long generation can be cancelled between chunks.
# Cancel is a flag file (Logs\cancel.request), so a second console can cancel a run in this process:
#   PacketRat-CLI.bat inbox cancel
# The browser server handles one request at a time, so the browser has no cancel button yet.

function Get-PacketRatCancelFlagPath {
    return (Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'Logs') 'cancel.request')
}

function Request-PacketRatCancel {
    $path = Get-PacketRatCancelFlagPath
    $dir = Split-Path $path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($path, (Get-Date).ToString('o'))
    return $path
}

function Clear-PacketRatCancel {
    Remove-Item -LiteralPath (Get-PacketRatCancelFlagPath) -Force -ErrorAction SilentlyContinue
}

function Test-PacketRatCancelRequested {
    return (Test-Path -LiteralPath (Get-PacketRatCancelFlagPath))
}

function Test-PacketRatStreamingEnabled {
    return ([string][Environment]::GetEnvironmentVariable('PACKETRAT_LLM_STREAM') -match '^(?i:1|true|yes|on)$')
}

function ConvertFrom-PacketRatSseData {
    <#
    .SYNOPSIS
      One "data:" payload of an OpenAI-style event stream -> @{ Done; Text }. Anything that is not a text delta is ignored;
      an {"error": ...} event throws.
    #>
    param([AllowEmptyString()][string]$Data)
    $d = $Data.Trim()
    if (-not $d) { return @{ Done = $false; Text = '' } }
    if ($d -eq '[DONE]') { return @{ Done = $true; Text = '' } }
    try { $evt = $d | ConvertFrom-Json } catch { return @{ Done = $false; Text = '' } }
    if ($evt.PSObject.Properties['error'] -and $evt.error) {
        $m = if ($evt.error.PSObject.Properties['message']) { [string]$evt.error.message } else { [string]$evt.error }
        throw ('Fairlead reported an error while streaming: ' + $m)
    }
    $text = ''
    if ($evt.PSObject.Properties['choices'] -and $evt.choices -and @($evt.choices).Count -gt 0) {
        $c = @($evt.choices)[0]
        if ($c.PSObject.Properties['delta'] -and $c.delta -and $c.delta.PSObject.Properties['content']) {
            $text = ConvertTo-PacketRatLlmText -Value $c.delta.content
        } elseif ($c.PSObject.Properties['text']) {
            $text = ConvertTo-PacketRatLlmText -Value $c.text
        }
    }
    return @{ Done = $false; Text = [string]$text }
}

function Read-PacketRatSseStream {
    <#
    .SYNOPSIS
      Read an event stream to its end ([DONE] or close) and return the joined text. Between chunks (and at most every
      read-timeout) it calls -ShouldCancel; when that returns true the run stops with OperationCanceledException.
      -OnToken receives each text piece as it arrives.
    #>
    param(
        [Parameter(Mandatory)][IO.Stream]$Stream,
        [scriptblock]$OnToken,
        [scriptblock]$ShouldCancel,
        [int]$TimeoutSec = 180
    )
    $decoder = (New-Object System.Text.UTF8Encoding $false).GetDecoder()
    $bytes = New-Object byte[] 4096
    $chars = New-Object char[] 8192
    $pending = New-Object System.Text.StringBuilder
    $text = New-Object System.Text.StringBuilder
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    $done = $false
    while (-not $done) {
        if ($ShouldCancel -and (& $ShouldCancel)) { throw (New-Object System.OperationCanceledException 'Generation cancelled.') }
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Fairlead stopped sending data (timed out).' }
        $n = 0
        try {
            $n = $Stream.Read($bytes, 0, $bytes.Length)
        } catch [System.IO.IOException] {
            # Read timeout: nothing arrived in this slice. Loop to re-check cancel and the overall deadline.
            # Any other I/O failure (connection reset, closed stream) is a real error.
            $inner = $_.Exception.InnerException
            $timedOut = ($inner -is [Net.Sockets.SocketException] -and $inner.ErrorCode -eq 10060) -or ($_.Exception.Message -match '(?i)timed out|timeout')
            if (-not $timedOut) { throw }
            continue
        }
        if ($n -le 0) { break }
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
        $count = $decoder.GetChars($bytes, 0, $n, $chars, 0)
        [void]$pending.Append($chars, 0, $count)
        $buffer = $pending.ToString()
        $last = $buffer.LastIndexOf("`n")
        if ($last -lt 0) { continue }
        [void]$pending.Clear()
        [void]$pending.Append($buffer.Substring($last + 1))
        foreach ($line in $buffer.Substring(0, $last).Split("`n")) {
            $line = $line.TrimEnd("`r")
            if (-not $line.StartsWith('data:')) { continue }
            $evt = ConvertFrom-PacketRatSseData -Data $line.Substring(5)
            if ($evt.Done) { $done = $true; break }
            if ($evt.Text) {
                [void]$text.Append($evt.Text)
                if ($OnToken) { & $OnToken $evt.Text }
            }
        }
    }
    return $text.ToString()
}

function Wait-PacketRatTask {
    # Task.Wait throws an AggregateException when the task faulted; the caller reads task.IsFaulted instead.
    param($Task, [int]$Milliseconds)
    try { return $Task.Wait($Milliseconds) } catch { return $true }
}

function Invoke-PacketRatChatStream {
    <#
    .SYNOPSIS
      POST a chat request with "stream": true and return the joined text. HttpWebRequest is used because
      Invoke-RestMethod cannot hand back a half-read body. Polls -ShouldCancel while waiting for the first byte too.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][byte[]]$Body,
        [scriptblock]$OnToken,
        [scriptblock]$ShouldCancel,
        [int]$TimeoutSec = 180
    )
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.Method = 'POST'
    $req.ContentType = 'application/json; charset=utf-8'
    $req.Accept = 'text/event-stream'
    $req.ReadWriteTimeout = 500
    $req.ServicePoint.Expect100Continue = $false
    foreach ($k in $Headers.Keys) { if ($k -ne 'Accept') { $req.Headers[$k] = [string]$Headers[$k] } }
    $req.ContentLength = $Body.Length
    $out = $req.GetRequestStream()
    try { $out.Write($Body, 0, $Body.Length) } finally { $out.Close() }
    $task = $req.GetResponseAsync()
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    while (-not (Wait-PacketRatTask $task 250)) {
        if ($ShouldCancel -and (& $ShouldCancel)) { $req.Abort(); throw (New-Object System.OperationCanceledException 'Generation cancelled.') }
        if ([DateTime]::UtcNow -gt $deadline) { $req.Abort(); throw 'Fairlead did not answer (timed out).' }
    }
    if ($task.IsFaulted) {
        $err = $task.Exception.GetBaseException()
        $status = ''
        if ($err -is [System.Net.WebException] -and $err.Response) { $status = ' (HTTP ' + [int]$err.Response.StatusCode + ')' }
        throw ('Fairlead refused the request' + $status + ': ' + $err.Message)
    }
    $resp = $task.Result
    try {
        $stream = $resp.GetResponseStream()
        try {
            return (Read-PacketRatSseStream -Stream $stream -OnToken $OnToken -ShouldCancel $ShouldCancel -TimeoutSec $TimeoutSec)
        } catch {
            try { $req.Abort() } catch {}
            throw
        } finally { $stream.Close() }
    } finally { $resp.Close() }
}

# --- Who is on the port (the key is sent only after this passes) --------------------------------------------
# Same rule as edge-ops FleetPort Test-FleetServiceIdentity and Semaphore Test-SemAiIdentity: the address must
# answer /__fleethacker/id as fairlead, exactly one process above pid 4 must hold the port, and a reported path
# must be that process's executable or its powershell -File script. Never a substring match. Fail closed.

function ConvertTo-PacketRatAbsolutePath {
    param([string]$Path)
    if (-not $Path) { return $null }
    $p = $Path.Trim().Trim('"').Replace('/', '\')
    if ($p -notmatch '^(?:[A-Za-z]:\\|\\\\[^\\?.]+\\[^\\]+)') { return $null }
    if ($env:OS -eq 'Windows_NT') {
        try { $p = [IO.Path]::GetFullPath($p) } catch { return $null }
    } elseif ($p -match '\\\.{1,2}(\\|$)') {
        return $null
    }
    return $p.TrimEnd('\')
}

function Split-PacketRatCommandLine {
    # CommandLineToArgvW rules, as FleetPort Split-FleetCommandLine states them.
    param([string]$CommandLine)
    $out = New-Object System.Collections.Generic.List[string]
    if (-not $CommandLine) { return , $out.ToArray() }
    $sb = New-Object System.Text.StringBuilder
    $inQuote = $false; $have = $false; $i = 0; $n = $CommandLine.Length
    while ($i -lt $n) {
        $c = $CommandLine[$i]
        if ($c -eq '\') {
            $j = $i; while ($j -lt $n -and $CommandLine[$j] -eq '\') { $j++ }
            $count = $j - $i
            if ($j -lt $n -and $CommandLine[$j] -eq '"') {
                [void]$sb.Append('\', [int][Math]::Floor($count / 2))
                if ($count % 2 -eq 1) { [void]$sb.Append('"'); $i = $j + 1 } else { $i = $j }
            } else { [void]$sb.Append('\', $count); $i = $j }
            $have = $true; continue
        }
        if ($c -eq '"') {
            if ($inQuote -and ($i + 1) -lt $n -and $CommandLine[$i + 1] -eq '"') { [void]$sb.Append('"'); $i += 2; $have = $true; continue }
            $inQuote = -not $inQuote; $have = $true; $i++; continue
        }
        if (-not $inQuote -and ($c -eq ' ' -or $c -eq "`t")) {
            if ($have) { $out.Add($sb.ToString()); [void]$sb.Clear(); $have = $false }
            $i++; continue
        }
        [void]$sb.Append($c); $have = $true; $i++
    }
    if ($have) { $out.Add($sb.ToString()) }
    return , $out.ToArray()
}

function Get-PacketRatScriptFromCommandLine {
    param([string]$CommandLine)
    [string[]]$argv = Split-PacketRatCommandLine $CommandLine
    if ($null -eq $argv -or $argv.Count -lt 3) { return $null }
    $exeLeaf = ($argv[0] -split '[\\/]')[-1]
    if (@('powershell', 'powershell.exe', 'pwsh', 'pwsh.exe') -notcontains $exeLeaf.ToLowerInvariant()) { return $null }
    for ($k = 1; $k -lt $argv.Count - 1; $k++) {
        $a = $argv[$k].ToLowerInvariant()
        if ($a -eq '-file' -or $a -eq '-f' -or $a -eq '/file') { return $argv[$k + 1] }
        if ($a -match '^[-/](c|command|e|ec|encodedcommand|commandwithargs|cwa)$') { return $null }
        if ($a -match '^[-/](executionpolicy|ep|ex|windowstyle|w|version|v|inputformat|if|outputformat|of|psconsolefile|configurationname|workingdirectory|wd|settingsfile)$') { $k++; continue }
        if ($a -notmatch '^[-/]') { return $null }
    }
    return $null
}

function Test-PacketRatReportedPath {
    param([string]$Path, [string]$CommandLine, [string]$ExecutablePath)
    $want = ConvertTo-PacketRatAbsolutePath $Path
    if (-not $want) { return $false }
    $exe = ConvertTo-PacketRatAbsolutePath $ExecutablePath
    if ($exe -and [string]::Equals($exe, $want, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $scriptPath = ConvertTo-PacketRatAbsolutePath (Get-PacketRatScriptFromCommandLine $CommandLine)
    if ($scriptPath -and [string]::Equals($scriptPath, $want, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $false
}

function Get-PacketRatIdField {
    param($Id, [string]$Name)
    if ($null -eq $Id) { return $null }
    if ($Id -is [System.Collections.IDictionary]) {
        if ($Id.Contains($Name)) { return $Id[$Name] }
        return $null
    }
    $prop = $Id.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Get-PacketRatFairleadOwnPath {
    # When the id answer has no path: accept only Fairlead's own start script or a Fairlead executable, read from
    # the process, never from text the listener chose to omit.
    param($Info)
    if (-not $Info) { return '' }
    $cmd = ''; $exe = ''
    if ($Info -is [System.Collections.IDictionary]) {
        if ($Info.Contains('CommandLine')) { $cmd = [string]$Info['CommandLine'] }
        if ($Info.Contains('ExecutablePath')) { $exe = [string]$Info['ExecutablePath'] }
    } else {
        $cmd = [string](Get-PacketRatIdField $Info 'CommandLine')
        $exe = [string](Get-PacketRatIdField $Info 'ExecutablePath')
    }
    $scriptPath = ConvertTo-PacketRatAbsolutePath (Get-PacketRatScriptFromCommandLine $cmd)
    if ($scriptPath -and $scriptPath -match '(?i)\\scripts\\Start-Fairlead\.ps1\z') { return $scriptPath }
    $exePath = ConvertTo-PacketRatAbsolutePath $exe
    if ($exePath -and (($exePath -split '[\\/]')[-1]) -match '(?i)\Afairlead[\w.-]*\.exe\z') { return $exePath }
    return ''
}

function Get-PacketRatPortOwners {
    param([int]$Port)
    $owners = New-Object System.Collections.Generic.List[int]
    $have = $false
    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        $have = $true
        foreach ($c in @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)) {
            $owners.Add([int]$c.OwningProcess)
        }
    } else {
        $sys = [Environment]::SystemDirectory
        $netstat = $null
        if ($sys) {
            $candidate = Join-Path $sys 'netstat.exe'
            if (Test-Path -LiteralPath $candidate) { $netstat = $candidate }
        }
        if ($netstat) {
            $have = $true
            foreach ($line in @(& $netstat -ano -p TCP 2>$null)) {
                if ([string]$line -match '^\s*TCP\s+\S+:(\d+)\s+\S+\s+LISTENING\s+(\d+)\s*$' -and [int]$Matches[1] -eq $Port) {
                    $owners.Add([int]$Matches[2])
                }
            }
        }
    }
    if (-not $have) { return @() }
    return @($owners | Sort-Object -Unique)
}

function Get-PacketRatProcessInfo {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return $null }
    if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) { return $null }
    $proc = $null
    try { $proc = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = {0}" -f $ProcessId) -ErrorAction Stop } catch { return $null }
    if (-not $proc) { return $null }
    return @{ CommandLine = [string]$proc.CommandLine; ExecutablePath = [string]$proc.ExecutablePath }
}

function Get-PacketRatFairleadIdDocument {
    # GET /__fleethacker/id with no key and no redirect. Throws when the answer is missing or unusable.
    param([Uri]$Uri)
    if (-not $Uri -or -not $Uri.IsLoopback) { throw 'PacketRat only asks Fairlead to identify itself on this PC, so the Fairlead key was not sent.' }
    $idUrl = $Uri.GetLeftPart([UriPartial]::Authority) + '/__fleethacker/id'
    $req = [Net.HttpWebRequest]::Create($idUrl)
    $req.Method = 'GET'
    $req.Timeout = 3000
    $req.ReadWriteTimeout = 3000
    $req.Proxy = $null
    $req.AllowAutoRedirect = $false
    $req.Accept = 'application/json'
    $resp = $null
    $text = ''
    try {
        $resp = $req.GetResponse()
        $reader = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { if ($resp) { $resp.Close() } }
    if ([string]::IsNullOrEmpty($text) -or $text.Length -gt 4096) { throw 'Fairlead did not identify itself, so the Fairlead key was not sent.' }
    try { return ($text | ConvertFrom-Json) } catch { throw 'Fairlead did not identify itself, so the Fairlead key was not sent.' }
}

# Replaceable so tests never touch a real port: { param($Uri) -> id object }, { param($Port) -> pids }, { param($ProcessId) -> @{CommandLine;ExecutablePath} }.
$script:PacketRatFairleadIdReader = { param($Uri) Get-PacketRatFairleadIdDocument -Uri $Uri }
$script:PacketRatPortOwnerReader = { param($Port) Get-PacketRatPortOwners -Port $Port }
$script:PacketRatProcessInfoReader = { param($ProcessId) Get-PacketRatProcessInfo -ProcessId $ProcessId }

function Set-PacketRatFairleadReaders {
    param([scriptblock]$IdReader, [scriptblock]$PortOwners, [scriptblock]$ProcessInfo)
    if ($IdReader) { $script:PacketRatFairleadIdReader = $IdReader }
    if ($PortOwners) { $script:PacketRatPortOwnerReader = $PortOwners }
    if ($ProcessInfo) { $script:PacketRatProcessInfoReader = $ProcessInfo }
}

function Use-PacketRatFairleadTestIdentity {
    # A stand-in identity for tests that are not about the check. No network call.
    $script:PacketRatFairleadIdReader = { param($Uri) [pscustomobject]@{ tool = 'fairlead'; pid = 4242; path = 'C:\Fairlead\scripts\Start-Fairlead.ps1' } }
    $script:PacketRatPortOwnerReader = { param($Port) ,@(4242) }
    $script:PacketRatProcessInfoReader = { param($ProcessId) @{ CommandLine = 'powershell.exe -NoProfile -File C:\Fairlead\scripts\Start-Fairlead.ps1'; ExecutablePath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' } }
}

function Test-PacketRatFairleadIdentity {
    <#
    .SYNOPSIS
      Throw (and do not send the key) unless the address is Fairlead and that process holds the port.
    #>
    param([Parameter(Mandatory)][Uri]$Uri)
    $refused = 'Something other than Fairlead is answering on that address, so the Fairlead key was not sent.'
    $owners = @()
    try { $owners = @(& $script:PacketRatPortOwnerReader $Uri.Port) } catch {
        throw 'PacketRat could not see which program holds the AI address, so the Fairlead key was not sent.'
    }
    $ids = New-Object System.Collections.Generic.List[int]
    foreach ($owner in @($owners)) {
        if ($null -eq $owner -or [string]::IsNullOrWhiteSpace([string]$owner)) { continue }
        $n = 0
        if ([int]::TryParse([string]$owner, [ref]$n)) { $ids.Add($n) }
    }
    $unique = @($ids | Sort-Object -Unique)
    if ($unique.Count -ne 1 -or $unique[0] -le 4) {
        throw 'PacketRat could not confirm that Fairlead holds the AI address, so the Fairlead key was not sent.'
    }
    $ownerId = [int]$unique[0]
    $id = $null
    try { $id = & $script:PacketRatFairleadIdReader $Uri } catch {
        throw 'Fairlead did not identify itself, so the Fairlead key was not sent.'
    }
    $tool = [string](Get-PacketRatIdField $id 'tool')
    if ($tool -cne 'fairlead') { throw $refused }
    $idPid = 0
    if (-not [int]::TryParse([string](Get-PacketRatIdField $id 'pid'), [ref]$idPid) -or $idPid -ne $ownerId) { throw $refused }
    $info = $null
    try { $info = & $script:PacketRatProcessInfoReader $ownerId } catch { $info = $null }
    $reported = [string](Get-PacketRatIdField $id 'path')
    if ([string]::IsNullOrWhiteSpace($reported)) {
        $reported = Get-PacketRatFairleadOwnPath -Info $info
        if (-not $reported) { throw $refused }
    }
    $cmd = ''; $exe = ''
    if ($info -is [System.Collections.IDictionary]) {
        if ($info.Contains('CommandLine')) { $cmd = [string]$info['CommandLine'] }
        if ($info.Contains('ExecutablePath')) { $exe = [string]$info['ExecutablePath'] }
    } elseif ($info) {
        $cmd = [string](Get-PacketRatIdField $info 'CommandLine')
        $exe = [string](Get-PacketRatIdField $info 'ExecutablePath')
    }
    if (-not (Test-PacketRatReportedPath -Path $reported -CommandLine $cmd -ExecutablePath $exe)) { throw $refused }
}

function Invoke-PacketRatChat {
    <#
    .SYNOPSIS
      One chat call to Fairlead (OpenAI chat completions). Fairlead picks the model behind the route name.
      The key is sent only after Fairlead identifies itself on that address.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Messages,
        [string]$Model,
        [int]$MaxTokens = 8192,
        [double]$Temperature = 0.2,
        [int]$TimeoutSec = 180,
        [switch]$Stream,
        [scriptblock]$OnToken,
        [scriptblock]$ShouldCancel
    )

    $cfg = Get-PacketRatFairleadConfig
    if ($Model) { $cfg.Model = $Model }
    $key = Get-PacketRatFairleadKey
    $idUri = $null
    if (-not [Uri]::TryCreate($cfg.Url, [UriKind]::Absolute, [ref]$idUri)) {
        throw 'PacketRat could not confirm that Fairlead holds the AI address, so the Fairlead key was not sent.'
    }
    Test-PacketRatFairleadIdentity -Uri $idUri

    $msgList = @()
    foreach ($m in $Messages) {
        if ($m -is [hashtable]) {
            $msgList += @{ role = [string]$m['role']; content = [string]$m['content'] }
        } else {
            $msgList += @{ role = [string]$m.role; content = [string]$m.content }
        }
    }

    # Streaming is opt-in: -Stream, or PACKETRAT_LLM_STREAM=1 for every call.
    $useStream = ($Stream.IsPresent -or (Test-PacketRatStreamingEnabled))
    $payload = [ordered]@{
        messages    = $msgList
        max_tokens  = $MaxTokens
        model       = $cfg.Model
        temperature = $Temperature
        stream      = $useStream
    }
    $json  = $payload | ConvertTo-Json -Depth 8
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)

    Write-Host ("[*] PacketRat AI via Fairlead  route={0}" -f $cfg.Model) -ForegroundColor DarkCyan
    Write-Host ("    {0}" -f $cfg.Url) -ForegroundColor DarkGray

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {}

    $headers = @{
        Accept             = 'application/json'
        Authorization      = ('Bearer ' + $key)
        'X-Fairlead-Label' = $script:PacketRatFairleadDefaults.AppName
    }
    if ($cfg.Privacy -eq 'local') { $headers['X-Fairlead-Privacy'] = 'local' }

    if ($useStream) {
        if (-not $ShouldCancel) { $ShouldCancel = { Test-PacketRatCancelRequested } }
        Clear-PacketRatCancel
        $headers['Accept'] = 'text/event-stream'
        $streamed = Invoke-PacketRatChatStream -Url $cfg.Url -Headers $headers -Body $bytes -OnToken $OnToken -ShouldCancel $ShouldCancel -TimeoutSec $TimeoutSec
        if (-not $streamed) { throw 'Fairlead returned no recognized text content.' }
        return [pscustomobject]@{
            Model    = $cfg.Model
            Raw      = $null
            Text     = $streamed
            Streamed = $true
        }
    }

    $resp = Invoke-RestMethod -Uri $cfg.Url -Method Post `
        -Headers $headers `
        -Body $bytes `
        -ContentType 'application/json; charset=utf-8' `
        -TimeoutSec $TimeoutSec

    # Responses may return a string, text block array or content.parts.
    # Avoid casting arrays into "System.Object[]" instead of real report text.
    $text=''
    if($resp.choices -and $resp.choices[0].message){
        $text=ConvertTo-PacketRatLlmText -Value $resp.choices[0].message.content
    }
    if(-not $text -and $resp.choices -and $resp.choices[0].text){
        $text=ConvertTo-PacketRatLlmText -Value $resp.choices[0].text
    }
    if(-not $text){throw 'Fairlead returned no recognized text content.'}

    return [pscustomobject]@{
        Model    = $cfg.Model
        Raw      = $resp
        Text     = $text
    }
}
