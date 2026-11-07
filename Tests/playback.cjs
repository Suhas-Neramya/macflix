const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const source = fs.readFileSync(path.join(__dirname, '../Resources/Playback.js'), 'utf8');

function setup({host = 'www.netflix.com', route = '/watch/123', focused = null, playerAPI = true,
  videoElement = true, controlButton = false, buttonDisabled = false, buttonWidth = 40, playReject = false} = {}) {
  const listeners = {}, intervals = [], actions = [], routes = [];
  let now = 10_000, videoQueries = 0;
  const video = {paused: false, pause() { actions.push('video.pause'); this.paused = true; }, play() {
    actions.push('video.play');
    if (playReject) return Promise.reject(new Error('play blocked'));
    this.paused = false;
    return Promise.resolve();
  }, ended: false};
  const controller = {isPaused: () => video.paused, pause() { actions.push('pause'); video.paused = true; }, play() { actions.push('play'); video.paused = false; }};
  const player = playerAPI ? {appContext: {getPlayerApp: () => ({getAPI: () => ({videoPlayer: {
    getAllPlayerSessionIds: () => ['session'], getVideoPlayerBySessionId: () => controller
  }})})}} : undefined;
  const window = {
    netflix: player,
    webkit: {messageHandlers: {playback: {postMessage: value => routes.push(value)}}},
    addEventListener: (name, fn) => { listeners[name] = fn; }
  };
  const fullscreen = {element: {id: 'existing-fullscreen'}, calls: []};
  const button = controlButton ? {disabled: buttonDisabled, getBoundingClientRect: () => ({width: buttonWidth}), click: () => actions.push('page.play')} : null;
  const context = vm.createContext({
    location: {hostname: host, pathname: route}, window,
    document: {activeElement: focused, fullscreenElement: fullscreen.element,
      documentElement: {requestFullscreen: () => fullscreen.calls.push('request')},
      exitFullscreen: () => fullscreen.calls.push('exit'),
      querySelector: selector => {
        if (selector === 'video') { videoQueries++; return videoElement ? video : null; }
        return button;
      }},
    Date: {now: () => now},
    setInterval: fn => { intervals.push(fn); return intervals.length; }
  });
  vm.runInContext(source, context);
  return {actions, fullscreen, intervals, listeners, routes, video, window, context,
    advance: ms => { now += ms; }, videoQueries: () => videoQueries};
}

function key(code, extra = {}) {
  return {code, key: code === 'Space' ? ' ' : code, keyCode: code === 'Space' ? 32 : 75,
    repeat: false, prevented: 0, stopped: 0, preventDefault() { this.prevented++; },
    stopImmediatePropagation() { this.stopped++; }, ...extra};
}

const fixture = setup();
fixture.listeners.keydown(key('Space'));
fixture.listeners.keydown(key('Space', {repeat: true}));
assert.deepEqual(fixture.actions, ['video.pause']);
fixture.listeners.keyup(key('Space'));
fixture.listeners.keydown(key('k'));
assert.deepEqual(fixture.actions, ['video.pause', 'video.play']);
fixture.listeners.keyup(key('k'));

for (const target of [{tagName: 'INPUT'}, {tagName: 'TEXTAREA'}, {tagName: 'SELECT'}, {tagName: 'DIV', isContentEditable: true}]) {
  const editable = setup({focused: target});
  const event = key('Space');
  editable.listeners.keydown(event);
  assert.equal(event.prevented, 0);
  assert.deepEqual(editable.actions, []);
}
for (const modifier of [{metaKey: true}, {ctrlKey: true}, {altKey: true}]) {
  const modified = setup();
  const event = key('k', modifier);
  modified.listeners.keydown(event);
  assert.equal(event.prevented, 0);
  assert.deepEqual(modified.actions, []);
}
const outsideWatch = setup({route: '/browse'});
outsideWatch.listeners.keydown(key('Space'));
assert.deepEqual(outsideWatch.actions, []);
const otherHost = setup({host: 'notnetflix.com'});
assert.equal(otherHost.window.macflixPlayback, undefined);

const sleepPause = setup();
sleepPause.video.paused = true;
sleepPause.window.macflixPlayback.pause();
assert.deepEqual(sleepPause.actions, ['video.pause']);
assert.equal(sleepPause.context.document.fullscreenElement, sleepPause.fullscreen.element);
assert.deepEqual(sleepPause.fullscreen.calls, []);
const videoFallback = setup({playerAPI: false});
videoFallback.listeners.keydown(key('Space'));
assert.deepEqual(videoFallback.actions, ['video.pause']);

