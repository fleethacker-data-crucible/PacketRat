# PacketRat - LLM client (compatible with Halyard GenAi / Grok endpoints)
#requires -Version 5.1

$script:PacketRatLlmDefaults = @{
    GrokUrl    = 'https://advana-jupiter.cloud.databricks.mil/serving-endpoints/databricks-grok-4-6/invocations'
    GrokModel  = 'system.ai.grok-4-6'
    GenAiUrl   = 'https://api.genai.mil/v1/chat/completions'
    GenAiModel = 'gemini-3.8-flash'
}

# Runtime-only credential selection. Never write manually entered tokens to files.
# 'ARC' is the internal credential-source value shared with Web/app.js (kept for compatibility); it means Lazarette.
$script:PacketRatCredentialSource = 'ARC'
$script:PacketRatManualTokens = @{ GenAi = $null; Grok = $null }

function Get-PacketRatCredentialStatus {
    [CmdletBinding()]
    param()
    $arcFound = $false
    if (Get-Command Find-PacketRatLazaretteRoot -ErrorAction SilentlyContinue) {
        $arcFound = [bool](Find-PacketRatLazaretteRoot)
    }
    return @{
        source = $script:PacketRatCredentialSource
        manual = @{
            GenAi = -not [string]::IsNullOrWhiteSpace([string]$script:PacketRatManualTokens.GenAi)
            Grok = -not [string]::IsNullOrWhiteSpace([string]$script:PacketRatManualTokens.Grok)
        }
        arcDetected = $arcFound
        arcItems = @{
            GenAi = Resolve-PacketRatLazaretteServiceName -Profile GenAi
            Grok = Resolve-PacketRatLazaretteServiceName -Profile Grok
        }
    }
}

