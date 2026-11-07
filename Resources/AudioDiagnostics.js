async function (preferAtmos = false, nativeBridgeEnabled = false) {
  const report = {
    requestPatch: {enabled: false},
    selectedTrack: null,
    availableTracks: [],
    trackInspection: 'No active Netflix player',
    atmosSelection: 'Not attempted',
    dolbyDigitalPlusCanPlay: document.createElement('video').canPlayType('audio/mp4; codecs="ec-3"'),
    spatialAudioCapability: [],
    note: 'Capability checks and track metadata do not prove actual Atmos rendering.'
  };
  if (location.hostname !== 'netflix.com' && !location.hostname.endsWith('.netflix.com')) {
    report.trackInspection = 'Not a Netflix page';
    return JSON.stringify(report, null, 2);
  }
  const native = window.__netflixDevNativeAudioStatus;
  report.nativeAudioBridge = {
    enabled: nativeBridgeEnabled === true,
    available: !!native && typeof native === 'object',
    active: native?.active === true,
    reason: ['waiting','unavailable','starting','native','preparing','timeout','protected-audio','unsupported-audio','decode-error','listener-failed','stale-session','invalid-message','parser-error','native-error','track-change','media-gone','media-change','queue-limit','navigation'].includes(native?.reason) ? native.reason : 'unknown',
    state: ['idle', 'collecting', 'preparing', 'ready', 'stopped'].includes(native?.state) ? native.state : 'unavailable',
    nativeTime: Number.isFinite(native?.nativeTime) ? Math.max(0, native.nativeTime) : 0,
    driftSeconds: Number.isFinite(native?.driftSeconds) ? native.driftSeconds : 0,
    seeking: native?.seeking === true,
    rate: Number.isFinite(native?.rate) ? native.rate : 1,
    segments: Number.isSafeInteger(native?.segments) && native.segments >= 0 ? native.segments : 0,
    bytes: Number.isSafeInteger(native?.bytes) && native.bytes >= 0 ? native.bytes : 0,
    audible: native?.audible === true
  };
  const patch = window.__netflixNativeMultichannelStatus;
  if (patch) {
    report.requestPatch = {
      enabled: patch.enabled === true,
      changedSerializations: Number.isSafeInteger(patch.changedSerializations) ? patch.changedSerializations : 0,
      matchedProfileArrays: Number.isSafeInteger(patch.matchedProfileArrays) ? patch.matchedProfileArrays : 0,
      requestedAtmos: patch.requestedAtmos === true
    };
  }
  const configurations = ['file', 'media-source'].flatMap(type => [
    {type, label: 'DD+ 5.1', channels: '6', spatialRendering: false},
    {type, label: 'Atmos decoding', channels: '16', spatialRendering: false},
    {type, label: 'Atmos spatial rendering', channels: '16', spatialRendering: true}
  ]);
  async function inspectCapabilities() {
    return Promise.all(configurations.map(async sample => {
    if (!navigator.mediaCapabilities?.decodingInfo) return {...sample, result: 'API unavailable'};
    let timer;
    try {
      const info = await Promise.race([
        navigator.mediaCapabilities.decodingInfo({type: sample.type, audio: {
          contentType: 'audio/mp4; codecs="ec-3"', channels: sample.channels,
          bitrate: 768000, samplerate: 48000, spatialRendering: sample.spatialRendering
        }}),
        new Promise((_, reject) => {timer = setTimeout(() => reject(new Error('timeout')), 3000);})
      ]);
      return {...sample, supported: info.supported === true};
    } catch (error) {
      return {...sample, error: error.message === 'timeout' ? 'timeout' : 'Capability query failed'};
    } finally {clearTimeout(timer);}
    }));
  }

  function metadata(track) {
    if (!track || typeof track !== 'object') return null;
    const result = {};
    for (const key of ['displayName', 'language', 'bcp47', 'codec', 'channels', 'isAtmos', 'isDolbyAtmos', 'trackType', 'rawTrackType', 'contentProfile']) {
      const value = track[key];
      if (typeof value === 'string') result[key] = value.slice(0, 160);
      else if (typeof value === 'boolean' || (typeof value === 'number' && Number.isFinite(value))) result[key] = value;
    }
    return result;
  }
  function isAtmos(track) {
    return track?.isAtmos === true || track?.isDolbyAtmos === true ||
      track?.contentProfile === 'ddplus-atmos-dash' ||
      (typeof track?.displayName === 'string' && /\bDolby Atmos\b/i.test(track.displayName));
  }
  function language(track) {
    const value = track?.bcp47 || track?.language;
    return typeof value === 'string' && /^[a-z]{2,3}(?:-[a-z0-9]{2,8})*$/i.test(value) ? value.toLowerCase() : null;
  }
  async function inspectPlayer() {
  try {
    const app = window.netflix?.appContext;
    const playerApp = typeof app?.getPlayerApp === 'function' ? app.getPlayerApp() : app?.state?.playerApp;
    const api = playerApp?.getAPI?.()?.videoPlayer;
    const sessions = api?.getAllPlayerSessionIds?.();
    if (!Array.isArray(sessions) || !sessions.length) return;
    const player = api.getVideoPlayerBySessionId(sessions[sessions.length - 1]);
    if (typeof player?.getAudioTrack !== 'function') {
      report.trackInspection = 'Selected-track API unavailable';
      return;
    }
    const current = player.getAudioTrack();
    report.selectedTrack = metadata(current);
    report.trackInspection = 'Player metadata available; output format unverified';
    const list = typeof player.getAudioTrackList === 'function' ? player.getAudioTrackList() : null;
    if (Array.isArray(list)) report.availableTracks = list.slice(0, 100).map(metadata).filter(Boolean);
    else report.trackInspection = 'Selected track available; track-list API unavailable';

    // shortcut: Netflix's private track API can change; skip unknown shapes instead of guessing.
    const attempts = window.__netflixDevAtmosAttempts ||= new WeakMap();
    if (isAtmos(current)) report.atmosSelection = 'Selected track reports Atmos; output unverified';
    else if (!preferAtmos || !report.requestPatch.enabled) report.atmosSelection = 'Preference disabled';
    else if (attempts.has(player)) report.atmosSelection = attempts.get(player);
    else if (!report.dolbyDigitalPlusCanPlay) {
      report.atmosSelection = 'Dolby Digital Plus playback unavailable; kept current audio';
    } else if (!Array.isArray(list) || typeof player.setAudioTrack !== 'function') {
      report.atmosSelection = 'Track-selection API unavailable; kept current audio';
    } else {
      const lang = language(current);
      const candidate = list.find(track => isAtmos(track) && lang && language(track) === lang &&
        track.trackType === current.trackType && track.rawTrackType === current.rawTrackType &&
        (typeof track.id === 'string' || typeof track.id === 'number') && track.id !== current.id);
      if (!candidate) {
        report.atmosSelection = 'No explicit Atmos alternative in the selected language/type; kept current audio';
      } else {
        attempts.set(player, 'Atmos selection requested once; awaiting selected-track confirmation');
        try {
          await player.setAudioTrack(candidate);
          report.selectedTrack = metadata(player.getAudioTrack());
          report.atmosSelection = isAtmos(player.getAudioTrack())
            ? 'Selected track reports Atmos; output unverified'
            : attempts.get(player);
        } catch (_) {
          attempts.set(player, 'Player rejected the Atmos selection; no retry for this session');
          report.atmosSelection = attempts.get(player);
        }
      }
    }
  } catch (_) {
    report.trackInspection = 'Player inspection failed; no raw error or account data recorded';
  }
  }
  await inspectPlayer();
  report.spatialAudioCapability = await inspectCapabilities();
  return JSON.stringify(report, null, 2);
}
