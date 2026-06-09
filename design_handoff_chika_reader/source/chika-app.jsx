// chika-app.jsx — Chika · Chitra Katha reader prototype
const { useState, useEffect, useRef, useCallback } = React;

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "markScheme": "ochre"
}/*EDITMODE-END*/;

/* ----------------------------------------------------------- */
/* persistence                                                  */
/* ----------------------------------------------------------- */
function load(key, fallback) {
  try { const v = localStorage.getItem(key); return v ? JSON.parse(v) : fallback; }
  catch (e) { return fallback; }
}
function save(key, val) { try { localStorage.setItem(key, JSON.stringify(val)); } catch (e) {} }

/* ----------------------------------------------------------- */
/* comic catalogue (styled placeholders — original titles)      */
/* ----------------------------------------------------------- */
const CATALOGUE = [
  { id: 'inktiger',  title: 'THE INK\nTIGER',     issue: 'ISSUE 01', accent: 'var(--crimson)',    ground: 'var(--ink)',       motif: 0, pages: 14 },
  { id: 'ruins',     title: 'RANI OF\nTHE RUINS', issue: 'ISSUE 03', accent: 'var(--ochre)',      ground: 'var(--maroon-deep)', motif: 1, pages: 12 },
  { id: 'monsoon',   title: 'THE LAST\nMONSOON',  issue: 'ISSUE 02', accent: 'var(--cream)',      ground: 'var(--crimson)',   motif: 2, pages: 16 },
  { id: 'vajra',     title: 'VAJRA',              issue: 'ISSUE 07', accent: 'var(--crimson-bright)', ground: 'var(--ink-soft)', motif: 3, pages: 10 },
  { id: 'bazaar',    title: 'MIDNIGHT\nBAZAAR',   issue: 'ISSUE 01', accent: 'var(--ochre)',      ground: 'var(--ink)',       motif: 1, pages: 13 },
  { id: 'ghazipur',  title: 'GHOST OF\nGHAZIPUR', issue: 'ISSUE 04', accent: 'var(--cream)',      ground: 'var(--maroon)',    motif: 0, pages: 11 },
  { id: 'solar',     title: 'SOLAR\nSENTINEL',    issue: 'ISSUE 05', accent: 'var(--crimson)',    ground: 'var(--ink)',       motif: 2, pages: 15 },
  { id: 'naga',      title: 'NAGA\nCITY',         issue: 'ISSUE 02', accent: 'var(--ochre)',      ground: 'var(--maroon-deep)', motif: 3, pages: 12 },
];

/* ----------------------------------------------------------- */
/* small reticle bracket set                                    */
/* ----------------------------------------------------------- */
function Reticle({ inset = 10, size = 16, color = 'var(--cream)', w = 2.5, z = 3 }) {
  const b = `${w}px solid ${color}`;
  const base = { position: 'absolute', width: size, height: size, zIndex: z };
  return (
    <React.Fragment>
      <span style={{ ...base, top: inset, left: inset, borderTop: b, borderLeft: b }} />
      <span style={{ ...base, top: inset, right: inset, borderTop: b, borderRight: b }} />
      <span style={{ ...base, bottom: inset, left: inset, borderBottom: b, borderLeft: b }} />
      <span style={{ ...base, bottom: inset, right: inset, borderBottom: b, borderRight: b }} />
    </React.Fragment>
  );
}

const STARBURST = 'polygon(50% 0,60% 16%,78% 9%,74% 28%,95% 30%,80% 46%,98% 62%,77% 64%,80% 86%,60% 74%,52% 96%,42% 75%,22% 88%,23% 65%,2% 64%,18% 46%,4% 30%,25% 28%,21% 9%,40% 16%)';

