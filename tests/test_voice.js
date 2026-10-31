// Offline tests for Web/voice.js: speech text cleanup and local-voice-only selection. No audio is played.
const assert = require('assert');
const v = require('../Web/voice.js');
assert.strictEqual(v.toSpeech('**Bold** see https://example.test/x?a=1 | table'), 'Bold see link table');
assert.strictEqual(v.toSpeech(null), '');
assert(v.toSpeech('word '.repeat(500), 100).length <= 103, 'long text is cut');
const voices = [
  { name: 'Online (Natural) A', lang: 'en-US', localService: false },
  { name: 'Google US English', lang: 'en-US', localService: false },
  { name: 'Local FR', lang: 'fr-FR', localService: true },
  { name: 'Local EN', lang: 'en-GB', localService: true },
];
assert.strictEqual(v.pickLocalVoice(voices, 'en').name, 'Local EN', 'prefers a local voice in the language');
assert.strictEqual(v.pickLocalVoice(voices, 'de').name, 'Local FR', 'falls back to any local voice');
assert.strictEqual(v.pickLocalVoice(voices.slice(0, 2), 'en'), null, 'never picks a cloud voice');
assert.strictEqual(v.pickLocalVoice([], 'en'), null);
(async () => {
  assert.strictEqual(await v.speak('hello'), false, 'no speech engine in node: stays silent');
  let said = null;
  v.registerEngine({ speak: async (t) => { said = t; } });
  assert.strictEqual(await v.speak('Aye **aye** https://x.test'), true);
  assert.strictEqual(said, 'Aye aye link', 'a plugged-in engine gets cleaned text');
  v.registerEngine(null);
  console.log('voice tests passed');
})();
