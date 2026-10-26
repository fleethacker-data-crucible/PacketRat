# PacketRat work-project development requirements

Before changing any Windows workstation launcher, read docs/WORKSTATION_LAUNCH_STANDARD.md, then check the current launchers in Lazarette and Halyard. Do not assume plain powershell.exe -File works on approved managed-workstation builds. Preserve PowerShell 5.1 and browser-only dependencies; verify path quoting, STA for COM, visible failures, and policy precedence. Use process-scoped execution-policy convention only when permitted, never attempt to circumvent central controls. Keep app changes on feature branches until verified on the target workstation.


## Stable launcher and AI credential contract

Exactly two user-facing BAT files in the root: `Launch-PacketRat.bat` for browser GUI (`demo`, `diagnostics` subcommands) and `PacketRat-CLI.bat` for console. `MailHawk.bat` and `MailHawk-CLI.bat` are forwarding stubs for pre-rename shortcuts only; do not add logic to them. Do not add new root BAT launchers for each mode. Maintain two AI credential paths: Lazarette/approved environment and GUI-entered manual session token (never persist the latter or return it from an API). Before inbox analysis, fail fast if the selected provider has no usable token. Future changes must preserve token-handling safeguards and workstation policy compliance.

## AI output and email signature contract

Before modifying prompts, parsers, drafting or report UI, read `docs/AI_WIRE_PROTOCOL_V1.md`. Model outputs must use strict, versioned envelopes: exactly one `PACKETRAT_DRAFT_V1` subject/body reply, one `PACKETRAT_REPORT_V1` JSON report with deterministic sections, and `PACKETRAT_INSIGHT_V1` for follow-up report generations. Reject malformed or truncated envelopes instead of dumping raw model text. Never trust model-provided Outlook message IDs or execute HTML from report fields.

Outlook's existing authenticated account reply signature must be preserved after displaying the reply inspector, with reviewed AI text inserted *before* that content. The model never authors or duplicates the user's signature. The original reply subject stays unchanged unless the user explicitly elects an override. No automatic sending. Add Windows PowerShell 5.1 and browser regression tests for protocol changes.
