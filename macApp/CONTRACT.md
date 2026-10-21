# Chika for Mac: phase 1 build contract

Native macOS 15+ SwiftUI app. Read this before writing any file. Three people build in parallel;
this file is the agreement between them.

## Ground rules

- Lazy senior dev. The best code is the code never written. **Port** from `iosApp/Sources/*.swift`
  (Swift, iOS/Catalyst) and `shared/src/commonMain/kotlin/**` (Kotlin) instead of designing anew.
  Keep names, comments and structure; drop what the Mac does not need.
- Write only inside `macApp/`, only the files you own (table below). Never edit `iosApp/`, `shared/`,
  `app/` or anything outside `macApp/`.
- No new dependencies. Allowed: **ZIPFoundation** (`https://github.com/weichsel/ZIPFoundation`, from 0.9.19)
  and **libarchive-for-swift** (`https://github.com/matteo-pacini/libarchive-for-swift`, exact 1.0.0,
  product `libarchive`, the raw C API). Both ship macOS slices.
- Swift 5 language mode (`SWIFT_VERSION: "5.0"` / `swiftLanguageVersions: [.v5]`), deployment target
  macOS 15.0, Xcode 26. Coordinates stay `Float` to match the Kotlin and the Android app.
- One small test for every new non-trivial piece of logic. Trivial ports need none.
- Comment only the why the code cannot show. A known limit gets `// shortcut: <limit>, <when to upgrade>`.
- Finish the whole piece you own, including its tests and the build. Report what you skipped.

## Layout and ownership

```
macApp/
  CONTRACT.md                 this file
  README.md                   B1   how to generate, build, test, run
  project.yml                 B1   XcodeGen spec: app target Chika + test target ChikaTests
  Chika.entitlements          B1   app-sandbox + files.user-selected.read-write
  Resources/                  B1   Fonts/, Assets.xcassets, MangaPanelDetector.mlpackage, PrivacyInfo.xcprivacy
  ChikaCore/                  A    Swift package: the shared core + its tests (swift test)
    Package.swift
    Sources/ChikaCore/*.swift
    Tests/ChikaCoreTests/*.swift
  Sources/
    ChikaApp.swift            B1   @main, scenes, environment objects
    Brand/ChikaTheme.swift    B1   palette, fonts, Color(hex:)
    Brand/ChikaBrand.swift    B1   Halftone, StarburstShape, Reticle, ChikaMark, ChikaWordmark, OchreBadge, PageCoin, KickerText, RoundedCornerShape
    Library/ChikaSettings.swift     B1
    Library/ReadingProgress.swift   B1
    Library/LibraryStore.swift      B1
    Library/CoverLoader.swift       B1
    Library/LibraryView.swift       B1   + ComicCard, GeneratedCover, AddTile
    Library/SettingsView.swift      B1
    Archive/CbzArchive.swift        B1
    Archive/CbrReader.swift         B1
    Archive/CbrConverter.swift      B1
    Reader/PageLoader.swift         B2
    Reader/CoreMLPanelDetector.swift B2
    Reader/ReaderModel.swift        B2
    Reader/ReaderView.swift         B2   + CameraFraming, DirectionChip
    Reader/PeekView.swift           B2   floating panel window content + NSWindow bridge
  Tests/                      B1 owns the target; each adds tests for their own code
    LibraryStoreTests.swift   B1
    CbrReaderTests.swift      B1
```

Source material (read, do not edit): `iosApp/Sources/*.swift`, `iosApp/project.yml`,
`iosApp/Chika-macOS.entitlements`, `iosApp/Sources/Info.plist`, `iosApp/Sources/Fonts`,
`iosApp/Sources/Assets.xcassets`, `iosApp/Sources/MangaPanelDetector.mlpackage`,
`iosApp/Sources/PrivacyInfo.xcprivacy`, `iosApp/ci/SyntheticManga.cbz` (test comic),
`shared/src/commonMain/kotlin/**`, `shared/src/commonTest/kotlin/**`.

## A: ChikaCore API (A implements; B1 and B2 import `ChikaCore`)

