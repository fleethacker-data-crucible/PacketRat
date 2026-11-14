# PacketRat - AI client. Every AI call goes to Fairlead (the Fleet model router) and nowhere else.
#requires -Version 5.1

# Fairlead answers on this PC at http://127.0.0.1:8776 and owns the endpoints, models and provider keys.
#   PACKETRAT_FAIRLEAD_URL      another loopback address for Fairlead (a different port); anything not on this PC is refused.
#   PACKETRAT_FAIRLEAD_MODEL    the route name to ask for (default 'auto').
#   PACKETRAT_FAIRLEAD_PRIVACY  'local' adds X-Fairlead-Privacy: local so prompts stay on local models.
# The key PacketRat sends is the Windows Credential Manager generic credential Fairlead/PacketRat when that is installed,
# and otherwise the first line of Fairlead's local token (%LOCALAPPDATA%\Fairlead\local-token, or FAIRLEAD_LOCAL_TOKEN_FILE).
# There is no environment-variable or vault fallback. The key is sent only after /__fleethacker/id names Fairlead.
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

# --- The Fairlead key: installed credential, else the local token -------------------------------------------------
# Tests set an override so they never read a user's token. The default is Fairlead's own file.
$script:PacketRatUseDefaultLocalToken = $true
$script:PacketRatLocalTokenPath = ''

function Get-PacketRatFairleadLocalTokenPath {
    <#
    .SYNOPSIS
      Where Fairlead keeps the local token for this Windows account.
    #>
    [CmdletBinding()]
    param()
    if (-not $script:PacketRatUseDefaultLocalToken) { return [string]$script:PacketRatLocalTokenPath }
    $custom = [Environment]::GetEnvironmentVariable('FAIRLEAD_LOCAL_TOKEN_FILE')
    if (-not [string]::IsNullOrWhiteSpace($custom)) { return $custom.Trim() }
    $base = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($base)) {
        try { $base = [Environment]::GetFolderPath('LocalApplicationData') } catch { $base = '' }
    }
    if ([string]::IsNullOrWhiteSpace($base)) { return '' }
    return (Join-Path (Join-Path $base 'Fairlead') 'local-token')
}

function Set-PacketRatLocalTokenPath {
    # $null returns to the real file. Any other value, including a path that does not exist, is used instead.
    param([object]$Path)
    if ($null -eq $Path) { $script:PacketRatUseDefaultLocalToken = $true; $script:PacketRatLocalTokenPath = ''; return }
    $script:PacketRatUseDefaultLocalToken = $false
    $script:PacketRatLocalTokenPath = [string]$Path
}

function Read-PacketRatLocalTokenFile {
    # The first line, when it is a Fairlead client key (fl- and at least 19 characters). '' otherwise. Never logged.
    param([string]$Path)
    try {
        if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.File]::Exists($Path)) { return '' }
        if ((New-Object IO.FileInfo $Path).Length -gt 4096) { return '' }
        $text = [IO.File]::ReadAllText($Path)
        $line = ($text -split "`r?`n", 2)[0]
        if (-not $line) { return '' }
        $line = $line.Trim().TrimStart([char]0xFEFF)
        if ($line -cmatch '\Afl-[A-Za-z0-9_-]{16,256}\z') { return $line }
        return ''
    } catch { return '' }
}

function Resolve-PacketRatFairleadKey {
    # @{ Key; Source } where Source is credential, local-token or none. Key is '' when none. Never logged.
    $key = ''
    try { $key = [string](& $script:PacketRatCredentialReader (Get-PacketRatFairleadTarget)) } catch { $key = '' }
    $key = $key.Trim()
    if (-not [string]::IsNullOrWhiteSpace($key)) { return @{ Key = $key; Source = 'credential' } }
    $token = Read-PacketRatLocalTokenFile -Path (Get-PacketRatFairleadLocalTokenPath)
    if (-not [string]::IsNullOrWhiteSpace($token)) { return @{ Key = $token; Source = 'local-token' } }
    return @{ Key = ''; Source = 'none' }
}

# --- Who is listening, before any key is sent ---------------------------------------------------------------------
$script:PacketRatFairleadIdentity = { param([string]$Url) Test-PacketRatFairleadIdentity -Url $Url }

function Set-PacketRatFairleadIdentity {
    # Tests pass { $null } when their fake is not a Fairlead process. $null restores the real check.
    param([scriptblock]$Check)
    if ($Check) { $script:PacketRatFairleadIdentity = $Check }
    else { $script:PacketRatFairleadIdentity = { param([string]$Url) Test-PacketRatFairleadIdentity -Url $Url } }
}

