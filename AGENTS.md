# MailHawk work-project development requirements

Before changing any Windows workstation launcher, read docs/NAUTILUS_LAUNCH_STANDARD.md, then check the current launchers in ARC and Cascade. Do not assume plain powershell.exe -File works on approved Nautilus builds. Preserve PowerShell 5.1 and browser-only dependencies; verify path quoting, STA for COM, visible failures, and policy precedence. Use process-scoped execution-policy convention only when permitted, never attempt to circumvent central controls. Keep app changes on feature branches until verified on the target workstation.


## Stable launcher and AI credential contract

Exactly two user-facing BAT files in the root: `MailHawk.bat` for browser GUI (`demo`, `diagnostics` subcommands) and `MailHawk-CLI.bat` for console. Do not add new root BAT launchers for each mode. Maintain two AI credential paths: ARC/approved environment and GUI-entered manual session token (never persist the latter or return it from an API). Before inbox analysis, fail fast if the selected provider has no usable token. Future changes must preserve token-handling safeguards and workstation policy compliance.
