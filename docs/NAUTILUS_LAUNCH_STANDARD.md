# Nautilus-compatible startup convention (work projects)

Purpose: keep PowerShell/browser apps consistent with proven Lazarette and Halyard launch patterns. This is an engineering compatibility requirement, not permission to circumvent government IT restrictions.

## Required design checks for every new work-related PowerShell app

1. Before writing launchers, inspect the current sun-of-anton/Lazarette and sun-of-anton/Halyard entrypoints, README launch instructions, and permissions expectations. Do not assume the architecture from memory is current.
2. For authorized PowerShell 5.1 deployments, match Halyard's process-scoped launcher pattern: powershell.exe -NoProfile -ExecutionPolicy Bypass -File PATH (add -STA when Outlook COM or UI requires it). This command is used by existing Halyard launchers and the original MailHawk (now PacketRat) Windows Forms launcher. The process-scoped setting is not elevation and cannot supersede Group Policy.
3. Never attempt to defeat Group Policy, AppLocker, WDAC, antivirus, endpoint monitoring, or administrator controls. If policy blocks the app, stop and obtain an approved signed deployment or IT exception.
4. Launch from the script's directory (%~dp0), quote paths, preserve argument forwarding, exit with a meaningful code, and display errors rather than silently closing.
5. Include a non-invasive preflight capable of inspecting PowerShell version, effective policy, required files, script parser errors, and localhost binding without accessing emails, secrets, or Lazarette vault contents.
6. Browser UIs must be loopback-only with constrained origins and explicit routes. Use approved built-in PowerShell/.NET components without relying on installs unavailable on Nautilus.
7. Never assume passing development browser tests means launch works under Windows PowerShell 5.1, Outlook COM, Lazarette, CAC, or Navy endpoint controls. Verify on the target workstation before merging into production main.
8. Develop compatibility changes on a branch. Merge only after verification; document the tested entrypoint and relevant failure output.

## Current comparison (2026-10-22)

- Halyard (formerly Cascade) launcher: powershell.exe -NoProfile -ExecutionPolicy Bypass -File ...
- Lazarette (formerly ARC): integrators dot-source `lib\Arc.ps1` (ARC 5; `lib\Lazarette.ps1` when present) and call `Unlock-ArcVaultInteractive` / `Get-ArcSecret`. ARC 3/4's `pm.ps1` is now a stub that throws (see Lazarette `docs/INTEGRATION.md`).
- MailHawk (now PacketRat) original Start-MailHawk.bat (retired): explicitly uses -ExecutionPolicy Bypass -STA.
- MailHawk (now PacketRat) v2 web/demo batch scripts accidentally omitted the execution-policy argument. The revised launchers match Halyard and retain STA.

## Troubleshooting

Run Launch-PacketRat.bat diagnostics first. It reports policy context without modifying policy, collecting mail, or reading credentials. If Windows policy refuses process-scoped launching, use the approved signing or software-delivery channel instead of security-control evasion.

## PacketRat current launcher contract

The only user-facing Windows batch files are `Launch-PacketRat.bat` (browser GUI, `demo`, and `diagnostics` subcommands) and `PacketRat-CLI.bat` (console mode). `MailHawk.bat` and `MailHawk-CLI.bat` only forward to them so pre-rename shortcuts keep working. Root `Start-PacketRat-*.bat` files have been removed. The `.ps1` PowerShell hosts remain internal application components.

For Lazarette instability, the browser Configuration workspace supports explicit **Lazarette / configured environment** or **Manual · current session** token selection. The latter is memory-only in the running PowerShell process and must be authorized for the target workstation and data classification.
