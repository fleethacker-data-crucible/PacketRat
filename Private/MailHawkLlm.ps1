# MailHawk - LLM client (compatible with Cascade GenAi / Grok endpoints)
#requires -Version 5.1

$script:MailHawkLlmDefaults = @{
    GrokUrl    = 'https://advana-jupiter.cloud.databricks.mil/serving-endpoints/databricks-grok-4-6/invocations'
    GrokModel  = 'system.ai.grok-4-6'
    GenAiUrl   = 'https://api.genai.mil/v1/chat/completions'
    GenAiModel = 'gemini-3.8-flash'
}

function Get-MailHawkLlmConfig {
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
        if ($resolved -eq 'GenAi') { $url = $script:MailHawkLlmDefaults.GenAiUrl }
        else { $url = $script:MailHawkLlmDefaults.GrokUrl }
    }
    if ([string]::IsNullOrWhiteSpace($model)) {
        if ($resolved -eq 'GenAi') { $model = $script:MailHawkLlmDefaults.GenAiModel }
        else { $model = $script:MailHawkLlmDefaults.GrokModel }
    }

    return [pscustomobject]@{
        Profile = $resolved
        Url     = $url.TrimEnd('/')
        Model   = $model
    }
}

function Get-MailHawkLlmToken {
    <#
    .SYNOPSIS
      Profile-isolated tokens:
        GenAi  -> GENAI_TOKEN  / ARC service genapi
        Grok   -> DATABRICKS_TOKEN / ARC service advana-api
      Env overrides: MAILHAWK_ARC_ITEM_* / CASCADE_ARC_ITEM_* preferred over hard-coded names.
      Never prints secret values (length only).
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Auto', 'Grok', 'GenAi')]
        [string]$ForProfile = 'Auto',
        [switch]$AllowPrompt
    )

    if ($ForProfile -eq 'Auto') {
        $cfg = Get-MailHawkLlmConfig -Profile Auto
        $ForProfile = $cfg.Profile
    }

    if ($ForProfile -eq 'GenAi') {
        $envTarget = 'GENAI_TOKEN'
    } else {
        $envTarget = 'DATABRICKS_TOKEN'
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

    # 3) ARC vault — resolve canonical (or env-overridden) service name
    $arcItem = Resolve-MailHawkArcServiceName -Profile $ForProfile

    if (Get-Command Import-MailHawkArcSession -ErrorAction SilentlyContinue) {
        Write-Host '[*] Loading ARC vault (on-demand, pm.ps1 once)...' -ForegroundColor DarkGray
        try {
            $null = Import-MailHawkArcSession -Quiet
        } catch {
            Write-Host ("[!] ARC load skipped: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }

    if (Get-Command Get-MailHawkArcSecretByName -ErrorAction SilentlyContinue) {
        try {
            Write-Host ("[*] Looking up ARC service '{0}'..." -f $arcItem) -ForegroundColor DarkGray
            $got = Get-MailHawkArcSecretByName -ServiceName $arcItem
            if (-not [string]::IsNullOrWhiteSpace($got)) {
                $plain = [string]$got.Trim()
                Set-Item -Path "Env:$envTarget" -Value $plain
                # length only — never print secret material
                Write-Host ("[*] Loaded {0} from ARC service '{1}' (len={2})" -f $envTarget, $arcItem, $plain.Length) -ForegroundColor DarkGray
                return $plain
            }
        } catch {
            Write-Verbose "ARC secret load failed: $($_.Exception.Message)"
        }
    }

    throw ("No LLM token found for profile {0}. Set {1} in mailhawk.env, or ARC services genapi / advana-api via Projects\arc (pm.ps1)." -f $ForProfile, $envTarget)
}

function Invoke-MailHawkChat {
    <#
    .SYNOPSIS
      Call GenAi or Grok endpoint (same shape as Cascade Invoke-CascadeChat).
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

    $cfg = Get-MailHawkLlmConfig -Profile $Profile
    if ($Model) {
        $cfg = [pscustomobject]@{ Profile = $cfg.Profile; Url = $cfg.Url; Model = $Model }
    }

    $token = Get-MailHawkLlmToken -ForProfile $cfg.Profile
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

    Write-Host ("[*] MailHawk LLM  profile={0}  model={1}" -f $cfg.Profile, $cfg.Model) -ForegroundColor DarkCyan
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

    # Normalize text extraction
    $text = $null
    if ($resp.choices -and $resp.choices[0].message.content) {
        $text = [string]$resp.choices[0].message.content
    }
    elseif ($resp.choices -and $resp.choices[0].text) {
        $text = [string]$resp.choices[0].text
    }
    elseif ($resp.candidates -and $resp.candidates[0].content.parts) {
        $text = ($resp.candidates[0].content.parts | ForEach-Object { $_.text }) -join ''
    }
    elseif ($resp.content) {
        $text = [string]$resp.content
    }

    return [pscustomobject]@{
        Profile  = $cfg.Profile
        Model    = $cfg.Model
        Raw      = $resp
        Text     = $text
    }
}
