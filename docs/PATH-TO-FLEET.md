# Path to fleet

One page for a security or workstation reviewer: what PacketRat is, what it touches on a Windows PC, where data can go, and what has and has not been proven. Every statement in the inventory is checked against the source by `tests/Test-PacketRatFleetInventory.ps1`; the status section is a judgement and says so.

**What it is.** A local tool that reads mail (classic Outlook, or exported `.eml` and `.msg` files) and turns it into a reviewed action queue. It never sends mail. Drafts open in Outlook for a person to send.

## What it needs

- Windows PowerShell 5.1 (built in) and Edge or Chrome. No installer, no administrator rights, no NuGet or third-party DLLs.
- Optional: classic Outlook (COM provider), the Microsoft Graph PowerShell modules (Graph provider, off by default), Fairlead (the Fleet model router) for AI.

## What it touches

| Area | What PacketRat does |
|---|---|
| Programs it starts | Fairlead, by calling edge-ops FleetPort `Start-FleetService -Name fairlead` when nothing is listening and Fairlead is installed next to PacketRat (or `FAIRLEAD_DIR` names it). That helper starts Fairlead hidden, with its tray, and Fairlead keeps running after PacketRat exits. `PACKETRAT_FAIRLEAD_AUTOSTART=off` turns this off. PacketRat also starts the system browser for its own page. It stops only its own server. |
| Compiled code | C# is compiled in memory from source with `Add-Type` (framework assemblies only). No DLL is shipped, loaded or cached on disk. |
| Listening | One HTTP server bound to loopback only (`127.0.0.1`, default port 8766, or a free port). POST requests need a per-session nonce. |
| Files it writes | Under `Logs/`: the action queue, rules, dismissals and counts (`packetrat-store.json`), `packetrat.log`, and a runtime file per running server. `Logs/` is not committed. Raw AI responses are written only if `PACKETRAT_SAVE_RAW_AI=1`. |
| What the queue stores | Subject, sender name and address, and PacketRat's reason for each tracked action. Not message bodies. |
| Mail it changes | Only on a named command with `--yes`: archive and move, in classic Outlook. Nothing is sent or deleted. See `docs/CLI.md`. |

## Where data can go

| Destination | When | What |
|---|---|---|
| The AI router (Fairlead) | Only when a person runs an analysis, report, draft or question | Sender, subject and message text of the mail involved. The only AI address is Fairlead on this PC (`127.0.0.1:8776`; a different port only if `PACKETRAT_FAIRLEAD_URL` says so, and never another host). Fairlead decides which model sees it: set `PACKETRAT_FAIRLEAD_PRIVACY=local` to keep prompts on local models. Use only a Fairlead route your organization has approved for email content. |
| Microsoft Graph | Only with the Graph provider selected | Mail read through the signed-in account's Graph modules (scopes Mail.Read, Mail.ReadWrite, User.Read), which needs the organization's authorization. |
| Anywhere else | Never | No telemetry, no usage data, no update check. The counts stay in the local store. |

Credentials: PacketRat's Fairlead key comes from Windows Credential Manager (`Fairlead/PacketRat`) when that credential is present, otherwise the first line of `%LOCALAPPDATA%\Fairlead\local-token` (Fairlead's token for this Windows account). The key is sent only after `GET /__fleethacker/id` on that loopback address names Fairlead and the reported process holds the port. A key is never taken on a command line, never saved from the browser, never logged and never returned by an API. There is no environment-variable or vault fallback.

## What is proven and what is not

Proven by offline tests (run in CI on Windows PowerShell 5.1, with fakes for Outlook, Graph and the AI): triage rules and draft parsing, the strict AI wire protocol, the command and API parity, the inbox actions against a fake Outlook, the Files provider on invented mail, the counts export, the Fairlead router setting against a stub, the Fairlead key order (credential, then local token) and the refusal to send that key until Fairlead's identity check passes, and the call to `Start-FleetService -Name fairlead` (a stand-in module; the real Fairlead process is not started).

Not proven, and needing a person on the target machine: classic Outlook on a managed workstation (COM analysis, draft opening, archive and move), a live run through Fairlead, Microsoft Graph sign-in, and the browser experience under the workstation's policies. The README's status table says the same.

## Before a managed workstation runs it

1. Read `docs/WORKSTATION_LAUNCH_STANDARD.md` and run `Launch-PacketRat.bat diagnostics`.
2. Decide the AI endpoint with the organization and set it (or leave only the offline demo and the Files provider).
3. Confirm the Outlook actions on a test mailbox, not a real one, before enabling them for anyone.
4. Have the reviewer re-run the inventory test after any change that touches the lists above.

## Tests

`tests/Test-PacketRatFleetInventory.ps1` (in CI) scans the source and fails if: a network client appears outside the two files named here, a send or delete call appears, a prebuilt DLL is loaded, the server could bind beyond loopback, `Start-Process` appears outside the files named here, or this page loses a section.
