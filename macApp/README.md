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
