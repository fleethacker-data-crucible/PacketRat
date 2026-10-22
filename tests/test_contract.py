"""Static development checks. Does not execute PowerShell or access Outlook."""
from pathlib import Path
from PIL import Image
ROOT=Path(__file__).resolve().parents[1]
SERVICE=(ROOT/'Start-MailHawk-Web.ps1').read_text()
CLIENT=(ROOT/'Web/app.js').read_text()
HTML=(ROOT/'Web/index.html').read_text()
assert '[Net.IPAddress]::Loopback' in SERVICE
assert "'/api/status'" in SERVICE and "'/api/open-draft'" in SERVICE
assert "'/api/credentials'" in SERVICE and "'/api/credentials/check'" in SERVICE
assert "'mailhawk-logo.png'" in SERVICE and "'mailhawk-icon.png'" in SERVICE
assert 'Read-MailHawkBody' in SERVICE and '$Stream.Read($buffer' in SERVICE
assert 'X-Content-Type-Options: nosniff' in SERVICE
assert "'POST'" in SERVICE
assert '$reply.Display()' in SERVICE and '$reply.Send(' not in SERVICE
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
print('Source and asset contract checks passed')
