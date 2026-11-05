"""Static development checks. Does not execute PowerShell or access Outlook."""
import re
from pathlib import Path
from PIL import Image
ROOT=Path(__file__).resolve().parents[1]
# The browser server plus its command core (Private/PacketRatApi.ps1, shared with the CLI since CLI parity).
SERVICE=(ROOT/'Start-PacketRat-Web.ps1').read_text()+(ROOT/'Private/PacketRatApi.ps1').read_text()
CLIENT=(ROOT/'Web/app.js').read_text()
HTML=(ROOT/'Web/index.html').read_text()
assert '[Net.IPAddress]::Loopback' in SERVICE
assert "'/api/status'" in SERVICE and "'/api/open-draft'" in SERVICE
assert "'/api/report/generate'" in SERVICE and "'/api/report/track'" in SERVICE
assert "Find-PacketRatReportSource" in SERVICE
assert "'report-experience.js'" in SERVICE
assert (ROOT/'Private/PacketRatReport.ps1').is_file()
assert (ROOT/'Web/report-experience.js').is_file()
assert "'/api/credentials/check'" in SERVICE and "'/api/credentials/status'" in SERVICE
assert "'/api/credentials/clear'" not in SERVICE and "Route -eq '/api/credentials'" not in SERVICE
# Fleet UI assets are on the served allow-list.
for asset in ('shell.js','icons.js','vendor/fleet/fleet.css','brand/mark.svg','brand/emblem-dark.png','brand/emblem-light.png'):
    assert "'"+asset+"'" in SERVICE, asset
    assert (ROOT/'Web'/asset).is_file(), asset
assert "'.svg'='image/svg+xml" in SERVICE
assert 'packetrat-logo.png' not in SERVICE and 'packetrat-icon.png' not in SERVICE
assert 'Read-PacketRatBody' in SERVICE and '$Stream.Read($buffer' in SERVICE
assert 'X-Content-Type-Options: nosniff' in SERVICE
assert "'POST'" in SERVICE
COM=(ROOT/'Private/Get-OutlookMailSummary.ps1').read_text()
assert '$reply.Display()' in COM and '$reply.HTMLBody=Join-PacketRatReplyHtml' in COM
assert '$reply.Send(' not in COM and '$reply.Send(' not in SERVICE
assert 'New-PacketRatOutlookReplyDraft' in SERVICE
assert (ROOT/'Private/PacketRatProtocol.ps1').exists()
assert 'ConvertFrom-PacketRatDraftV1' in (ROOT/'Private/PacketRatDraft.ps1').read_text()
assert 'ConvertFrom-PacketRatReportV1' in (ROOT/'Public/Invoke-PacketRatInboxAnalysis.ps1').read_text()
assert "?demo=1" in CLIENT or "'demo'" in CLIENT
assert '__PACKETRAT_NONCE__' in HTML
assert 'id="credentialToken"' not in HTML and 'type="password"' not in HTML, 'PacketRat accepts no pasted tokens'
assert 'id="checkCredentials"' in HTML
assert "credentials/check" in CLIENT and "credentials/clear" not in CLIENT and "credentialSource" not in CLIENT
assert Image.open(ROOT/'Web/brand/emblem-dark.png').size==Image.open(ROOT/'Web/brand/emblem-light.png').size
assert (ROOT/'Web/brand/mark.svg').read_bytes()==(ROOT/'assets/brand/mark.svg').read_bytes(), 'Served mark matches assets/brand'
assert 'data-app="packetrat"' in HTML and HTML.index('vendor/fleet/fleet.css')<HTML.index('href="style.css"')
assert not (ROOT/'Logs').exists(), 'Local user email records must not ship.'
LLM=(ROOT/'Private/PacketRatLlm.ps1').read_text()
assert 'Fairlead/' in LLM and 'PacketRatManualTokens' not in LLM and 'PacketRatCredentialSource' not in LLM
assert 'AI_ENDPOINT' not in LLM and 'DATABRICKS' not in LLM and 'LLM_URL' not in LLM
assert 'Write-PacketRatLog' not in LLM, 'No credential logging in LLM bridge'
assert (ROOT/'Launch-PacketRat.bat').exists() and (ROOT/'PacketRat-CLI.bat').exists()
assert not (ROOT/'Private/LazaretteBridge.ps1').exists(), 'PacketRat reads no vault: its only credential is the Fairlead key in Credential Manager'
LLMSRC=(ROOT/'Private/PacketRatLlm.ps1').read_text()
assert 'https://' not in LLMSRC, 'No organization endpoint is hard-coded'
assert "Url     = 'http://127.0.0.1:8776/v1/chat/completions'" in LLMSRC, 'Fairlead on this PC is the only default'
assert 'Fairlead/' in LLMSRC and 'X-Fairlead-Label' in LLMSRC
assert set(re.findall(r"https?://([^/:'\"\s]+)",LLMSRC))=={'127.0.0.1'}, 'Only loopback is built in'
LIFE=(ROOT/'Private/PacketRatLifecycle.ps1').read_text()
assert "'/api/heartbeat'" in SERVICE and "'/api/session/stop'" in SERVICE
assert 'PacketRatLifecycle' in SERVICE and 'Write-PacketRatRuntimeFile' in SERVICE and 'Remove-PacketRatRuntimeFile' in SERVICE
assert 'packetrat-server-' in LIFE and 'PACKETRAT_AUTO_STOP' in LIFE
assert 'Nonce' not in LIFE, 'Runtime files must never carry the session nonce'
assert "navigator.sendBeacon('/api/heartbeat'" in CLIENT and "'pagehide'" in CLIENT
assert 'id="endSession"' in HTML
assert (ROOT/'Stop-PacketRat.ps1').is_file()
assert 'PACKETRAT_AUTO_STOP' in (ROOT/'Config/packetrat.env.example').read_text()
# Saved preferences are written as {provider, folder, ...} and must be read back under the same names (the mail folder field is mailFolder).
assert "[['provider','provider'],['mailFolder','folder'],['maxEmails','maxEmails'],['daysBack','daysBack']]" in CLIENT, 'loadSettings must read folder back into mailFolder'
print('Source and asset contract checks passed')