const fullscreenPlayback = setup();
fullscreenPlayback.listeners.keydown(key('Space'));
fullscreenPlayback.listeners.keydown(key('Space', {repeat: true}));
assert.deepEqual(fullscreenPlayback.actions, ['video.pause']);
fullscreenPlayback.listeners.keyup(key('Space'));
fullscreenPlayback.listeners.keydown(key('k'));
assert.deepEqual(fullscreenPlayback.actions, ['video.pause', 'video.play']);
assert.equal(fullscreenPlayback.context.document.fullscreenElement, fullscreenPlayback.fullscreen.element);
assert.deepEqual(fullscreenPlayback.fullscreen.calls, []);

const fullScreenShortcut = setup();
const fullScreenKey = key('f');
fullScreenShortcut.listeners.keydown(fullScreenKey);
assert.equal(fullScreenKey.prevented, 0);
assert.deepEqual(fullScreenShortcut.actions, []);

const safePageFallback = setup({videoElement: false, controlButton: true});
safePageFallback.video.paused = true;
safePageFallback.listeners.keydown(key('k'));
assert.deepEqual(safePageFallback.actions, ['page.play']);
assert.equal(safePageFallback.context.document.fullscreenElement, safePageFallback.fullscreen.element);
assert.deepEqual(safePageFallback.fullscreen.calls, []);

const routeStatus = setup({route: '/browse'});
routeStatus.intervals[0]();
routeStatus.intervals[0]();
routeStatus.context.location.pathname = '/watch/456';
routeStatus.intervals[0]();
routeStatus.context.location.pathname = '/browse';
routeStatus.intervals[0]();
assert.deepEqual(routeStatus.routes.map(route => route.watching), [false, true, false]);

const telemetry = setup();
telemetry.intervals[0]();
const firstMetrics = JSON.parse(JSON.stringify(telemetry.routes.at(-1)));
assert.deepEqual(firstMetrics, {watching: true, playing: true});
assert.deepEqual(Object.keys(firstMetrics).sort(), ['playing', 'watching']);
telemetry.video.paused = true;
telemetry.advance(2000);
telemetry.intervals[0]();
assert.equal(telemetry.routes.at(-1).playing, false);
telemetry.video.paused = false;
telemetry.advance(2000);
telemetry.intervals[0]();
assert.equal(telemetry.routes.at(-1).playing, true);
telemetry.context.location.pathname = '/browse';
telemetry.intervals[0]();
assert.deepEqual(JSON.parse(JSON.stringify(telemetry.routes.at(-1))), {watching: false, playing: false});
const hiddenTelemetry = setup({route: '/browse'});
hiddenTelemetry.intervals[0]();
assert.equal(hiddenTelemetry.videoQueries(), 0);

async function testPlayFailureFallbacks() {
  const explicitButton = setup({controlButton: true, playReject: true});
  explicitButton.video.paused = true;
  explicitButton.listeners.keydown(key('k'));
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(explicitButton.actions, ['video.play', 'page.play']);
  assert.deepEqual(explicitButton.fullscreen.calls, []);
  assert.equal(explicitButton.context.document.fullscreenElement, explicitButton.fullscreen.element);
  assert(!explicitButton.routes.some(message => message.playbackFailed));

  const noControl = setup({controlButton: false, playReject: true});
  noControl.video.paused = true;
  noControl.listeners.keydown(key('k'));
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(noControl.actions, ['video.play']);
  assert(noControl.routes.some(message => message.playbackFailed === true));
  assert.deepEqual(noControl.fullscreen.calls, []);
  assert.equal(noControl.context.document.fullscreenElement, noControl.fullscreen.element);

  for (const options of [{controlButton: true, buttonDisabled: true}, {controlButton: true, buttonWidth: 0}]) {
    const unsafeControl = setup({...options, playReject: true});
    unsafeControl.video.paused = true;
    unsafeControl.listeners.keydown(key('k'));
    await new Promise(resolve => setImmediate(resolve));
    assert.deepEqual(unsafeControl.actions, ['video.play']);
    assert(unsafeControl.routes.some(message => message.playbackFailed === true));
    assert.deepEqual(unsafeControl.fullscreen.calls, []);
    assert.equal(unsafeControl.context.document.fullscreenElement, unsafeControl.fullscreen.element);
  }
}

testPlayFailureFallbacks().then(() => {
  console.log('Passed: media-element play/pause, modifiers, editable fields, repeats, fullscreen preservation, F shortcut pass-through, sleep pause, safe failure fallback, and playback-state-only route status.');
}).catch(error => { console.error(error); process.exitCode = 1; });
