(() => {
  if (!/^(?:[^.]+\.)*netflix\.com$/.test(location.hostname) || window.__netflixNativeMultichannelStatus) return;
  const status = {enabled: true, changedSerializations: 0, matchedProfileArrays: 0, requestedAtmos: false, deliveredAudio: 'unverified'};
  window.__netflixNativeMultichannelStatus = status;
  const original = JSON.stringify;
  const additions = ['ddplus-2.0-dash', 'ddplus-5.1-dash', 'ddplus-5.1hq-dash', 'ddplus-atmos-dash'];
  JSON.stringify = function(value, replacer, spacing) {
    if (replacer != null) return original.call(this, value, replacer, spacing);
    let modified = false;
    const output = original.call(this, value, (key, item) => {
      if (key !== 'profiles' || !Array.isArray(item) || !item.every(entry => typeof entry === 'string') ||
          !item.some(entry => /^(heaac|xheaac|aac)-/.test(entry))) return item;
      status.matchedProfileArrays += 1;
      status.requestedAtmos = true;
      const extra = additions.filter(entry => !item.includes(entry));
      modified ||= extra.length > 0;
      return extra.length ? [...item, ...extra] : item;
    }, spacing);
    status.changedSerializations += Number(modified);
    return output;
  };
})();
