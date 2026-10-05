const journey = document.querySelector('.film-journey');
const stage = document.querySelector('.film-stage');
const world = document.querySelector('.flight-world');
const pages = [...document.querySelectorAll('.flight-page')].map((element) => ({
  element,
  depth: Number(element.dataset.depth),
}));
const chapterPanels = [...document.querySelectorAll('.chapter')];
const progressCount = document.querySelector('.stage-progress-current');
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');

const CAMERA_TRAVEL = 4900;
const artwork = {
  a: 'media/story-atlas-a.webp',
  b: 'media/story-atlas-b.webp',
};

let visible = false;
let raf = 0;
let progress = -1;
let chapter = -1;
let flightStarted = false;
let lookX = 0;
let lookY = 0;
let targetLookX = 0;
let targetLookY = 0;

const clamp = (value) => Math.max(0, Math.min(1, value));

function chapterFor(value) {
  if (value < .08) return 0;
  if (value < .30) return 1;
  if (value < .55) return 2;
  if (value < .79) return 3;
  return 4;
}

function setChapter(value) {
  const next = chapterFor(value);
  if (next === chapter) return;
  chapter = next;
  stage.dataset.chapter = String(next);
  progressCount.textContent = String(next).padStart(2, '0');
  for (const panel of chapterPanels) panel.classList.toggle('is-active', Number(panel.dataset.index) === next);
}

function readJourney() {
  const travel = Math.max(1, journey.offsetHeight - stage.offsetHeight);
  const distance = -journey.getBoundingClientRect().top;
  return clamp(distance / travel);
}

function loadFlight() {
  if (flightStarted || reducedMotion.matches || !CSS.supports('transform-style', 'preserve-3d')) return;
  flightStarted = true;
  stage.dataset.mediaState = 'loading';

  Promise.all(Object.values(artwork).map((src) => {
    const image = new Image();
    image.src = src;
    return image.decode();
  })).then(() => {
    if (reducedMotion.matches) return;
    for (const { element } of pages) {
      const atlas = element.querySelector('.atlas-a') ? artwork.a : artwork.b;
      element.querySelector('.flight-art').style.backgroundImage = `url("${atlas}")`;
    }
    stage.classList.add('flight-ready');
    stage.dataset.mediaState = 'ready';
  }).catch(() => {
    stage.classList.remove('flight-ready');
    stage.dataset.mediaState = 'fallback';
  });
}

function setFlightMotion(value) {
  const cameraZ = value * CAMERA_TRAVEL;
  const weaveX = Math.sin(value * Math.PI * 4) * 22;
  const weaveY = Math.sin(value * Math.PI * 3) * 10;

  world.style.setProperty('--camera-z', `${cameraZ.toFixed(1)}px`);
  world.style.setProperty('--camera-x', `${(lookX + weaveX).toFixed(1)}px`);
  world.style.setProperty('--camera-y', `${(lookY + weaveY).toFixed(1)}px`);
  stage.style.setProperty('--journey-progress', value.toFixed(4));
  stage.style.setProperty('--aura-x', `${((value - .5) * 90).toFixed(1)}px`);

  for (const { element, depth } of pages) {
    const distance = depth + cameraZ;
    const hidden = distance > 825 || distance < -950;
    if (element.hidden !== hidden) element.hidden = hidden;
    if (!hidden) {
      const entering = clamp((distance + 950) / 200);
      const passing = clamp((825 - distance) / 175);
      element.style.opacity = Math.min(entering, passing).toFixed(3);
    }
  }
}

function render() {
  raf = 0;
  if (!visible || document.hidden || reducedMotion.matches) return;

  const next = readJourney();

  lookX += (targetLookX - lookX) * .12;
  lookY += (targetLookY - lookY) * .12;
  if (next !== progress || Math.abs(targetLookX - lookX) > .08 || Math.abs(targetLookY - lookY) > .08) {
    progress = next;
    setChapter(progress);
    setFlightMotion(progress);
  }
  if (Math.abs(targetLookX - lookX) > .08 || Math.abs(targetLookY - lookY) > .08) schedule();
}

function schedule() {
  if (visible && !document.hidden && !reducedMotion.matches && !raf) raf = requestAnimationFrame(render);
}

function begin() {
  if (!visible || document.hidden || reducedMotion.matches) return;
  loadFlight();
  schedule();
}

function stop() {
  cancelAnimationFrame(raf);
  raf = 0;
}

stage.addEventListener('pointermove', (event) => {
  if (event.pointerType === 'touch' || reducedMotion.matches) return;
  const bounds = stage.getBoundingClientRect();
  targetLookX = (.5 - (event.clientX - bounds.left) / bounds.width) * 46;
  targetLookY = (.5 - (event.clientY - bounds.top) / bounds.height) * 24;
  schedule();
});
stage.addEventListener('pointerleave', () => {
  targetLookX = 0;
  targetLookY = 0;
  schedule();
});

addEventListener('scroll', schedule, { passive: true });
addEventListener('resize', schedule);

const observer = new IntersectionObserver(([entry]) => {
  visible = entry.isIntersecting;
  if (visible) begin(); else stop();
});
observer.observe(journey);

document.documentElement.classList.add('has-motion');
const revealObserver = new IntersectionObserver((entries) => {
  for (const entry of entries) {
    if (!entry.isIntersecting) continue;
    entry.target.classList.add('is-visible');
    revealObserver.unobserve(entry.target);
  }
}, { threshold: .08, rootMargin: '0px 0px -6% 0px' });
document.querySelectorAll('[data-reveal]').forEach((item) => revealObserver.observe(item));

document.addEventListener('visibilitychange', () => {
  if (document.hidden) stop(); else begin();
});

reducedMotion.addEventListener('change', () => {
  if (reducedMotion.matches) {
    stop();
    stage.classList.remove('flight-ready');
    stage.dataset.mediaState = 'poster';
    for (const { element } of pages) element.querySelector('.flight-art').style.backgroundImage = '';
    flightStarted = false;
    setChapter(0);
  } else {
    progress = -1;
    begin();
  }
});

setChapter(0);
setFlightMotion(0);
