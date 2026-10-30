# PacketRat - LLM client (compatible with Halyard AI endpoint / Grok endpoints)
#requires -Version 5.1

# The AiEndpoint profile defaults to the local phoenix-lai server's OpenAI-compatible API on this PC
# (loopback only). PACKETRAT_AI_ENDPOINT_URL overrides it, and the shared LLM_URL overrides every profile.
# The Grok profile is an outside provider, so it has no built-in URL: set PACKETRAT_GROK_URL (or LLM_URL)
# in Config\packetrat.env. No other host is built in.
$script:PacketRatLlmDefaults = @{
    GrokUrlEnv        = 'PACKETRAT_GROK_URL'
    GrokModel         = 'system.ai.grok-4-6'
    AiEndpointUrlEnv  = 'PACKETRAT_AI_ENDPOINT_URL'
    AiEndpointUrl     = 'http://127.0.0.1:1234/v1/chat/completions'   # local phoenix-lai
    AiEndpointModel   = 'gemini-3.8-flash'
    LocalDefaultModel = 'phoenixlai'   # phoenix-lai's name for "the model it has loaded"
}

# Profile token environment variables, in lookup order.
$script:PacketRatLlmTokenEnv = @{
    AiEndpoint = @('AI_ENDPOINT_TOKEN', 'GENAI_TOKEN')   # second entry: legacy alias (deprecated), still read
    Grok       = @('DATABRICKS_TOKEN')
}

# Legacy alias: the former AI-endpoint profile name is still accepted and mapped to AiEndpoint.
$script:PacketRatLlmProfileAliases = @{ 'GenAi' = 'AiEndpoint' }

function ConvertTo-PacketRatLlmProfile {
    <#
    .SYNOPSIS
      Normalize a -Profile value to Auto | Grok | AiEndpoint. Deprecated names are mapped; anything else throws.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Profile = 'Auto')
    if ([string]::IsNullOrWhiteSpace($Profile)) { return 'Auto' }
    $p = $Profile.Trim()
    foreach ($known in @('Auto', 'Grok', 'AiEndpoint')) {
        if ($p -eq $known) { return $known }
    }
    foreach ($alias in $script:PacketRatLlmProfileAliases.Keys) {
        if ($p -eq $alias) { return $script:PacketRatLlmProfileAliases[$alias] }
    }
    throw ("Unknown AI profile '{0}'. Use Auto, Grok or AiEndpoint." -f $p)
}

function Get-PacketRatLlmEnvToken {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Grok', 'AiEndpoint')][string]$Profile)
    foreach ($name in $script:PacketRatLlmTokenEnv[$Profile]) {
        $v = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v.Trim() }
    }
    return $null
}

# Runtime-only credential selection. Never write manually entered tokens to files.
# 'Lazarette' is the in-memory credential-source value shared with Web/app.js (never persisted).
$script:PacketRatCredentialSource = 'Lazarette'
$script:PacketRatManualTokens = @{ AiEndpoint = $null; Grok = $null }

function Get-PacketRatCredentialStatus {
    [CmdletBinding()]
    param()
    $lazaretteFound = $false
    if (Get-Command Find-PacketRatLazaretteRoot -ErrorAction SilentlyContinue) {
        $lazaretteFound = [bool](Find-PacketRatLazaretteRoot)
    }
    return @{
        source = $script:PacketRatCredentialSource
        manual = @{
            AiEndpoint = -not [string]::IsNullOrWhiteSpace([string]$script:PacketRatManualTokens.AiEndpoint)
            Grok = -not [string]::IsNullOrWhiteSpace([string]$script:PacketRatManualTokens.Grok)
        }
        lazaretteDetected = $lazaretteFound
        lazaretteItems = @{
            AiEndpoint = Resolve-PacketRatLazaretteServiceName -Profile AiEndpoint
            Grok = Resolve-PacketRatLazaretteServiceName -Profile Grok
        }
    }
}

