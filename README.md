# MailHawk · Intelligence Workspace

MailHawk turns Outlook mail into a human-reviewed action queue. It runs a **local PowerShell 5.1** engine and serves an HTML/CSS/JavaScript dashboard over `127.0.0.1` — no Node, Python, or admin installation on the target computer.

![MailHawk selected flying hawk brand](Web/mailhawk-logo.png)

> **Status:** Integrated prototype. The browser GUI and sample-data interactions were tested in Chromium. Real Outlook COM, Microsoft Graph, approved ARC credentials, and AI endpoints still require validation on a permitted Windows workstation. Do not treat this as accredited or production-ready software.

## Launch

1. Download/extract the repository into a folder you can write to.
2. Double-click `Start-MailHawk-Web.bat` or run `powershell.exe -NoProfile -STA -File .\Start-MailHawk-Web.ps1`.
3. The browser opens at the **loopback** URL shown in PowerShell (default `http://127.0.0.1:8766/`, with automatic fallback if taken).
4. For a **non-sensitive demo**, add `?demo=1` to the URL. The sample items are hardcoded; **Outlook and the AI are not contacted**. Demo changes are confined to this browser tab's `sessionStorage`.
5. Keep the PowerShell window open. Press Ctrl+C to end the local server.

The existing `Start-MailHawk.bat` (Windows Forms) and `Start-MailHawk-Console.bat` launchers remain available as fallbacks. `Start-MailHawk-Demo.bat` opens the sample-data demo directly. `Start-MailHawk-Web.ps1 -NoBrowser` starts the service without opening a browser automatically.

## Major workflows

| Workspace | Capability |
|---|---|
| Overview | Intelligence banner, action KPIs, high-priority signals, recent report highlights |
| Action queue | Search, sort, filter, mark done/in-progress/reopen, dismiss, draft and open source Outlook message |
| AI intelligence | Last analysis report plus provider/model information |
| Dismissal memory | Persistent dismissed-message history and restore |
| Configuration | Provider, AI profile, max messages, days back |
| Draft assistant | Generate, edit, copy, or open as Outlook reply for **manual review** |

A fresh AI draft requires an inbox analysis during the same server session. No automatic sends, unattended mailbox actions, or background scheduling are implemented. AI operations run synchronously on the local service; they can make the GUI wait. True AI streaming/cancellation is **not yet implemented**.

## Configuration

Copy `Config/mailhawk.env.example` to `Config/mailhawk.env` (ignored by Git). Or rely on approved ARC parameter manager discovery. Tokens must **never** be placed in browser code or committed to Git.

- Profiles: `Auto`, `GenAi`, `Grok`.
- Outlook access: desktop COM (recommended for local opening/drafts); Graph needs its own approved authorization/modules.
- Outlook/AI capabilities rely on what's allowed by your organization.

## Security model and caveats

- TCP server binds only `127.0.0.1`, not a network interface.
- A per-process nonce and same-origin checks protect POST routes, and GET is read-only. Paths are allowlisted and response types explicit.
- Mail content and reports stay out of Git; runtime store/logs are written inside ignored `Logs/`.
- The AI is untrusted input. Checklist identity is resolved against the original Outlook scan, not model-supplied EntryIDs.
- A local browser origin is **not an enterprise security boundary**. Do not deploy as a shared server; further security review, logging minimization, and organizational approval are required.
- Drafts open in Outlook but are **not sent** by MailHawk.

## API (local only)

| Method | Route | Effect |
|---|---|---|
| GET | `/api/health` | Basic service availability |
| GET | `/api/state` | Local checklist, dismissals, last session report |
| POST | `/api/analyze` | Synchronous Outlook + AI analysis |
| POST | `/api/status` | Change checklist status |
| POST | `/api/dismiss` | Remember false positive |
| POST | `/api/restore` | Restore a dismissal |
| POST | `/api/open` | Open Outlook message window |
| POST | `/api/draft` | AI-generated reply body |
| POST | `/api/open-draft` | Open Outlook reply window, no send |

## Development validation

`tests/test_frontend.py` runs browser checks with Python + Playwright on a **development computer**, not as a target workstation dependency. It starts a static server and exercises the offline demo workflow, assets, navigation, action filtering, dismissal restore, and drafting. Windows PowerShell/Outlook integration requires additional native workstation testing.

## Layout

- `Web/` frontend and selected MailHawk logo/icon.
- `Start-MailHawk-Web.ps1` loopback HTTP service and API routes.
- `Private/` Outlook collectors, ARC integration, LLM, persistence and drafts.
- `Public/Invoke-MailHawkInboxAnalysis.ps1` classification pipeline.
- `Config/mailhawk.env.example` sanitized template.
- `tests/` offline UI and source contract tests.
