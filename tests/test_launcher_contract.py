"""Offline source checks for the work-project launcher contract; Python is dev-only."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class LauncherTests(unittest.TestCase):
    def test_web_policy_parity(self):
        txt = (ROOT / 'Start-MailHawk-Web.bat').read_text()
        self.assertIn('-NoProfile', txt)
        self.assertIn('-ExecutionPolicy Bypass', txt)
        self.assertIn('-STA', txt)
        self.assertIn('"%REPO%Start-MailHawk-Web.ps1"', txt)
        self.assertIn('exit /b %EXIT_CODE%', txt)

    def test_demo_reuses_web_launcher(self):
        txt=(ROOT/'Start-MailHawk-Demo.bat').read_text()
        self.assertIn('call "%~dp0Start-MailHawk-Web.bat" -Demo',txt)

    def test_diagnostics_do_not_change_machine_policy_or_read_mail(self):
        txt=(ROOT/'tools/Test-MailHawkStartup.ps1').read_text()
        for forbidden in ('Set-ExecutionPolicy','New-Object -ComObject Outlook','Import-Module ARC','Disable'):
            self.assertNotIn(forbidden,txt)
        self.assertIn('Get-ExecutionPolicy -List',txt)
        self.assertIn('Parser]::ParseFile',txt)

    def test_standard_documented(self):
        self.assertTrue((ROOT/'docs/NAUTILUS_LAUNCH_STANDARD.md').is_file())
        self.assertTrue((ROOT/'AGENTS.md').is_file())

if __name__=='__main__': unittest.main()