Foundation only. No AppKit/SwiftUI/CoreML. Every type `public`. 1:1 port of the Kotlin, same
constants, same algorithms, same comments. Dropped on purpose: `PanelReliability`, `lerpPanel`.

```swift
public struct Panel: Equatable, Hashable, Codable, Sendable {
    public var left: Float, top: Float, right: Float, bottom: Float
    public init(left: Float, top: Float, right: Float, bottom: Float)
    public var width: Float      // max(right - left, 0)
    public var height: Float
    public var area: Float
    public var centerX: Float
    public var centerY: Float
    public static let fullPage: Panel   // 0,0,1,1
}

public struct Letterbox: Equatable, Sendable {
    public let scale: Float
    public let padX: Int, padY: Int, newW: Int, newH: Int
    public static func fit(pageW: Int, pageH: Int, inputSize: Int) -> Letterbox
}

public struct DetectResult: Equatable, Sendable {
    public let panels: [Panel], bubbles: [Panel]
    public let pageW: Int, pageH: Int
    public init(panels: [Panel], bubbles: [Panel], pageW: Int, pageH: Int)
}

public struct YoloPanelDecoder: Sendable {
    public static let panelClass = 0, textClass = 1
    public static let defaultInputSize = 640
    public static let defaultConfidence: Float = 0.25
    public static let defaultNmsIoU: Float = 0.45
    public static let defaultContainment: Float = 0.6
    public static let defaultMinAreaFraction: Float = 0.008
    public let inputSize: Int
    public init(inputSize: Int = 640, confidenceThreshold: Float = 0.25, nmsIoU: Float = 0.45,
                containmentThreshold: Float = 0.6, minAreaFraction: Float = 0.008)
    /// raw is row-major in `shape` ([1, numDet, 6] or [1, attrs, anchors] / [1, anchors, attrs]).
    public func decode(raw: [Float], shape: [Int], letterbox: Letterbox, pageW: Int, pageH: Int) -> DetectResult
}

public enum PanelOrdering {
    public static func order(_ panels: [Panel], rightToLeft: Bool = false) -> [Panel]
}

public enum PanelGapFiller {
    public struct Config: Sendable {
        public var minAreaFraction: Float, minSideFraction: Float, grid: Int, maxFills: Int
        public init(minAreaFraction: Float = 0.07, minSideFraction: Float = 0.12, grid: Int = 64, maxFills: Int = 8)
    }
    public static func fill(_ panels: [Panel], config: Config = Config()) -> [Panel]
}

public enum PanelPlanner {
    public struct Config: Sendable {
        // every field of the Kotlin Config, same names (camelCase), same defaults, memberwise public init with defaults
        public static let manga: Config   // smallAreaFraction 0.05, maxMergeCount 2
    }
    public static func plan(ordered: [Panel], bubbles: [Panel], pageW: Int, pageH: Int,
                            rightToLeft: Bool, config: Config = Config()) -> [Panel]
}

public enum PanelPipeline {
    public static func zoomRegions(panels: [Panel], bubbles: [Panel], pageW: Int, pageH: Int, rightToLeft: Bool) -> [Panel]
}

public struct PageDraw: Equatable, Sendable {
    public let left: Float, top: Float, scaledWidth: Float, scaledHeight: Float
}
public func computePageDraw(camera: Panel, bitmapW: Int, bitmapH: Int,
                            containerW: Float, containerH: Float, fill: Float = 0.98) -> PageDraw

public enum ComicFormat: Sendable { case cbz, cbr, unknown }
public enum ComicFormatDetector {
    public static func detect(head: [UInt8], fileExtension: String) -> ComicFormat
}

public enum NaturalOrder {
    public static func compare(_ a: String, _ b: String) -> Int        // <0, 0, >0 like the Kotlin
    public static func isOrderedBefore(_ a: String, _ b: String) -> Bool
}
public func isImageEntry(_ name: String) -> Bool

public enum PageConstants {
    public static let maxPageDimension = 2560
    public static let cacheMemoryDivisor = 4
    public static let cacheMaxBytes = 512 * 1024 * 1024
}
/// Android's computeInSampleSize (was private in iosApp/Sources/PageLoader.swift). Largest power of
/// two keeping the long edge at or above maxDim.
public func computeInSampleSize(longEdge: Int, maxDim: Int) -> Int

/// Page + slot state machine of the reader, pulled out so it is testable. Slots on a page:
/// -1 = whole-page intro, 0..<n = panels, n = whole-page outro. `regions == nil` = this page's
/// panels are not detected yet. Fixes the audit bug where a placeholder [fullPage] counted as a
/// real panel (back-page landed on panel 2; fast taps skipped undetected pages).
public struct ReaderSlots: Equatable, Sendable {
    public static let outroSentinel = Int.max   // "land on the outro once regions are known"
    public var page: Int
    public var step: Int
    public var regions: [Panel]?                // nil = unknown
    public init(page: Int = 0, step: Int = -1, regions: [Panel]? = nil)
    public var panelCount: Int                  // regions?.count ?? 0
    public var onPanel: Bool                    // 0 <= step && step < panelCount
    public var isFullPage: Bool                 // !onPanel
    public var camera: Panel                    // regions![step] when onPanel, else .fullPage
    public enum Move: Equatable, Sendable { case moved, blocked, nextPage, previousPage }
    /// Detection landed. regions = r; if step == outroSentinel || step > r.count { step = r.count }.
    public mutating func setRegions(_ r: [Panel])
    /// regions known (n = count): cur = min(step, n); next = cur + delta.
    ///   next > n  → if page + 1 < pageCount { page += 1; step = -1; regions = nil; return .nextPage } else .blocked
    ///   next < -1 → if page > 0 { page -= 1; step = outroSentinel; regions = nil; return .previousPage } else .blocked
    ///   else step = next; .moved
    /// regions unknown: delta > 0: step == outroSentinel → next page (as above), else .blocked (wait for detection).
    ///                  delta < 0: step == outroSentinel → step = -1, .moved; step == -1 → previous page (as above); else .blocked
    public mutating func advance(by delta: Int, pageCount: Int) -> Move
    public mutating func showWholePage()        // step = -1
}
```

