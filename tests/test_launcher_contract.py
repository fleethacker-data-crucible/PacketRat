"""Offline launcher regression checks. Python is used on development machines only."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class LauncherTests(unittest.TestCase):
    def test_exactly_two_user_facing_launchers(self):
        launchers = sorted(p.name for p in ROOT.glob('*.bat'))
        self.assertEqual(launchers, ['Launch-LocalDev.bat', 'Launch-PacketRat.bat', 'MailHawk-CLI.bat', 'MailHawk.bat', 'PacketRat-CLI.bat'])

    def test_former_mailhawk_names_forward(self):
        # Rename compatibility: old shortcuts to MailHawk.bat / MailHawk-CLI.bat keep working.
        for old, new in (('MailHawk.bat', 'Launch-PacketRat.bat'), ('MailHawk-CLI.bat', 'PacketRat-CLI.bat')):
            text = (ROOT/old).read_text()
            self.assertIn('call "%~dp0' + new + '" %*', text)
            self.assertLessEqual(len([l for l in text.splitlines() if l.strip()]), 3)
            self.assertNotIn('powershell', text.lower())
        local = (ROOT/'Launch-LocalDev.bat').read_text()
        self.assertIn('Start-PacketRat-Web.ps1', local)
        self.assertIn('-Demo', local)
        self.assertNotIn('Set-ExecutionPolicy', local)

    def test_gui_launch_matches_halyard_convention(self):
        text = (ROOT/'Launch-PacketRat.bat').read_text()
        self.assertIn('-NoProfile', text)
        self.assertIn('-ExecutionPolicy Bypass', text)
        self.assertIn('-STA', text)
        self.assertIn('Start-PacketRat-Web.ps1', text)
        for command in (':GUI', ':DEMO', ':DIAGNOSTICS'):
            self.assertIn(command, text)
        self.assertIn('exit /b %EXIT_CODE%', text)

    def test_cli_uses_console_only(self):
        text = (ROOT/'PacketRat-CLI.bat').read_text()
        self.assertIn('-ConsoleOnly %*', text)
        self.assertIn('-ExecutionPolicy Bypass', text)

    def test_diagnostics_noninvasive(self):
        text = (ROOT/'tools/Test-PacketRatStartup.ps1').read_text()
        for forbidden in ('Set-ExecutionPolicy','New-Object -ComObject Outlook','Import-Module ARC','Import-Module Lazarette','Disable'):
            self.assertNotIn(forbidden, text)
        self.assertIn('Get-ExecutionPolicy -List', text)
        self.assertIn('Parser]::ParseFile', text)
        self.assertIn("'Launch-PacketRat.bat','PacketRat-CLI.bat'", text)

    def test_lifecycle_launch_options(self):
        text = (ROOT/'Launch-PacketRat.bat').read_text()
        for option in ('--replace', '--stay', ':STOP', 'Stop-PacketRat.ps1'):
            self.assertIn(option, text)
        self.assertIn('Start-PacketRat-Web.ps1" %*', text)
        self.assertIn('-Replace', (ROOT/'Launch-LocalDev.bat').read_text())
        service = (ROOT/'Start-PacketRat-Web.ps1').read_text()
        for needle in ('[switch]$Stay', '[switch]$Replace', 'Stop it and start fresh?', "'^--?stay$'", "'^--?replace$'"):
            self.assertIn(needle, service)
        stop = (ROOT/'Stop-PacketRat.ps1').read_text()
        self.assertIn('Stop-PacketRatProcesses', stop)

    def test_contract_documented(self):
        self.assertTrue((ROOT/'docs/WORKSTATION_LAUNCH_STANDARD.md').exists())
        self.assertTrue((ROOT/'AGENTS.md').exists())

if __name__ == '__main__':
    unittest.main()
