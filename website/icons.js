/* Native artwork selection is an enhancement; generation 26 is the HTML fallback. */
(() => {
  'use strict';
  const body = document.querySelector('.icon-body');
  if (!body) return;
  const within = (work, milliseconds) => new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Icon preparation timed out')), milliseconds);
    Promise.resolve(work).then(value => { clearTimeout(timer); resolve(value); }, error => { clearTimeout(timer); reject(error); });
  });
  const decode = src => {
    const image = new Image();
    image.src = src;
    return image.decode();
  };
  async function generation() {
    try {
      const hints = navigator.userAgentData;
      if (hints?.platform !== 'macOS' || hints.mobile || typeof hints.getHighEntropyValues !== 'function') return 26;
      const data = await within(hints.getHighEntropyValues(['platformVersion']), 250);
      if (data.platform !== 'macOS' || data.mobile || typeof data.platformVersion !== 'string' ||
          !/^\d+(?:\.\d+){0,2}$/.test(data.platformVersion)) return 26;
      return Number(data.platformVersion.split('.')[0]) >= 27 ? 27 : 26;
    } catch { return 26; }
  }
  window.mousuIconReady = (async () => {
    let selected = await generation();
    let layered = false;
    if (selected === 27) {
      try {
        // Prepare the entire set before swapping: no mixed generations mid-wink.
        await within(Promise.all([
          'assets/mousu-icon-27-160.webp', 'assets/mousu-icon-27-320.webp',
          'assets/mousu-icon-paused-27-320.webp', 'assets/mousu-favicon-27.png',
          'assets/mousu-icon-parts-27.webp',
        ].map(decode)), 1800);
        layered = true;
      } catch { selected = 26; }
    }
    if (selected === 26) {
      try { await within(decode('assets/mousu-icon-parts-26.webp'), 1800); layered = true; }
      catch { /* The original complete icon can still perform without parts. */ }
    }
    if (selected === 27) {
      const active = body.querySelector('.icon-active');
      active.srcset = 'assets/mousu-icon-27-160.webp 160w, assets/mousu-icon-27-320.webp 320w';
      active.src = 'assets/mousu-icon-27-160.webp';
      body.querySelector('.icon-paused').src = 'assets/mousu-icon-paused-27-320.webp';
      body.querySelectorAll('.icon-smear img').forEach(image => { image.src = 'assets/mousu-icon-27-320.webp'; });
      document.querySelector('link[rel="icon"]').href = 'assets/mousu-favicon-27.png';
    }
    document.documentElement.dataset.iconGeneration = String(selected);
    if (layered) body.dataset.layered = 'true';
    return selected;
  })();
})();
