#requires -Version 5.1
# Local deterministic tests: do not contact Outlook, ARC or an LLM.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Private/MailHawkStore.ps1')
. (Join-Path $root 'Private/MailHawkRules.ps1')
. (Join-Path $root 'Private/MailHawkProtocol.ps1')
. (Join-Path $root 'Private/MailHawkDraft.ps1')

function Assert-MailHawk($Condition,[string]$Message) {
    if(-not $Condition){throw "Test failure: $Message"}
}
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('mh-test-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testRoot -Force)
try {
    $store=Get-MailHawkStore -Root $testRoot
    Assert-MailHawk (@($store.Rules).Count -ge 4) 'default rules'
    $messages=@(
        [pscustomobject]@{Index=1;Fingerprint='test-one';EntryID='1';FromName='Reviewer';FromEmail='reviewer@navy.mil';Subject='Please approve this task';BodyPreview='Need response';IsDirect=$true;AppearsReplied=$false;UserDismissed=$false;IsSensitive=$false},
        [pscustomobject]@{Index=2;Fingerprint='test-two';EntryID='2';FromName='Digest';FromEmail='no-reply@example.com';Subject='Weekly digest';BodyPreview='FYI news only';IsDirect=$false;AppearsReplied=$false;UserDismissed=$false;IsSensitive=$false},
        [pscustomobject]@{Index=3;Fingerprint='test-three';EntryID='3';FromName='Team';FromEmail='team@navy.mil';Subject='News and updates';BodyPreview='No action requested';IsDirect=$false;AppearsReplied=$false;UserDismissed=$false;IsSensitive=$false}
    )
    $suggest=@([pscustomobject]@{Index=2;Key='test-two';EntryID='2';From='Digest';Subject='Weekly digest';Why='Model false positive';Urgency='High'})
    $result=Invoke-MailHawkRuleTriage -Emails $messages -Suggested $suggest -Store $store
    Assert-MailHawk (@($result.Items | Where-Object Key -eq 'test-one').Count -eq 1) 'direct mil request included'
    Assert-MailHawk (@($result.Items | Where-Object Key -eq 'test-one')[0].Urgency -eq 'High') 'direct mil escalated'
    Assert-MailHawk (@($result.Items | Where-Object Key -eq 'test-three').Count -eq 0) 'unrequested mil message not escalated'
    Assert-MailHawk (@($result.SuppressedKeys).Count -eq 1) 'automated false positive suppressed'
    $store=Merge-MailHawkChecklist -Store $store -Items @($result.Items) -Root $testRoot
    $store=Set-MailHawkChecklistPriority -Store $store -Key 'test-one' -Urgency Low -Root $testRoot
    $store=Merge-MailHawkChecklist -Store $store -Items @($result.Items) -Root $testRoot
    Assert-MailHawk (@($store.Checklist | Where-Object Key -eq 'test-one')[0].Urgency -eq 'Low') 'manual priority survives reanalysis'
    $store=Clear-MailHawkChecklistPriorityOverride -Store $store -Key 'test-one' -Root $testRoot
    Assert-MailHawk (@($store.Checklist | Where-Object Key -eq 'test-one')[0].Urgency -eq 'High') 'AI/rule priority restored'
    $store=Set-MailHawkRules -Store $store -Rules @(
      [pscustomobject]@{Id='custom-domain';Name='Review navy domains';Enabled=$true;Match='SenderDomain';Value='navy.mil';Effect='Medium'}
    ) -Root $testRoot
    Assert-MailHawk (@((Get-MailHawkStore -Root $testRoot).Rules).Count -eq 1) 'custom rule persisted'
    # Wire-envelope and Outlook-signature tests run in Test-MailHawkProtocol.ps1.
    Write-Host 'MailHawk local rules and draft parsing tests passed' -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