function ConvertTo-PacketRatNormalPath {
    # An absolute Windows path (drive or UNC) with . and .. removed, or '' when it is not one. No substring match later.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = $Path.Trim().Trim('"').Replace('/', '\')
    $root = ''
    $body = ''
    if ($p -match '^[A-Za-z]:\\') {
        $root = $p.Substring(0, 2)
        $body = $p.Substring(2).Trim('\')
    } elseif ($p -match '^\\\\[^\\]+\\[^\\]+') {
        $m = [regex]::Match($p, '^\\\\([^\\]+)\\([^\\]+)\\?(.*)$')
        if (-not $m.Success) { return '' }
        $root = '\\' + $m.Groups[1].Value + '\' + $m.Groups[2].Value
        $body = $m.Groups[3].Value
    } else { return '' }
    $stack = New-Object System.Collections.Generic.List[string]
    foreach ($seg in ($body -split '\\')) {
        if ($seg -eq '' -or $seg -eq '.') { continue }
        if ($seg -eq '..') { if ($stack.Count -gt 0) { $stack.RemoveAt($stack.Count - 1) }; continue }
        [void]$stack.Add($seg)
    }
    $tail = ($stack.ToArray() -join '\')
    if ($tail) { return ($root.TrimEnd('\') + '\' + $tail) }
    return $root.TrimEnd('\')
}

function Get-PacketRatListenerPids {
    # PIDs listening on the port. Get-NetTCPConnection, else netstat. Throws when neither can be asked.
    param([int]$Port)
    $owners = New-Object System.Collections.Generic.List[int]
    $asked = $false
    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        $asked = $true
        try {
            $conns = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop)
            foreach ($c in $conns) {
                $n = [int]$c.OwningProcess
                if ($n -gt 0 -and -not $owners.Contains($n)) { [void]$owners.Add($n) }
            }
            return @($owners)
        } catch { }
    }
    $netstat = $null
    try { $netstat = Join-Path ([Environment]::SystemDirectory) 'netstat.exe' } catch { $netstat = $null }
    if ($netstat -and (Test-Path -LiteralPath $netstat)) {
        $asked = $true
        foreach ($line in @(& $netstat -ano -p TCP 2>$null) + @(& $netstat -ano -p TCPv6 2>$null)) {
            if ([string]$line -match '^\s*TCP\s+\S+:(\d+)\s+\S+\s+LISTENING\s+(\d+)\s*$' -and [int]$Matches[1] -eq $Port) {
                $n = [int]$Matches[2]
                if ($n -gt 0 -and -not $owners.Contains($n)) { [void]$owners.Add($n) }
            }
        }
        return @($owners)
    }
    if (-not $asked) { throw 'PacketRat could not read which program is listening, so the key was not sent.' }
    return @($owners)
}

function Get-PacketRatProcessPaths {
    # ExecutablePath and the -File script from the process command line. Both '' when the process cannot be read.
    param([int]$ProcessId)
    $p = $null
    try { $p = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop } catch { $p = $null }
    if (-not $p) { return @{ ExecutablePath = ''; ScriptPath = '' } }
    $file = ''
    $m = [regex]::Match([string]$p.CommandLine, '(?i)(?:^|\s)[-/](?:file|f)\s+(?:"([^"]+)"|(\S+))')
    if ($m.Success) { if ($m.Groups[1].Success) { $file = $m.Groups[1].Value } else { $file = $m.Groups[2].Value } }
    return @{ ExecutablePath = [string]$p.ExecutablePath; ScriptPath = $file }
}

function Test-PacketRatProcessPath {
    # $true only when $Path is exactly the process executable or its -File script. Never a substring.
    param([int]$ProcessId, [string]$Path)
    $want = ConvertTo-PacketRatNormalPath $Path
    if (-not $want) { return $false }
    $paths = Get-PacketRatProcessPaths -ProcessId $ProcessId
    foreach ($candidate in @($paths.ExecutablePath, $paths.ScriptPath)) {
        $c = ConvertTo-PacketRatNormalPath $candidate
        if ($c -and [string]::Equals($c, $want, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-PacketRatJsonField($Obj, [string]$Name) {
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) {
        if ($Obj.Contains($Name)) { return $Obj[$Name] }
        return $null
    }
    $prop = $Obj.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Get-PacketRatFairleadIdDocument {
    # The JSON from GET /__fleethacker/id, or $null. The request carries no key.
    param([Uri]$Uri, [int]$TimeoutSec = 3)
    $hostName = $Uri.Host
    if ($hostName.Contains(':')) { $hostName = '[' + $hostName + ']' }
    $idUrl = '{0}://{1}:{2}/__fleethacker/id' -f $Uri.Scheme, $hostName, $Uri.Port
    $req = [Net.HttpWebRequest]::Create($idUrl)
    $req.Method = 'GET'
    $req.Timeout = $TimeoutSec * 1000
    $req.ReadWriteTimeout = $TimeoutSec * 1000
    $req.Proxy = $null
    $req.AllowAutoRedirect = $false
    $req.Accept = 'application/json'
    $req.UserAgent = 'PacketRat'
    $resp = $null
    try {
        $resp = $req.GetResponse()
        $reader = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
        if ($text.Length -gt 4096) { return $null }
        return ($text | ConvertFrom-Json)
    } catch { return $null } finally {
        if ($null -ne $resp) { try { $resp.Close() } catch {} }
    }
}

function Test-PacketRatFairleadIdentity {
    <#
    .SYNOPSIS
      $null when the address is Fairlead, else a sentence that does not contain a key.
      The id request is made with no key. The reported pid must hold the port, and the reported path must be
      that process's executable or -File script. A missing path is accepted only when the process is
      scripts\Start-Fairlead.ps1 or a Fairlead executable.
    #>
    param([string]$Url)
    $refused = 'Something other than Fairlead is answering on this port, so the key was not sent.'
    if (-not (Test-PacketRatLoopbackUrl -Url $Url)) { return 'The Fairlead address is not on this PC, so the key was not sent.' }
    $u = [Uri]$Url
    $owners = @()
    try { $owners = @(Get-PacketRatListenerPids -Port $u.Port) } catch { return 'PacketRat could not read which program is listening, so the key was not sent.' }
    if ($owners.Count -eq 0) { return 'Fairlead is not running, so the key was not sent.' }
    if ($owners.Count -gt 1) { return $refused }
    $owner = [int]$owners[0]
    if ($owner -le 4) { return $refused }
    $id = Get-PacketRatFairleadIdDocument -Uri $u
    $tool = Get-PacketRatJsonField $id 'tool'
    if ($tool -cne 'fairlead') { return 'The program on this port did not identify itself as Fairlead, so the key was not sent.' }
    $idPid = 0
    if (-not [int]::TryParse([string](Get-PacketRatJsonField $id 'pid'), [ref]$idPid) -or $idPid -ne $owner) { return $refused }
    $reported = Get-PacketRatJsonField $id 'path'
    if ($reported -isnot [string] -or [string]::IsNullOrWhiteSpace($reported)) {
        $paths = Get-PacketRatProcessPaths -ProcessId $owner
        $script = ConvertTo-PacketRatNormalPath $paths.ScriptPath
        $exe = ConvertTo-PacketRatNormalPath $paths.ExecutablePath
        if ($script -and $script -match '(?i)\\scripts\\Start-Fairlead\.ps1\z') { $reported = $script }
        elseif ($exe -and ([IO.Path]::GetFileName($exe) -match '(?i)\Afairlead[\w.-]*\.exe\z')) { $reported = $exe }
        else { return 'The program on this port says it is Fairlead but does not run Fairlead, so the key was not sent.' }
    }
    if (-not (Test-PacketRatProcessPath -ProcessId $owner -Path $reported)) { return $refused }
    return $null
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

function Get-PacketRatFairleadKey {
    <#
    .SYNOPSIS
      The Fairlead client key for PacketRat, or a clear error. Never printed or logged.
      Credential Manager (Fairlead/PacketRat) wins. Otherwise the local token file.
    #>
    [CmdletBinding()]
    param()
    $resolved = Resolve-PacketRatFairleadKey
    if ([string]::IsNullOrWhiteSpace($resolved.Key)) {
        throw ('Open Fairlead and install a key for {0}.' -f $script:PacketRatFairleadDefaults.AppName)
    }
    return [string]$resolved.Key
}

function Get-PacketRatCredentialStatus {
    <#
    .SYNOPSIS
      Where PacketRat sends AI calls and whether a Fairlead key is available. Never returns the key.
    #>
    [CmdletBinding()]
    param()
    $cfg = Get-PacketRatFairleadConfig
    $resolved = Resolve-PacketRatFairleadKey
    $installed = -not [string]::IsNullOrWhiteSpace($resolved.Key)
    $message = ('Open Fairlead and install a key for {0}.' -f $script:PacketRatFairleadDefaults.AppName)
    if ($resolved.Source -eq 'credential') { $message = 'Fairlead key found for PacketRat.' }
    elseif ($resolved.Source -eq 'local-token') { $message = 'Fairlead local token found for PacketRat.' }
    return @{
        router       = 'Fairlead'
        url          = $cfg.Url
        model        = $cfg.Model
        privacy      = $cfg.Privacy
        target       = (Get-PacketRatFairleadTarget)
        keySource    = [string]$resolved.Source
        keyInstalled = $installed
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

function Invoke-PacketRatChat {
    <#
    .SYNOPSIS
      One chat call to Fairlead (OpenAI chat completions). Fairlead picks the model behind the route name.
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
    $who = & $script:PacketRatFairleadIdentity $cfg.Url
    if ($who) {
        $who = [string]$who
        if ($who.Contains($key)) { $who = $who.Replace($key, '[key]') }
        throw $who
    }

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
