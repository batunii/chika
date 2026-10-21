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
