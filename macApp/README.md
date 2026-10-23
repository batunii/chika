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
- **Dim**: in Panels mode, darkens the page around the current panel, and the whole page while the
  whole page shows; in Two pages, Scroll and the peek window it lowers the whole page's brightness.

## Bookmarks

⌘D bookmarks where you are, or removes the bookmarks there if there are any: the panel in Panels
mode (the page when the whole page shows), the spread's first page in Two pages, the top page in
Scroll. In Two pages and Scroll any bookmark on a page on screen counts as here, a panel's too.
The bookmark menu in the top bar is filled when the current spot is bookmarked; it lists the comic's
bookmarks in page order ("Page 4 · panel 2") and picking one jumps there (in Two pages and Scroll,
to its page). A bookmark keeps its panel number, so after a direction flip or a panel edit it can
land on a different panel. Bookmarks live next to the progress in the same database and go when an
imported comic is deleted; a comic read in place keeps them, like its progress, so they come back if
it is added again.

## Copy and export

⌘C (Edit > Copy) puts what you are reading on the clipboard as an image: the current panel in
Panels mode (the page when the whole page shows), both pages of the spread side by side in Two
pages, the page at the top in Scroll. In the peek window ⌘C copies what the peek shows (the whole
spread in Two pages). ⇧⌘E (Export Panel…) saves that image as a PNG wherever you choose, named
"<title> p<page>.png".
Both are also in the "…" menu at the end of the top bar, and do nothing while a new page is still
loading. The image is the decoded page without the night filter: full size up to about 5000 px
(larger scans are halved until they fit; in Scroll the limit is on the page's width, so a long strip
keeps its full height), and in Two pages both pages joined at the taller page's height.

## Panel editor

When detection gets a page wrong, ⌘E (or Edit Panels in the "…" menu) in Panels mode opens the
panel editor on the current page, once the page and its panels have loaded. It shows the whole page
with each panel as a numbered box (the number is its place in the reading order):

- Drag on the page to draw a new panel; it is read last. Dragging across a box that is not selected
  also draws, unless the drag starts on the box's number.
- Drag a box's number onto another box to give it that box's place in the reading order (the boxes
  in between shift by one).
- Click a box to select it, Shift-click to add or remove one; click the page to select none.
- Drag a selected box to move it, or one of its corners to resize it. Panels stay on the page and
  never get smaller than 2% of it on a side.
- Delete removes the selected panels.
- The toolbar: Earlier and Later move the selected panel in the reading order; Merge joins two or
  more into the box around them (read where the first of them was); Split across cuts one into top
  and bottom halves, Split down into side-by-side halves (the right half first when reading right
  to left); Auto order puts every panel in reading order for the comic's direction; Reset to
  detected forgets the page's saved panels and detects them again.
- Return saves, Esc (or Cancel) closes without saving. While editing, the arrow keys, clicks, zoom
  and ⌘C do nothing in the reader, and peek auto-advance pauses (the peek's own arrows still step).

A saved page reads its edited panels instead of detected ones (the status line says "· edited"),
keeps their order when the reading direction is flipped, and saving with no panels left reads the
page whole. Edits are kept per page in the progress database and go when an imported comic is
deleted; a comic read in place keeps them, like its progress (until then the training export counts
them as skipped). A bookmark or resume point on that page keeps its panel number, so after an edit it can
land on a different panel.

## Stored detections

Each page's detector output (its zoom regions for both reading directions and its speech-balloon
boxes) is kept in the progress database, so reopening a comic, flipping its direction or opening the
peek window never waits on the detector. After a comic is imported or opened, Chika detects the pages
not stored yet in the background, one comic at a time at low priority with its own copy of the model,
so the reader's own detection never queues behind it. Rows carry the detector's version
(`CoreMLPanelDetector.version`): bump it when the model, decoder or planner changes and old rows are
detected again. They also carry the file's size and modification date, so a comic edited in place (a
page added, say) is detected again rather than given another page's panels; the same goes for the
stored balloon text below. Progress, bookmarks and panel edits are kept. Panel edits still win over
stored detections. Deleting an imported comic drops its rows.

## Translate

The speech-bubble button in the reader's top bar (⇧⌘T) translates the speech balloons on screen,
in Panels and Two pages (not Scroll or the peek window yet). Each balloon the panel detector found
is read with Vision's text recognition, which detects the language itself and reads vertical
Japanese columns right to left, then translated on this Mac by Apple's Translation framework. The
translation is drawn over the balloon on the balloon's own paper colour, shrunk to fit, and follows
the camera, zoom and pan like the page; hover a balloon to see the original. Settings (⌘,) picks
the language to translate into, the system language by default. The first translation from a
language may ask to download it; text already in the target language and balloons without letters
are left alone, and "can't translate" in the status line means the pair is not supported or the
download was declined.