Tests (Swift Testing, `import Testing`): port all nine files in `shared/src/commonTest` (skip the
`lerpPanel` test; `DevicePageDiagnosticTest` may be skipped if it only prints), plus
`ReaderSlotsTests` (at least: restore outro with unknown regions then setRegions(6 panels) → camera is
fullPage and step == 6; forward from intro with unknown regions → .blocked; forward past outro → .nextPage
with step -1 and regions nil; back from intro → .previousPage with step == outroSentinel) and a
`computeInSampleSize` test for 2559, 2560, 2561, 5120, 5121 with maxDim 2560.

## B1 ↔ B2 seams (what each provides to the other)

### B1 provides

```swift
// Brand/ChikaTheme.swift  (port of iosApp ChikaTheme.swift; NSFontDescriptor for the Archivo wght axis)
enum Chika { static let ink, inkSoft, crimson, crimsonBright, maroon, maroonDeep, cream, paper, ochre, creamMuted: Color }
extension Font { static func anton(_ size: CGFloat) -> Font; static func archivo(_ size: CGFloat, weight: CGFloat = 600) -> Font }
extension Color { init(hex: UInt32) }
struct KickerText: View { init(_ text: String, size: CGFloat = 11, color: Color = Chika.creamMuted) }
// Brand/ChikaBrand.swift  (port of iosApp ChikaBrand.swift, unchanged API)
struct Halftone: View; extension View { func halftone(...); func comicShadow(offset:color:corner:) }
struct StarburstShape: Shape; struct Reticle: View (color:inset:length:stroke:); struct ChikaMark: View (size:)
struct ChikaWordmark: View; struct OchreBadge: View (text:); struct PageCoin: View (page:total:); struct RoundedCornerShape: Shape

// Library/ChikaSettings.swift  — absorbs the old ReadingPrefs (zoomFill/fillLevels are dead: dropped)
@MainActor final class ChikaSettings: ObservableObject {
    @Published var amoled: Bool                  // UserDefaults "chika.amoledTheme"
    @Published var defaultRightToLeft: Bool      // UserDefaults "chika.readingDirection.default.rtl"
    var ground: Color; var groundSoft: Color
}

// Library/ReadingProgress.swift  (port; same UserDefaults keys so nothing is lost)
struct Progress: Codable, Equatable { var page: Int; var step: Int; var total: Int; var rtl: Bool? }   // fraction/percent dropped
enum ReadingProgress {
    static func get(_ url: URL) -> Progress?
    static func set(_ url: URL, page: Int, step: Int, total: Int, rtl: Bool)
    static func clear(_ url: URL)
    static func markOpened(_ url: URL)
    static func readingDirection(_ url: URL, default: Bool) -> Bool
    static func openedMap() -> [String: Double]      // decoded ONCE by LibraryStore.refresh (audit bug 7)
    static func all() -> [String: Progress]           // decoded once for the library cards
}

// Archive/CbzArchive.swift (port; ZIPFoundation)
final class CbzArchive { init(url: URL) throws; var pageCount: Int; func readPage(_ index: Int) throws -> Data }

// Library/LibraryStore.swift
@MainActor final class LibraryStore: ObservableObject {
    @Published private(set) var comics: [URL]
    @Published var importing: Bool
    @Published var importError: String?
    static var importableTypes: [UTType]
    init(directory: URL? = nil)   // nil = Application Support/Chika/Comics; tests pass a temp dir
    func refresh()
    func importComic(from url: URL)   // ONE path for all (port of importMacComic): stage, detect format, convert CBR,
                                      // validate pageCount > 0, then move to a COLLISION-SAFE name ("Name 2.cbz", "Name 3.cbz"…).
                                      // Never overwrite, never delete-before-copy. (audit bugs 1 and 4)
    func delete(_ url: URL)           // also CoverLoader.evict(url) and ReadingProgress.clear(url)
}

// Library/CoverLoader.swift (port to NSImage/CGImage)
enum CoverLoader { static func load(for url: URL) async -> (cover: NSImage?, pageCount: Int); static func evict(_ url: URL) }
```

