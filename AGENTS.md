# MailHawk work-project development requirements

Before changing any Windows workstation launcher, read docs/NAUTILUS_LAUNCH_STANDARD.md, then check the current launchers in ARC and Cascade. Do not assume plain powershell.exe -File works on approved Nautilus builds. Preserve PowerShell 5.1 and browser-only dependencies; verify path quoting, STA for COM, visible failures, and policy precedence. Use process-scoped execution-policy convention only when permitted, never attempt to circumvent central controls. Keep app changes on feature branches until verified on the target workstation.
