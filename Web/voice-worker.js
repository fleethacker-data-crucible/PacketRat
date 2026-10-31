/* Speech-to-text worker. Loads transformers.js and a Whisper model ONLY from /voice-assets/ (same origin, hash-checked by the
   server, listed in Config/voice-assets.json). Remote model hosts are switched off, so a missing file is an error, never a
   download. NOT exercised by the offline tests: it needs the assets, which are not in the repo. */
let asr = null;

async function load() {
  const lib = await import('/voice-assets/transformers.min.js');
  const env = lib.env;
  env.allowRemoteModels = false;
  env.allowLocalModels = true;
  env.localModelPath = '/voice-assets/models/';
  env.useBrowserCache = false;
  env.backends.onnx.wasm.wasmPaths = '/voice-assets/';
  env.backends.onnx.wasm.numThreads = 1;
  asr = await lib.pipeline('automatic-speech-recognition', 'whisper-tiny.en', { dtype: 'q8', device: 'wasm' });
}

self.onmessage = async (e) => {
  const m = e.data || {};
  try {
    if (m.type === 'load') {
      await load();
      self.postMessage({ type: 'ready' });
    } else if (m.type === 'transcribe') {
      if (!asr) throw new Error('The speech model is not loaded.');
      const out = await asr(m.audio);
      self.postMessage({ type: 'text', id: m.id, text: String((out && out.text) || '').trim() });
    }
  } catch (err) {
    self.postMessage({ type: 'error', id: m.id, message: String((err && err.message) || err) });
  }
};