// comic action-ray + halftone backdrop for the reader
function ActionRays({ color = 'var(--crimson)' }) {
  const rays = [];
  for (let i = 0; i < 24; i++) {
    rays.push(`${color} ${i % 2 ? 0 : 0}deg`, `${color} ${(360 / 24) * (i + 0.5)}deg`, `transparent ${(360 / 24) * (i + 0.5)}deg`, `transparent ${(360 / 24) * (i + 1)}deg`);
  }
  return (
    <React.Fragment>
      <div style={{ position: 'absolute', inset: '-30%', opacity: 0.06, pointerEvents: 'none',
        background: `repeating-conic-gradient(from 0deg, ${color} 0deg 5deg, transparent 5deg 12deg)` }} />
      <div className="halftone-bg" style={{ position: 'absolute', inset: 0, color, opacity: 0.05, pointerEvents: 'none' }} />
    </React.Fragment>
  );
}

/* ----------------------------------------------------------- */
/* C · dark app mark (mini)                                     */
/* ----------------------------------------------------------- */
const MARK_SCHEMES = {
  maroon: { bg: 'var(--maroon)', cell: 'var(--cream)', cellBorder: 'var(--ink)',    spine: 'var(--crimson-bright)', spineBorder: 'var(--ink)' },
  dark:   { bg: 'var(--ink)',    cell: 'var(--cream)', cellBorder: 'var(--crimson)', spine: 'var(--crimson-bright)', spineBorder: 'var(--cream)' },
  cream:  { bg: 'var(--paper)',  cell: 'var(--ink)',   cellBorder: 'var(--ink)',     spine: 'var(--crimson)',        spineBorder: 'var(--ink)' },
  crimson:{ bg: 'var(--crimson)',cell: 'var(--cream)', cellBorder: 'var(--ink)',     spine: 'var(--maroon-deep)',    spineBorder: 'var(--cream)' },
  ochre:  { bg: 'var(--ochre)',  cell: 'var(--ink)',   cellBorder: 'var(--maroon)',  spine: 'var(--crimson)',        spineBorder: 'var(--ink)' },
};
function MiniMark({ box = 34, scheme = 'maroon' }) {
  const S = MARK_SCHEMES[scheme] || MARK_SCHEMES.maroon;
  const bw = Math.max(1.5, box * 0.05);
  const cell = { background: S.cell, borderRadius: box * 0.06, border: `${bw}px solid ${S.cellBorder}`, boxSizing: 'border-box' };
  return (
    <div style={{ width: box, height: box, borderRadius: box * 0.24, background: S.bg, display: 'flex', alignItems: 'center', justifyContent: 'center', flex: '0 0 auto' }}>
      <div style={{ display: 'grid', gridTemplateColumns: '1.5fr 1fr 1fr', gridTemplateRows: '1.4fr 1fr 1fr 1.4fr', gap: box * 0.05, width: box * 0.66, height: box * 0.66 }}>
        <div style={{ ...cell, gridColumn: '1 / 4', gridRow: '1 / 2' }} />
        <div style={{ gridColumn: '1 / 2', gridRow: '2 / 4', background: S.spine, borderRadius: box * 0.06, border: `${bw}px solid ${S.spineBorder}` }} />
        <div style={{ ...cell, gridColumn: '1 / 4', gridRow: '4 / 5' }} />
      </div>
    </div>
  );
}

