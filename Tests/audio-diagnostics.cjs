const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const source = fs.readFileSync(path.join(__dirname, '../Resources/AudioDiagnostics.js'), 'utf8');

function setup(options = {}) {
  let selected = {id: 'stereo', language: 'en', trackType: 'PRIMARY', displayName: 'English', ...options.current};
  const atmosphere = {id: 'atmos', language: 'en', trackType: 'PRIMARY', isAtmos: true, displayName: 'English (Dolby Atmos)', ...options.candidate};
  const seen = [], selections = [], events = [];
  const player = {
    getAudioTrack: () => { events.push('selected-track'); return selected; },
    getAudioTrackList: () => [selected, atmosphere],
    setAudioTrack: track => {
      events.push('set-audio-track');
      selections.push(track);
      if (options.reject) throw new Error('private-secret-error');
      if (!options.pending) selected = track;
    }
  };
  if (options.missingList) delete player.getAudioTrackList;
  const context = vm.createContext({
    location: {hostname: options.host || 'www.netflix.com'},
    window: {
      __netflixNativeMultichannelStatus: {enabled: options.enabled !== false, changedSerializations: 1, requestedAtmos: true, privateToken: 'secret-token'},
      __netflixDevNativeAudioStatus: {state: 'ready', reason: 'parser-error', nativeTime: 12.5, driftSeconds: 0.03, seeking: false, rate: 1, segments: 3, bytes: 2048, audible: true, url: 'http://127.0.0.1/private', privateToken: 'secret-token'},
      netflix: options.noPlayer ? undefined : {appContext: {getPlayerApp: () => ({getAPI: () => ({videoPlayer: {
        getAllPlayerSessionIds: () => ['private-session-id'], getVideoPlayerBySessionId: () => player
      }})})}}
    },
    document: {
      createElement: () => ({canPlayType: () => options.ec3Support === false ? '' : 'probably'}),
      querySelector: () => options.noVideo ? null : {readyState: options.readyState ?? 0, networkState: options.networkState ?? 0,
        paused: options.paused ?? true, error: options.videoError === undefined ? null : {code: options.videoError, message: 'private media error'}}
    },
    navigator: options.noCapabilities ? {} : {mediaCapabilities: {decodingInfo: async config => {
      events.push('decoding-info');
      seen.push(config);
      return {supported: options.supported !== false, smooth: false, powerEfficient: false};
    }}},
    setTimeout, clearTimeout
  });
  return {seen, selections, events, run: async (prefer = true, nativeEnabled = true) => JSON.parse(await vm.runInContext(`(${source})(${prefer}, ${nativeEnabled})`, context))};
}

(async () => {
  const good = setup({current: {privateToken: 'secret-token'}, candidate: {urls: ['https://private.example/token'], privateToken: 'secret-token'}});
  let report = await good.run();
  assert.equal(report.spatialAudioCapability.length, 6);
  assert.deepEqual(report.startup, {videoPresent: true, readyState: 0, networkState: 0, paused: true, videoErrorCode: null, playerSessionPresent: true});
  assert.equal(good.seen.filter(x => x.audio.channels === '16' && x.audio.spatialRendering).length, 2);
  assert.equal(good.selections.length, 1);
  assert(good.events.indexOf('set-audio-track') < good.events.indexOf('decoding-info'), 'request a matching track before slow capability probes');
  assert.equal(report.selectedTrack.isAtmos, true);
  assert.match(report.atmosSelection, /output unverified/);
  assert(!JSON.stringify(report).includes('secret-token'));
  assert(!JSON.stringify(report).includes('private-session-id'));
  assert(!JSON.stringify(report).includes('private.example'));
  assert.deepEqual(report.nativeAudioBridge, {enabled: true, available: true, active: false, reason: 'parser-error', state: 'ready', nativeTime: 12.5, driftSeconds: 0.03, seeking: false, rate: 1, segments: 3, bytes: 2048, audible: true});
  assert(!JSON.stringify(report).includes('privateToken'));
  assert(!JSON.stringify(report).includes('127.0.0.1'));
  assert(!JSON.stringify(report).includes('private media error'));
  assert(!JSON.stringify(report).includes('"id"'));
  const startup = setup({noVideo: true, noPlayer: true, readyState: 99, networkState: -1, videoError: 9});
  report = await startup.run(false);
  assert.deepEqual(report.startup, {videoPresent: false, readyState: null, networkState: null, paused: null, videoErrorCode: null, playerSessionPresent: false});
  await good.run();
  assert.equal(good.selections.length, 1);

  for (const options of [
    {supported: false}, {noCapabilities: true}, {missingList: true}, {noPlayer: true},
    {enabled: false}, {ec3Support: false}, {candidate: {language: 'fr'}}, {candidate: {trackType: 'ASSISTIVE'}},
    {current: {language: undefined}}, {candidate: {id: undefined}},
    {candidate: {isAtmos: false, displayName: 'English (5.1)', channels: 6}},
    {candidate: {isAtmos: 'true', displayName: 'English', channels: 16}},
    {host: 'notnetflix.com'}
  ]) {
    const fixture = setup(options);
    await fixture.run();
    const shouldSelectBeforeCapabilities = options.supported === false || options.noCapabilities === true;
    assert.equal(fixture.selections.length, shouldSelectBeforeCapabilities ? 1 : 0,
      shouldSelectBeforeCapabilities ? 'matching Atmos selection precedes observational capability probes' : JSON.stringify(options));
  }
  const inspectionOnly = setup();
  await inspectionOnly.run(false);
  assert.equal(inspectionOnly.selections.length, 0);

  const pending = setup({pending: true});
  report = await pending.run();
  assert.match(report.atmosSelection, /awaiting/);
  await pending.run();
  assert.equal(pending.selections.length, 1, 'Do not override user preferences repeatedly');

  const rejected = setup({reject: true});
  report = await rejected.run();
  assert.match(report.atmosSelection, /rejected/);
  assert(!JSON.stringify(report).includes('private-secret-error'));
  await rejected.run();
  assert.equal(rejected.selections.length, 1);
  console.log('Passed: Atmos capability matrix, guarded track selection, language/type preservation, fallback, repeat prevention and report redaction.');
})().catch(error => {console.error(error); process.exitCode = 1;});
