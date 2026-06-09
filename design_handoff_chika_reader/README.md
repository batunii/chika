# Chika · Chitra Katha — Reader App · Developer Handoff

A mobile comic-reader prototype with a full comic-book / pulp-print visual identity
(bold Anton display type, halftone dot textures, reticle brackets, hard offset shadows,
crimson + cream + ink palette). This package contains everything needed to rebuild it
in a production codebase.

> **Design note:** the latest revision dials the library background texture down
> (halftone wash and the crimson header starburst are now subtle) so the covers carry
> the page. Keep it quiet — see `chika-app.jsx` → `Library` and `ActionRays`.

---

## 1. What's in this package

```
design_handoff_chika_reader/
├── README.md                  ← you are here
├── source/                    ← the working prototype (run it, read it)
│   ├── Chika App.html         ← entry point: the reader app
│   ├── chika-app.jsx          ← all app logic + components (React, Babel JSX)
│   ├── chika-brand.css        ← brand tokens (colors, font classes, halftone)
│   ├── ios-frame.jsx          ← device bezel wrapper (prototype-only chrome)
│   ├── tweaks-panel.jsx       ← in-prototype tweak controls (prototype-only)
│   ├── Chika Logo.html        ← the logo exploration / construction file
│   └── design-canvas.jsx      ← canvas used for the logo exploration (not app)
└── assets/
    ├── logo-wordmark.png      ← primary stacked wordmark (CHI|KA + Chitra Katha)
    ├── logo-lockup.png        ← horizontal icon + wordmark lockup (app header)
    ├── icon-maroon.png        ← app icon, maroon ground (primary, 512²)
    ├── icon-dark.png          ← app icon, ink ground (512²)
    ├── icon-cream.png         ← app icon, cream ground (512²)
    └── screens/
        ├── library.png        ← Library / "Your Library" grid
        └── reader.png         ← Reader / panel view
```

`source/` is a self-contained prototype — open `Chika App.html` in any browser to see
the real thing (interactions, animation, persistence all work).

---

## 2. Brand tokens

These live in `chika-brand.css` as CSS custom properties. Port them verbatim.

| Token | Hex | Role |
|---|---|---|
| `--ink` | `#17100E` | near-black; primary dark ground, line art |
| `--ink-soft` | `#2A201C` | softer dark ground |
| `--crimson` | `#D11F2D` | primary brand red |
| `--crimson-bright` | `#E62534` | accent red (logo spine, highlights) |
| `--maroon` | `#7C1620` | deep red ground (app icon bg) |
| `--maroon-deep` | `#5C0F18` | darkest red; shadows-on-red |
| `--cream` | `#F3E9D6` | primary light / paper text on dark |
| `--paper` | `#FAF3E4` | lightest paper ground |
| `--ochre` | `#E0A22B` | gold/marigold accent (badges, page coin) |

### Typography
| Class | Family | Usage |
|---|---|---|
| `.anton` | **Anton** (400) | display headlines, the wordmark, comic titles, page numbers |
| `.archivo` | **Archivo** (400–900) | UI labels, issue tags, body / metadata (use 800 uppercase for kickers) |
| `.baloo` | **Baloo 2** (500–800) | Devanagari script ("चित्र कथा") and friendly numerals |

Google Fonts import (already in both HTML files):
```
https://fonts.googleapis.com/css2?family=Anton&family=Archivo:wght@400;500;600;700;800;900&family=Baloo+2:wght@500;600;700;800
```

### Signature texture & motifs (rebuild these as utilities)
- **Halftone dots** — `.halftone-bg`: `radial-gradient(currentColor 1.6px, transparent 1.7px)` at `background-size: 9px 9px`. Set `color` to tint; mask with a `linear-gradient` for the fade. Keep opacity **low** (0.05–0.22).
- **Reticle brackets** — four L-shaped corner marks (see `Reticle` in `chika-app.jsx`). Used on the logo spine and active panels.
- **Hard offset shadow** — `box-shadow: 8px 8px 0 var(--ink)` (no blur) on framed panels.
- **Heavy ink frame** — `border: 4–5px solid var(--ink)` around panels/covers.
- **Starburst** — `STARBURST` clip-path polygon (in `chika-app.jsx`) for action bursts/badges.

