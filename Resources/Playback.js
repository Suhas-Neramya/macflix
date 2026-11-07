(() => {
  if (location.hostname !== 'netflix.com' && !location.hostname.endsWith('.netflix.com')) return;
  if (window.macflixPlayback) return;
  function control(pauseOnly = false) {
    const video = document.querySelector('video');
    const paused = video?.paused ?? true;
    const action = pauseOnly || !paused ? 'pause' : 'play';
    const resume = () => {
      const button = document.querySelector('[data-uia="player-resume"], [data-uia="interrupt-autoplay-continue"], button[data-uia="control-play-pause-play"]');
      if (button && !button.disabled && button.getBoundingClientRect().width > 0) { button.click(); return true; }
      return false;
    };
    const failed = () => window.webkit?.messageHandlers.playback?.postMessage({playbackFailed: true});
    if (video) {
      if (action === 'pause') { video.pause(); return; }
      Promise.resolve(video.play()).catch(() => { if (!resume()) failed(); });
    } else if (!resume()) {
      failed();
    }
  }
  window.macflixPlayback = {pause: () => control(true)};
  const held = new Set();
  const keyOf = event => event.code === 'Space' || event.keyCode === 32 ? 'Space' : event.key?.toLowerCase() === 'k' ? 'k' : null;
  window.addEventListener('keydown', event => {
    const key = keyOf(event);
    const field = document.activeElement;
    if (!key || event.metaKey || event.ctrlKey || event.altKey ||
        !location.pathname.startsWith('/watch/') ||
        field && (['INPUT', 'TEXTAREA', 'SELECT'].includes(field.tagName) || field.isContentEditable)) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    if (event.repeat || held.has(key)) return;
    held.add(key);
    control();
  }, true);
  window.addEventListener('keyup', event => {
    if (!held.delete(keyOf(event))) return;
    event.preventDefault();
    event.stopImmediatePropagation();
  }, true);
  window.addEventListener('blur', () => held.clear());
  let lastReport = 0, route = '';
  setInterval(() => {
    const watching = location.pathname.startsWith('/watch/');
    const video = watching ? document.querySelector('video') : null;
    const nextRoute = watching ? location.pathname : '';
    if (nextRoute === route && Date.now() - lastReport < 2000) return;
    route = nextRoute; lastReport = Date.now();
    window.webkit?.messageHandlers.playback?.postMessage({
      watching,
      playing: !!video && !video.paused && !video.ended
    });
  }, 500);
})();
