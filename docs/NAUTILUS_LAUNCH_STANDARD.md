# Nautilus-compatible startup convention (work projects)

Purpose: keep PowerShell/browser apps consistent with proven ARC and Cascade launch patterns. This is an engineering compatibility requirement, not permission to circumvent government IT restrictions.

## Required design checks for every new work-related PowerShell app

1. Before writing launchers, inspect the current ashable2/arc and ashable2/cascade entrypoints, README launch instructions, and permissions expectations. Do not assume the architecture from memory is current.
2. For authorized PowerShell 5.1 deployments, match Cascade's process-scoped launcher pattern: powershell.exe -NoProfile -ExecutionPolicy Bypass -File PATH (add -STA when Outlook COM or UI requires it). This command is used by existing Cascade launchers and the original MailHawk Windows Forms launcher. The process-scoped setting is not elevation and cannot supersede Group Policy.
3. Never attempt to defeat Group Policy, AppLocker, WDAC, antivirus, endpoint monitoring, or administrator controls. If policy blocks the app, stop and obtain an approved signed deployment or IT exception.
4. Launch from the script's directory (%~dp0), quote paths, preserve argument forwarding, exit with a meaningful code, and display errors rather than silently closing.
5. Include a non-invasive preflight capable of inspecting PowerShell version, effective policy, required files, script parser errors, and localhost binding without accessing emails, secrets, or ARC vault contents.
6. Browser UIs must be loopback-only with constrained origins and explicit routes. Use approved built-in PowerShell/.NET components without relying on installs unavailable on Nautilus.
7. Never assume passing development browser tests means launch works under Windows PowerShell 5.1, Outlook COM, ARC, CAC, or Navy endpoint controls. Verify on the target workstation before merging into production main.
8. Develop compatibility changes on a branch. Merge only after verification; document the tested entrypoint and relevant failure output.

## Current comparison (2026-10-22)

- Cascade Cascade-GUI.bat: powershell.exe -NoProfile -ExecutionPolicy Bypass -File ...
- ARC pm.ps1: native PowerShell 5.1 entrypoint loaded via dot-source and pm commands; no dedicated batch startup shown in the top-level README.
- MailHawk original Start-MailHawk.bat: explicitly uses -ExecutionPolicy Bypass -STA.
- MailHawk v2 web/demo batch scripts accidentally omitted the execution-policy argument. The revised launchers match Cascade and retain STA.

## Troubleshooting

Run Start-MailHawk-Diagnostics.bat first. It reports policy context without modifying policy, collecting mail, or reading credentials. If Windows policy refuses process-scoped launching, use the approved signing or software-delivery channel instead of security-control evasion.
