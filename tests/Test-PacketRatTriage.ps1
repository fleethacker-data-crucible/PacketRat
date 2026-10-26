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
    # Rules saved under the former match names keep working and are saved under the new names.
    $legacyNames=@($script:PacketRatRuleMatchAliases.Keys)
    Assert-PacketRat ($legacyNames.Count -eq 2) 'legacy rule match aliases defined'
    foreach($legacyName in $legacyNames){
        $legacyRule=[pscustomobject]@{Id='legacy';Name='Legacy';Enabled=$true;Match=$legacyName;Value='';Effect='Low'}
        Assert-PacketRat (Test-PacketRatRule -Rule $legacyRule -Mail $messages[0]) ('legacy match name evaluated: '+$legacyName)
    }
    $store=Set-PacketRatRules -Store $store -Rules @(
      [pscustomobject]@{Id='custom-domain';Name='Review agency domains';Enabled=$true;Match='SenderDomain';Value='agency.example';Effect='Medium'},
      [pscustomobject]@{Id='legacy-rule';Name='Legacy organization rule';Enabled=$true;Match=$legacyNames[0];Value='';Effect='High'}
    ) -Root $testRoot
    $saved=@((Get-PacketRatStore -Root $testRoot).Rules)
    Assert-PacketRat ($saved.Count -eq 2) 'custom rules persisted'
    Assert-PacketRat (@($saved | Where-Object { $script:PacketRatRuleMatchAliases.ContainsKey([string]$_.Match) }).Count -eq 0) 'legacy match names saved under the new names'
    # AI profile names, endpoint configuration and vault item names (no network, no real vault).
    $profileAlias=@($script:PacketRatLlmProfileAliases.Keys)[0]
    Assert-PacketRat ((ConvertTo-PacketRatLlmProfile -Profile $profileAlias) -eq 'AiEndpoint') 'deprecated profile name maps to AiEndpoint'
    Assert-PacketRat ((ConvertTo-PacketRatLlmProfile -Profile 'grok') -eq 'Grok') 'profile names are case-insensitive'
    $threw=$false;try{$null=ConvertTo-PacketRatLlmProfile -Profile 'Nope'}catch{$threw=$true}
    Assert-PacketRat $threw 'unknown profile rejected'
    $envNames=@('LLM_URL','LLM_MODEL','PACKETRAT_AI_ENDPOINT_URL','PACKETRAT_GROK_URL','PACKETRAT_LAZARETTE_ITEM_AiEndpoint','DATABRICKS_TOKEN','LLM_TOKEN')+@($script:PacketRatLlmTokenEnv.AiEndpoint)+@($script:PacketRatLlmVaultItems.AiEndpoint.EnvKeys)
    $savedEnv=@{};foreach($n in $envNames){$savedEnv[$n]=[Environment]::GetEnvironmentVariable($n);[Environment]::SetEnvironmentVariable($n,$null)}
    try{
        $cfg=Get-PacketRatLlmConfig -Profile $profileAlias
        Assert-PacketRat ($cfg.Profile -eq 'AiEndpoint' -and $cfg.Url -eq '') 'no endpoint URL is built in'
        $threw='';try{$null=Invoke-PacketRatChat -Messages @(@{role='user';content='x'}) -Profile AiEndpoint}catch{$threw=$_.Exception.Message}
        Assert-PacketRat ($threw -match 'PACKETRAT_AI_ENDPOINT_URL') 'missing endpoint URL explained before any token or network use'
        $env:PACKETRAT_GROK_URL='https://databricks.example.org/serving-endpoints/x/invocations'
        Assert-PacketRat ((Get-PacketRatLlmConfig -Profile Grok).Url -eq $env:PACKETRAT_GROK_URL) 'Grok URL read from configuration'
        # Token environment: the current name wins, the deprecated name is still read.
        $legacyTokenEnv=$script:PacketRatLlmTokenEnv.AiEndpoint[1]
        [Environment]::SetEnvironmentVariable($legacyTokenEnv,'legacy-value')
        Assert-PacketRat ((Get-PacketRatLlmToken -ForProfile AiEndpoint) -eq 'legacy-value') 'deprecated token variable still read'
        $env:AI_ENDPOINT_TOKEN='current-value'
        Assert-PacketRat ((Get-PacketRatLlmToken -ForProfile $profileAlias) -eq 'current-value') 'current token variable preferred'
        Assert-PacketRat ((Get-PacketRatLlmConfig -Profile Auto).Profile -eq 'AiEndpoint') 'Auto resolves to AiEndpoint when its token is set'
        # Vault items: canonical names emitted; a vault that only has the former item names still works.
        Assert-PacketRat ((Resolve-PacketRatLazaretteServiceName -Profile AiEndpoint) -eq 'ai-endpoint-api') 'canonical AI endpoint item'
        Assert-PacketRat ((Resolve-PacketRatLazaretteServiceName -Profile Grok) -eq 'grok-api') 'canonical Grok item'
        [Environment]::SetEnvironmentVariable($script:PacketRatLlmVaultItems.AiEndpoint.EnvKeys[1],'old-override')
        Assert-PacketRat ((Resolve-PacketRatLazaretteServiceName -Profile AiEndpoint) -eq 'old-override') 'deprecated item override still read'
        $env:PACKETRAT_LAZARETTE_ITEM_AiEndpoint='new-override'
        Assert-PacketRat ((Resolve-PacketRatLazaretteServiceName -Profile AiEndpoint) -eq 'new-override') 'current item override preferred'
        $script:fakeVault=@{}
        foreach($spec in $script:PacketRatLlmVaultItems.Values){$script:fakeVault[$spec.Legacy[0]]='secret-'+$spec.Name}
        function global:Get-LazaretteSecret { param([string]$Service) if($script:fakeVault.ContainsKey($Service)){return $script:fakeVault[$Service]}; throw 'not found' }
        function global:Test-LazaretteVaultUnlocked { $true }
        try{
            Assert-PacketRat ((Get-PacketRatLazaretteSecretByName -ServiceName 'ai-endpoint-api') -eq 'secret-ai-endpoint-api') 'former AI endpoint item found when the canonical item is absent'
            Assert-PacketRat ((Get-PacketRatLazaretteSecretByName -ServiceName 'grok-api') -eq 'secret-grok-api') 'former Grok item found when the canonical item is absent'
            Assert-PacketRat ($null -eq (Get-PacketRatLazaretteSecretByName -ServiceName 'custom-item')) 'custom names get no aliases'
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
