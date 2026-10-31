/* PacketRat Bridge voice: speech out with LOCAL voices only. Nothing here sends audio or text off this PC.
   The pure helpers are exported for node tests; the browser part attaches window.PacketRatVoice. */
(function (root) {
  'use strict';
  function toSpeech(text, max) {
    var t = String(text == null ? '' : text).replace(/https?:\/\/\S+/g, ' link ').replace(/[*_`#>|\[\]{}<]/g, ' ').replace(/\s+/g, ' ').trim();
    max = max || 1200;
    return t.length > max ? t.slice(0, max).replace(/\s+\S*$/, '') + '...' : t;
  }
  // Only voices the OS runs on this PC. Edge's "Online (Natural)" voices and Chrome's "Google" voices stream to the cloud.
  function pickLocalVoice(voices, lang) {
    var local = (voices || []).filter(function (v) { return v && v.localService === true; });
    if (!local.length) return null;
    var want = String(lang || 'en').toLowerCase();
    var match = local.filter(function (v) { return String(v.lang || '').toLowerCase().indexOf(want) === 0; });
    return (match.length ? match : local)[0];
  }
  var api = { toSpeech: toSpeech, pickLocalVoice: pickLocalVoice };

  var plug = null; // optional engine: { speak(text) -> Promise, stop() }, e.g. a local Piper adapter added later
  api.registerEngine = function (engine) { plug = engine && typeof engine.speak === 'function' ? engine : null; };
  api.available = function () { return !!plug || !!(root.speechSynthesis && root.SpeechSynthesisUtterance); };
  api.stop = function () { if (plug && plug.stop) plug.stop(); if (root.speechSynthesis) root.speechSynthesis.cancel(); };
  api.speak = function (text) {
    var say = toSpeech(text);
    if (!say) return Promise.resolve(false);
    if (plug) return Promise.resolve(plug.speak(say)).then(function () { return true; });
    if (!root.speechSynthesis || !root.SpeechSynthesisUtterance) return Promise.resolve(false);
    var voice = pickLocalVoice(root.speechSynthesis.getVoices(), (root.navigator && root.navigator.language || 'en').slice(0, 2));
    if (!voice) return Promise.resolve(false); // no local voice installed: stay silent rather than use a cloud one
    return new Promise(function (resolve) {
      var u = new root.SpeechSynthesisUtterance(say);
      u.voice = voice; u.lang = voice.lang; u.onend = function () { resolve(true); }; u.onerror = function () { resolve(false); };
      root.speechSynthesis.cancel(); root.speechSynthesis.speak(u);
    });
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.PacketRatVoice = api;
})(typeof window !== 'undefined' ? window : globalThis);
