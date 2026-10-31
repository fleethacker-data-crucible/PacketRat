// Offline tests for the pure parts of Web/voice-input.js: hail matching, resampling, voice-activity detection.
// The microphone, worker and Whisper model are not exercised here (the model files are not in the repo).
const assert = require('assert');
const v = require('../Web/voice-input.js');

// --- hail matching ---
assert.deepStrictEqual(v.matchWake('Bridge, what is most urgent?'), { woke: true, standDown: false, command: 'what is most urgent' });
assert.deepStrictEqual(v.matchWake('Bridge.'), { woke: true, standDown: false, command: '' });
assert.strictEqual(v.matchWake('Hail PacketRat, brief me').command, 'brief me');
assert.strictEqual(v.matchWake('Bridge PacketRat what needs me').command, 'what needs me', 'the longer hail wins over plain "bridge"');
assert.strictEqual(v.matchWake('  BRIDGE!!  read my queue ').command, 'read my queue', 'case and punctuation are ignored');
assert.strictEqual(v.matchWake('the bridge is closed today').woke, false, 'the hail must open the utterance');
assert.strictEqual(v.matchWake('bridgeport update').woke, false, 'a word that merely starts with "bridge" does not wake it');
assert.strictEqual(v.matchWake('').woke, false);
assert.strictEqual(v.matchWake(null).woke, false);
assert.strictEqual(v.matchWake('Stand down').standDown, true);
assert.strictEqual(v.matchWake('secure the bridge now').standDown, true);
assert.strictEqual(v.matchWake('Stand down').woke, false);

// --- spoken shortcuts ---
assert.strictEqual(v.intent('Brief me.'), 'brief');
assert.strictEqual(v.intent('  What needs me? '), 'brief');
assert.strictEqual(v.intent('Status report'), 'brief');
assert.strictEqual(v.intent('brief me on the weather in Norfolk'), null, 'only the whole phrase is a shortcut');
assert.strictEqual(v.intent(''), null);

// --- resampling ---
const tone = Float32Array.from({ length: 4800 }, (_, i) => Math.sin(2 * Math.PI * 440 * i / 48000));
const down = v.downsample(tone, 48000, 16000);
assert.strictEqual(down.length, 1600);
assert(Math.max(...down) > 0.5 && Math.max(...down) <= 1, 'amplitude survives averaging');
assert.strictEqual(v.downsample(tone, 16000, 16000).length, 4800);
assert.strictEqual(v.downsample(new Float32Array(0), 48000).length, 0);
assert.throws(() => v.downsample(tone, 8000, 16000), /below/);

// --- voice-activity detection ---
const rate = 16000, chunk = 1600; // 100 ms
const loud = () => Float32Array.from({ length: chunk }, (_, i) => 0.2 * Math.sin(i / 5));
const quiet = () => new Float32Array(chunk);
let vad = v.createVad();
let out = [];
const feed = (c) => { const r = vad.feed(c); if (r) out.push(r); };
for (let i = 0; i < 5; i++) feed(quiet());            // silence alone yields nothing
assert.strictEqual(out.length, 0);
for (let i = 0; i < 6; i++) feed(loud());             // 600 ms of speech
for (let i = 0; i < 8; i++) feed(quiet());            // then silence ends the utterance
assert.strictEqual(out.length, 1, 'one utterance');
assert(out[0].length >= 6 * chunk, 'the whole utterance is returned');
vad = v.createVad(); out = [];
feed(loud()); for (let i = 0; i < 8; i++) feed(quiet());
assert.strictEqual(out.length, 0, 'a 100 ms blip is too short and is dropped');
vad = v.createVad({ maxMs: 1000 }); out = [];
for (let i = 0; i < 12; i++) feed(loud());
assert(out.length >= 1, 'continuous noise is cut at the maximum length');
console.log('voice input tests passed');