### B2 provides

```swift
// Reader/ReaderModel.swift — one per open comic; shared by the reader window and the peek window
@MainActor final class ReaderModel: ObservableObject {
    let comicURL: URL
    init(comicURL: URL, settings: ChikaSettings)      // loads archive, restores progress, starts page load
    @Published private(set) var state: LoadState      // enum LoadState { case loading, failed(String), ready }
    @Published private(set) var slots: ReaderSlots
    @Published private(set) var image: CGImage?
    @Published private(set) var detecting: Bool
    @Published var rightToLeft: Bool
    var pageCount: Int
    var title: String
    func advance(by delta: Int)       // uses ReaderSlots.advance; on .nextPage/.previousPage loads the page
    func turnPage(next: Bool)
    func goToPage(_ index: Int)       // scrubber
    func showWholePage()
    func toggleDirection()
}

/// App-wide registry so both windows for one comic observe the same model.
@MainActor final class ReaderModels: ObservableObject {
    func model(for url: URL, settings: ChikaSettings) -> ReaderModel
    func release(_ url: URL)
}

// Reader/ReaderView.swift
struct ReaderView: View { let comicURL: URL }     // reads ReaderModels + ChikaSettings from the environment
// Reader/PeekView.swift
struct PeekView: View { let comicURL: URL }
```

### B1 wires the scenes (Sources/ChikaApp.swift)

```swift
@main struct ChikaApp: App {
    @StateObject private var settings = ChikaSettings()
    @StateObject private var readers = ReaderModels()
    var body: some Scene {
        WindowGroup("Chika") { LibraryView().environmentObject(settings).environmentObject(readers) }
            .defaultSize(width: 1000, height: 740)
        WindowGroup("Reader", id: "reader", for: URL.self) { $url in
            if let url { ReaderView(comicURL: url).environmentObject(settings).environmentObject(readers) }
        }
        WindowGroup("Peek", id: "peek", for: URL.self) { $url in
            if let url { PeekView(comicURL: url).environmentObject(settings).environmentObject(readers) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowLevel(.floating)
        .windowResizability(.contentSize)
        Settings { SettingsView().environmentObject(settings) }
    }
}
```

