# MailHawk — Outlook Intelligence Workspace

MailHawk helps triage Outlook emails into a human-reviewed action queue. The browser UI runs on a local Windows PowerShell 5.1 service. No Python or Node.js installation is required on the target workstation.

![Selected MailHawk logo](Web/mailhawk-logo.png)

> **Status:** Integrated prototype. Offline/browser functionality has been tested in development; real Outlook COM, Graph, ARC/CAC, AI provider connectivity, and Navy workstation execution need validation in the approved environment. Not accredited or production-ready.

## Only two launchers

- **`MailHawk.bat`** — opens the modern browser GUI, the default.
- **`MailHawk-CLI.bat`** — runs console-only inbox analysis (`-Profile GenAi` or `-Profile Grok` are accepted).

The browser launcher also supports optional commands from an existing CMD prompt:

```bat
MailHawk.bat
MailHawk.bat demo
MailHawk.bat diagnostics
MailHawk.bat -NoBrowser
MailHawk.bat -Port 8766
MailHawk-CLI.bat -Profile GenAi
```

The five former user-facing BAT files were retired. Internal PowerShell files (`Start-MailHawk-Web.ps1`, `Start-MailHawk.ps1`) remain as implementation entrypoints and are not additional launchers.

The PowerShell process-scoped startup convention matches Cascade, but it **cannot override organization-managed security policy**. If the workstation blocks execution, use an approved signing/deployment process. The diagnostics option checks required files, parsing, policy precedence and local network binding without accessing mail or credentials.

## Interactive intelligence report

The report is now an interactive, **source-verified intelligence workspace**, not merely pasted GenAI Markdown. It includes:

- Conservative recovery of common encoding artifacts and model formatting, without stripping ordinary Unicode.
- Verified inline source references and clickable table rows when GenAI includes source indices. Invalid model references are never made actionable.
- A searchable list of actual source messages from the most recent inbox scan. Open in Outlook, draft a reply, or explicitly create an action from a report source. Graph-to-classic-Outlook opening is not yet implemented.
- Generate **Action plan**, **Leadership briefing**, **Risk review**, or **Explanation** from the full report or a selected section; follow-ups are generated on demand and do not send email or silently alter the action queue.
- Report-quality indicators for unresolved character artifacts, unsupported model references, missing structured output, and conflicts between AI suggestions and local triage rules.

Legacy reports without source indices show a verified source list rather than pretending arbitrary prose can be mapped safely to an Outlook message. If GenAI returns incomplete structured output, MailHawk warns instead of displaying partial JSON as trustworthy triage.

See [Deep Report Intelligence Audit](docs/REPORT_INTELLIGENCE_AUDIT.md) for detailed findings, remediation, limitations, and the longer-term schema-first architecture proposal.

**Security:** Mail content and the report are treated as untrusted data. The browser escapes rendered HTML, APIs require a current verified source for report-originated actions, and no AI-generated reply is sent automatically. Use only approved AI endpoints for authorized mail data.

## Intelligence workspace enhancements (feature branch)

- Overview KPI cards open the matching **Active**, **High priority**, **Completed**, or **Filtered** workspace.
- Priority signals are clickable, and subject titles in the action queue open the original message in desktop Outlook (COM mode).
- An action can be manually upgraded/downgraded High / Medium / Low. Manual overrides survive rescans and can be reset to the AI/rule suggestion.
- **Configuration → Intelligence rules** provides editable, ordered, enableable defaults plus custom sender/domain/subject/preview rules. The filter review lists reversible rule exclusions.
- The report workspace renders GenAI Markdown as readable sections, safe tables, and bullets rather than showing raw blockquote chevrons.
- Draft generation requests a **20,000-token output ceiling** (provider permitting), and offers separately editable Response A/B alternatives. The selected response opens in Outlook for human review only.

The default .mil rule requires a **verified direct recipient and actionable language**. A .mil sender alone does not create a mandatory task. See [Triage Rules and Drafts](docs/TRIAGE_RULES_AND_DRAFTS.md).

## Choosing an AI token source

Open **Configuration → Credentials & connections** in the GUI.

1. Select **ARC / configured environment** to use the existing approved ARC bridge (GenAi service `genapi` or Grok service `advana-api`; override names in `Config/mailhawk.env` if needed).
2. Or select **Manual · current session**, select GenAi or Grok, paste a token for an **approved** provider, then select **Apply credential source**. Repeat for another provider if needed.
3. Select **Check available token** to verify that the selected provider's token resolves locally. This does **not** contact an AI endpoint or scan your inbox.
4. Select **Forget manual tokens** to erase manual credential references held in the current PowerShell process.

Manual credentials are **not saved to disk, environment files, localStorage, or GitHub** by MailHawk. They are held only in the PowerShell service process while it runs and are cleared on service exit or when switching back to ARC. A local process/browser is not an enterprise credential vault; only use this option if permitted under your organization's token-handling policy. Never use unapproved AI endpoints for sensitive or official mail.

**Why “no LLM token” happened:** Earlier browser releases silently searched environment variables/ARC without user-configurable source selection. Now the selected source is explicit, errors include useful setup instructions, and **Analyze inbox checks token availability before reading messages**.

`Config/mailhawk.env.example` contains optional ARC discovery, service names, and provider configuration. Do not commit real token values.

## What works and what still needs verification

| Workflow | State |
|---|---|
| Browser dashboard, inbox action queue, dismissal memory, draft review | Implemented |
| Offline demonstration (`MailHawk.bat demo`) | No Outlook or LLM connection |
| Outlook COM analysis, draft-opening and reply detection | Implementation present; target Windows validation required |
| ARC managed credential integration | Implementation present; requires ARC unlock/session test |
| Manual credential configuration | Session-only implementation; network/API testing required |
| Microsoft Graph | Requires organization-authorized Graph configuration |
| Live AI provider calls | Depends on valid credentials, endpoint permissions, and network |
| Streaming/cancellable agent operations | Not implemented |
| Edit/sort triage rules, manual priority overrides and suppression review | Implemented; target workstation validation pending |
| Polished report renderer and draft option parsing | Implemented; test coverage added |
| Automatic sending | Not implemented and deliberately disabled |

## Security

The HTTP service binds to local loopback only. POST requests require same-origin checks and a per-process request nonce. The selected hawk logo ships as an actual PNG, not a remote reference. User email state and logs belong under the ignored `Logs/` directory. Generated drafts require human review; MailHawk never sends messages automatically.

## Project layout

- `MailHawk.bat` and `MailHawk-CLI.bat` — the only user launchers.
- `Start-MailHawk-Web.ps1` — local HTTP/JSON service.
- `Start-MailHawk.ps1` — legacy engine with console mode used by the CLI.
- `Web/` — browser application, styling, and logo assets.
- `Private/`, `Public/` — Outlook, ARC, AI, persistence and analysis modules.
- `tools/Test-MailHawkStartup.ps1` — noninvasive diagnostics invoked by `MailHawk.bat diagnostics`.
- `tests/` — development-only source/browser tests.

**Browser demo:** `MailHawk.bat demo` loads hard-coded test messages and does not touch Outlook or LLM endpoints. Real API keys must not be entered in demo mode.

See `docs/NAUTILUS_LAUNCH_STANDARD.md` for the ARC/Cascade launch convention and security constraints.
