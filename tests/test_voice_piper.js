// Offline tests for the pure parts of Web/voice-piper.js. The real engine and model are exercised by the live check
// described in docs/VOICE.md, not here.
const assert = require('assert');
const p = require('../Web/voice-piper.js');
assert.deepStrictEqual(p.splitSentences(''), []);
assert.deepStrictEqual(p.splitSentences(null), []);
assert.deepStrictEqual(p.splitSentences('Bridge, all quiet.'), ['Bridge, all quiet.']);
const two = p.splitSentences('Bridge, you have 4 open actions, 2 high priority. Number 1, high priority, from Dana: Approve the budget.', 60);
assert(two.length >= 2 && two.every(s => s.length <= 60), 'long text splits into short chunks');
assert.strictEqual(two.join(' ').replace(/\s+/g, ' '), 'Bridge, you have 4 open actions, 2 high priority. Number 1, high priority, from Dana: Approve the budget.'.replace(/\s+/g, ' ').replace(/([:;]) /g, '$1 '), 'nothing is lost or reordered');
const long = p.splitSentences('word '.repeat(200), 100);
assert(long.length >= 10 && long.every(s => s.length <= 100), 'a run-on with no punctuation is still cut');
assert.strictEqual(p.BASE, '/voice-assets/tts/');
// install registers a Bridge engine; synthesis goes through the injected loader
const voice = require('../Web/voice.js');
globalThis.PacketRatVoice = voice;
let seen = [];
p._loader = async (cfg) => ({ synthesize: async (t, sp, ls) => { seen.push([t, sp, ls, cfg.model]); return { arrayBuffer: async () => new ArrayBuffer(0) }; } });
p.install({ model: 'en_GB-alan-medium', speaker: 0, lengthScale: 1.0 });
assert.strictEqual(voice.available(), true, 'the engine is registered');
(async () => {
  await p.preload();
  voice.registerEngine(null);
  console.log('voice piper tests passed');
})();