The library opens a comic with `openWindow(id: "reader", value: url)`. The reader opens peek with
`openWindow(id: "peek", value: url)` (⌘⇧P) and the peek's expand button does the reverse then
`dismissWindow(id: "peek", value: url)`.

## Behaviour that phase 1 must have

Library (B1): grid of covers + progress (port of `MacLibraryView` + `ComicCard`/`GeneratedCover`/`AddTile`
from `LibraryView.swift`); Import button (⌘O) via `.fileImporter` (multi-select); drag-and-drop of files
onto the grid (`.onDrop(of: [.fileURL])`); context-menu Remove with confirmation; "Import failed" alert;
sort by last opened then natural name, decoding progress **once** per refresh; settings (⌘,): AMOLED toggle,
default reading direction, about/version (port of `MenuView`'s content).

Reader (B2): port of `ReaderView.swift` + `PageLoader.swift` + `CoreMLPanelDetector.swift` onto
`ReaderSlots` and `ChikaCore`. Keep: CameraFraming GeometryEffect, serial io/detect queues, load token,
panel cache per page cleared on direction change, prefetch of next page, page fade-in, top bar (back
closes the window, title, status "Page x/y · panel n/m | full page | detecting…", prev/next, whole page
⌘0, direction chip, peek ⌘⇧P), bottom bar (scrubber + PageCoin). Lock only the archive read in
`PageLoader`, decode outside the lock (audit bug 9). Input: click left third = back, right third =
forward, double-click = whole page; `MagnifyGesture` zoom 1–5×, `DragGesture` pan with the ported
`clampPan`; keys via `.onKeyPress`: ← → (panel), Space / Shift-Space (panel), ⌘[ ⌘] or PageUp/PageDown
(page), Esc closes. Two-finger swipe page turn is NOT in phase 1 (note it).
Persist progress on every slot change via `ReadingProgress.set` (page, step, total, rtl).

Peek window (B2): shows only the current camera (panel) of the same `ReaderModel`, framed by
`computePageDraw` with fill 1.0, no chrome. A hover-revealed bar: ← →, opacity slider 0.4–1.0,
minimize, expand (back to the full reader). Keys ← → Space work when focused. A small
`NSViewRepresentable` grabs the `NSWindow` once to set `collectionBehavior = [.canJoinAllSpaces,
.fullScreenAuxiliary]`, `hidesOnDeactivate = false`, `isMovableByWindowBackground = true`, and keeps
`window.aspectRatio` equal to the current camera's pixel aspect, with `alphaValue` bound to the opacity.
Minimize = `window.miniaturize(nil)`. No click-through. Default size: 420 px wide, height from the
panel aspect. Position/size restoration is whatever SwiftUI gives for free.

Settings/Info (B1): bundle id `com.chakra.comicreader`, category `public.app-category.books`,
document types + exported UTIs copied from `iosApp/project.yml`, `ATSApplicationFontsPath: Fonts`,
`ITSAppUsesNonExemptEncryption: false`. Entitlements: `com.apple.security.app-sandbox`,
`com.apple.security.files.user-selected.read-write`. Signing for local builds: `CODE_SIGN_IDENTITY: "-"`
(ad hoc) so `xcodebuild` works without a team; the README says how to set a team.

## Done means

- `cd macApp/ChikaCore && swift test` passes (A).
- `cd macApp && xcodegen generate && xcodebuild -scheme Chika -configuration Debug build` passes.
- `xcodebuild -scheme Chika test` runs `ChikaTests` (B1's tests) and passes.
- The app launches, imports `iosApp/ci/SyntheticManga.cbz` (copy it first: the repo ignores *.cbz), opens
  it, steps panels with → and lands on the whole page with ←+← from page 2, opens peek with ⌘⇧P.
