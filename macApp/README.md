# Chika for Mac

Native macOS 15+ SwiftUI app (not Catalyst). The Xcode project is generated from `project.yml`
with [XcodeGen](https://github.com/yonaskolb/XcodeGen) and is not committed.

## Generate, build, test, run

```sh
cd macApp
xcodegen generate
xcodebuild -project Chika.xcodeproj -scheme Chika -configuration Debug build
xcodebuild -project Chika.xcodeproj -scheme Chika test        # ChikaTests (library import, CBR reader)
(cd ChikaCore && swift test)                                  # the shared core
open Chika.xcodeproj                                          # or run from Xcode (⌘R)
```

`xcodegen generate` also writes `Info.plist` from the `info:` block in `project.yml`; edit the
YAML, not the plist.

To try a comic: copy `iosApp/ci/SyntheticManga.cbz` somewhere (the repo ignores `*.cbz`), then
⌘O or drop it on the library window.

## Layout

- `ChikaCore/`: Swift package with the panel pipeline, reader slot state machine and archive
  helpers, ported from `shared/` (Kotlin). Foundation only, tested with `swift test`.
- `Sources/Library`, `Sources/Brand`, `Sources/Archive`: library window, settings, brand look,
  CBZ/CBR import.
- `Sources/Reader`: reader and peek windows, Core ML panel detection.
- `Resources/`: fonts, asset catalog, the panel-detector model (compiled by Xcode), privacy manifest.
- `Tests/`: the `ChikaTests` unit-test bundle, hosted in the app.

Comics are stored in `~/Library/Containers/com.chakra.comicreader/Data/Documents/Comics` (the app is
sandboxed; this is the same folder and bundle id the Catalyst app used, so its library and progress carry over).

## Reading modes

Each comic remembers its mode (the book/grid menu in the reader's top bar):

- **Panels** (⌘1): the camera steps panel by panel; ← → or Space step, ⌘[ ⌘] turn pages.
- **Two pages** (⌘2): facing pages side by side, mirrored for right-to-left. The cover and any
  double-page scan (wider than tall) stand alone. ← → step a spread.
- **Scroll** (⌘3): every page in one vertical strip at the window's width, for webtoons. Swipe or
  use ← → / Space / Page Up/Down to move most of a screen; ⌘[ ⌘] and the scrubber jump to a page.

## Night filters

For reading late, the moon menu in the reader's top bar (or Settings, ⌘,) changes the pages, never
the app's own controls. ⌥⌘N cycles it in the reader. The choice is app-wide, not per comic.

- **Invert**: dark pages with the colours' hues kept.
- **Sepia**: warm monochrome.
- **Dim**: in Panels mode, darkens the page around the current panel (on the whole page nothing
  is darkened); in Two pages, Scroll and the peek window it lowers the whole page's brightness.

## Bookmarks

⌘D bookmarks where you are, or removes the bookmark if there is one: the panel in Panels mode
(the page when the whole page shows), the spread's first page in Two pages, the top page in Scroll.
The bookmark menu in the top bar is filled when the current spot is bookmarked; it lists the comic's
bookmarks in page order ("Page 4 · panel 2") and picking one jumps there (in Two pages and Scroll,
to its page). Bookmarks live next to the progress in the same database and go when the comic is
deleted from the library.

## Copy and export

⌘C (Edit > Copy) puts what you are reading on the clipboard as an image: the current panel in
Panels mode (the page when the whole page shows), both pages of the spread side by side in Two
pages, the page at the top in Scroll. In the peek window ⌘C copies what the peek shows (the whole
spread in Two pages). ⇧⌘E (Export Panel…) saves that image as a PNG wherever you choose, named
"<title> p<page>.png".
Both are also in the "…" menu at the end of the top bar, and do nothing while a new page is still
loading. The image is the decoded page without the night filter: full size up to about 5000 px
(larger scans are halved until they fit), and in Two pages both pages joined at the taller page's height.

## Panel editor

When detection gets a page wrong, ⌘E (or Edit Panels in the "…" menu) in Panels mode opens the
panel editor on the current page, once the page and its panels have loaded. It shows the whole page
with each panel as a numbered box (the number is its place in the reading order):

- Drag on the page to draw a new panel; it is read last. Dragging across a box that is not selected
  also draws.
- Click a box to select it, Shift-click to add or remove one; click the page to select none.
- Drag a selected box to move it, or one of its corners to resize it. Panels stay on the page and
  never get smaller than 2% of it on a side.
- Delete removes the selected panels.
- The toolbar: Earlier and Later move the selected panel in the reading order; Merge joins two or
  more into the box around them (read where the first of them was); Split across cuts one into top
  and bottom halves, Split down into side-by-side halves (the right half first when reading right
  to left); Auto order puts every panel in reading order for the comic's direction; Reset to
  detected forgets the page's saved panels and detects them again.
- Return saves, Esc (or Cancel) closes without saving. While editing, the arrow keys, clicks and
  zoom do not move the reader.

A saved page reads its edited panels instead of detected ones (the status line says "· edited"),
keeps their order when the reading direction is flipped, and saving with no panels left reads the
page whole. Edits are kept per page in the progress database and go when the comic is deleted from
the library. A bookmark or resume point on that page keeps its panel number, so after an edit it can
land on a different panel.

## Peek auto-advance

The peek window (⇧⌘P) can read by itself: the play button in its hover bar, or P while it is
focused, steps one panel (a spread in Two pages, where the peek shows both pages, a page in Scroll)
every few seconds. The stepper next to it sets the wait, 2 to 20 seconds (5 by default, remembered
app-wide; its tooltip shows the current value). Any step, by hand or by the timer, starts the wait
again; a page whose panels are still being detected is held until they land; playing stops by itself
at the end of the comic, or if the comic could not be opened.

## Where the library lives

- **Imported copies** (⌘O, or files dropped on the window) go to the Comics folder above. CBZ,
  CBR, CB7 and PDF are accepted: CBR and CB7 are converted to CBZ on import, PDFs are kept as they are.
- **Read in place** (⇧⌘O, or a folder dropped on the window or opened with Chika): single comics or whole folders stay
  where they are. Chika keeps a security-scoped bookmark for each (entitlement
  `com.apple.security.files.bookmarks.app-scope`) and watches folders with FSEvents, so new CBZ/CBR
  files appear by themselves
  (PDFs are not picked up from folders; add them one by one). Removing one only forgets the bookmark; the files are never touched.
  A CBR or CB7 read in place is converted once into `Library/Caches/Chika/Converted` inside the container.
- **Progress** is a SQLite table at `Library/Application Support/Chika/progress.sqlite` inside the
  container, keyed by file identity (volume UUID + inode), so renaming a comic keeps its place. The
  first launch copies the old UserDefaults progress over and leaves it for the Catalyst app.

## Finder thumbnails (Quick Look)

The app embeds `ChikaThumbnails.appex`, which draws a comic's cover as its Finder icon for .cbz,
.cbr and .cb7. macOS picks it up once it knows the app: run Chika from `/Applications`, or register
a build in place and reset Quick Look:

```sh
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R build/Build/Products/Debug/Chika.app
qlmanage -r
qlmanage -t -x -s 256 -o /tmp SomeComic.cbz     # writes /tmp/SomeComic.cbz.png
```

## Signing

Local builds sign ad hoc (`CODE_SIGN_IDENTITY: "-"`), so no team is needed. To sign with your
team, either edit the base settings in `project.yml`:

```yaml
CODE_SIGN_STYLE: Automatic
CODE_SIGN_IDENTITY: "Apple Development"
DEVELOPMENT_TEAM: XXXXXXXXXX
```

or pass them on the command line:

```sh
xcodebuild -scheme Chika CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM=XXXXXXXXXX build
```

## If `xcodebuild` hangs at "Resolve Package Graph"

On some machines SwiftPM stalls on a keychain lookup while downloading the libarchive binary.
Resolve once in Xcode (File → Packages → Resolve Package Versions), then build offline:

```sh
xcodebuild -project Chika.xcodeproj -scheme Chika -configuration Debug \
  -clonedSourcePackagesDirPath ~/Library/Developer/Xcode/DerivedData/Chika-*/SourcePackages \
  -disableAutomaticPackageResolution build
```
