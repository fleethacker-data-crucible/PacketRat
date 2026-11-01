# Bridge: talking to PacketRat

Bridge is PacketRat's voice layer. Everything stays on this PC: no audio, text or transcript is sent to a cloud service, and nothing is sent or changed in your mail by voice.

## Speech out (now)
- **Brief me** on Overview reads a short briefing of the top open actions. `PacketRat-CLI.bat assist brief` returns the same text with no AI call.
- Speech uses **only voices installed on this PC** (Windows voices). Browser "Online" or "Google" voices stream to a cloud service, so they are never used; if no local voice exists PacketRat stays silent and shows the text.
- Off until you tick **Speak replies**; the choice is remembered in this browser only.
- **TalkForge voice (recommended).** When TalkForge's own files are set up (below), Bridge speaks with TalkForge's Piper neural voice instead of the Windows voices. It uses TalkForge's engine, ONNX Runtime and voice models unchanged; nothing is copied into this repo and nothing is downloaded or sent anywhere.
  1. `git clone` TalkForge and fetch its assets (its `populate-assets.bat`, or the release zip) so `assets\models\<voice>.onnx` exists.
  2. Run once: `powershell -File tools\New-VoiceManifest.ps1 -TalkForgeAssets <TalkForge>\assets -Model en_US-lessac-high`. It hashes the 11 files and records the hashes in `Config\voice-assets.json` (the shipped file already pins TalkForge's current `en_US-lessac-high`).
  3. Set `PACKETRAT_TTS_DIR=<TalkForge>\assets` (in `Config\packetrat.env` as `PACKETRAT_TTS_DIR=...`) and start PacketRat. Bridge notes "Speaking with the TalkForge voice" and Speak replies is on.
  4. Pick another voice: run populate-assets for it, rerun the manifest tool with `-Model en_GB-alan-medium` (a British male voice, closest to a butler-AI sound), restart.
  The first sentence waits for the voice to load (a few seconds; the high-quality model is 114 MB); later sentences stream while the previous one plays. Check with `PacketRat-CLI.bat voice status` (`tts` section).
- Without TalkForge set up, Bridge falls back to the PC's installed voices as above.
- Live check: in headless Chromium, TalkForge's engine loaded in about 1.5 s and spoke two sentences (about 9 s including playback) with `en_US-lessac-high`.

## Ask (text, and spoken when Speak replies is on)
- **Ask** (Overview > Bridge) and `assist ask --question "..."` send your question plus the open queue to Fairlead (your configured route; `auto` by default). The model answers in a strict `PACKETRAT_ASSIST_V1` envelope; anything else is rejected.
- It may **propose** `dismiss`, `status` or `priority` changes for items in the queue. Proposals are never run: the browser shows a **Confirm** button per proposal and the CLI prints the exact command to run yourself. Unknown actions, unknown keys and bad values are rejected. It cannot send, archive, move or delete mail.
- Queue text comes from email, so the model is told to treat it as untrusted data.

## Speech in (local only, opt-in)
- **Hold to talk** records while the button (or Space/Enter on it) is held, transcribes in a Web Worker with a local Whisper model, and sends the text to **Ask**. **Listen for the hail** keeps the microphone open and acts only on an utterance that starts with a nautical hail: "Bridge ...", "Bridge PacketRat ..." or "Hail PacketRat ...". Bridge answers "Aye." and runs the rest as a question. "Stand down" (or "Secure the bridge") closes the microphone.
- The hail is **off at every start** and never remembered; the panel shows **Microphone OPEN** whenever the mic is live, in addition to the browser's own indicator. Audio never leaves the page and is not logged or stored.
- The browser's built-in speech recognition is **not** used: in Chrome and Edge it streams audio to the vendor's servers.
- **Assets are not in the repo (62 MB).** `Config/voice-assets.json` already pins these 12 files by SHA-256; get exactly these and put them under `Web/vendor/voice` (or `PACKETRAT_VOICE_DIR`), keeping the layout:
  - from `https://cdn.jsdelivr.net/npm/@huggingface/transformers@3.8.1/dist/`: `transformers.min.js`, `ort-wasm-simd-threaded.jsep.mjs`, `ort-wasm-simd-threaded.jsep.wasm` (top level of the folder);
  - from `https://huggingface.co/Xenova/whisper-tiny.en/resolve/79fb389fc764e7c395bd330e9531d9d32ada7049/`: `config.json`, `generation_config.json`, `preprocessor_config.json`, `tokenizer.json`, `tokenizer_config.json`, `added_tokens.json`, `special_tokens_map.json`, `onnx/encoder_model_quantized.onnx`, `onnx/decoder_model_merged_quantized.onnx` into `models/whisper-tiny.en/` (and its `onnx/`).
  Download them once on a PC that may reach those hosts; PacketRat itself never downloads anything. A file that differs from the pinned hash is refused. `voice status` / the panel say what is missing. To use other files, put them there and run `tools/New-VoiceManifest.ps1 -VoiceInputDir Web/vendor/voice` to re-pin.
- **Spoken shortcuts:** "Bridge, brief me" (also "status report", "what needs me") reads the local briefing with no AI call; anything else goes to Ask.
- The page now allows WebAssembly (`'wasm-unsafe-eval'`) and same-origin workers in its content security policy; nothing else about the policy loosened.
- **Live check (headless Chromium, real server):** the TalkForge voice said three phrases and the Whisper worker transcribed each exactly; the hail matcher woke on "Bridge, what is most urgent?", stood down on "Stand down" and ignored an unrelated sentence. First load is slow while the server hashes the files (about 27 s for the voice, 15 s for Whisper); later loads are faster. **Not verified:** a real microphone, real room noise, and the voice-activity threshold; expect to tune those.

## Tests
`tests/test_voice.js` (text cleanup, local-voice-only choice) and `tests/Test-PacketRatAssistant.ps1` (briefing) run offline in CI. Nothing has been heard through a real speaker on a workstation.
