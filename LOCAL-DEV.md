# MAILHAWK — local development (no CAC)

Run `Launch-LocalDev.bat` from this repository on your **personal Windows PC** after checking out the feature branch. Do not use on a managed system to defeat organizational security policy.

## What it does

- Prerequisite: Windows PowerShell 5.1; no CAC needed.
- Startup: Starts the existing ?demo=1 UI with sample mail, sample reports and in-browser demonstration actions.
- Boundary: Demo UI does not read Outlook or request AI credentials; this does not test a real inbox or GenAI endpoint.
- Lifecycle: stops any MailHawk already running first (`-Replace`, and says what it stopped); closing the tab stops the dev server. Add `--stay` to keep it running.
- Diagnostics / manual check: `powershell.exe -NoProfile -File Start-MailHawk-Web.ps1 -Demo`.

## Workflow

```powershell
git fetch origin
git switch feature/local-dev-no-cac-launcher
.\Launch-LocalDev.bat
```

The original production launcher and authentication checks remain unchanged. Mock, local, or offline sessions are **not** authenticated Navy sessions, and must not contain CUI, real credentials, classified material, or production personal data.

When stable, remove `Launch-LocalDev.bat` (and the ARC mock files where applicable) from the release branch. Do not deploy them as a means of avoiding CAC or authorization for live systems.