function Set-PacketRatCredentialConfiguration {
    [CmdletBinding()]
    param(
        [ValidateSet('ARC','Manual')][string]$Source,
        [ValidateSet('GenAi','Grok')][string]$Profile = 'GenAi',
        [AllowEmptyString()][string]$Token = ''
    )
    if ($Source -eq 'ARC') {
        $script:PacketRatManualTokens.GenAi = $null
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
    $script:PacketRatManualTokens.GenAi = $null
    $script:PacketRatManualTokens.Grok = $null
    return Get-PacketRatCredentialStatus
}

function Get-PacketRatLlmConfig {
    [CmdletBinding()]
    param(
        [ValidateSet('Auto', 'Grok', 'GenAi')]
        [string]$Profile = 'Auto'
    )

    $url   = $env:LLM_URL
    $model = $env:LLM_MODEL
    $resolved = $Profile

    if ($Profile -eq 'Auto') {
        if ($url -match 'databricks\.mil|serving-endpoints') { $resolved = 'Grok' }
        elseif ($url -match 'genai\.mil') { $resolved = 'GenAi' }
        elseif ($script:PacketRatCredentialSource -eq 'Manual' -and
                [string]::IsNullOrWhiteSpace([string]$script:PacketRatManualTokens.GenAi) -and
                -not [string]::IsNullOrWhiteSpace([string]$script:PacketRatManualTokens.Grok)) {
            $resolved = 'Grok'
        }
        elseif (-not [string]::IsNullOrWhiteSpace($env:DATABRICKS_TOKEN) -and [string]::IsNullOrWhiteSpace($env:GENAI_TOKEN)) {
            $resolved = 'Grok'
        }
        elseif (-not [string]::IsNullOrWhiteSpace($env:GENAI_TOKEN)) {
            $resolved = 'GenAi'
        }
        else {
            $resolved = 'GenAi'
        }
    }

    if ([string]::IsNullOrWhiteSpace($url)) {
        if ($resolved -eq 'GenAi') { $url = $script:PacketRatLlmDefaults.GenAiUrl }
        else { $url = $script:PacketRatLlmDefaults.GrokUrl }
    }
    if ([string]::IsNullOrWhiteSpace($model)) {
        if ($resolved -eq 'GenAi') { $model = $script:PacketRatLlmDefaults.GenAiModel }
        else { $model = $script:PacketRatLlmDefaults.GrokModel }
    }

    return [pscustomobject]@{
        Profile = $resolved
        Url     = $url.TrimEnd('/')
        Model   = $model
    }
}

function Get-PacketRatLlmToken {
    <#
    .SYNOPSIS
      Profile-isolated tokens:
        GenAi  -> GENAI_TOKEN  / Lazarette item genapi
        Grok   -> DATABRICKS_TOKEN / Lazarette item advana-api
      Env overrides: PACKETRAT_LAZARETTE_ITEM_*, then MAILHAWK_ARC_ITEM_* / CASCADE_ARC_ITEM_*, preferred over hard-coded names.
      Never prints secret values (length only).
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Auto', 'Grok', 'GenAi')]
        [string]$ForProfile = 'Auto',
        [switch]$AllowPrompt
    )

    if ($ForProfile -eq 'Auto') {
        $cfg = Get-PacketRatLlmConfig -Profile Auto
        $ForProfile = $cfg.Profile
    }

    if ($ForProfile -eq 'GenAi') {
        $envTarget = 'GENAI_TOKEN'
    } else {
        $envTarget = 'DATABRICKS_TOKEN'
    }

    # Manual credentials are session-only and never fall back to environment or Lazarette.
    if ($script:PacketRatCredentialSource -eq 'Manual') {
        $manual = [string]$script:PacketRatManualTokens[$ForProfile]
        if ([string]::IsNullOrWhiteSpace($manual)) {
            throw ("No manual token configured for {0}. Open Configuration > Credentials, select Manual, enter an approved token and click Apply." -f $ForProfile)
        }
        return $manual
    }

    # 1) Profile-specific env token
    $existing = [Environment]::GetEnvironmentVariable($envTarget)
    if (-not [string]::IsNullOrWhiteSpace($existing)) {
        return $existing.Trim()
    }

    # 2) Shared fallback some teams still use
    if (-not [string]::IsNullOrWhiteSpace($env:LLM_TOKEN)) {
        return $env:LLM_TOKEN.Trim()
    }

    # 3) Lazarette vault — resolve canonical (or env-overridden) service name
    $arcItem = Resolve-PacketRatLazaretteServiceName -Profile $ForProfile

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
            Write-Host ("[*] Looking up Lazarette item '{0}'..." -f $arcItem) -ForegroundColor DarkGray
            $got = Get-PacketRatLazaretteSecretByName -ServiceName $arcItem
            if (-not [string]::IsNullOrWhiteSpace($got)) {
                $plain = [string]$got.Trim()
                Set-Item -Path "Env:$envTarget" -Value $plain
                # length only — never print secret material
                Write-Host ("[*] Loaded {0} from Lazarette item '{1}' (len={2})" -f $envTarget, $arcItem, $plain.Length) -ForegroundColor DarkGray
                return $plain
            }
        } catch {
            Write-Verbose "Lazarette secret load failed: $($_.Exception.Message)"
        }
    }

    throw ("No managed LLM token available for {0}. Check Lazarette is installed/unlocked with item {1}, or switch to Manual under PacketRat Configuration > Credentials." -f $ForProfile, $arcItem)
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

function Invoke-PacketRatChat {
    <#
    .SYNOPSIS
      Call GenAi or Grok endpoint (same shape as Halyard's chat call, formerly Cascade Invoke-CascadeChat).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Messages,
        [ValidateSet('Auto', 'Grok', 'GenAi')]
        [string]$Profile = 'Auto',
        [string]$Model,
        [int]$MaxTokens = 8192,
        [double]$Temperature = 0.2,
        [int]$TimeoutSec = 180
    )

    $cfg = Get-PacketRatLlmConfig -Profile $Profile
    if ($Model) {
        $cfg = [pscustomobject]@{ Profile = $cfg.Profile; Url = $cfg.Url; Model = $Model }
    }

    $token = Get-PacketRatLlmToken -ForProfile $cfg.Profile
    $token = $token.Trim().Trim("'").Trim('"')
    if ($token -match '^(?i)Bearer\s+(.+)$') { $token = $Matches[1].Trim() }
    $token = ($token -replace '[\r\n]', '').Trim()

    if ([string]::IsNullOrWhiteSpace($token)) {
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
            stream      = $false
        }
    }

    $json  = $payload | ConvertTo-Json -Depth 8
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)

    Write-Host ("[*] PacketRat LLM  profile={0}  model={1}" -f $cfg.Profile, $cfg.Model) -ForegroundColor DarkCyan
    Write-Host ("    {0}" -f $cfg.Url) -ForegroundColor DarkGray

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {}

    $headers = @{
        Authorization = ('Bearer ' + $token)
        Accept        = 'application/json'
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