/* ----------------------------------------------------------- */
/* comic cover                                                  */
/* ----------------------------------------------------------- */
function CoverArt({ comic }) {
  const dark = comic.accent === 'var(--cream)' || comic.accent === 'var(--ochre)';
  const titleColor = dark ? comic.accent : 'var(--cream)';
  return (
    <div style={{ position: 'absolute', inset: 0, background: comic.ground, overflow: 'hidden' }}>
      {/* halftone wash */}
      <div className="halftone-bg" style={{ position: 'absolute', inset: 0, color: comic.accent, opacity: 0.22,
        WebkitMaskImage: 'linear-gradient(160deg,#000,transparent 70%)', maskImage: 'linear-gradient(160deg,#000,transparent 70%)' }} />
      {/* motif graphic */}
      {comic.motif === 0 && (
        <div style={{ position: 'absolute', right: -28, top: -20, width: 130, height: 130, borderRadius: '50%',
          border: `10px solid ${comic.accent}`, opacity: 0.5 }} />
      )}
      {comic.motif === 1 && (
        <div style={{ position: 'absolute', inset: 0, background: `linear-gradient(115deg, transparent 52%, ${comic.accent} 52%, ${comic.accent} 60%, transparent 60%)`, opacity: 0.6 }} />
      )}
      {comic.motif === 2 && (
        <div style={{ position: 'absolute', left: '50%', top: '34%', transform: 'translate(-50%,-50%)', width: 96, height: 96,
          background: comic.accent, opacity: 0.85, clipPath: 'polygon(50% 0,61% 35%,98% 35%,68% 57%,79% 91%,50% 70%,21% 91%,32% 57%,2% 35%,39% 35%)' }} />
      )}
      {comic.motif === 3 && (
        <div style={{ position: 'absolute', right: 16, top: 18, bottom: 70, width: 16, background: comic.accent, opacity: 0.7, borderRadius: 3 }} />
      )}
      {/* top issue tag */}
      <div className="archivo" style={{ position: 'absolute', top: 12, left: 12, fontSize: 8.5, fontWeight: 800, letterSpacing: '0.18em',
        color: titleColor, opacity: 0.85, background: 'rgba(0,0,0,0.18)', padding: '3px 6px', borderRadius: 3 }}>{comic.issue}</div>
      {/* title */}
      <div className="anton" style={{ position: 'absolute', left: 12, right: 12, bottom: 16, color: titleColor,
        fontSize: 25, lineHeight: 0.92, whiteSpace: 'pre-line', textShadow: '2px 2px 0 rgba(0,0,0,0.35)' }}>{comic.title}</div>
    </div>
  );
}

function CoverCard({ comic, progress, onOpen }) {
  const pct = progress ? Math.round(((progress.page + 1) / comic.pages) * 100) : 0;
  const started = progress && progress.page > 0;
  return (
    <button onClick={() => onOpen(comic)} style={{
      display: 'block', padding: 0, border: 'none', background: 'none', cursor: 'pointer', textAlign: 'left', width: '100%',
    }}>
      <div style={{ position: 'relative', width: '100%', aspectRatio: '0.7', borderRadius: 4, overflow: 'hidden',
        border: '3px solid var(--ink)', boxShadow: '5px 5px 0 rgba(0,0,0,0.7), 0 0 0 1.5px rgba(243,233,214,0.12)' }}>
        <CoverArt comic={comic} />
        {comic._new && (
          <div style={{ position: 'absolute', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'center',
            background: 'rgba(12,9,7,0.55)', backdropFilter: 'blur(1px)' }}>
            <Reticle inset={10} size={20} color="var(--crimson-bright)" />
            <span className="archivo" style={{ fontSize: 9, fontWeight: 800, letterSpacing: '0.2em', color: 'var(--cream)' }}>SCANNING…</span>
          </div>
        )}
        {/* progress meter pinned to bottom of cover */}
        <div style={{ position: 'absolute', left: 0, right: 0, bottom: 0, height: 7, background: 'var(--ink)', borderTop: '1.5px solid rgba(0,0,0,0.6)' }}>
          <div style={{ height: '100%', width: pct + '%', background: 'var(--ochre)' }} />
        </div>
      </div>
      <div className="archivo" style={{ marginTop: 9, color: 'var(--cream)', fontSize: 12, fontWeight: 800, lineHeight: 1.1, letterSpacing: '0.01em', textTransform: 'uppercase' }}>
        {comic.title.replace('\n', ' ')}
      </div>
      <div className="archivo" style={{ marginTop: 2, color: 'rgba(243,233,214,0.5)', fontSize: 9.5, fontWeight: 600, letterSpacing: '0.04em' }}>
        {started ? `${pct}% · pg ${progress.page + 1}/${comic.pages}` : `${comic.pages} pages`}
      </div>
    </button>
  );
}

/* ----------------------------------------------------------- */
/* placeholder comic page art                                   */
/* ----------------------------------------------------------- */
const PANEL_TINTS = ['var(--paper)', 'var(--cream)', '#E8D9BE', '#EADEC6'];
function panelFill(comic, k) {
  const tints = [comic.accent, 'var(--maroon)', 'var(--ink-soft)', 'var(--ochre)', 'var(--crimson)'];
  return tints[k % tints.length];
}