function Set-PacketRatCredentialConfiguration {
    [CmdletBinding()]
    param(
        [ValidateSet('Lazarette','Manual')][string]$Source,
        [string]$Profile = 'AiEndpoint',
        [AllowEmptyString()][string]$Token = ''
    )
    $Profile = ConvertTo-PacketRatLlmProfile -Profile $Profile
    if ($Profile -eq 'Auto') { throw 'Select AiEndpoint or Grok for a manual token.' }
    if ($Source -eq 'Lazarette') {
        $script:PacketRatManualTokens.AiEndpoint = $null
        $script:PacketRatManualTokens.Grok = $null
    } elseif (-not [string]::IsNullOrWhiteSpace($Token)) {
        if ($Token.Length -gt 8192 -or $Token -match '[\r\n\x00-\x1F]') {
            throw 'Manual token is invalid (length/control characters).'
        }
        $clean = $Token.Trim().Trim("'").Trim('"')
        if ($clean -match '^(?i)Bearer\s+(.+)$') { $clean = $Matches[1].Trim() }
        if ([string]::IsNullOrWhiteSpace($clean)) { throw 'Manual token cannot be blank.' }
        $script:PacketRatManualTokens[$Profile] = $clean
    }
    $script:PacketRatCredentialSource = $Source
    return Get-PacketRatCredentialStatus
}

function Clear-PacketRatManualTokens {
    [CmdletBinding()]
    param()
    $script:PacketRatManualTokens.AiEndpoint = $null
    $script:PacketRatManualTokens.Grok = $null
    return Get-PacketRatCredentialStatus
}

function Get-PacketRatLlmConfig {
    [CmdletBinding()]
    param(
        [string]$Profile = 'Auto'
    )
    $Profile = ConvertTo-PacketRatLlmProfile -Profile $Profile

    $url   = $env:LLM_URL
    $model = $env:LLM_MODEL
    $resolved = $Profile

    if ($Profile -eq 'Auto') {
        if ($url -match 'serving-endpoints') { $resolved = 'Grok' }
        elseif ($script:PacketRatCredentialSource -eq 'Manual' -and
                [string]::IsNullOrWhiteSpace([string]$script:PacketRatManualTokens.AiEndpoint) -and
                -not [string]::IsNullOrWhiteSpace([string]$script:PacketRatManualTokens.Grok)) {
            $resolved = 'Grok'
        }
        elseif ((Get-PacketRatLlmEnvToken -Profile Grok) -and -not (Get-PacketRatLlmEnvToken -Profile AiEndpoint)) {
            $resolved = 'Grok'
        }
        else {
            $resolved = 'AiEndpoint'
        }
    }

    if ([string]::IsNullOrWhiteSpace($url)) {
        if ($resolved -eq 'AiEndpoint') { $url = [Environment]::GetEnvironmentVariable($script:PacketRatLlmDefaults.AiEndpointUrlEnv) }
        else { $url = [Environment]::GetEnvironmentVariable($script:PacketRatLlmDefaults.GrokUrlEnv) }
    }
    $isDefault = $false
    if ([string]::IsNullOrWhiteSpace($url) -and $resolved -eq 'AiEndpoint') {
        $url = $script:PacketRatLlmDefaults.AiEndpointUrl
        $isDefault = $true
    }
    if ([string]::IsNullOrWhiteSpace($model)) {
        if ($isDefault) { $model = $script:PacketRatLlmDefaults.LocalDefaultModel }
        elseif ($resolved -eq 'AiEndpoint') { $model = $script:PacketRatLlmDefaults.AiEndpointModel }
        else { $model = $script:PacketRatLlmDefaults.GrokModel }
    }

    return [pscustomobject]@{
        Profile    = $resolved
        Url        = ([string]$url).Trim().TrimEnd('/')
        Model      = $model
        DefaultUrl = $isDefault
    }
}

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

function Get-PacketRatLlmAuthToken {
    <#
    .SYNOPSIS
      The token to send for a resolved endpoint configuration, or $null when none is needed.
      Remote endpoints need a token (see Get-PacketRatLlmToken). A loopback endpoint such as the local
      phoenix-lai server has its API key off by default, so its token is optional: a manual, profile or
      LLM_TOKEN value is used when set, the vault is not opened, and no Authorization header is sent without one.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)
    if (-not (Test-PacketRatLoopbackUrl -Url ([string]$Config.Url))) {
        return Get-PacketRatLlmToken -ForProfile $Config.Profile
    }
    if ($script:PacketRatCredentialSource -eq 'Manual') {
        $manual = [string]$script:PacketRatManualTokens[$Config.Profile]
        if ([string]::IsNullOrWhiteSpace($manual)) { return $null }
        return $manual.Trim()
    }
    $existing = Get-PacketRatLlmEnvToken -Profile $Config.Profile
    if (-not [string]::IsNullOrWhiteSpace($existing)) { return $existing }
    if (-not [string]::IsNullOrWhiteSpace($env:LLM_TOKEN)) { return $env:LLM_TOKEN.Trim() }
    return $null
}

