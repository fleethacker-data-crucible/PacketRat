"""Static development checks. Does not execute PowerShell or access Outlook."""
from pathlib import Path
from PIL import Image
ROOT=Path(__file__).resolve().parents[1]
SERVICE=(ROOT/'Start-MailHawk-Web.ps1').read_text()
CLIENT=(ROOT/'Web/app.js').read_text()
HTML=(ROOT/'Web/index.html').read_text()
assert '[Net.IPAddress]::Loopback' in SERVICE
assert "'/api/status'" in SERVICE and "'/api/open-draft'" in SERVICE
assert "'/api/report/generate'" in SERVICE and "'/api/report/track'" in SERVICE
assert "Find-MailHawkReportSource" in SERVICE
assert "'report-experience.js'" in SERVICE
assert (ROOT/'Private/MailHawkReport.ps1').is_file()
assert (ROOT/'Web/report-experience.js').is_file()
assert "'/api/credentials'" in SERVICE and "'/api/credentials/check'" in SERVICE
assert "'mailhawk-logo.png'" in SERVICE and "'mailhawk-icon.png'" in SERVICE
assert 'Read-MailHawkBody' in SERVICE and '$Stream.Read($buffer' in SERVICE
assert 'X-Content-Type-Options: nosniff' in SERVICE
assert "'POST'" in SERVICE
COM=(ROOT/'Private/Get-OutlookMailSummary.ps1').read_text()
assert '$reply.Display()' in COM and '$reply.HTMLBody=Join-MailHawkReplyHtml' in COM
assert '$reply.Send(' not in COM and '$reply.Send(' not in SERVICE
assert 'New-MailHawkOutlookReplyDraft' in SERVICE
assert (ROOT/'Private/MailHawkProtocol.ps1').exists()
assert 'ConvertFrom-MailHawkDraftV1' in (ROOT/'Private/MailHawkDraft.ps1').read_text()
assert 'ConvertFrom-MailHawkReportV1' in (ROOT/'Public/Invoke-MailHawkInboxAnalysis.ps1').read_text()
assert "?demo=1" in CLIENT or "'demo'" in CLIENT
assert '__MAILHAWK_NONCE__' in HTML
assert 'id="credentialToken"' in HTML and 'type="password"' in HTML
assert "credentialSource" in CLIENT and "credentials/clear" in CLIENT
assert (ROOT/'Web/mailhawk-logo.png').is_file()
assert Image.open(ROOT/'Web/mailhawk-icon.png').size==(320,320)
assert not (ROOT/'Logs').exists(), 'Local user email records must not ship.'
LLM=(ROOT/'Private/MailHawkLlm.ps1').read_text()
assert 'MailHawkManualTokens' in LLM and "MailHawkCredentialSource" in LLM
assert 'Write-MailHawkLog' not in LLM, 'No credential logging in LLM bridge'
assert (ROOT/'MailHawk.bat').exists() and (ROOT/'MailHawk-CLI.bat').exists()
LIFE=(ROOT/'Private/MailHawkLifecycle.ps1').read_text()
assert "'/api/heartbeat'" in SERVICE and "'/api/session/stop'" in SERVICE
assert 'MailHawkLifecycle' in SERVICE and 'Write-MailHawkRuntimeFile' in SERVICE and 'Remove-MailHawkRuntimeFile' in SERVICE
assert 'mailhawk-server-' in LIFE and 'MAILHAWK_AUTO_STOP' in LIFE
assert 'Nonce' not in LIFE, 'Runtime files must never carry the session nonce'
assert "navigator.sendBeacon('/api/heartbeat'" in CLIENT and "'pagehide'" in CLIENT
assert 'id="endSession"' in HTML
assert (ROOT/'Stop-MailHawk.ps1').is_file()
assert 'MAILHAWK_AUTO_STOP' in (ROOT/'Config/mailhawk.env.example').read_text()
print('Source and asset contract checks passed')