function Bubble({ text }) {
  return (
    <div style={{ position: 'absolute', top: '12%', left: '10%', maxWidth: '55%', background: '#fff', border: '2px solid var(--ink)',
      borderRadius: 12, padding: '6px 9px', boxShadow: '2px 2px 0 var(--ink)' }}>
      <div className="archivo" style={{ fontSize: 8.5, fontWeight: 700, color: 'var(--ink)', lineHeight: 1.2 }}>{text}</div>
      <div style={{ position: 'absolute', left: 16, bottom: -10, width: 0, height: 0, borderLeft: '8px solid transparent', borderRight: '8px solid transparent', borderTop: '12px solid var(--ink)' }} />
      <div style={{ position: 'absolute', left: 17, bottom: -6, width: 0, height: 0, borderLeft: '6px solid transparent', borderRight: '6px solid transparent', borderTop: '9px solid #fff' }} />
    </div>
  );
}
function Sfx({ word, color = 'var(--crimson-bright)' }) {
  return (
    <div style={{ position: 'absolute', right: '8%', bottom: '14%', transform: 'rotate(-10deg)' }}>
      <div className="baloo" style={{ fontSize: 26, fontWeight: 800, color: 'var(--cream)', WebkitTextStroke: '3px var(--ink)', paintOrder: 'stroke fill', letterSpacing: '0.02em' }}>{word}</div>
    </div>
  );
}
function Figure({ tint }) {
  return (
    <React.Fragment>
      <div style={{ position: 'absolute', left: '50%', bottom: 0, transform: 'translateX(-50%)', width: '46%', height: '62%',
        background: 'rgba(23,16,14,0.5)', borderRadius: '40% 40% 8% 8%' }} />
      <div style={{ position: 'absolute', left: '50%', bottom: '52%', transform: 'translateX(-50%)', width: '22%', aspectRatio: '1', borderRadius: '50%', background: 'rgba(23,16,14,0.55)' }} />
    </React.Fragment>
  );
}

function Panel({ comic, k, content, style }) {
  return (
    <div style={{ position: 'relative', border: '3px solid var(--ink)', background: panelFill(comic, k), overflow: 'hidden', ...style }}>
      <div className="halftone-bg" style={{ position: 'absolute', inset: 0, color: 'var(--ink)', opacity: 0.16 }} />
      {content === 'fig' && <Figure />}
      {content === 'bubble' && <Bubble text={['MEANWHILE…', 'WHO GOES THERE?', 'NOT SO FAST!', 'AT LAST.'][k % 4]} />}
      {content === 'sfx' && <Sfx word={['DHOOM!', 'DHADAAM!', 'KRAKK!', 'WHOOSH'][k % 4]} />}
      {content === 'both' && (<React.Fragment><Figure /><Sfx word={['DHADAAM!', 'DHOOM!'][k % 2]} /></React.Fragment>)}
    </div>
  );
}

// deterministic layout per page index
function PageArt({ comic, page }) {
  const layout = page % 5;
  const pad = 12, gap = 8;
  const wrap = { position: 'absolute', inset: 0, padding: pad, display: 'grid', gap, background: 'var(--paper)' };
  if (page === 0) {
    // splash / cover-ish opening page
    return (
      <div style={{ ...wrap, gridTemplate: '1fr / 1fr' }}>
        <div style={{ position: 'relative', border: '3px solid var(--ink)', overflow: 'hidden', background: comic.ground }}>
          <CoverArt comic={comic} />
        </div>
      </div>
    );
  }
  if (layout === 1) return (
    <div style={{ ...wrap, gridTemplate: '1fr 1fr / 1fr 1fr' }}>
      <Panel comic={comic} k={page} content="fig" />
      <Panel comic={comic} k={page + 1} content="bubble" />
      <Panel comic={comic} k={page + 2} content="sfx" />
      <Panel comic={comic} k={page + 3} content="fig" />
    </div>
  );
  if (layout === 2) return (
    <div style={{ ...wrap, gridTemplate: '1.3fr 1fr / 1fr 1fr' }}>
      <Panel comic={comic} k={page} content="both" style={{ gridColumn: '1 / 3' }} />
      <Panel comic={comic} k={page + 1} content="bubble" />
      <Panel comic={comic} k={page + 2} content="fig" />
    </div>
  );
  if (layout === 3) return (
    <div style={{ ...wrap, gridTemplate: '1fr 1fr 1fr / 1fr' }}>
      <Panel comic={comic} k={page} content="bubble" />
      <Panel comic={comic} k={page + 1} content="sfx" />
      <Panel comic={comic} k={page + 2} content="fig" />
    </div>
  );
  if (layout === 4) return (
    <div style={{ ...wrap, gridTemplate: '1fr 1.2fr / 1fr 1fr' }}>
      <Panel comic={comic} k={page} content="fig" />
      <Panel comic={comic} k={page + 1} content="fig" />
      <Panel comic={comic} k={page + 2} content="both" style={{ gridColumn: '1 / 3' }} />
    </div>
  );
  // layout 0
  return (
    <div style={{ ...wrap, gridTemplate: '1fr 1.4fr / 1fr' }}>
      <Panel comic={comic} k={page} content="bubble" />
      <Panel comic={comic} k={page + 1} content="both" />
    </div>
  );
}

