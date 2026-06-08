# Comic Book Reader

An Android comic reader that opens **CBZ** and **CBR** files, detects the panels on each page with
OpenCV, and guides you through them one tap at a time — page → panel → panel → … → zoom out → next
page. Built with Kotlin and Jetpack Compose.

## Reading experience

When you open a page it's shown in full (zoomed out). Tapping the **right** third of the screen
advances: first to panel 1, then panel 2, and so on in reading order. After the last panel a tap
zooms back out to the whole page; the next tap turns to the next page (which again starts zoomed
out, so page turns always happen from a full-page view — smooth and consistent).

| Gesture | Action |
|---|---|
| Tap **right** third | Next (panel, then next page) |
| Tap **left** third | Previous |
| Tap **center** | Show/hide the top bar |
| Pinch / drag | Free zoom & pan the current view |
| Top bar ⇄ button | Toggle left-to-right / right-to-left (manga) ordering |

Panel detection is automatic and runs lazily (current page on demand, next page prefetched). If a
page doesn't match the usual bordered-panel layout (splash pages, borderless/full-bleed art, very
noisy scans), the reader gracefully falls back to showing the whole page as a single "panel", so
reading never breaks.

## Requirements

- **Android Studio** (bundles the JDK + SDK). Developed against JDK 21 and SDK **API 36**.
- A **run target**: a physical device with USB debugging, or an emulator (AVD).
- `minSdk 26` (Android 8.0) · `compileSdk / targetSdk 36`.

## Build & run

1. **Open** the project folder in Android Studio (`File → Open`) and let it sync Gradle. First sync
   downloads dependencies (incl. the OpenCV AAR, ~tens of MB) and may take a few minutes.
2. Pick a run target:
   - **Phone:** Settings → About phone → tap *Build number* 7× to enable Developer Options →
     enable **USB debugging** → plug in via USB and accept the prompt.
   - **Emulator:** *Device Manager* → *Add a device* → e.g. *Pixel 7, API 36* (it downloads the
     system image).
3. Press **Run ▶**.

Command line (from the project root):

```bash
./gradlew assembleDebug          # build the APK
./gradlew installDebug           # build + install on the connected device/emulator
```

`local.properties` already points `sdk.dir` at `C:\Users\syson\AppData\Local\Android\Sdk`. If you
move the SDK, update that path (the file is machine-specific and git-ignored).

## Using the app

1. Tap the **+** button and pick a `.cbz` or `.cbr` file. The app copies it into its own storage,
   validates it, generates a cover, and adds it to your library. The original file is left untouched.
2. Tap a cover to read. Your position (page **and** panel) is saved automatically and resumes next
   time. Long-press a cover to remove it from the library.

## Architecture

```
data/archive   ComicArchive abstraction; ZipComicArchive (CBZ via commons-compress),
               RarComicArchive (CBR via junrar); magic-byte format detection; natural sort.
data/page      PageLoader — decodes pages with downsampling + an LRU bitmap cache.
data/db        Room: ComicEntity / ComicDao / AppDatabase.
data/library   LibraryRepository — import (copy + cover), list, progress, delete.
detection      PanelDetector (OpenCV: threshold → morphology → contours → filter) and
               PanelOrdering (row clustering, LTR/RTL). Falls back to a single full-page panel.
ui/reader      ReaderViewModel (the page→panel→outro slot state machine) + ReaderScreen
               (animated camera framing, tap zones, pinch/pan, page-turn fade).
ui/library     LibraryViewModel + LibraryScreen (cover grid, SAF import, delete).
ui/nav         AppNavHost — Library ⇄ Reader.
```

## Known limitations / notes

- **RAR5:** junrar fully supports RAR4. RAR5 archives are only partially supported and may fail to
  open; such files surface a friendly error.
- **Panel detection is heuristic.** The tuning knobs live in `PanelDetector.Config` (min/max panel
  area, edge size, morphology kernel, overlap thresholds). Expect to tune these against real comics.
- Supported page image types inside archives: JPEG, PNG, WebP, GIF, BMP, AVIF.
- First launch initializes OpenCV's native libraries; if that ever fails, the app still runs and
  simply shows whole pages without panel zooming.

## Roadmap ideas

- Manual panel correction/reordering for mis-detected pages.
- PDF support (Android `PdfRenderer`) and image-folder "comics".
- Per-comic settings (reading direction is already persisted), and an ML-based detector option.
