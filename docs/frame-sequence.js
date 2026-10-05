// Pass an absolute or page-relative manifest URL. Pair canvas with a visible poster.
export function createFrameSequence(canvas, manifestUrl, {
  smoothingMs = 110, concurrency = 4, timeoutMs = 20000,
  maxDecodedMiB = 128, onState = () => {},
} = {}) {
  const context = canvas.getContext('2d', {alpha: false});
  const controller = new AbortController(), images = [];
  let manifest, target = 0, current = 0, painted = -1, raf = 0, lastTime = 0;
  let disposed = false, failed = false, loaded = false;
  const timer = setTimeout(fail, timeoutMs);
  function state(value) { canvas.dataset.state = value; onState(value); }
  function fail() {
    if (disposed || failed) return;
    failed = true; clearTimeout(timer); controller.abort();
    cancelAnimationFrame(raf); images.forEach(img => { if (img) img.src = ''; });
    images.length = 0; state('fallback');
  }
  function paint() {
    const index = Math.round(current * (manifest.frameCount - 1));
    if (index === painted) return;
    const perSheet = manifest.columns * manifest.rows, cell = index % perSheet;
    context.drawImage(images[Math.floor(index / perSheet)],
      (cell % manifest.columns) * manifest.width,
      Math.floor(cell / manifest.columns) * manifest.height,
      manifest.width, manifest.height, 0, 0, canvas.width, canvas.height);
    painted = index; canvas.dataset.frame = String(index);
    canvas.classList.add('has-frame');
  }
  function tick(now) {
    raf = 0;
    if (disposed || failed || !loaded || document.hidden) { lastTime = 0; return; }
    const dt = lastTime ? Math.min(now - lastTime, 50) : 16.7; lastTime = now;
    current += (target - current) * (smoothingMs > 0 ? 1 - Math.exp(-dt / smoothingMs) : 1);
    if (Math.abs(target-current) < 0.0001) current = target;
    paint();
    if (current !== target) raf = requestAnimationFrame(tick); else lastTime = 0;
  }
  function wake() { if (loaded && !raf && !disposed && !failed) raf = requestAnimationFrame(tick); }
  document.addEventListener('visibilitychange', wake);
  state('loading');
  const ready = (async () => {
    try {
      if (!context) throw Error('Canvas unavailable');
      const url = new URL(manifestUrl, document.baseURI);
      const response = await fetch(url, {signal: controller.signal});
      if (!response.ok) throw Error('Manifest unavailable');
      manifest = await response.json();
      for (const key of ['width','height','columns','rows','frameCount']) {
        if (!Number.isSafeInteger(manifest[key]) || manifest[key] <= 0) throw Error('Invalid manifest');
      }
      const count = Math.ceil(manifest.frameCount / (manifest.columns * manifest.rows));
      const bytes = count * manifest.columns * manifest.rows * manifest.width * manifest.height * 4;
      if (manifest.version !== 1 || !Array.isArray(manifest.sheets) || manifest.sheets.length !== count || bytes > maxDecodedMiB*1024**2) throw Error('Invalid or oversized sequence');
      canvas.width = manifest.width; canvas.height = manifest.height;
      let next = 0;
      async function worker() {
        while (next < count && !disposed && !failed) {
          const i = next++, img = new Image(); images[i] = img; img.decoding = 'async';
          img.src = new URL(manifest.sheets[i], url).href;
          await img.decode();
          if (!disposed && !failed && (img.naturalWidth !== manifest.width*manifest.columns || img.naturalHeight !== manifest.height*manifest.rows)) throw Error('Sheet size mismatch');
        }
      }
      await Promise.all(Array.from({length:Math.max(1, Math.min(count, Math.floor(concurrency) || 1))}, worker));
      if (disposed || failed) return false;
      clearTimeout(timer); loaded = true; current = target; paint(); state('ready');
      return true;
    } catch { fail(); return false; }
  })();
  return {
    ready,
    setProgress(p) { if (Number.isFinite(p)) { target = Math.max(0,Math.min(1,p)); wake(); } },
    dispose() {
      disposed = true; clearTimeout(timer); controller.abort(); cancelAnimationFrame(raf);
      document.removeEventListener('visibilitychange', wake);
      images.forEach(img => { if (img) img.src = ''; }); images.length = 0;
    },
  };
}