/* ----------------------------------------------------------- */
/* Library view                                                 */
/* ----------------------------------------------------------- */
function Library({ comics, progress, onOpen, onAdd, markScheme }) {
  return (
    <div style={{ minHeight: '100%', background: 'var(--ink)', position: 'relative', overflow: 'hidden' }}>
      <div className="halftone-bg" style={{ position: 'absolute', inset: 0, color: 'var(--crimson)', opacity: 0.05, pointerEvents: 'none' }} />
      {/* comic action-burst behind header */}
      <div style={{ position: 'absolute', top: 24, right: -54, width: 168, height: 168, opacity: 0.16, pointerEvents: 'none',
        background: 'var(--crimson)',
        clipPath: 'polygon(50% 0,58% 30%,80% 12%,72% 38%,100% 38%,76% 54%,93% 78%,64% 68%,62% 100%,48% 72%,28% 94%,33% 64%,5% 70%,28% 48%,4% 28%,33% 34%,30% 6%)' }} />
      {/* header */}
      <div style={{ position: 'relative', padding: '64px 18px 14px', display: 'flex', alignItems: 'center', gap: 11 }}>
        <div style={{ filter: 'drop-shadow(3px 3px 0 rgba(0,0,0,0.6))' }}><MiniMark box={40} scheme={markScheme} /></div>
        <div>
          <div className="anton" style={{ fontSize: 27, lineHeight: 0.8, color: 'var(--cream)', textShadow: '2px 2px 0 rgba(0,0,0,0.5)' }}>
            CHI<span style={{ color: 'var(--crimson)' }}>KA</span>
          </div>
          <div className="archivo" style={{ fontSize: 8.5, fontWeight: 800, letterSpacing: '0.26em', color: 'rgba(243,233,214,0.55)', marginTop: 3 }}>CHITRA KATHA</div>
        </div>
      </div>
      {/* banner section tag */}
      <div style={{ position: 'relative', padding: '2px 18px 18px' }}>
        <span className="anton" style={{ display: 'inline-block', width: 'max-content', whiteSpace: 'nowrap', background: 'var(--ochre)', color: 'var(--ink)',
          fontSize: 15, letterSpacing: '0.04em', padding: '6px 16px 5px', borderRadius: 3,
          border: '2.5px solid var(--ink)', boxShadow: '3px 3px 0 rgba(0,0,0,0.6)', transform: 'rotate(-1.5deg)' }}>YOUR LIBRARY</span>
      </div>
      {/* grid */}
      <div style={{ position: 'relative', padding: '0 18px 40px', display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
        {comics.map(c => (
          <CoverCard key={c._uid} comic={c} progress={progress[c._uid]} onOpen={onOpen} />
        ))}
        {/* add tile — comic burst */}
        <button onClick={onAdd} style={{ border: 'none', background: 'none', cursor: 'pointer', padding: 0, textAlign: 'left' }}>
          <div style={{ position: 'relative', width: '100%', aspectRatio: '0.7', borderRadius: 4, overflow: 'hidden',
            border: '3px dashed rgba(243,233,214,0.4)', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 12 }}>
            <div className="halftone-bg" style={{ position: 'absolute', inset: 0, color: 'var(--ochre)', opacity: 0.12 }} />
            <div style={{ position: 'relative', width: 64, height: 64, display: 'flex', alignItems: 'center', justifyContent: 'center',
              background: 'var(--crimson)', filter: 'drop-shadow(3px 3px 0 rgba(0,0,0,0.6))',
              clipPath: 'polygon(50% 0,61% 18%,82% 10%,76% 32%,98% 35%,80% 50%,96% 70%,72% 67%,68% 92%,50% 76%,32% 92%,28% 67%,4% 70%,20% 50%,2% 35%,24% 32%,18% 10%,39% 18%)' }}>
              <svg width="24" height="24" viewBox="0 0 22 22"><path d="M11 3v16M3 11h16" stroke="var(--cream)" strokeWidth="3" strokeLinecap="round" /></svg>
            </div>
            <span className="anton" style={{ position: 'relative', fontSize: 14, letterSpacing: '0.04em', color: 'var(--cream)' }}>LOAD COMIC</span>
          </div>
        </button>
      </div>
    </div>
  );
}

/* ----------------------------------------------------------- */
/* Reader view                                                  */
/* ----------------------------------------------------------- */
function Reader({ comic, page, onPage, onClose }) {
  const N = comic.pages;
  const go = (p) => onPage(Math.max(0, Math.min(N - 1, p)));
  const tap = (e) => {
    const x = e.clientX - e.currentTarget.getBoundingClientRect().left;
    if (x < e.currentTarget.clientWidth * 0.4) go(page - 1);
    else if (x > e.currentTarget.clientWidth * 0.6) go(page + 1);
  };
  return (
    <div style={{ position: 'absolute', inset: 0, background: '#0c0907', display: 'flex', flexDirection: 'column', overflow: 'hidden' }}>
      <ActionRays color={comic.accent === 'var(--ink)' ? 'var(--crimson)' : comic.accent} />
      {/* top bar */}
      <div style={{ position: 'absolute', top: 0, left: 0, right: 0, zIndex: 5, paddingTop: 52,
        display: 'flex', alignItems: 'center', gap: 12, padding: '52px 16px 12px',
        background: 'linear-gradient(to bottom, rgba(12,9,7,0.92), transparent)' }}>
        <button onClick={onClose} style={{ border: 'none', background: 'rgba(243,233,214,0.12)', borderRadius: 999, width: 38, height: 38, display: 'flex', alignItems: 'center', justifyContent: 'center', cursor: 'pointer' }}>
          <svg width="11" height="18" viewBox="0 0 11 18"><path d="M9 2L2 9l7 7" stroke="var(--cream)" strokeWidth="2.4" fill="none" strokeLinecap="round" strokeLinejoin="round" /></svg>
        </button>
        <div style={{ flex: 1 }}>
          <div className="archivo" style={{ fontSize: 13, fontWeight: 800, color: 'var(--cream)', lineHeight: 1 }}>{comic.title.replace('\n', ' ')}</div>
          <div className="archivo" style={{ fontSize: 9, fontWeight: 600, letterSpacing: '0.14em', color: 'rgba(243,233,214,0.5)', marginTop: 3 }}>{comic.issue}</div>
        </div>
      </div>

      {/* page */}
      <div onClick={tap} style={{ flex: 1, position: 'relative', cursor: 'pointer' }}>
        <div style={{ position: 'absolute', inset: 0, top: '4%', bottom: '13%', left: '4%', right: '4%' }}>
          <div style={{ position: 'relative', width: '100%', height: '100%', border: '4px solid var(--ink)', boxShadow: '5px 6px 0 rgba(0,0,0,0.55), 0 12px 34px rgba(0,0,0,0.6)' }}>
            <PageArt comic={comic} page={page} />
            <Reticle inset={6} size={14} color="rgba(230,37,52,0.9)" w={2} />
          </div>
        </div>
      </div>

      {/* bottom scrubber */}
      <div style={{ position: 'absolute', left: 0, right: 0, bottom: 0, zIndex: 5, padding: '20px 22px 34px',
        background: 'linear-gradient(to top, rgba(12,9,7,0.97) 60%, transparent)' }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 12 }}>
          <span className="anton" style={{ fontSize: 12, letterSpacing: '0.18em', color: 'rgba(243,233,214,0.55)' }}>SWIPE TO TURN</span>
          {/* comic starburst page badge */}
          <div style={{ position: 'relative', width: 58, height: 58, display: 'flex', alignItems: 'center', justifyContent: 'center', filter: 'drop-shadow(2.5px 2.5px 0 rgba(0,0,0,0.6))' }}>
            <div style={{ position: 'absolute', inset: 0, background: 'var(--ink)', clipPath: STARBURST }} />
            <div style={{ position: 'absolute', inset: 3, background: 'var(--ochre)', clipPath: STARBURST }} />
            <span className="anton" style={{ position: 'relative', fontSize: 19, color: 'var(--ink)', lineHeight: 0.8, textAlign: 'center' }}>
              {page + 1}<span style={{ fontSize: 9, display: 'block', marginTop: 1 }}>/ {N}</span>
            </span>
          </div>
        </div>
        <input className="scrub" type="range" min={0} max={N - 1} value={page}
          onChange={(e) => go(parseInt(e.target.value, 10))}
          style={{ '--fill': ((page) / (N - 1) * 100) + '%' }} />
      </div>
    </div>
  );
}

/* ----------------------------------------------------------- */
/* App + device scaling                                         */
/* ----------------------------------------------------------- */
function useFit(w, h) {
  const [s, setS] = useState(1);
  useEffect(() => {
    const fit = () => setS(Math.min(window.innerWidth / (w + 24), window.innerHeight / (h + 24), 1.1));
    fit(); window.addEventListener('resize', fit); return () => window.removeEventListener('resize', fit);
  }, [w, h]);
  return s;
}

function App() {
  const [t, setTweak] = window.useTweaks(TWEAK_DEFAULTS);
  const [comics, setComics] = useState(() => load('chika.comics', CATALOGUE.slice(0, 4).map((c, i) => ({ ...c, _uid: c.id }))));
  const [progress, setProgress] = useState(() => load('chika.progress', {}));
  const [view, setView] = useState({ name: 'library' });
  const scale = useFit(402, 874);

  useEffect(() => save('chika.comics', comics), [comics]);
  useEffect(() => save('chika.progress', progress), [progress]);

  const openComic = (c) => setView({ name: 'reader', uid: c._uid });
  const setPage = (uid, p) => setProgress(pr => ({ ...pr, [uid]: { page: p } }));

  const addComic = () => {
    const have = new Set(comics.map(c => c.id));
    const next = CATALOGUE.find(c => !have.has(c.id)) || CATALOGUE[(comics.length) % CATALOGUE.length];
    const uid = next.id + '-' + Date.now().toString(36);
    const fresh = { ...next, _uid: uid, _new: true };
    setComics(cs => [...cs, fresh]);
    setTimeout(() => setComics(cs => cs.map(c => c._uid === uid ? { ...c, _new: false } : c)), 1400);
  };

  const active = view.name === 'reader' ? comics.find(c => c._uid === view.uid) : null;
  const activePage = active ? (progress[active._uid]?.page || 0) : 0;

  return (
    <div style={{ transform: `scale(${scale})`, transformOrigin: 'center center' }}>
      <window.IOSDevice dark>
        {view.name === 'library'
          ? <Library comics={comics} progress={progress} onOpen={openComic} onAdd={addComic} markScheme={t.markScheme} />
          : <Reader comic={active} page={activePage} onPage={(p) => setPage(active._uid, p)} onClose={() => setView({ name: 'library' })} />}
      </window.IOSDevice>
      <window.TweaksPanel>
        <window.TweakSection label="Brand" />
        <window.TweakSelect label="Logo color" value={t.markScheme}
          options={['maroon', 'dark', 'cream', 'crimson', 'ochre']}
          onChange={(v) => setTweak('markScheme', v)} />
      </window.TweaksPanel>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
