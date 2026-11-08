const vm = require('node:vm');
const fs = require('node:fs');
const assert = require('node:assert/strict');
const source = fs.readFileSync(require('node:path').join(__dirname, '../Resources/NativeAudioBridge.js'), 'utf8');

function boxes(...types) {
  const result = new Uint8Array(types.length * 8);
  types.forEach((type, index) => {
    const offset = index * 8;result[offset + 3] = 8;
    for (let i = 0; i < 4; i++) result[offset + 4 + i] = type.charCodeAt(i);
  });
  return result.buffer;
}
function boxTypes(data) {
  const bytes = Buffer.from(data, 'base64'), types = [];
  for (let offset = 0; offset + 8 <= bytes.length;) {
    const size = bytes.readUInt32BE(offset);
    if (size < 8 || size > bytes.length - offset) return [];
    types.push(bytes.toString('ascii', offset + 4, offset + 8));offset += size;
  }
  return types.join('+');
}

async function setup({failAppend = false, failNative = false, failNativeAppendNumbers = [], failNativeAppendAfter = Infinity, failHandoff = false, userMuted = false, initialAppend = new Uint8Array([0,1,2,255]).buffer, prepareSyncs = 0, timestampOffset = 0, changeTimeDuringFirstSync = false} = {}) {
  const sent = [], appended = [], listeners = {}, audioEvents = [];
  let now = 1000, intervalTick;
  let remainingPrepareSyncs = prepareSyncs;
  let changedTimeDuringSync = false;
  const nativeAppendFailures = new Set(failNativeAppendNumbers);
  let nativeAppendCount = 0;
  class SourceBuffer {
    constructor() { this.timestampOffset = timestampOffset; }
    appendBuffer(input) {
      if (failAppend) throw new Error('browser rejected');
      appended.push(Array.from(new Uint8Array(input)));
      return 'original-result';
    }
    changeType() {}
    remove() {}
  }
  class MediaSource { addSourceBuffer(type) { this.buffer = new SourceBuffer(); return this.buffer; } }
  class Media {}
  Object.defineProperties(Media.prototype, {
    muted: {get() { return this._muted || false; }, set(value) { this._muted = !!value; audioEvents.push(value ? 'web-muted' : 'web-unmuted'); }, configurable: true},
    volume: {get() { return this._volume ?? 1; }, set(value) { this._volume = value; }, configurable: true}
  });
  const media = new Media(); Object.assign(media, {paused: false, ended: false, seeking: false, playbackRate: 1, currentTime: 4});
  media.muted = userMuted;
  audioEvents.length = 0;
  let replyCount = 0;
  const context = vm.createContext({
    location: {hostname: 'www.netflix.com'},
    document: {querySelectorAll: () => [media], querySelector: () => media, addEventListener: (name, fn) => {listeners[name] = fn;}},
    window: {MediaSource, SourceBuffer, HTMLMediaElement: Media, webkit: {messageHandlers: {nativeAudio: {postMessage: async msg => {
      sent.push(msg);
      if (msg.action === 'append') {
        nativeAppendCount++;
        if (nativeAppendFailures.has(nativeAppendCount) || nativeAppendCount > failNativeAppendAfter) throw new Error('timeout');
      }
      if ((failNative && msg.action === "append") || (failHandoff && msg.audible === true)) throw new Error(typeof failNative === 'string' ? `MacflixNativeAudio:${failNative}` : "Native audio could not decode the sample");
      if (msg.action === 'sync' && msg.audible === true) audioEvents.push('native-audible');
      if (msg.action === 'sync' && changeTimeDuringFirstSync && !changedTimeDuringSync) {
        changedTimeDuringSync = true;
        media.currentTime = 5;
        return {state:'ready', nativeTime:4, driftSeconds:0, seeking:false, rate:1, segments:3, bytes:4, servedSegments:2, nativeSeekable:[[0,8]], loaded:[[0,6]], audible:false};
      }
      if (msg.action === 'sync' && remainingPrepareSyncs > 0) {
        remainingPrepareSyncs--;
        return {state:'preparing', nativeTime:4, driftSeconds:0, seeking:false, rate:0, segments:3, bytes:4, servedSegments:2, nativeSeekable:[[0,8]], loaded:[[0,6]], audible:false};
      }
      if (msg.action === 'stop') return {state:'stopped'};
      replyCount++;
      return {state:msg.action === 'begin' ? 'collecting' : 'ready', nativeTime:msg.action === 'sync' ? media.currentTime : 4, driftSeconds:0, seeking:false, rate:1, segments:3, bytes:4, servedSegments:2, nativeSeekable:[[0,8]], loaded:[[0,6]], audible:msg.audible === true};
    }}}}},
    sessionStorage: {getItem: () => null, setItem() {}},
    btoa: value => Buffer.from(value, 'binary').toString('base64'),
    setTimeout, clearTimeout, setInterval(callback) { intervalTick = callback; return 1; }, clearInterval() {}, Date: {now: () => now}, Uint8Array, ArrayBuffer, Reflect, Promise, WeakMap, Set, Math, Number, String, Object, Error
  });
  context.window.window = context.window;
  context.window.document = context.document;
  context.window.location = context.location;
  context.window.sessionStorage = context.sessionStorage;
  context.window.addEventListener = () => {};
  context.window.setInterval = context.setInterval;
  vm.runInContext('window.__proto__ = globalThis', context);
  vm.runInContext(source, context);
  const buffer = new MediaSource().addSourceBuffer('audio/mp4; codecs="ec-3"');
  const output = failAppend ? null : buffer.appendBuffer(initialAppend);
  await new Promise(resolve => setImmediate(resolve));
  const appendAgain = async (input = new Uint8Array([4,5,6,7]).buffer) => {const result = buffer.appendBuffer(input); await new Promise(resolve => setImmediate(resolve)); return result;};
  return {sent, appended, listeners, media, buffer, output, appendAgain, tick: async (ms, paused = false) => {now += ms; media.paused = paused; intervalTick(); await new Promise(resolve => setImmediate(resolve));}, status:context.window.__netflixDevNativeAudioStatus, audioEvents};
}

