# PacketRat — local development (no smart card)

Run `Launch-LocalDev.bat` from this repository on your **personal Windows PC** after checking out the feature branch. Do not use on a managed system to defeat organizational security policy.

## What it does

- Prerequisite: Windows PowerShell 5.1; no smart card needed.
- Startup: Starts the existing ?demo=1 UI with sample mail, sample reports and in-browser demonstration actions.
- Boundary: Demo UI does not read Outlook or request AI credentials; this does not test a real inbox or AI endpoint.
- Lifecycle: stops any PacketRat already running first (`-Replace`, and says what it stopped); closing the tab stops the dev server. Add `--stay` to keep it running.
- Diagnostics / manual check: `powershell.exe -NoProfile -File Start-PacketRat-Web.ps1 -Demo`.

## Workflow

```powershell
git fetch origin
git switch <feature-branch>
.\Launch-LocalDev.bat
```

The original production launcher and authentication checks remain unchanged. Mock, local, or offline sessions are **not** authenticated operational sessions, and must not contain sensitive or regulated data, real credentials, or production personal data.

When stable, remove `Launch-LocalDev.bat` (and the Lazarette mock files where applicable) from the release branch. Do not deploy them as a means of avoiding smart card sign-in or authorization for live systems.
