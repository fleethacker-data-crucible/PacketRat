# Bridge: talking to PacketRat

Bridge is PacketRat's voice layer. Everything stays on this PC: no audio, text or transcript is sent to a cloud service, and nothing is sent or changed in your mail by voice.

## Speech out (now)
- **Brief me** on Overview reads a short briefing of the top open actions. `PacketRat-CLI.bat assist brief` returns the same text with no AI call.
- Speech uses **only voices installed on this PC** (Windows voices). Browser "Online" or "Google" voices stream to a cloud service, so they are never used; if no local voice exists PacketRat stays silent and shows the text.
- Off until you tick **Speak replies**; the choice is remembered in this browser only.
- A local neural engine such as a Piper adapter can be plugged in later with `PacketRatVoice.registerEngine({ speak, stop })`; nothing is bundled today.

## Tests
`tests/test_voice.js` (text cleanup, local-voice-only choice) and `tests/Test-PacketRatAssistant.ps1` (briefing) run offline in CI. Nothing has been heard through a real speaker on a workstation.