(async () => {
  const ok = await setup();
  assert.equal(ok.output, 'original-result');
  assert.deepEqual(ok.appended, [[0,1,2,255]]);
  assert.deepEqual(ok.sent.filter(m => m.action === 'append').map(m => Buffer.from(m.data, 'base64').toJSON().data), [[0,1,2,255]]);
  assert.equal(ok.sent[0].action, 'begin');
  assert.equal(ok.status.active, true);
  assert.equal(JSON.stringify(ok.status.nativeSeekable), '[[0,8]]');
  assert.equal(JSON.stringify(ok.status.loaded), '[[0,6]]');
  assert.equal(ok.status.servedSegments, 2);
  assert.equal(ok.status.timeline.sourceBufferTimestampOffset, 0);
  assert.equal(ok.media._muted, true, 'Web audio is physically muted only after handoff');
  assert.equal(ok.media.muted, false, 'The page still sees the user mute preference');
  assert(ok.audioEvents.indexOf('web-muted') < ok.audioEvents.indexOf('native-audible'), 'Mute WebKit before enabling native audio');
  ok.media.muted = true;
  await new Promise(resolve => setImmediate(resolve));
  assert(ok.sent.some(message => message.action === 'sync' && message.muted === true), 'User mute reaches native');
  const rejected = await setup({failNative:true});
  assert.equal(rejected.media._muted, false);
  assert.equal(rejected.status.active, false);
  assert(rejected.sent.some(message => message.action === 'stop'));
  const parserFailure = await setup({failNative:'parser-error'});
  assert.equal(parserFailure.status.reason, 'parser-error');
  assert(!JSON.stringify(parserFailure.status).includes('MacflixNativeAudio:'));
  const initial = boxes('ftyp','moov');
  const fragment = () => boxes('moof','mdat');
  const recovered = await setup({initialAppend:initial, failNativeAppendNumbers:[5]});
  await recovered.appendAgain(fragment());
  await recovered.appendAgain(fragment());
  await recovered.appendAgain(fragment());
  await recovered.appendAgain(fragment());
  assert.equal(recovered.status.reason, 'timeout');
  await recovered.appendAgain(fragment());
  assert.equal(recovered.sent.filter(message => message.action === 'begin').length, 2, 'Retry one transient failure on the same source buffer');
  const retryBegin = recovered.sent.findIndex((message, index) => index > 0 && message.action === 'begin');
  assert.deepEqual(recovered.sent.slice(retryBegin + 1).filter(message => message.action === 'append').map(message => boxTypes(message.data)),
    ['ftyp+moov', 'moof+mdat', 'moof+mdat', 'moof+mdat', 'moof+mdat'], 'Replay init and recent complete fragments before the live fragment');
  assert.equal(recovered.status.active, true);
  const retryLimit = await setup({initialAppend:initial, failNativeAppendAfter:4});
  await retryLimit.appendAgain(fragment());
  await retryLimit.appendAgain(fragment());
  await retryLimit.appendAgain(fragment());
  await retryLimit.appendAgain(fragment());
  assert.equal(retryLimit.status.reason, 'timeout');
  await retryLimit.appendAgain(fragment());
  await retryLimit.appendAgain(fragment());
  assert.equal(retryLimit.sent.filter(message => message.action === 'begin').length, 2, 'Do not retry repeatedly after the bounded retry also fails');
  assert.equal(retryLimit.status.active, false);
  const failedHandoff = await setup({failHandoff:true});
  assert.equal(failedHandoff.media._muted, false, 'Failure after muting restores web audio');
  assert.equal(failedHandoff.status.active, false);
  const mutedUser = await setup({failNative:true,userMuted:true});
  assert.equal(mutedUser.media.muted, true, 'Failure preserves a user-muted player');
  const prewarming = await setup({prepareSyncs:2, timestampOffset:-18.65});
  assert.equal(prewarming.media._muted, false, 'Keep WebKit audible during native preparation');
  assert.equal(prewarming.status.active, false);
  await prewarming.appendAgain();
  assert.equal(prewarming.media._muted, false, 'Continue WebKit playback while the native target is not ready');
  await prewarming.appendAgain();
  assert.equal(prewarming.status.active, true, 'Switch only after the native bridge reports ready');
  assert(prewarming.audioEvents.indexOf('web-muted') < prewarming.audioEvents.indexOf('native-audible'));
  assert.equal(prewarming.status.timeline.sourceBufferTimestampOffset, -18.65);
  const slowPrewarm = await setup({prepareSyncs:10});
  await slowPrewarm.tick(9000);
  assert.equal(slowPrewarm.media._muted, false, 'An eight second wait does not interrupt WebKit while native audio prepares');
  for (let i = 0; i < 9; i++) await slowPrewarm.tick(1000);
  assert.equal(slowPrewarm.status.active, true, 'A native track that becomes ready after nine seconds can take over');
  const boundedPrewarm = await setup({prepareSyncs:1000});
  await boundedPrewarm.tick(29000);
  await boundedPrewarm.tick(40000, true);
  await boundedPrewarm.tick(1000);
  assert.equal(boundedPrewarm.status.reason, 'preparing-timeout', 'Paused time does not consume the active-playback preparation budget');
  await boundedPrewarm.appendAgain(fragment());
  assert.equal(boundedPrewarm.sent.filter(message => message.action === 'begin').length, 1, 'Preparation expiry cannot replay a newer, forward-shifted buffer');
  assert.equal(boundedPrewarm.media._muted, false, 'Preparation expiry keeps WebKit audible');
  const userMuteDuringWarmup = await setup({prepareSyncs:2});
  userMuteDuringWarmup.media.muted = true;
  assert.equal(userMuteDuringWarmup.media._muted, true, 'A user mute during preparation applies immediately');
  assert.equal(userMuteDuringWarmup.media.muted, true, 'Native ownership does not clear user mute');
  const seekDuringReady = await setup({changeTimeDuringFirstSync:true});
  assert.equal(seekDuringReady.media._muted, false, 'A stale ready reply cannot mute WebKit after a concurrent seek');
  assert.equal(seekDuringReady.status.active, false);
  await seekDuringReady.appendAgain();
  assert.equal(seekDuringReady.status.active, true, 'Handoff waits for a ready reply aligned to the new playhead');
  const untouched = await setup({failAppend:true});
  assert.throws(() => untouched.buffer.appendBuffer(new Uint8Array([1]).buffer), /browser rejected/);
  assert.equal(untouched.sent.length, 0);
  const denied = vm.createContext({location:{hostname:'notnetflix.com'}, window:{}, document:{}});
  vm.runInContext(source, denied);
  assert.equal(denied.window.__netflixDevNativeAudioStatus, undefined);
  console.log('Passed: Netflix-only install, byte-identical append forwarding after original acceptance, original return/errors, and native begin ordering.');
})().catch(error => {console.error(error); process.exitCode = 1;});