Recognized text is stored per comic, page and balloon in the progress database (rows carry
`BalloonReader.version`: bump it when recognition changes), translations per text and target
language, so a page is only read and translated once. Both go when an imported comic is deleted.

## Read aloud

The speaker button in the reader's top bar (⇧⌘R) reads the speech balloons out loud, one at a time,
in Panels and Two pages (turning to Scroll or closing the window stops it). It uses Translate's text
recognition and stored text, so a page read for one is not read again for the other: the translation
when Translate is on and has one, else the text off the page, in a voice for that text's language (the
system voice when there is none). The balloon being spoken is outlined. In Panels mode it reads the
balloons of the panel on screen (each balloon belongs to the panel it overlaps most), in Two pages
every balloon of the spread, in reading order; then it steps on like the arrow key and carries on, to
the end of the comic. A panel with no text gets about 1.5 s, a whole-page view a short beat. Stepping
by hand cuts the balloon off and carries on from the new place. Settings (⌘,) sets the speed.

## Training export

File > Export Panel Corrections… turns pages fixed in the panel editor into training data for the
panel detector, so the model can learn from the reader's corrections. Only a page whose every box was
drawn by hand in the editor (drawn boxes may then be moved and resized) is exported: the editor
starts from the reader's zoom regions, not from panels. Those are padded (5.7% of a panel's size on
each side), may cover two merged neighbours or be pieces of one panel (the planner splits a
full-width panel into 2, a broad panel or a whole page into 4, the gap filler adds boxes for
uncovered strips), and Merge and Split make boxes that are rarely one panel either; trained on, they
would teach the detector to pad, merge and split. To export a page, delete its boxes and draw each
panel tightly. Pick (or create) a folder; Chika writes each such page of a comic that is still in the
library as
`images/train/chika_<title>_p<page>.jpg` (the archive's own bytes when the page is a JPEG, else
re-encoded) and its boxes as `labels/train/chika_<title>_p<page>.txt`, one `0 cx cy w h` line per
panel (class 0 = panel, normalized, 6 decimals), the layout `training/scripts` writes. The page
number is 1-based and three digits, and the title has anything but letters, digits and `-` replaced
by `_`. Comics whose titles would give the same name (ignoring case) also get 8 hex digits from the
comic's identity, `chika_<title>_<id>_p<page>`. A page saved with no boxes goes out as one page-sized
panel, the way the reader shows it. The closing alert counts edits skipped because their comic is no
longer in the library or a box was not drawn by hand, and pages that could not be read (the comic
will not open, or has shrunk). Edits saved before this rule existed count as not drawn.

Like the COMICS pages, these carry panel labels only, no text (class 1) boxes. To fold them into
the training set, copy both folders into the dataset from the repo's `training` folder (the `chika_`
prefix keeps them apart from the `comics_` and `m109_` pages), then train as usual:

```sh
cd training
cp -R <export>/images/train/. dataset/images/train/
cp -R <export>/labels/train/. dataset/labels/train/
```

Each export writes every corrected page again over the same names; export into a new folder rather
than over an old one, so a page you have since reset to detection, or a comic whose name changed,
leaves no stale files behind.

## Peek window

⇧⌘P floats the current panel in a small always-on-top window with no frame or title bar. Drag it
by the panel, resize it from its edges. Hovering fades in its controls as floating Liquid Glass
pieces (frosted material before macOS 26): minimize on the left, previous/next panel, auto-advance,
seconds per panel and window opacity in the middle (the last two hide when the window is narrow),
and back to the full reader on the right.

## Peek auto-advance

The peek window (⇧⌘P) can read by itself: the play button in its hover bar, or P while it is
focused, steps one panel (a spread in Two pages, where the peek shows both pages, a page in Scroll)
every few seconds. The stepper next to it sets the wait, 2 to 20 seconds (5 by default, remembered
app-wide; its tooltip shows the current value). Any step, by hand or by the timer, starts the wait
again, and the wait only starts once the page is on screen with its panels detected. It pauses while
the pointer is over the peek or the reader's panel editor is open, and starts the wait again after.
Playing stops by itself at the end of the comic, if the comic could not be opened, or when the peek
goes out of sight (minimized, Chika hidden with ⌘H, the screen locked or asleep, the screen saver
on), so it never reads on where you cannot see it.

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
