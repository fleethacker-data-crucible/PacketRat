#requires -Version 5.1
# Local deterministic tests: do not contact Outlook, Lazarette or an LLM.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Private/PacketRatStore.ps1')
. (Join-Path $root 'Private/PacketRatRules.ps1')
. (Join-Path $root 'Private/PacketRatProtocol.ps1')
. (Join-Path $root 'Private/PacketRatDraft.ps1')
. (Join-Path $root 'Private/LazaretteBridge.ps1')
. (Join-Path $root 'Private/PacketRatLlm.ps1')

function Assert-PacketRat($Condition,[string]$Message) {
    if(-not $Condition){throw "Test failure: $Message"}
}
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('mh-test-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testRoot -Force)
$savedOrgDomain=$env:PACKETRAT_ORG_DOMAIN
try {
    $env:PACKETRAT_ORG_DOMAIN='agency.example'
    $store=Get-PacketRatStore -Root $testRoot
    Assert-PacketRat (@($store.Rules).Count -ge 4) 'default rules'
    $messages=@(
        [pscustomobject]@{Index=1;Fingerprint='test-one';EntryID='1';FromName='Reviewer';FromEmail='reviewer@agency.example';Subject='Please approve this task';BodyPreview='Need response';IsDirect=$true;AppearsReplied=$false;UserDismissed=$false;IsSensitive=$false},
        [pscustomobject]@{Index=2;Fingerprint='test-two';EntryID='2';FromName='Digest';FromEmail='no-reply@example.com';Subject='Weekly digest';BodyPreview='FYI news only';IsDirect=$false;AppearsReplied=$false;UserDismissed=$false;IsSensitive=$false},
        [pscustomobject]@{Index=3;Fingerprint='test-three';EntryID='3';FromName='Team';FromEmail='team@agency.example';Subject='News and updates';BodyPreview='No action requested';IsDirect=$false;AppearsReplied=$false;UserDismissed=$false;IsSensitive=$false}
    )
    $suggest=@([pscustomobject]@{Index=2;Key='test-two';EntryID='2';From='Digest';Subject='Weekly digest';Why='Model false positive';Urgency='High'})
    $result=Invoke-PacketRatRuleTriage -Emails $messages -Suggested $suggest -Store $store
    Assert-PacketRat (@($result.Items | Where-Object Key -eq 'test-one').Count -eq 1) 'direct organization request included'
    Assert-PacketRat (@($result.Items | Where-Object Key -eq 'test-one')[0].Urgency -eq 'High') 'direct organization request escalated'
    Assert-PacketRat (@($result.Items | Where-Object Key -eq 'test-three').Count -eq 0) 'unrequested organization message not escalated'
    Assert-PacketRat (@($result.SuppressedKeys).Count -eq 1) 'automated false positive suppressed'
    $store=Merge-PacketRatChecklist -Store $store -Items @($result.Items) -Root $testRoot
    $store=Set-PacketRatChecklistPriority -Store $store -Key 'test-one' -Urgency Low -Root $testRoot
    $store=Merge-PacketRatChecklist -Store $store -Items @($result.Items) -Root $testRoot
    Assert-PacketRat (@($store.Checklist | Where-Object Key -eq 'test-one')[0].Urgency -eq 'Low') 'manual priority survives reanalysis'
    $store=Clear-PacketRatChecklistPriorityOverride -Store $store -Key 'test-one' -Root $testRoot
    Assert-PacketRat (@($store.Checklist | Where-Object Key -eq 'test-one')[0].Urgency -eq 'High') 'AI/rule priority restored'
    # Without a configured organization domain the organization rules never match.
    $env:PACKETRAT_ORG_DOMAIN=''
    $unset=Invoke-PacketRatRuleTriage -Emails $messages -Suggested @() -Store $store
    Assert-PacketRat (@($unset.Items | Where-Object Key -eq 'test-one')[0].Urgency -eq 'Medium') 'organization rule inert when no domain is configured'
    $env:PACKETRAT_ORG_DOMAIN='other.example, agency.example'
    $orgRule=[pscustomobject]@{Id='org';Name='Any org sender';Enabled=$true;Match='OrgSender';Value='';Effect='Low'}
    Assert-PacketRat (Test-PacketRatRule -Rule $orgRule -Mail $messages[2]) 'organization sender matched from a domain list'
    Assert-PacketRat (-not (Test-PacketRatRule -Rule $orgRule -Mail $messages[1])) 'other domain not matched'
    $store=Set-PacketRatRules -Store $store -Rules @(
      [pscustomobject]@{Id='custom-domain';Name='Review agency domains';Enabled=$true;Match='SenderDomain';Value='agency.example';Effect='Medium'},
      [pscustomobject]@{Id='org-rule';Name='Organization rule';Enabled=$true;Match='OrgSender';Value='';Effect='High'}
    ) -Root $testRoot
    $saved=@((Get-PacketRatStore -Root $testRoot).Rules)
    Assert-PacketRat ($saved.Count -eq 2) 'custom rules persisted'
    # AI profile names, endpoint configuration and vault item names (no network, no real vault).
    Assert-PacketRat ((ConvertTo-PacketRatLlmProfile -Profile 'AiEndpoint') -eq 'AiEndpoint') 'AiEndpoint profile accepted'
    Assert-PacketRat ((ConvertTo-PacketRatLlmProfile -Profile 'grok') -eq 'Grok') 'profile names are case-insensitive'
    $threw=$false;try{$null=ConvertTo-PacketRatLlmProfile -Profile 'Nope'}catch{$threw=$true}
    Assert-PacketRat $threw 'unknown profile rejected'
    $envNames=@('PACKETRAT_ROUTER','LLM_URL','LLM_MODEL','PACKETRAT_AI_ENDPOINT_URL','PACKETRAT_GROK_URL','PACKETRAT_LAZARETTE_ITEM_AiEndpoint','DATABRICKS_TOKEN','LLM_TOKEN')+@($script:PacketRatLlmTokenEnv.AiEndpoint)+@($script:PacketRatLlmVaultItems.AiEndpoint.EnvKeys)
    $savedEnv=@{};foreach($n in $envNames){$savedEnv[$n]=[Environment]::GetEnvironmentVariable($n);[Environment]::SetEnvironmentVariable($n,$null)}
    $env:PACKETRAT_ROUTER='direct'   # these checks are about the direct profile endpoints; Fairlead as the default is tested in Test-PacketRatFairleadDefault.ps1
    try{
        # Default: the local phoenix-lai API on loopback, with its loaded-model name.
        $cfg=Get-PacketRatLlmConfig -Profile AiEndpoint
        Assert-PacketRat ($cfg.Profile -eq 'AiEndpoint' -and $cfg.Url -eq 'http://127.0.0.1:1234/v1/chat/completions') 'AiEndpoint defaults to local phoenix-lai'
        Assert-PacketRat ($cfg.DefaultUrl -and $cfg.Model -eq 'phoenixlai') 'local default uses the loaded phoenix-lai model'
        Assert-PacketRat (Test-PacketRatLoopbackUrl -Url $cfg.Url) 'default endpoint is loopback'
        Assert-PacketRat (-not (Test-PacketRatLoopbackUrl -Url 'https://ai.example.org/v1/chat/completions')) 'remote URL is not loopback'
        Assert-PacketRat ((Get-PacketRatLlmConfig -Profile Auto).Url -eq $cfg.Url) 'Auto with no tokens uses the local default'
        Assert-PacketRat ($null -eq (Get-PacketRatLlmAuthToken -Config $cfg)) 'no token needed for the local default'
        # No token: the request goes out with no Authorization header (never an empty Bearer).
        $global:sentHeaders=$null;$global:sentUri=$null
        function global:Invoke-RestMethod { param($Uri,$Method,$Headers,$Body,$ContentType,$TimeoutSec) $global:sentUri=$Uri;$global:sentHeaders=$Headers;return [pscustomobject]@{choices=@([pscustomobject]@{message=[pscustomobject]@{content='ok'}})} }
        try{
            $reply=Invoke-PacketRatChat -Messages @(@{role='user';content='x'}) -Profile AiEndpoint
            Assert-PacketRat ($reply.Text -eq 'ok' -and $global:sentUri -eq 'http://127.0.0.1:1234/v1/chat/completions') 'chat posts to the local default'
            Assert-PacketRat (-not $global:sentHeaders.ContainsKey('Authorization')) 'no Authorization header without a token'
            $env:LLM_TOKEN='local-key'
            $null=Invoke-PacketRatChat -Messages @(@{role='user';content='x'}) -Profile AiEndpoint
            Assert-PacketRat ($global:sentHeaders['Authorization'] -eq 'Bearer local-key') 'optional token sent to the local endpoint when set'
            $env:LLM_TOKEN=$null
        }finally{ Remove-Item Function:\Invoke-RestMethod -ErrorAction SilentlyContinue }
        # Overrides: the profile variable replaces the default; the shared LLM_URL wins over both.
        $env:PACKETRAT_AI_ENDPOINT_URL='https://ai.example.org/v1/chat/completions/'
        $cfg=Get-PacketRatLlmConfig -Profile AiEndpoint
        Assert-PacketRat ($cfg.Url -eq 'https://ai.example.org/v1/chat/completions' -and -not $cfg.DefaultUrl -and $cfg.Model -ne 'phoenixlai') 'PACKETRAT_AI_ENDPOINT_URL overrides the default'
        $env:LLM_URL='http://localhost:5000/v1/chat/completions'
        Assert-PacketRat ((Get-PacketRatLlmConfig -Profile AiEndpoint).Url -eq $env:LLM_URL) 'LLM_URL overrides every profile'
        $env:LLM_URL=$null;$env:PACKETRAT_AI_ENDPOINT_URL=$null
        # Grok is an outside provider: no built-in URL, explained before any token or network use.
        Assert-PacketRat ((Get-PacketRatLlmConfig -Profile Grok).Url -eq '') 'no Grok URL is built in'
        $threw='';try{$null=Invoke-PacketRatChat -Messages @(@{role='user';content='x'}) -Profile Grok}catch{$threw=$_.Exception.Message}
        Assert-PacketRat ($threw -match 'PACKETRAT_GROK_URL') 'missing Grok URL explained before any token or network use'
        $env:PACKETRAT_GROK_URL='https://databricks.example.org/serving-endpoints/x/invocations'
        Assert-PacketRat ((Get-PacketRatLlmConfig -Profile Grok).Url -eq $env:PACKETRAT_GROK_URL) 'Grok URL read from configuration'
        # Token environment: AI_ENDPOINT_TOKEN is the AiEndpoint variable.
        $env:AI_ENDPOINT_TOKEN='current-value'
        Assert-PacketRat ((Get-PacketRatLlmToken -ForProfile AiEndpoint) -eq 'current-value') 'AI_ENDPOINT_TOKEN read'
        Assert-PacketRat ((Get-PacketRatLlmConfig -Profile Auto).Profile -eq 'AiEndpoint') 'Auto resolves to AiEndpoint when its token is set'
        # Vault items: names emitted and read.
        Assert-PacketRat ((Resolve-PacketRatLazaretteServiceName -Profile AiEndpoint) -eq 'ai-endpoint-api') 'AI endpoint item name'
        Assert-PacketRat ((Resolve-PacketRatLazaretteServiceName -Profile Grok) -eq 'grok-api') 'Grok item name'
        $env:PACKETRAT_LAZARETTE_ITEM_AiEndpoint='new-override'
        Assert-PacketRat ((Resolve-PacketRatLazaretteServiceName -Profile AiEndpoint) -eq 'new-override') 'item override read'
        $script:fakeVault=@{}
        foreach($spec in $script:PacketRatLlmVaultItems.Values){$script:fakeVault[$spec.Name]='secret-'+$spec.Name}
        function global:Get-LazaretteSecret { param([string]$Service) if($script:fakeVault.ContainsKey($Service)){return $script:fakeVault[$Service]}; throw 'not found' }
        function global:Test-LazaretteVaultUnlocked { $true }
        try{
            Assert-PacketRat ((Get-PacketRatLazaretteSecretByName -ServiceName 'ai-endpoint-api') -eq 'secret-ai-endpoint-api') 'AI endpoint item read from the vault'
            Assert-PacketRat ((Get-PacketRatLazaretteSecretByName -ServiceName 'grok-api') -eq 'secret-grok-api') 'Grok item read from the vault'
            Assert-PacketRat ($null -eq (Get-PacketRatLazaretteSecretByName -ServiceName 'custom-item')) 'an unknown item name returns nothing'
        }finally{
            Remove-Item Function:\Get-LazaretteSecret,Function:\Test-LazaretteVaultUnlocked -ErrorAction SilentlyContinue
        }
    }finally{
        foreach($n in $savedEnv.Keys){[Environment]::SetEnvironmentVariable($n,$savedEnv[$n])}
    }
    # Wire-envelope and Outlook-signature tests run in Test-PacketRatProtocol.ps1.
    Write-Host 'PacketRat local rules and draft parsing tests passed' -ForegroundColor Green
} finally {
    $env:PACKETRAT_ORG_DOMAIN=$savedOrgDomain
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
