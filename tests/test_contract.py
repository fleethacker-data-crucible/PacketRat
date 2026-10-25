"""Static development checks. Does not execute PowerShell or access Outlook."""
from pathlib import Path
from PIL import Image
ROOT=Path(__file__).resolve().parents[1]
SERVICE=(ROOT/'Start-PacketRat-Web.ps1').read_text()
CLIENT=(ROOT/'Web/app.js').read_text()
HTML=(ROOT/'Web/index.html').read_text()
assert '[Net.IPAddress]::Loopback' in SERVICE
assert "'/api/status'" in SERVICE and "'/api/open-draft'" in SERVICE
assert "'/api/report/generate'" in SERVICE and "'/api/report/track'" in SERVICE
assert "Find-PacketRatReportSource" in SERVICE
assert "'report-experience.js'" in SERVICE
assert (ROOT/'Private/PacketRatReport.ps1').is_file()
assert (ROOT/'Web/report-experience.js').is_file()
assert "'/api/credentials'" in SERVICE and "'/api/credentials/check'" in SERVICE
assert "'packetrat-logo.png'" in SERVICE and "'packetrat-icon.png'" in SERVICE
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
assert 'id="credentialToken"' in HTML and 'type="password"' in HTML
assert "credentialSource" in CLIENT and "credentials/clear" in CLIENT
assert (ROOT/'Web/packetrat-logo.png').is_file()
assert Image.open(ROOT/'Web/packetrat-icon.png').size==(320,320)
assert not (ROOT/'Logs').exists(), 'Local user email records must not ship.'
LLM=(ROOT/'Private/PacketRatLlm.ps1').read_text()
assert 'PacketRatManualTokens' in LLM and "PacketRatCredentialSource" in LLM
assert 'Write-PacketRatLog' not in LLM, 'No credential logging in LLM bridge'
assert (ROOT/'Launch-PacketRat.bat').exists() and (ROOT/'PacketRat-CLI.bat').exists()
BRIDGE=(ROOT/'Private/LazaretteBridge.ps1').read_text()
# Lazarette (formerly ARC) consumer contract: new names first, former names as fallbacks.
order=['$env:LAZARETTE_PATH','$env:ARC_PATH',"'LAZARETTE_PATH', 'ARC_PATH'","'Lazarette')","'ARC')"]
positions=[BRIDGE.index(x) for x in order]
assert positions==sorted(positions), 'Lazarette must be resolved before ARC'
assert BRIDGE.index("'Get-LazaretteSecret', 'Get-ArcSecret'") < BRIDGE.index('Get-PmStarkApiKey -ServiceName')
assert "'Lazarette.ps1', 'Arc.ps1'" in BRIDGE, 'Discovery by lib\\Lazarette.ps1 / lib\\Arc.ps1 (ARC 5)'
assert BRIDGE.index("'Lazarette.ps1', 'Arc.ps1'") < BRIDGE.index("Join-Path $full 'pm.ps1'"), 'pm.ps1 only as the last resort'
assert "'Unlock-LazaretteVaultInteractive', 'Unlock-ArcVaultInteractive'" in BRIDGE
assert "'genapi'" in BRIDGE and "'advana-api'" in BRIDGE, 'Vault item names unchanged'
STORE=(ROOT/'Private/PacketRatStore.ps1').read_text()
assert "'mailhawk-store.json'" in STORE and 'Copy-Item' in STORE and 'Remove-Item' not in STORE
assert "'mailhawk-prefs','packetrat-prefs'" in CLIENT
LIFE=(ROOT/'Private/PacketRatLifecycle.ps1').read_text()
assert "'/api/heartbeat'" in SERVICE and "'/api/session/stop'" in SERVICE
assert 'PacketRatLifecycle' in SERVICE and 'Write-PacketRatRuntimeFile' in SERVICE and 'Remove-PacketRatRuntimeFile' in SERVICE
assert 'packetrat-server-' in LIFE and 'PACKETRAT_AUTO_STOP' in LIFE
assert 'Nonce' not in LIFE, 'Runtime files must never carry the session nonce'
assert "navigator.sendBeacon('/api/heartbeat'" in CLIENT and "'pagehide'" in CLIENT
assert 'id="endSession"' in HTML
assert (ROOT/'Stop-PacketRat.ps1').is_file()
assert 'PACKETRAT_AUTO_STOP' in (ROOT/'Config/packetrat.env.example').read_text()
print('Source and asset contract checks passed')
