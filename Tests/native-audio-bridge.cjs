const vm = require('node:vm');
const fs = require('node:fs');
const assert = require('node:assert/strict');
const source = fs.readFileSync(require('node:path').join(__dirname, '../Resources/NativeAudioBridge.js'), 'utf8');

async function setup({failAppend = false, failNative = false, failHandoff = false, userMuted = false} = {}) {
  const sent = [], appended = [], listeners = {};
  class SourceBuffer {
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
    muted: {get() { return this._muted || false; }, set(value) { this._muted = !!value; }, configurable: true},
    volume: {get() { return this._volume ?? 1; }, set(value) { this._volume = value; }, configurable: true}
  });
  const media = new Media(); Object.assign(media, {paused: false, ended: false, seeking: false, playbackRate: 1, currentTime: 4});
  media.muted = userMuted;
  let replyCount = 0;
  const context = vm.createContext({
    location: {hostname: 'www.netflix.com'},
    document: {querySelectorAll: () => [media], querySelector: () => media, addEventListener: (name, fn) => {listeners[name] = fn;}},
    window: {MediaSource, SourceBuffer, HTMLMediaElement: Media, webkit: {messageHandlers: {nativeAudio: {postMessage: async msg => {
      sent.push(msg);
      if ((failNative && msg.action === "append") || (failHandoff && msg.audible === true)) throw new Error(typeof failNative === 'string' ? `MacflixNativeAudio:${failNative}` : "Native audio could not decode the sample");
      if (msg.action === 'stop') return {state:'stopped'};
      replyCount++;
      return {state:msg.action === 'begin' ? 'collecting' : 'ready', nativeTime:4, driftSeconds:0, seeking:false, rate:1, segments:3, bytes:4, audible:msg.audible === true};
    }}}}},
    sessionStorage: {getItem: () => null, setItem() {}},
    btoa: value => Buffer.from(value, 'binary').toString('base64'),
    setTimeout, clearTimeout, setInterval() { return 1; }, clearInterval() {}, Date, Uint8Array, ArrayBuffer, Reflect, Promise, WeakMap, Set, Math, Number, String, Object, Error
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
  const output = failAppend ? null : buffer.appendBuffer(new Uint8Array([0,1,2,255]).buffer);
  await new Promise(resolve => setImmediate(resolve));
  return {sent, appended, listeners, media, buffer, output, status:context.window.__netflixDevNativeAudioStatus};
}

(async () => {
  const ok = await setup();
  assert.equal(ok.output, 'original-result');
  assert.deepEqual(ok.appended, [[0,1,2,255]]);
  assert.deepEqual(ok.sent.filter(m => m.action === 'append').map(m => Buffer.from(m.data, 'base64').toJSON().data), [[0,1,2,255]]);
  assert.equal(ok.sent[0].action, 'begin');
  assert.equal(ok.status.active, true);
  assert.equal(ok.media._muted, true, 'Web audio is physically muted only after handoff');
  assert.equal(ok.media.muted, false, 'The page still sees the user mute preference');
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
  const failedHandoff = await setup({failHandoff:true});
  assert.equal(failedHandoff.media._muted, false, 'Failure after muting restores web audio');
  assert.equal(failedHandoff.status.active, false);
  const mutedUser = await setup({failNative:true,userMuted:true});
  assert.equal(mutedUser.media.muted, true, 'Failure preserves a user-muted player');
  const untouched = await setup({failAppend:true});
  assert.throws(() => untouched.buffer.appendBuffer(new Uint8Array([1]).buffer), /browser rejected/);
  assert.equal(untouched.sent.length, 0);
  const denied = vm.createContext({location:{hostname:'notnetflix.com'}, window:{}, document:{}});
  vm.runInContext(source, denied);
  assert.equal(denied.window.__netflixDevNativeAudioStatus, undefined);
  console.log('Passed: Netflix-only install, byte-identical append forwarding after original acceptance, original return/errors, and native begin ordering.');
})().catch(error => {console.error(error); process.exitCode = 1;});
