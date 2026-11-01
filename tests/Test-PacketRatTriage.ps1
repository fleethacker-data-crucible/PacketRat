#requires -Version 5.1
# Local deterministic tests: do not contact Outlook or an LLM.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Private/PacketRatStore.ps1')
. (Join-Path $root 'Private/PacketRatRules.ps1')
. (Join-Path $root 'Private/PacketRatProtocol.ps1')
. (Join-Path $root 'Private/PacketRatDraft.ps1')
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
    # The AI client talks only to Fairlead on this PC (no network here; the full checks are in Test-PacketRatFairlead.ps1).
    $envNames=@('PACKETRAT_FAIRLEAD_URL','PACKETRAT_FAIRLEAD_MODEL','PACKETRAT_FAIRLEAD_PRIVACY')
    $savedEnv=@{};foreach($n in $envNames){$savedEnv[$n]=[Environment]::GetEnvironmentVariable($n);[Environment]::SetEnvironmentVariable($n,$null)}
    try{
        $cfg=Get-PacketRatFairleadConfig
        Assert-PacketRat ($cfg.Url -eq 'http://127.0.0.1:8776/v1/chat/completions' -and $cfg.Model -eq 'auto') 'the AI client defaults to Fairlead on this PC with the auto route'
        Assert-PacketRat (Test-PacketRatLoopbackUrl -Url $cfg.Url) 'the default address is loopback'
        Assert-PacketRat (-not (Test-PacketRatLoopbackUrl -Url 'https://ai.example.org/v1/chat/completions')) 'a remote URL is not loopback'
        $env:PACKETRAT_FAIRLEAD_URL='https://ai.example.org/v1/chat/completions'
        $threw='';try{$null=Get-PacketRatFairleadConfig}catch{$threw=$_.Exception.Message}
        Assert-PacketRat ($threw -match 'on this PC') 'a Fairlead address that is not on this PC is refused'
    }finally{
        foreach($n in $savedEnv.Keys){[Environment]::SetEnvironmentVariable($n,$savedEnv[$n])}
    }
    # Wire-envelope and Outlook-signature tests run in Test-PacketRatProtocol.ps1.
    Write-Host 'PacketRat local rules and draft parsing tests passed' -ForegroundColor Green
} finally {
    $env:PACKETRAT_ORG_DOMAIN=$savedOrgDomain
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
