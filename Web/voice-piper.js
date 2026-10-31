/* PacketRat Bridge: speak with the TalkForge voice (Piper neural TTS, ONNX Runtime Web) on this PC.
   The engine, runtime and voice model are TalkForge's own files, served from /voice-assets/tts/ and hash-checked by the
   server. Nothing is fetched from a CDN or sent anywhere. Pure helpers are exported for node tests. */
(function (root) {
  'use strict';
  var BASE = '/voice-assets/tts/';

  // Short chunks start speaking sooner and keep each synthesis call small.
  function splitSentences(text, max) {
    max = max || 220;
    var t = String(text == null ? '' : text).replace(/\s+/g, ' ').trim();
    if (!t) return [];
    var parts = t.match(/[^.!?;:]+[.!?;:]*\s*/g) || [t], out = [], cur = '';
    parts.forEach(function (p) {
      p = p.trim();
      while (p.length > max) { var cut = p.lastIndexOf(' ', max); if (cut < 40) cut = max; out.push(p.slice(0, cut).trim()); p = p.slice(cut).trim(); }
      if ((cur + ' ' + p).trim().length > max) { if (cur) out.push(cur); cur = p; } else cur = (cur + ' ' + p).trim();
    });
    if (cur) out.push(cur);
    return out;
  }
  var api = { splitSentences: splitSentences, BASE: BASE };

  var engine = null, loading = null, ctx = null, token = 0, current = null, cfgNow = null;
  // Injectable for tests: returns a PiperEngine-like object { synthesize(text, speaker, lengthScale) -> Blob }.
  api._loader = function (cfg) {
    var model = cfg.model;
    return import(BASE + 'vendor/onnx/ort.min.mjs').then(function (ort) {
      ort.env.wasm.numThreads = 1; // single thread: no SharedArrayBuffer / cross-origin isolation needed
      return import(BASE + 'vendor/piper-engine.js');
    }).then(function (mod) {
      return mod.PiperEngine.load(BASE + 'models/' + model + '.onnx', BASE + 'models/' + model + '.onnx.json', BASE + 'vendor/onnx/',
        { wasm: BASE + 'wasm/piper_phonemize.wasm', data: BASE + 'wasm/piper_phonemize.data' });
    });
  };
  function ensure() {
    if (engine) return Promise.resolve(engine);
    if (!loading) loading = api._loader(cfgNow).then(function (e) { engine = e; return e; }, function (err) { loading = null; throw err; });
    return loading;
  }
  function play(blob) {
    return blob.arrayBuffer().then(function (buf) {
      ctx = ctx || new root.AudioContext();
      return ctx.decodeAudioData(buf);
    }).then(function (audio) {
      return new Promise(function (resolve) {
        var src = ctx.createBufferSource(); src.buffer = audio; src.connect(ctx.destination);
        src.onended = function () { if (current === src) current = null; resolve(); };
        current = src; src.start();
      });
    });
  }
  function speak(text) {
    var my = ++token, parts = splitSentences(text);
    if (!parts.length) return Promise.resolve();
    return ensure().then(function (e) {
      var synth = function (s) { return e.synthesize(s, cfgNow.speaker || 0, cfgNow.lengthScale || 1.0); };
      var next = synth(parts[0]), chain = Promise.resolve();
      parts.forEach(function (_, i) {
        chain = chain.then(function () {
          if (my !== token) return;
          var cur = next;
          if (i + 1 < parts.length) next = synth(parts[i + 1]); // synthesize the next sentence while this one plays
          return cur.then(function (blob) { if (my === token) return play(blob); });
        });
      });
      return chain;
    });
  }
  function stop() { token++; if (current) { try { current.stop(); } catch (e) { /* already ended */ } current = null; } }

  // Registers the TalkForge voice as Bridge's speech engine. Loading is lazy: the model is fetched on the first sentence.
  api.install = function (cfg) {
    cfgNow = cfg;
    if (root.PacketRatVoice) root.PacketRatVoice.registerEngine({ speak: speak, stop: stop, name: 'TalkForge ' + cfg.model });
  };
  api.preload = function () { return ensure(); };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.PacketRatPiper = api;
})(typeof window !== 'undefined' ? window : globalThis);
