# Bridge: talking to PacketRat

Bridge is PacketRat's voice layer. Everything stays on this PC: no audio, text or transcript is sent to a cloud service, and nothing is sent or changed in your mail by voice.

## Speech out (now)
- **Brief me** on Overview reads a short briefing of the top open actions. `PacketRat-CLI.bat assist brief` returns the same text with no AI call.
- Speech uses **only voices installed on this PC** (Windows voices). Browser "Online" or "Google" voices stream to a cloud service, so they are never used; if no local voice exists PacketRat stays silent and shows the text.
- Off until you tick **Speak replies**; the choice is remembered in this browser only.
- A local neural engine such as a Piper adapter can be plugged in later with `PacketRatVoice.registerEngine({ speak, stop })`; nothing is bundled today.

## Ask (text, and spoken when Speak replies is on)
- **Ask** (Overview > Bridge) and `assist ask --question "..."` send your question plus the open queue to your configured AI profile (a local endpoint by default). The model answers in a strict `PACKETRAT_ASSIST_V1` envelope; anything else is rejected.
- It may **propose** `dismiss`, `status` or `priority` changes for items in the queue. Proposals are never run: the browser shows a **Confirm** button per proposal and the CLI prints the exact command to run yourself. Unknown actions, unknown keys and bad values are rejected. It cannot send, archive, move or delete mail.
- Queue text comes from email, so the model is told to treat it as untrusted data.

## Tests
`tests/test_voice.js` (text cleanup, local-voice-only choice) and `tests/Test-PacketRatAssistant.ps1` (briefing) run offline in CI. Nothing has been heard through a real speaker on a workstation.