function Get-PacketRatLlmToken {
    <#
    .SYNOPSIS
      Profile-isolated tokens:
        AiEndpoint -> AI_ENDPOINT_TOKEN / Lazarette item ai-endpoint-api
        Grok       -> DATABRICKS_TOKEN  / Lazarette item grok-api
      Deprecated environment and item names are still read (see $script:PacketRatLlmTokenEnv and
      $script:PacketRatLlmVaultItems). Item-name env overrides are preferred over the canonical names.
      Never prints secret values (length only).
    #>
    [CmdletBinding()]
    param(
        [string]$ForProfile = 'Auto',
        [switch]$AllowPrompt
    )
    $ForProfile = ConvertTo-PacketRatLlmProfile -Profile $ForProfile

    if ($ForProfile -eq 'Auto') {
        $cfg = Get-PacketRatLlmConfig -Profile Auto
        $ForProfile = $cfg.Profile
    }

    $envTarget = $script:PacketRatLlmTokenEnv[$ForProfile][0]

    # Manual credentials are session-only and never fall back to environment or Lazarette.
    if ($script:PacketRatCredentialSource -eq 'Manual') {
        $manual = [string]$script:PacketRatManualTokens[$ForProfile]
        if ([string]::IsNullOrWhiteSpace($manual)) {
            throw ("No manual token configured for {0}. Open Configuration > Credentials, select Manual, enter an approved token and click Apply." -f $ForProfile)
        }
        return $manual
    }

    # 1) Profile-specific env token (current name first, then its legacy alias)
    $existing = Get-PacketRatLlmEnvToken -Profile $ForProfile
    if (-not [string]::IsNullOrWhiteSpace($existing)) {
        return $existing
    }

    # 2) Shared fallback some teams still use
    if (-not [string]::IsNullOrWhiteSpace($env:LLM_TOKEN)) {
        return $env:LLM_TOKEN.Trim()
    }

    # 3) Lazarette vault - resolve canonical (or env-overridden) service name
    $lazaretteItem = Resolve-PacketRatLazaretteServiceName -Profile $ForProfile

    if (Get-Command Import-PacketRatLazaretteSession -ErrorAction SilentlyContinue) {
        Write-Host '[*] Loading Lazarette vault (on-demand, once per process)...' -ForegroundColor DarkGray
        try {
            $null = Import-PacketRatLazaretteSession -Quiet
        } catch {
            Write-Host ("[!] Lazarette load skipped: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }

    if (Get-Command Get-PacketRatLazaretteSecretByName -ErrorAction SilentlyContinue) {
        try {
            Write-Host ("[*] Looking up Lazarette item '{0}'..." -f $lazaretteItem) -ForegroundColor DarkGray
            $got = Get-PacketRatLazaretteSecretByName -ServiceName $lazaretteItem
            if (-not [string]::IsNullOrWhiteSpace($got)) {
                $plain = [string]$got.Trim()
                Set-Item -Path "Env:$envTarget" -Value $plain
                # length only - never print secret material
                Write-Host ("[*] Loaded {0} from Lazarette item '{1}' (len={2})" -f $envTarget, $lazaretteItem, $plain.Length) -ForegroundColor DarkGray
                return $plain
            }
        } catch {
            Write-Verbose "Lazarette secret load failed: $($_.Exception.Message)"
        }
    }

    throw ("No managed LLM token available for {0}. Check Lazarette is installed/unlocked with item {1}, or switch to Manual under PacketRat Configuration > Credentials." -f $ForProfile, $lazaretteItem)
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
        throw ('The AI endpoint reported an error while streaming: ' + $m)
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
        if ([DateTime]::UtcNow -gt $deadline) { throw 'The AI endpoint stopped sending data (timed out).' }
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
        if ([DateTime]::UtcNow -gt $deadline) { $req.Abort(); throw 'The AI endpoint did not answer (timed out).' }
    }
    if ($task.IsFaulted) {
        $err = $task.Exception.GetBaseException()
        $status = ''
        if ($err -is [System.Net.WebException] -and $err.Response) { $status = ' (HTTP ' + [int]$err.Response.StatusCode + ')' }
        throw ('The AI endpoint refused the request' + $status + ': ' + $err.Message)
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
      Call the AI endpoint or Grok endpoint (same shape as Halyard's chat call).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Messages,
        [string]$Profile = 'Auto',
        [string]$Model,
        [int]$MaxTokens = 8192,
        [double]$Temperature = 0.2,
        [int]$TimeoutSec = 180,
        [switch]$Stream,
        [scriptblock]$OnToken,
        [scriptblock]$ShouldCancel
    )

    $cfg = Get-PacketRatLlmConfig -Profile $Profile
    if ([string]::IsNullOrWhiteSpace($cfg.Url)) {
        $urlEnv = if ($cfg.Profile -eq 'AiEndpoint') { $script:PacketRatLlmDefaults.AiEndpointUrlEnv } else { $script:PacketRatLlmDefaults.GrokUrlEnv }
        throw ("No endpoint URL configured for profile {0}. Set {1} (or LLM_URL) in Config\packetrat.env." -f $cfg.Profile, $urlEnv)
    }
    if ($Model) {
        $cfg = [pscustomobject]@{ Profile = $cfg.Profile; Url = $cfg.Url; Model = $Model; DefaultUrl = $cfg.DefaultUrl }
    }

    $local = Test-PacketRatLoopbackUrl -Url $cfg.Url
    $token = [string](Get-PacketRatLlmAuthToken -Config $cfg)
    $token = $token.Trim().Trim("'").Trim('"')
    if ($token -match '^(?i)Bearer\s+(.+)$') { $token = $Matches[1].Trim() }
    $token = ($token -replace '[\r\n]', '').Trim()

    if ([string]::IsNullOrWhiteSpace($token) -and -not $local) {
        throw "LLM token empty after sanitization."
    }

    $msgList = @()
    foreach ($m in $Messages) {
        if ($m -is [hashtable]) {
            $msgList += @{ role = [string]$m['role']; content = [string]$m['content'] }
        } else {
            $msgList += @{ role = [string]$m.role; content = [string]$m.content }
        }
    }

    # Streaming is opt-in and only for OpenAI-style endpoints; the Grok / serving-endpoints shape stays non-streaming.
    $useStream = ($Stream.IsPresent -or (Test-PacketRatStreamingEnabled)) -and -not ($cfg.Profile -eq 'Grok' -or $cfg.Url -match 'serving-endpoints')

    if ($cfg.Profile -eq 'Grok' -or $cfg.Url -match 'serving-endpoints') {
        $payload = [ordered]@{
            messages    = $msgList
            max_tokens  = $MaxTokens
            model       = $cfg.Model
            temperature = $Temperature
        }
    } else {
        $payload = [ordered]@{
            messages    = $msgList
            max_tokens  = $MaxTokens
            model       = $cfg.Model
            temperature = $Temperature
            stream      = $useStream
        }
    }

    $json  = $payload | ConvertTo-Json -Depth 8
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)

    Write-Host ("[*] PacketRat LLM  profile={0}  model={1}" -f $cfg.Profile, $cfg.Model) -ForegroundColor DarkCyan
    Write-Host ("    {0}" -f $cfg.Url) -ForegroundColor DarkGray

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {}

    # No Authorization header at all when a local endpoint has no token (never an empty "Bearer ").
    $headers = @{ Accept = 'application/json' }
    if (-not [string]::IsNullOrWhiteSpace($token)) { $headers['Authorization'] = 'Bearer ' + $token }

    if ($useStream) {
        if (-not $ShouldCancel) { $ShouldCancel = { Test-PacketRatCancelRequested } }
        Clear-PacketRatCancel
        $headers['Accept'] = 'text/event-stream'
        $streamed = Invoke-PacketRatChatStream -Url $cfg.Url -Headers $headers -Body $bytes -OnToken $OnToken -ShouldCancel $ShouldCancel -TimeoutSec $TimeoutSec
        if (-not $streamed) { throw 'The AI endpoint returned no recognized text content.' }
        return [pscustomobject]@{
            Profile  = $cfg.Profile
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

    # Provider responses may return a string, text block array or content.parts.
    # Avoid casting arrays into "System.Object[]" instead of real report text.
    $text=''
    if($resp.choices -and $resp.choices[0].message){
        $text=ConvertTo-PacketRatLlmText -Value $resp.choices[0].message.content
    }
    if(-not $text -and $resp.choices -and $resp.choices[0].text){
        $text=ConvertTo-PacketRatLlmText -Value $resp.choices[0].text
    }
    if(-not $text -and $resp.candidates -and $resp.candidates[0].content){
        $text=ConvertTo-PacketRatLlmText -Value $resp.candidates[0].content
    }
    if(-not $text -and $resp.content){
        $text=ConvertTo-PacketRatLlmText -Value $resp.content
    }
    if(-not $text){throw 'The AI endpoint returned no recognized text content.'}

    return [pscustomobject]@{
        Profile  = $cfg.Profile
        Model    = $cfg.Model
        Raw      = $resp
        Text     = $text
    }
}
