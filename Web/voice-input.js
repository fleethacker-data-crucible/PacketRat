/* PacketRat Bridge: speech IN, on this PC only. The microphone audio goes to a Web Worker in this page that runs a local
   Whisper model from /voice-assets/ (hash-checked by the server). Nothing is uploaded; there is no cloud fallback.
   The browser's own SpeechRecognition is never used because it streams audio to the browser vendor's servers.
   Pure helpers are exported for node tests; the controller attaches window.PacketRatListen. */
(function (root) {
  'use strict';
  var WAKE = ['hail packetrat', 'bridge packetrat', 'bridge'];
  var STAND_DOWN = ['stand down', 'secure the bridge'];

  function normalize(text) {
    return String(text == null ? '' : text).toLowerCase().replace(/[^a-z0-9\s]/g, ' ').replace(/\s+/g, ' ').trim();
  }
  // "Bridge, what is most urgent?" -> { woke: true, command: 'what is most urgent' }. The hail must open the utterance.
  function matchWake(text, phrases, standDown) {
    var n = normalize(text);
    var stops = standDown || STAND_DOWN;
    for (var s = 0; s < stops.length; s++) if (n === stops[s] || n.indexOf(stops[s] + ' ') === 0) return { woke: false, standDown: true, command: '' };
    var list = (phrases || WAKE).map(normalize).sort(function (a, b) { return b.length - a.length; });
    for (var i = 0; i < list.length; i++) {
      var p = list[i];
      if (n === p) return { woke: true, standDown: false, command: '' };
      if (n.indexOf(p + ' ') === 0) return { woke: true, standDown: false, command: n.slice(p.length + 1).trim() };
    }
    return { woke: false, standDown: false, command: '' };
  }

  function downsample(input, inRate, outRate) {
    outRate = outRate || 16000;
    if (!input || !input.length) return new Float32Array(0);
    if (inRate === outRate) return Float32Array.from(input);
    if (inRate < outRate) throw new Error('Input rate is below ' + outRate + ' Hz.');
    var ratio = inRate / outRate, len = Math.floor(input.length / ratio), out = new Float32Array(len);
    for (var i = 0; i < len; i++) {
      var a = Math.floor(i * ratio), b = Math.min(input.length, Math.floor((i + 1) * ratio)), sum = 0;
      for (var j = a; j < b; j++) sum += input[j];
      out[i] = b > a ? sum / (b - a) : 0;
    }
    return out;
  }

  // Energy VAD: feed 16 kHz chunks, get back one Float32Array per finished utterance (or null).
  function createVad(opts) {
    opts = opts || {};
    var rate = opts.rate || 16000, threshold = opts.threshold || 0.015;
    var minSpeech = (opts.minSpeechMs || 250) * rate / 1000, endSilence = (opts.endSilenceMs || 700) * rate / 1000;
    var maxLen = (opts.maxMs || 15000) * rate / 1000;
    var buf = [], speech = 0, silence = 0, active = false;
    function rms(c) { var s = 0; for (var i = 0; i < c.length; i++) s += c[i] * c[i]; return Math.sqrt(s / (c.length || 1)); }
    function flush() {
      var out = null;
      if (active && speech >= minSpeech) { var total = buf.reduce(function (n, c) { return n + c.length; }, 0); out = new Float32Array(total); var o = 0; buf.forEach(function (c) { out.set(c, o); o += c.length; }); }
      buf = []; speech = 0; silence = 0; active = false; return out;
    }
    return {
      feed: function (chunk) {
        var loud = rms(chunk) >= threshold;
        if (!active) { if (!loud) return null; active = true; }
        buf.push(chunk);
        if (loud) { speech += chunk.length; silence = 0; } else silence += chunk.length;
        var len = buf.reduce(function (n, c) { return n + c.length; }, 0);
        if (silence >= endSilence || len >= maxLen) return flush();
        return null;
      },
      reset: function () { buf = []; speech = 0; silence = 0; active = false; }
    };
  }

  var api = { normalize: normalize, matchWake: matchWake, downsample: downsample, createVad: createVad, WAKE: WAKE.slice() };

  // ---- Browser controller (not exercised by the node tests) ----
  if (typeof root.document !== 'undefined') {
    var worker = null, ctx = null, stream = null, node = null, ready = null, nextId = 1, pending = {};
    var talking = false, talkChunks = [], hail = null, vad = null, busy = false;
    function loadWorker() {
      if (ready) return ready;
      ready = new Promise(function (resolve, reject) {
        worker = new root.Worker('voice-worker.js', { type: 'module' });
        worker.onmessage = function (e) {
          var m = e.data || {};
          if (m.type === 'ready') resolve();
          else if (m.type === 'text' && pending[m.id]) { pending[m.id].resolve(m.text); delete pending[m.id]; }
          else if (m.type === 'error') { var err = new Error(m.message || 'Speech model error'); if (m.id && pending[m.id]) { pending[m.id].reject(err); delete pending[m.id]; } else { reject(err); ready = null; } }
        };
        worker.onerror = function () { ready = null; reject(new Error('The speech worker could not start.')); };
        worker.postMessage({ type: 'load' });
      });
      return ready;
    }
    function transcribe(audio) {
      return loadWorker().then(function () {
        return new Promise(function (resolve, reject) { var id = nextId++; pending[id] = { resolve: resolve, reject: reject }; worker.postMessage({ type: 'transcribe', id: id, audio: audio }, [audio.buffer]); });
      });
    }
    function openMic() {
      if (stream) return Promise.resolve();
      return root.navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true } }).then(function (s) {
        stream = s; ctx = new root.AudioContext();
        return ctx.audioWorklet.addModule('voice-worklet.js').then(function () {
          var src = ctx.createMediaStreamSource(stream); node = new root.AudioWorkletNode(ctx, 'packetrat-capture');
          node.port.onmessage = function (e) {
            var chunk = downsample(e.data, ctx.sampleRate, 16000);
            if (talking) talkChunks.push(chunk);
            else if (hail && vad) { var u = vad.feed(chunk); if (u && !busy) handleUtterance(u); }
          };
          src.connect(node);
        });
      });
    }
    function closeMic() {
      if (talking || hail) return;
      if (stream) stream.getTracks().forEach(function (t) { t.stop(); });
      if (ctx) ctx.close(); stream = null; ctx = null; node = null;
      if (api.onMic) api.onMic(false);
    }
    function handleUtterance(audio) {
      busy = true;
      transcribe(audio).then(function (text) {
        var m = matchWake(text);
        if (m.standDown) { api.setHail(false); if (api.onStandDown) api.onStandDown(); }
        else if (m.woke && hail) hail(m.command);
      }).catch(function (e) { if (api.onError) api.onError(e); }).then(function () { busy = false; });
    }
    api.startTalk = function () {
      if (talking) return Promise.resolve();
      talking = true; talkChunks = [];
      return openMic().then(function () { if (api.onMic) api.onMic(true); }).catch(function (e) { talking = false; throw e; });
    };
    api.stopTalk = function () {
      if (!talking) return Promise.resolve('');
      talking = false;
      var total = talkChunks.reduce(function (n, c) { return n + c.length; }, 0), audio = new Float32Array(total), o = 0;
      talkChunks.forEach(function (c) { audio.set(c, o); o += c.length; }); talkChunks = [];
      closeMic();
      if (total < 16000 * 0.3) return Promise.resolve('');
      return transcribe(audio);
    };
    // The hail is opt-in, never remembered across sessions, and keeps the microphone open only while it is on.
    api.setHail = function (on, onCommand) {
      if (!on) { hail = null; vad = null; var cb = api.onHail; closeMic(); if (cb) cb(false); return Promise.resolve(); }
      hail = onCommand || function () {}; vad = createVad();
      return openMic().then(function () { if (api.onMic) api.onMic(true); if (api.onHail) api.onHail(true); }).catch(function (e) { hail = null; vad = null; throw e; });
    };
    root.PacketRatListen = api;
  }
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window !== 'undefined' ? window : globalThis);