---

## 3. Logo system

The mark is a stylized **"C"** built from three stacked comic panels (two cream cells +
a crimson "spine" cell with reticle corners and a halftone wash). It reads as a letter
**and** as a comic page.

| Asset | When to use |
|---|---|
| `logo-wordmark.png` | Primary lockup — splash, marketing, about screens |
| `logo-lockup.png` | Horizontal icon + "CHIKA" — app header, nav |
| `icon-maroon.png` | **Primary** app icon / favicon (maroon ground) |
| `icon-dark.png` / `icon-cream.png` | Alt grounds for light/dark contexts |

The icon and marks are **code-generated** (vector-crisp at any size). Components:
- `PanelCMark` / `ChikaIcon` — full app icon (see `source/Chika Logo.html`)
- `MiniMark` — small in-app header mark, 5 color schemes in `MARK_SCHEMES` (`chika-app.jsx`)

The PNGs are exact renders at the sizes noted; regenerate from the source components if
you need other resolutions or true SVG.

---

## 4. Screens & components

The app is two views, switched by `view` state in `App` (`chika-app.jsx`):

### Library (`library.png`)
- Header: `MiniMark` + "CHIKA / CHITRA KATHA" lockup, subtle starburst behind it.
- "YOUR LIBRARY" ochre kicker badge.
- 2-column grid of `CoverCard`s + a dashed "add" tile (`onAdd`).
- Each cover (`CoverArt`) is a procedurally-styled placeholder: ground color, accent,
  one of 4 `motif` graphics, halftone wash, issue tag, Anton title. Progress bar +
  "% · pg N/M" metadata sit below.

### Reader (`reader.png`)
- Top bar: back button (`onClose`), title + issue.
- Multi-panel comic page laid out on a grid (`Page` component, varies by page index),
  framed in ink with hard shadow, speech bursts ("DHADAAM!").
- Tap right/left half to advance/go back (`tap` handler on the page), ochre page coin
  bottom-right, "SWIPE TO TURN" hint.

### Data model
`CATALOGUE` (array of comics) — fields: `id, title, issue, accent, ground, motif, pages`.
The prototype seeds the library with the first 4 and persists to `localStorage`
(`chika.comics`, `chika.progress`). Replace with real catalogue + reading-progress APIs.

### Tweakable brand option
`tweaks-panel.jsx` exposes one control — **Logo color** (`markScheme`: maroon / dark /
cream / crimson / ochre). This is prototype tooling; in production it maps to the
`MARK_SCHEMES` table. The `ios-frame.jsx` bezel and `tweaks-panel.jsx` are **prototype
chrome — drop them** when porting to a real device app.

---

## 5. Rebuilding it for production

1. **Tokens first** — port `chika-brand.css` (colors + font classes + `.halftone-bg`) into your design-token layer.
2. **Texture utilities** — implement halftone, reticle, hard-shadow, ink-frame as reusable mixins/components; they appear everywhere.
3. **Logo** — drop in the PNGs, or re-implement `ChikaIcon`/`MiniMark`/`PanelCMark` as components/SVG for crispness and the recolor schemes.
4. **Screens** — `Library` (cover grid) and `Reader` (panel pager). The cover-art generator (`CoverArt`) is a nice fallback for comics without bespoke art — keep it.
5. **Strip prototype-only files** — `ios-frame.jsx`, `tweaks-panel.jsx`, `design-canvas.jsx`, `Chika Logo.html` are not part of the shipping app.

The JSX in `source/` is plain React (hooks) transpiled in-browser by Babel. It reads
cleanly as a component reference — keep `chika-app.jsx` open alongside this doc.
