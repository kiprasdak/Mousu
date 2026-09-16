/* Native Icon Composer artwork, a finite performance, and an event-driven ripple field. */
(() => {
  'use strict';
  const hero = document.querySelector('.hero');
  const surface = document.querySelector('.page-surface');
  const copy = hero?.querySelector('.hero-copy');
  const icon = hero?.querySelector('.hero-icon');
  const body = icon?.querySelector('.icon-body');
  const pausedIcon = icon?.querySelector('.icon-paused');
  const smear = icon?.querySelector('.icon-smear');
  const rays = [...icon.querySelectorAll('.icon-ray')];
  const pointerPart = icon.querySelector('.icon-pointer');
  const cameraLight = hero?.querySelector('.camera-light');
  const canvas = surface?.querySelector('.hero-field');
  const ctx = canvas?.getContext('2d');
  if (!ctx || !surface || !copy || !body || !Element.prototype.animate) return;

  // A missing HDR texture leaves the ordinary green dot intact.
  cameraLight?.querySelector('.camera-light-hdr')?.decode()
    .then(() => { cameraLight.dataset.hdrReady = ''; }).catch(() => {});

  const reduce = matchMedia('(prefers-reduced-motion: reduce)');
  const forced = matchMedia('(forced-colors: active)');
  const dark = matchMedia('(prefers-color-scheme: dark)');
  const contrast = matchMedia('(prefers-contrast: more)');
  const sources = [...copy.querySelectorAll('[data-ripple-text]')];
  const layer = document.createElement('div');
  layer.className = 'ripple-type';
  layer.setAttribute('aria-hidden', 'true');
  copy.append(layer);
  const clamp = (value, low, high) => Math.max(low, Math.min(high, value));
  const pointer = { x: -1000, y: -1000, inside: false, opacity: 0 };
  // Adapted from the app's CanvasScrollMotion and ScrollEdgeFeedback.
  const scrollMotion = { y: 0, targetY: 0 };
  const dotSpeeds = [.94, .97, 1, 1.03, 1.06];
  const scrollFields = new Float64Array(5 * 9 * 2);
  const smooth = value => { const t = clamp(value, 0, 1); return t * t * (3 - 2 * t); };
  let scrollPulses = [], scrollAccent = null, accentStrength = 0;
  let lastWheelInput = -Infinity, lastScrollInput = -Infinity;
  let pointerClientX = -1000, pointerClientY = -1000;
  let width = 0, height = 0, originX = 0, originY = 0, copyY = 0;
  let viewTop = 0, surfaceHeight = 0, spacing = 26, dotRow = NaN, iconVisible = true;
  let iconX = 0, iconY = 0, letters = [], waves = [], dots = [];
  let frame = 0, lastTime = 0, clock = 0, visible = true;
  let playing = false, cueIndex = 0, animations = [];
  const camera = { x: 0, y: 0 };
  let cameraOpacity = 0, winkStrength = 0;
  let lastPointerWave = -1, lastScrollY = scrollY;
  let ready = false, introPlayed = false, measuring = false, typeActive = false;
  const duration = 4500;
  const contacts = [{ name: 'M', start: 2990 }, { name: 'ü', start: 3500 }];
  let landingTargets = [];
  const disabled = () => reduce.matches || forced.matches || document.hidden;

  function showType(active) {
    if (active === typeActive) return;
    typeActive = active;
    layer.style.visibility = active ? 'visible' : 'hidden';
    sources.forEach(source => source.classList.toggle('ripple-source', active));
  }

  function measure() {
    if (measuring) return;
    measuring = true;
    icon.disabled = !ready || disabled();
    showType(false);
    layer.replaceChildren();
    letters = [];
    const surfaceRect = surface.getBoundingClientRect();
    const copyRect = copy.getBoundingClientRect();
    width = Math.min(surfaceRect.width, 1920);
    height = innerHeight;
    surfaceHeight = surfaceRect.height;
    const ratio = Math.min(devicePixelRatio || 1, 2, Math.sqrt(1800000 / (width * height)));
    canvas.width = Math.round(width * ratio);
    canvas.height = Math.round(height * ratio);
    canvas.style.height = `${height}px`;
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
    originX = surfaceRect.left + (surfaceRect.width - width) / 2;
    originY = surfaceRect.top + scrollY;
    viewTop = scrollY - originY;
    copyY = copyRect.top + scrollY - originY;
    const iconRect = icon.getBoundingClientRect();
    iconX = iconRect.left + iconRect.width / 2 - originX;
    iconY = icon.offsetTop + copyY + iconRect.height / 2;
    if (cameraLight) {
      const rect = cameraLight.getBoundingClientRect();
      camera.x = rect.left + rect.width / 2 - originX;
      camera.y = rect.top + scrollY + rect.height / 2 - originY;
    }
    spacing = Math.max(26, Math.sqrt(width * height / 1350));
    // Reserve the moving grid's overscan rows inside the same dot budget.
    while ((Math.ceil(width / spacing) + 3) * (Math.ceil(height / spacing) + 3) > 1600) spacing += 1;
    dotRow = NaN;
    updateDots();
    if (!disabled()) {
      const fragment = document.createDocumentFragment();
      const segmenter = typeof Intl.Segmenter === 'function' ? new Intl.Segmenter(undefined, { granularity: 'grapheme' }) : null;
      for (const source of sources) {
        const style = getComputedStyle(source);
        const walker = document.createTreeWalker(source, NodeFilter.SHOW_TEXT);
        let node;
        while ((node = walker.nextNode())) {
          const text = node.textContent;
          let position = 0;
          const segments = segmenter ? [...segmenter.segment(text)] : [...text].map(segment => {
            const part = { segment, index: position }; position += segment.length; return part;
          });
          for (const { segment, index } of segments) {
            if (!segment.trim()) continue;
            const range = document.createRange();
            range.setStart(node, index);
            range.setEnd(node, index + segment.length);
            const rect = range.getBoundingClientRect();
            if (!rect.width || !rect.height) continue;
            const glyph = document.createElement('span');
            glyph.className = 'ripple-letter';
            glyph.textContent = segment;
            Object.assign(glyph.style, {
              fontFamily: style.fontFamily, fontSize: style.fontSize, fontWeight: style.fontWeight,
              fontStyle: style.fontStyle, fontStretch: style.fontStretch,
              letterSpacing: style.letterSpacing, color: style.color,
              lineHeight: `${rect.height}px`, left: `${rect.left - copyRect.left}px`,
              top: `${rect.top - copyRect.top}px`,
            });
            const name = source.closest('.hero-name') ? segment : null;
            let ascent = 0, inkTop = 0;
            if (name) {
              ctx.save(); ctx.font = `${style.fontWeight} ${style.fontSize} ${style.fontFamily}`;
              const metrics = ctx.measureText(segment); ctx.restore();
              const fontSize = parseFloat(style.fontSize);
              const fontAscent = metrics.fontBoundingBoxAscent || fontSize * .96;
              const fontDescent = metrics.fontBoundingBoxDescent || fontSize * .21;
              const baseline = (rect.height - fontAscent - fontDescent) / 2 + fontAscent;
              ascent = metrics.actualBoundingBoxAscent;
              inkTop = rect.top + scrollY - originY + baseline - ascent;
              glyph.style.transformOrigin = `50% ${baseline}px`;
              glyph.dataset.nameLetter = name;
            }
            fragment.append(glyph);
            letters.push({ el: glyph, name, ascent, inkTop,
              contactX: rect.left + rect.width * (name === 'M' ? .84 : .28) - originX,
              x: rect.left + rect.width / 2 - originX,
              y: rect.top + scrollY + rect.height / 2 - originY, dx: 0, dy: 0, vx: 0, vy: 0 });
          }
        }
      }
      layer.append(fragment);
    }
    measuring = false;
    wake();
  }

  // Stable dot identities travel with the grid, including their slight variations.
  function updateDots() {
    const row = Math.floor(-scrollMotion.y / spacing) - 1;
    if (row === dotRow) return;
    dotRow = row;
    dots = [];
    const rows = Math.ceil(height / spacing) + 3, columns = Math.ceil(width / spacing) + 3;
    for (let r = row; r < row + rows; r++) {
      for (let c = -1; c < columns - 1 && dots.length < 1600; c++) {
        let seed = Math.imul(c, 0x9e3779b9) ^ Math.imul(r, 0x85ebca6b);
        seed = Math.imul(seed ^ seed >>> 16, 0x7feb352d);
        seed = Math.imul(seed ^ seed >>> 15, 0x846ca68b);
        seed = (seed ^ seed >>> 16) >>> 0;
        dots.push({ x: c * spacing, y: r * spacing, brightness: .92 + (seed & 255) / 255 * .16,
          scale: .94 + (seed >>> 8 & 255) / 255 * .12, speed: (seed >>> 16) % 5,
          sparse: (seed >>> 24) % 48 === 0 ? .7 + (seed & 255) / 255 * .3 : 0 });
      }
    }
  }

  function ripple(x, y, strength = 1, speed = 390, lightsCamera = false) {
    if (disabled() || !visible) return;
    waves.push({ x, y, strength, speed, born: clock, lightsCamera });
    if (waves.length > 7) waves.shift();
    wake();
  }

  function stepCamera() {
    if (!cameraLight) return;
    let opacity = 0;
    if (camera.y >= viewTop && camera.y <= viewTop + height) {
      for (const wave of waves) {
        if (!wave.lightsCamera) continue;
        const age = clock - wave.born;
        const distance = Math.hypot(camera.x - wave.x, camera.y - wave.y);
        const front = Math.abs(distance - age * wave.speed);
        // Follow the passing wave band: bright at the crest, soft at its edges.
        // Overlapping waves sustain the light instead of restarting an animation.
        const envelope = 1 - smooth((front - 32) / 88);
        const release = smooth((2.05 - age) / .2);
        opacity = Math.max(opacity, envelope * release);
      }
    }
    opacity = Math.round(opacity * 1000) / 1000;
    if (opacity === cameraOpacity) return;
    cameraOpacity = opacity;
    if (opacity) cameraLight.style.opacity = String(opacity);
    else cameraLight.style.removeProperty('opacity');
  }

  function sparseIntensity() {
    if (!scrollAccent) return 0;
    const age = Math.max(0, clock - scrollAccent.born);
    return age < .1
      ? scrollAccent.initial + (scrollAccent.peak - scrollAccent.initial) * smooth(age / .1)
      : scrollAccent.peak * (1 - smooth((age - .1) / 2.2));
  }

  function pushScroll(dy, now) {
    if (disabled() || !visible) return;
    const magnitude = Math.abs(dy);
    if (!Number.isFinite(magnitude) || magnitude < .1) return;
    // Browser deltas describe page travel; the dots move with the content.
    scrollMotion.targetY -= dy;
    const current = sparseIntensity();
    scrollAccent = { born: clock, initial: current, peak: Math.max(current, Math.min(1, .45 + magnitude / 96)) };
    const strength = clamp(magnitude / 48, .18, 1);
    const add = (edge, amount) => {
      const previous = scrollPulses.findLast(pulse => pulse.edge === edge);
      if (previous && clock - previous.born < .075) previous.strength = Math.min(1, previous.strength + amount * .25);
      else scrollPulses.push({ edge, strength: amount, born: clock });
    };
    add(dy > 0 ? 0 : 1, strength);
    if (scrollPulses.length > 24) scrollPulses.splice(0, scrollPulses.length - 24);
    lastScrollInput = now;
    wake();
  }

  function advanceScroll(dt) {
    // The app's 45 ms exponential glide stays consistent across display refresh rates.
    const blend = 1 - Math.exp(-dt / .045);
    scrollMotion.y += (scrollMotion.targetY - scrollMotion.y) * blend;
    if (Math.abs(scrollMotion.targetY - scrollMotion.y) < .05) scrollMotion.y = scrollMotion.targetY;
    scrollPulses = scrollPulses.filter(pulse => clock - pulse.born < .7 / (.55 * dotSpeeds[0]));
    if (scrollAccent && clock - scrollAccent.born >= 2.3) scrollAccent = null;
    accentStrength = sparseIntensity();
    scrollFields.fill(0);
    // Cache the app's five timing variations and nine edge-distance samples once per frame.
    for (let speed = 0; speed < dotSpeeds.length; speed++) {
      for (let sample = 0; sample < 9; sample++) {
        const offset = (speed * 9 + sample) * 2;
        for (const pulse of scrollPulses) {
          const progress = (clock - pulse.born) * dotSpeeds[speed] * (.55 + .45 * sample / 8) / .7;
          if (progress <= 0 || progress >= 1) continue;
          const envelope = progress < .2 ? smooth(progress / .2) : 1 - smooth((progress - .2) / .8);
          scrollFields[offset + pulse.edge] += pulse.strength * envelope;
        }
        const energy = scrollFields[offset] + scrollFields[offset + 1];
        if (energy) {
          const compression = (1 - Math.exp(-energy * 1.6)) / energy;
          for (let edge = 0; edge < 2; edge++) scrollFields[offset + edge] *= compression;
        }
      }
    }
    return scrollMotion.y !== scrollMotion.targetY;
  }

  function scrollAt(x, y, speed = 2) {
    if (!scrollPulses.length) return { pulse: 0, scale: 0, y: 0 };
    const px = clamp(x / width, 0, 1), py = clamp((y - viewTop) / height, 0, 1);
    let pulse = 0, scale = 0, fy = 0;
    for (let edge = 0; edge < 2; edge++) {
      const distance = edge === 0 ? py : 1 - py;
      const position = smooth(distance * 2) * 8;
      const lower = Math.floor(position), upper = Math.min(lower + 1, 8), fraction = position - lower;
      const low = scrollFields[(speed * 9 + lower) * 2 + edge];
      const high = scrollFields[(speed * 9 + upper) * 2 + edge];
      const weight = low + (high - low) * fraction;
      const spatial = 1 - distance;
      const response = weight * (.001 + .999 * Math.pow(spatial, 2.2)) * (.995 + .005 * px);
      pulse += response;
      scale += weight * (.001 + .999 * Math.pow(spatial, 3.8)) * (.995 + .005 * px);
      fy += (edge === 0 ? -1 : 1) * response;
    }
    return { pulse, scale, y: fy };
  }

  // The signed wave carries a crest and a soft trailing trough, rather than a rigid push.
  function forceAt(x, y) {
    let fx = 0, fy = 0, energy = 0;
    for (const wave of waves) {
      const dx = x - wave.x, dy = y - wave.y;
      const distance = Math.hypot(dx, dy) || 1;
      const age = clock - wave.born;
      const front = distance - age * wave.speed;
      if (Math.abs(front) > 120) continue;
      const envelope = Math.exp(-front * front / 2800) * Math.exp(-age * .75) * wave.strength;
      const crest = Math.cos(front / 28) * envelope;
      fx += dx / distance * crest;
      fy += (dy / distance * .7 + .3) * crest;
      energy += Math.abs(envelope);
    }
    return { x: fx, y: fy, energy };
  }

  function drawField() {
    ctx.clearRect(0, 0, width, height);
    updateDots();
    // Clip the shared field to the page, including its header.
    const top = clamp(-viewTop, 0, height);
    const bottom = clamp(surfaceHeight - viewTop, 0, height);
    ctx.save();
    ctx.beginPath(); ctx.rect(0, top, width, Math.max(0, bottom - top)); ctx.clip();
    ctx.translate(0, -viewTop);
    const buckets = Array.from({ length: 27 }, () => []);
    const base = dark.matches ? [105, 157, 255] : [59, 115, 224];
    const highlight = dark.matches ? [245, 249, 255] : [24, 36, 58];
    const color = base.map((channel, index) => Math.round(channel + (highlight[index] - channel) * winkStrength * .65)).join(',');
    for (const dot of dots) {
      const x = dot.x, y = dot.y + scrollMotion.y + viewTop;
      const force = forceAt(x, y);
      const scroll = scrollAt(x, y, dot.speed);
      const accent = accentStrength * dot.sparse;
      const proximity = Math.max(0, 1 - Math.hypot(x - pointer.x, y - pointer.y) / 170);
      const edge = Math.min(1, Math.max(0, viewTop + height - y) / 28, Math.max(0, y - viewTop) / 16);
      const alpha = clamp((scroll.pulse * dot.brightness * .7 + accent * .28 + force.energy * .55 * (1 + winkStrength * .9) +
        proximity * proximity * pointer.opacity * .36) * edge, 0, .8);
      const bucket = Math.round(alpha / .8 * 8);
      const tone = Math.round(clamp(scroll.pulse + accent * .36 + winkStrength * Math.min(1, force.energy * 2), 0, 1) * 2);
      const growth = Math.min(13, 3 * scroll.scale + 8 * Math.pow(scroll.scale, 3) + 2 * accent);
      if (bucket) buckets[tone * 9 + bucket].push([
        x + force.x * 9, y + force.y * 9, .9 + growth * dot.scale * .34 + force.energy * .4,
      ]);
    }
    for (let tone = 0; tone < 3; tone++) {
      const tint = base.map((channel, index) => Math.round(channel + (highlight[index] - channel) * tone * .375)).join(',');
      for (let i = 1; i < 9; i++) {
        const bucket = buckets[tone * 9 + i];
        if (!bucket.length) continue;
        ctx.fillStyle = `rgba(${tint},${i / 8 * .8})`;
        ctx.beginPath();
        for (const [x, y, radius] of bucket) {
          ctx.moveTo(x + radius, y);
          ctx.arc(x, y, radius, 0, Math.PI * 2);
        }
        ctx.fill();
      }
    }
    // A quiet hairline makes the impulse legible before the dots reveal its wake.
    for (const wave of waves) {
      const age = clock - wave.born;
      const radius = age * wave.speed;
      if (radius < 3) continue;
      ctx.strokeStyle = `rgba(${color},${Math.max(0, .15 * (1 + winkStrength * 1.3) * wave.strength * Math.exp(-age * 2))})`;
      ctx.lineWidth = .7;
      ctx.beginPath(); ctx.arc(wave.x, wave.y, radius, 0, Math.PI * 2); ctx.stroke();
    }
    ctx.restore();
  }

  // A letter stores the landing's weight, then releases a smaller elastic rebound.
  function contactPress(elapsed, start) {
    const t = elapsed - start;
    if (t < 0 || t >= 360) return 0;
    if (t < 90) return smooth(t / 90);
    if (t < 210) return 1 - 1.26 * smooth((t - 90) / 120);
    return -.26 * (1 - smooth((t - 210) / 150));
  }

  function stepLetters(dt, elapsed) {
    let moving = false;
    for (const letter of letters) {
      const force = forceAt(letter.x, letter.y);
      const scroll = scrollAt(letter.x, letter.y);
      const tx = clamp(force.x * 5, -8, 8), ty = clamp(force.y * 9 + scroll.y * 3, -12, 12);
      letter.vx += ((tx - letter.dx) * 190 - letter.vx * 19) * dt;
      letter.vy += ((ty - letter.dy) * 190 - letter.vy * 19) * dt;
      letter.dx += letter.vx * dt; letter.dy += letter.vy * dt;
      const contact = contacts.find(contact => contact.name === letter.name);
      const press = contact ? contactPress(elapsed, contact.start) : 0;
      // Give the landing a stable surface; surrounding letters still follow the waves.
      const planted = contact ? smooth((elapsed - contact.start + 90) / 80) *
        (1 - smooth((elapsed - contact.start - 360) / 100)) : 0;
      const dx = letter.dx * (1 - planted), dy = letter.dy * (1 - planted) + press * 3;
      const active = Math.abs(press) + Math.abs(letter.dx) + Math.abs(letter.dy) + Math.abs(letter.vx) + Math.abs(letter.vy) > .025;
      if (active) {
        letter.el.style.transform = `translate(${dx.toFixed(3)}px,${dy.toFixed(3)}px) rotate(${(dx * .32).toFixed(3)}deg) scale(${(1 + press * .075).toFixed(4)},${(1 - press * .24).toFixed(4)})`;
        moving = true;
      } else {
        letter.dx = letter.dy = letter.vx = letter.vy = 0;
        letter.el.style.removeProperty('transform');
      }
    }
    return moving;
  }

  const cues = [
    [250, () => ripple(iconX, iconY + 24, .5, 300)],
    [1040, () => ripple(iconX + 17, iconY + 28, .75, 390)],
    [1180, () => { icon.dataset.pose = 'anticipating'; }],
    [1730, () => { icon.dataset.pose = 'wink'; }],
    [2310, () => { icon.dataset.pose = 'spinning'; ripple(iconX, iconY, .75, 340); }],
    [3080, () => {
      icon.dataset.pose = 'landing-m';
      const target = landingTargets[0];
      ripple(target.contactX, target.inkTop, .65, 360);
    }],
    [3590, () => {
      icon.dataset.pose = 'landing-u';
      const target = landingTargets[1];
      ripple(target.contactX, target.inkTop, 1.5, 440, true);
    }],
  ];

  function tick(now) {
    frame = 0;
    if (disabled() || !visible) { stop(); return; }
    const dt = Math.min((now - (lastTime || now - 16.67)) / 1000, .032);
    lastTime = now;
    let timeScale = 1, elapsed = 0;
    winkStrength = 0;
    if (playing) {
      elapsed = Number(animations[0]?.currentTime) || 0;
      while (cueIndex < cues.length && elapsed >= cues[cueIndex][0]) cues[cueIndex++][1]();
      // Ease into and out of slow motion without ever stopping waves or input.
      winkStrength = smooth((elapsed - 1550) / 180) * (1 - smooth((elapsed - 2280) / 240));
      timeScale = 1 - winkStrength * .78;
      if (elapsed >= duration) {
        playing = false; icon.dataset.pose = 'rest';
        animations.forEach(animation => animation.cancel()); animations = [];
      }
    }
    const motionDt = dt * timeScale;
    clock += motionDt;
    waves = waves.filter(wave => clock - wave.born < 2.05);
    stepCamera();
    const scrolling = advanceScroll(motionDt);
    const target = pointer.inside ? 1 : 0;
    pointer.opacity += (target - pointer.opacity) * (1 - Math.exp(-dt * 9));
    if (Math.abs(target - pointer.opacity) < .002) pointer.opacity = target;
    const moving = stepLetters(motionDt, elapsed);
    showType(moving || waves.length > 0 || scrollPulses.length > 0);
    drawField();
    if (playing || waves.length || scrollPulses.length || scrollAccent || scrolling || moving || pointer.opacity !== (pointer.inside ? 1 : 0)) wake();
    else {
      lastTime = 0;
      hero.dataset.motionState = 'rest';
      if (!pointer.inside) ctx.clearRect(0, 0, width, height);
    }
  }

  function wake() {
    if (frame || disabled() || !visible) return;
    hero.dataset.motionState = 'active';
    frame = requestAnimationFrame(tick);
  }

  function stop() {
    icon.disabled = !ready || disabled();
    cancelAnimationFrame(frame); frame = 0; lastTime = 0;
    animations.forEach(animation => animation.cancel()); animations = [];
    cameraOpacity = 0; cameraLight?.style.removeProperty('opacity');
    playing = false; winkStrength = 0; waves = []; showType(false);
    pointer.inside = false; pointer.opacity = 0;
    scrollPulses = []; scrollAccent = null; accentStrength = 0; scrollFields.fill(0);
    scrollMotion.y = scrollMotion.targetY;
    lastWheelInput = lastScrollInput = -Infinity;
    letters.forEach(letter => {
      letter.dx = letter.dy = letter.vx = letter.vy = 0;
      letter.el.style.removeProperty('transform');
    });
    ctx.clearRect(0, 0, width, height);
    icon.dataset.pose = 'rest'; hero.dataset.motionState = 'rest';
  }

  function perform() {
    if (!ready || disabled() || !visible || !iconVisible || playing) return;
    landingTargets = contacts.map(contact => letters.find(letter => letter.name === contact.name));
    if (landingTargets.some(target => !target)) return;
    introPlayed = true; playing = true; cueIndex = 0;
    icon.dataset.pose = 'dancing';
    // Millisecond timing keeps the pose, expression, and light beats together.
    const pose = (at, x, y, angle, sx = 1, sy = 1, easing = 'cubic-bezier(.22,.65,.3,1)') => ({
      offset: at / duration, transform: `translate(${x}px,${y}px) rotate(${angle}deg) scale(${sx},${sy})`, easing,
    });
    const fade = (at, opacity) => ({ offset: at / duration, opacity });
    const light = (at, blur = 0, brightness = 1) => ({
      offset: at / duration, filter: `blur(${blur}px) brightness(${brightness})`,
    });
    const iconSize = icon.offsetWidth;
    // Lower corner contour sampled from both native Composer tile generations.
    // The visible curve, rather than the transparent bounding-box corner, bears weight.
    const cornerContour = [[.33594, .47656], [.35781, .47031], [.37031, .46406],
      [.38281, .45469], [.39844, .44531], [.42031, .42344]];
    const cornerContact = (index, t) => {
      const press = smooth(t), side = index === 0 ? -1 : 1;
      const sx = 1 + press * (index === 0 ? .18 : .16);
      const sy = 1 - press * (index === 0 ? .24 : .20);
      // The M catches the ongoing clockwise turn and gently brakes it under load.
      const roll = index === 0 ? 2 * t - t * t : press;
      const tilt = side * (30 - roll * 6), radians = tilt * Math.PI / 180;
      const c = Math.cos(radians), sn = Math.sin(radians);
      const corner = cornerContour.map(([x, y]) => ({
        x: side * x * sx * c - y * sy * sn,
        y: side * x * sx * sn + y * sy * c,
      })).reduce((a, b) => b.y > a.y ? b : a);
      const target = landingTargets[index];
      // Scaling a letter about its baseline also moves its contact point sideways.
      const contactX = target.x + (target.contactX - target.x) * (1 + press * .075);
      const x = contactX - iconX - corner.x * iconSize;
      const y = target.inkTop + press * (3 + target.ascent * .24) - iconY - corner.y * iconSize;
      return { x, y, angle: 360 + tilt, sx, sy };
    };
    const cornerLanding = (index, start) => Array.from({ length: 13 }, (_, step) => {
      const point = cornerContact(index, step / 12);
      return pose(start + step * 7.5, point.x, point.y, point.angle, point.sx, point.sy,
        step === 12 ? 'cubic-bezier(.22,.65,.3,1)' : 'linear');
    });
    // One continuous airborne turn ends on the M, with no upright reset or back-turn.
    // Match its final translation/rotation speed to the first instant of corner roll.
    const contact = cornerContact(0, 0), nextContact = cornerContact(0, .001);
    const contactVX = (nextContact.x - contact.x) / .00009;
    const contactVY = (nextContact.y - contact.y) / .00009;
    const spinDuration = 680, rotationSpan = contact.angle + 73;
    const exitSlope = (12 / 90) * spinDuration / rotationSpan;
    const orbit = Array.from({ length: 49 }, (_, index) => {
      const t = index / 48;
      const rotation = t * t * (6 - 8 * t + 3 * t * t) + exitSlope * t * t * (t - 1);
      const sweep = smooth(t), angle = sweep * Math.PI * 2;
      const radius = 1 - .12 * sweep, release = smooth(t / .42);
      const approach = clamp((t - .55) / .45, 0, 1), blend = smooth(approach);
      // Hermite end tangent carries the corner into contact instead of easing to a stop.
      const tangent = approach * approach * (approach - 1) * spinDuration / 1000 * .45;
      const x = -18 * Math.sin(angle) * radius + contact.x * blend + contactVX * tangent;
      const y = -18 - 11 * (1 - Math.cos(angle)) * radius +
        (contact.y + 18) * blend + contactVY * tangent;
      return pose(2310 + t * spinDuration, x, y, -73 + rotationSpan * rotation,
        1.16 - .16 * release, 1.07 - .07 * release, 'linear');
    });
    animations.push(body.animate([
      pose(0, 0, 0, 0), pose(255, -3, 4, -7, 1.08, .87),
      pose(612, -24, -23, -18, .96, 1.05), pose(1020, 19, 2, 12, 1.09, .90),
      // Settle the hop, draw back against the wink, then turn into the eye pose.
      pose(1180, 8, -7, 0), pose(1460, 5, -11, 18, .96, 1.1, 'cubic-bezier(.55,0,.25,1)'),
      pose(1640, -5, -16, -58, 1.1, 1.14, 'cubic-bezier(.5,0,.2,1)'),
      pose(1750, -7, -12, -82, 1.23, .91), pose(1860, -6, -17, -77, 1.18, 1.09),
      // Give the expression time to read, with a little living drift rather than a freeze.
      // Open straight into the orbit, then carry its momentum into the word.
      ...orbit,
      // Roll onto the lower-left corner over M, then the lower-right corner over ü.
      ...cornerLanding(0, 2990).slice(1),
      pose(3320, -4, -28, 374, .94, 1.08, 'cubic-bezier(.45,0,.72,1)'),
      ...cornerLanding(1, 3500),
      pose(3850, 12, -30, 348, .96, 1.08, 'cubic-bezier(.45,0,.55,1)'),
      pose(4160, 0, 3, 362, 1.04, .95),
      pose(4380, 0, -1, 359.5, .99, 1.015),
      pose(duration, 0, 0, 360),
    ], { duration, fill: 'both' }));
    if (body.dataset.layered) {
      // The tile carries the weight; its real glass foreground follows through.
      // Local percentages keep this expression identical on the smaller mobile icon.
      const partPose = (at, x = 0, y = 0, angle = 0, sx = 1, sy = 1) => ({
        offset: at / duration,
        transform: `translate(${x}%,${y}%) rotate(${angle}deg) scale(${sx},${sy})`,
        easing: 'cubic-bezier(.22,.65,.3,1)',
      });
      // A clear fan-out at this 80 px size, traveling clockwise around the mark.
      const directions = [[0, -6], [-4.8, -4.8], [4.8, -4.8], [-6, 0], [6, 0], [-4.8, 4.8]];
      const rayOrder = [0, 5, 1, 4, 2, 3];
      rays.forEach((ray, index) => {
        const [x, y] = directions[index];
        const delay = rayOrder[index] * 24;
        const expression = ray.dataset.part === 'wink' ? [
          // This is the original upper-left ray, moving into the native pause pose.
          partPose(1460), partPose(1600, -4, -3.4, -26, 1.16, 1.16),
          partPose(1740, 6.14, -6.25, 45), partPose(2310, 6.14, -6.25, 45),
          partPose(2440, x * 1.25, y * 1.25, -30, 1.16, 1.16),
        ] : [
          partPose(1460), partPose(1650 + delay, x * .85, y * .85, -13, 1.12, 1.12),
          partPose(1830 + delay), partPose(2310),
          partPose(2440 + delay, x * 1.25, y * 1.25, -26, 1.16, 1.16),
        ];
        animations.push(ray.animate([
          partPose(0), partPose(255 + delay, -x * .45, -y * .45, -14, .88, .88),
          partPose(640 + delay, x, y, 18, 1.18, 1.18),
          partPose(970 + delay, -x * .2, -y * .2, -7, .95, .95), partPose(1190 + delay),
          ...expression,
          partPose(2730 + delay, x * .8, y * .8, 21, 1.08, 1.08),
          partPose(3130 + delay, -x * .65, -y * .65, -15, .84, .84),
          partPose(3350 + delay, x * .5, y * .5, 9, 1.09, 1.09),
          partPose(3640 + delay, -x * .55, -y * .55, -12, .87, .87),
          partPose(3900 + delay, x * .35, y * .35, 7, 1.06, 1.06),
          partPose(4250 + delay, -x * .08, -y * .08, -2, .99, .99), partPose(duration),
        ], { duration, fill: 'both' }));
      });
      animations.push(pointerPart.animate([
        partPose(0), partPose(290, -1.5, 3.5, -20, 1.08, .85),
        partPose(700, 3.5, -5, 23, .96, 1.15), partPose(1110, -2, 3.5, -15),
        partPose(1460), partPose(1700, 3.5, -2, 20, 1.12, .95),
        partPose(1920, 1.5, -.8, 10, 1.04, 1.04), partPose(2310, 0, 0, 5),
        partPose(2460, -3.8, 2.5, -38, 1.08, .96), partPose(2730, 3.2, -2.5, 24),
        partPose(3130, 0, 6, -21, 1.1, .78),
        partPose(3350, 0, -3.2, 11, .95, 1.12),
        partPose(3640, 0, 5, -17, 1.08, .83),
        partPose(3910, 0, -2.5, 9, .96, 1.09),
        partPose(4270, 0, .9, -3, 1.02, .97), partPose(duration),
      ], { duration, fill: 'both' }));
    } else {
      // A failed layer download retains the complete native active/paused frames.
      animations.push(pausedIcon.animate([
        fade(0, 0), fade(1660, 0), fade(1740, 1),
        fade(2310, 1), fade(2420, 0), fade(duration, 0),
      ], { duration, fill: 'both' }));
    }
    animations.push(body.animate([
      light(0), light(1550), light(1750, 0, 1.16),
      light(2310, 0, 1.1), light(2400, .25), light(2490, 1.2),
      light(2620, .55), light(2740), light(duration),
    ], { duration, fill: 'both' }));
    animations.push(smear.animate([
      fade(0, 0), fade(2370, 0), fade(2430, .24), fade(2490, .46),
      fade(2610, .22), fade(2740, 0), fade(duration, 0),
    ], { duration, fill: 'both' }));
    wake();
  }

  function locate(event) {
    return { x: event.clientX - originX, y: event.clientY + scrollY - originY };
  }
  surface.addEventListener('pointermove', event => {
    if (event.pointerType === 'touch' || disabled()) return;
    const point = locate(event);
    const inField = point.y >= 0 && point.y < surfaceHeight && !event.target.closest('a');
    const distance = Math.hypot(event.clientX - pointerClientX, event.clientY - pointerClientY);
    pointerClientX = event.clientX; pointerClientY = event.clientY;
    pointer.x = point.x; pointer.y = point.y; pointer.inside = inField;
    if (inField && distance > 5 && clock - lastPointerWave > .14 && !playing && performance.now() - lastScrollInput > 240) {
      ripple(point.x, point.y, .22, 310, false); lastPointerWave = clock;
    }
    wake();
  }, { passive: true });
  surface.addEventListener('pointerleave', () => { pointer.inside = false; wake(); }, { passive: true });
  surface.addEventListener('click', event => {
    if (event.target.closest('button, a') || getSelection()?.toString()) return;
    const point = locate(event);
    if (point.y >= 0 && point.y < surfaceHeight) ripple(point.x, point.y, .85, 400, true);
  });
  surface.addEventListener('wheel', event => {
    if (disabled() || event.ctrlKey) return;
    const point = locate(event);
    if (point.y < 0 || point.y > surfaceHeight) return;
    const unit = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? height : 1;
    lastWheelInput = performance.now();
    pushScroll(event.deltaY * unit, lastWheelInput);
  }, { passive: true });
  window.addEventListener('scroll', () => {
    const delta = scrollY - lastScrollY; lastScrollY = scrollY;
    viewTop = scrollY - originY;
    if (pointer.inside) pointer.y += delta;
    wake();
    const now = performance.now();
    // Native scrolling following a wheel event already has its wave. Keyboard,
    // touch and scrollbar movement share this fallback without duplicating it.
    if (Math.abs(delta) > .1 && now - lastWheelInput > 240) {
      pushScroll(delta, now);
    }
  }, { passive: true });
  icon.addEventListener('click', perform);
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) stop();
    else { measure(); if (!introPlayed) perform(); }
  });
  const preferenceChanged = () => {
    stop(); icon.disabled = !ready || disabled(); measure();
  };
  reduce.addEventListener('change', preferenceChanged);
  forced.addEventListener('change', preferenceChanged);
  dark.addEventListener('change', measure);
  contrast.addEventListener('change', measure);
  new ResizeObserver(measure).observe(surface);
  window.addEventListener('resize', () => { stop(); measure(); }, { passive: true });
  if ('IntersectionObserver' in window) {
    new IntersectionObserver(entries => {
      visible = entries[0].isIntersecting;
      if (!visible) stop();
      else wake();
    }).observe(surface);
    new IntersectionObserver(entries => {
      iconVisible = entries[0].isIntersecting;
      if (!iconVisible && playing) stop();
      else if (iconVisible && ready && !introPlayed) perform();
    }).observe(copy);
  }
  Promise.resolve(window.mousuIconReady).then(() =>
    Promise.all([...body.querySelectorAll('img')].map(image => image.decode()))
  ).then(() => {
    ready = true; icon.disabled = disabled(); measure(); perform();
  }).catch(() => { stop(); icon.disabled = true; sources.forEach(source => source.classList.remove('ripple-source')); layer.replaceChildren(); });
})();
