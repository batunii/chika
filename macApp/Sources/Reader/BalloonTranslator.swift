import SwiftUI
import Vision
import Translation
import ChikaCore

/// Reads one speech balloon off a decoded page: Vision text recognition on its crop, and the
/// balloon's paper colour for the translation to sit on. Safe to call off the main thread.
enum BalloonReader {
    /// Stored texts read by another version are read again: bump it when recognition changes.
    static let version = 1

    /// The balloon's text in reading order, "" when there is none, nil when recognition failed or was
    /// cancelled (not stored, so it is tried again).
    static func text(of balloon: Panel, in page: CGImage) async -> String? {
        guard let crop = crop(BalloonText.cropRect(balloon), of: page) else { return "" }
        // The Swift request (macOS 15) reads vertical Japanese columns; VNRecognizeTextRequest
        // finds nothing in them. Accurate by default; the language is detected per crop.
        var request = RecognizeTextRequest()
        request.automaticallyDetectsLanguage = true
        guard let lines = try? await request.perform(on: crop) else { return nil }
        return BalloonText.join(lines.compactMap { line in
            guard let text = line.topCandidates(1).first?.string else { return nil }
            let b = line.boundingBox.cgRect   // normalized, origin bottom-left
            return (Panel(left: Float(b.minX), top: Float(1 - b.maxY), right: Float(b.maxX), bottom: Float(1 - b.minY)), text)
        })
    }

    /// The balloon's paper colour, sampled from its middle so the artwork round an oval balloon's
    /// box corners stays out.
    static func paper(of balloon: Panel, in page: CGImage) -> (r: UInt8, g: UInt8, b: UInt8) {
        let dx = balloon.width * 0.2, dy = balloon.height * 0.2
        let middle = Panel(left: balloon.left + dx, top: balloon.top + dy, right: balloon.right - dx, bottom: balloon.bottom - dy)
        let side = 16
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        guard let crop = crop(middle, of: page) else { return (255, 255, 255) }
        pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?
                .draw(crop, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return BalloonText.paperColor(rgba: pixels)
    }

    private static func crop(_ box: Panel, of page: CGImage) -> CGImage? {
        let r = box.pixelRect(width: page.width, height: page.height)
        return page.cropping(to: CGRect(x: r.x, y: r.y, width: r.width, height: r.height))
    }
}

/// Translate: the visible pages' speech balloons, read once (stored per comic, page and balloon)
/// and translated on device by Apple's Translation framework (stored per text and target language).
/// The reader hands its pages to `show` and the session from `.translationTask` to `translate`.
@MainActor
final class BalloonTranslator: ObservableObject {
    struct Balloon: Identifiable {
        let box: Panel
        let original: String
        /// BCP 47, nil when not recognized: the page's language unless the balloon is sure of its own
        /// (BalloonText.languages), for its batch, its stored translation and Read aloud's voice.
        let language: String?
        let paper: Color
        let darkInk: Bool
        var translated: String?
        var id: Panel { box }
    }

    @Published var isOn = false
    /// The visible pages' balloons that have text, by page.
    @Published private(set) var balloons: [Int: [Balloon]] = [:]
    /// Drives the reader's `.translationTask`, which hands over a session when it changes to a new language pair.
    @Published private(set) var configuration: TranslationSession.Configuration? {
        didSet { session = nil }   // a session is fatal to use once its configuration has changed
    }
    @Published private(set) var reading = false
    /// A batch is asked for and not done yet: Read aloud waits for it rather than speak the original.
    @Published private(set) var translationPending = false
    @Published private(set) var failed = false
    private var url: URL?
    private var target = Locale.current.language
    private var work: Task<Void, Never>?
    /// The pages `work` reads, held here rather than by the task: a page turned past while another is
    /// still being read is let go of at once instead of waiting its turn with its decoded image.
    private var queued: [(page: Int, image: CGImage)] = []
    /// The session `.translationTask` handed over for `configuration`, kept for later batches in the same
    /// languages: invalidating the configuration, or setting an equal one again, does not run the task again.
    private var session: TranslationSession?
    /// The batch a new configuration was set for, until `.translationTask` hands over its session.
    private var waiting: (source: String?, texts: [String])?
    private var watchdog: Task<Void, Never>?
    /// Texts sent to translate since `show`: each goes once, so a language that fails does not hold up the others.
    private var sent: Set<String> = []

    /// The top bar's note, nil when there is nothing to say.
    var status: String? {
        guard isOn else { return nil }
        if reading || translationPending { return "translating…" }
        // One language failing (a stray balloon's) says nothing once the rest is translated.
        return failed && !balloons.values.joined().contains { $0.translated != nil } ? "can't translate" : nil
    }

    /// Reads (or recalls) the balloons of `pages` and asks for their translations into `target`.
    /// Pass no pages to clear. Work for the pages shown before stops. `revision` is the reader's
    /// (ReaderModel.revision): what is read is stored only while the file still matches it. `aloud`:
    /// Read aloud wants the text, so the balloons are read even with Translate off (and not translated).
    func show(_ pages: [(page: Int, image: CGImage)], of url: URL, revision: String?, rtl: Bool, target: Locale.Language,
              aloud: Bool = false) {
        let previous = work
        previous?.cancel()
        balloons = [:]
        failed = false
        reading = false
        sent = []
        self.url = url
        self.target = target
        // The configuration (and its session) stays with Translate off: an equal one set again later would hand over none.
        guard isOn || aloud, !pages.isEmpty else { queued = []; return }
        reading = true
        queued = pages
        let targetID = target.minimalIdentifier
        work = Task {
            await previous?.value   // one page's recognition at a time, however fast the pages turn
            guard !Task.isCancelled else { return }
            let pages = queued
            queued = []
            for (page, image) in pages {
                if Task.isCancelled { return }
                var boxes = ReadingProgress.detection(url, page: page, rtl: rtl, revision: revision)?.bubbles
                if boxes == nil {
                    // Two pages mode never detects, and an edited page may never have been.
                    let found = await offMain { ReaderModel.detector.detect(image) }
                    if Task.isCancelled { return }
                    if let found { ReadingProgress.setDetection(url, page: page, found, revision: revision) }
                    boxes = found?.bubbles
                }
                let known = ReadingProgress.balloonTexts(url, page: page, revision: revision)
                var read: [(box: Panel, text: String, paper: (r: UInt8, g: UInt8, b: UInt8))] = []
                for box in boxes ?? [] {
                    let stored = known[box]
                    let (text, paper) = await offMain {
                        (stored == nil ? await BalloonReader.text(of: box, in: image) : stored, BalloonReader.paper(of: box, in: image))
                    }
                    if Task.isCancelled { return }
                    if stored == nil, let text { ReadingProgress.setBalloonText(url, page: page, box: box, text: text, revision: revision) }
                    guard let text, !text.isEmpty else { continue }
                    read.append((box, text, paper))
                }
                let languages = BalloonText.languages(of: read.map(\.text))
                balloons[page] = zip(read, languages).map { read, language in
                    Balloon(box: read.box, original: read.text, language: language,
                            paper: Color(red: Double(read.paper.r) / 255, green: Double(read.paper.g) / 255, blue: Double(read.paper.b) / 255),
                            darkInk: BalloonText.inkIsDark(on: read.paper),
                            translated: ReadingProgress.translation(url, source: read.text, from: language, target: targetID))
                }
                if isOn { requestTranslation() }   // this page's balloons translate while the next page is read
            }
            reading = false
        }
    }

    /// Stops reading and forgets the balloons, for a reader that closes.
    func stop() {
        work?.cancel()
        work = nil
        queued = []
        balloons = [:]
        configuration = nil
        waiting = nil
        watchdog?.cancel()
        translationPending = false
        reading = false
    }

    /// The reader's `.translationTask` session for a new language pair: kept for the later batches in the
    /// same languages, and used at once for the batch it was asked for.
    func translate(with session: TranslationSession) async {
        guard let batch = waiting else { return }   // too late: given up on, and maybe not this configuration's
        watchdog?.cancel()
        waiting = nil
        self.session = session
        await translate(batch, with: session)
    }

    /// Translates one batch, stores and shows the translations, then sends the next batch.
    private func translate(_ batch: (source: String?, texts: [String]), with session: TranslationSession) async {
        guard session === self.session else { return }   // stopped since it was sent: the session is fatal to use now
        let url = self.url, target = self.target
        do {
            // Prompts for the language download first when it is not installed.
            let responses = try await session.translations(from: batch.texts.map { TranslationSession.Request(sourceText: $0) })
            if let url {
                for response in responses {
                    ReadingProgress.setTranslation(url, source: response.sourceText, from: batch.source, target: target.minimalIdentifier,
                                                   text: response.targetText)
                }
            }
            if url == self.url, target == self.target {   // else stored, but the reader moved on
                let found = Dictionary(responses.map { ($0.sourceText, $0.targetText) }, uniquingKeysWith: { a, _ in a })
                for (page, list) in balloons {
                    balloons[page] = list.map { var b = $0; b.translated = b.translated ?? found[b.original]; return b }
                }
            }
        } catch {
            // An unsupported pair, a declined download, or no network to fetch the language: the other languages go on.
            // A batch for a page turned past says nothing about this one.
            if !Task.isCancelled, balloons.values.joined().contains(where: { batch.texts.contains($0.original) }) { failed = true }
        }
        translationPending = false
        requestTranslation()
    }

    /// Texts on screen still to translate and not sent yet, in batches by language.
    private var pending: [(source: String?, texts: [String])] {
        Self.batches(balloons.values.joined().filter { $0.translated == nil && !sent.contains($0.original) }.map { ($0.original, $0.language) },
                     target: target)
    }

    /// Distinct texts worth translating (with letters, not already in `target`) grouped by their
    /// language: a session translates from one source language. The biggest batch (the page's own
    /// language) goes first, before a stray balloon's language can prompt for a download.
    static func batches(_ texts: [(text: String, language: String?)], target: Locale.Language) -> [(source: String?, texts: [String])] {
        let groups = Dictionary(grouping: texts.filter { BalloonText.isWorthTranslating($0.text) }, by: { $0.language })
            .filter { source, _ in source.map { !BalloonText.sameLanguage($0, target.minimalIdentifier) } ?? true }
        return groups.map { ($0.key, Set($0.value.map { $0.text }).sorted()) }
            .sorted { $0.texts.count != $1.texts.count ? $0.texts.count > $1.texts.count : ($0.source ?? "") < ($1.source ?? "") }
    }

    /// Sends the next batch, one at a time: through the session at hand when it is for the batch's
    /// languages, else through a new configuration, whose `.translationTask` hands over a new session.
    private func requestTranslation() {
        guard !translationPending, let batch = pending.first else { return }   // a batch out asks again when it is done
        translationPending = true
        sent.formUnion(batch.texts)
        let source = batch.source.map { Locale.Language(identifier: $0) }
        if let session, configuration?.source == source, configuration?.target == target {
            Task { await translate(batch, with: session) }
            return
        }
        waiting = batch
        configuration = TranslationSession.Configuration(source: source, target: target)
        // Never left saying nothing: a session that does not come is a language that can't be translated.
        watchdog?.cancel()
        watchdog = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, waiting != nil else { return }
            waiting = nil
            failed = true
            translationPending = false
        }
    }
}

/// Runs `body` off the main actor and cancels it with the calling task, so a page left behind stops
/// recognizing and lets go of its images.
private func offMain<T: Sendable>(_ body: @escaping @Sendable () async -> T) async -> T {
    let task = Task.detached(priority: .userInitiated, operation: body)
    return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
}

/// Translate's labels over one page, in the page's own coordinates: inside the page's transform, so
/// they follow camera tweens, zoom and pan, and under the night filter like the page itself.
struct BalloonLabels: View {
    let balloons: [BalloonTranslator.Balloon]

    var body: some View {
        GeometryReader { geo in
            ForEach(balloons.filter { $0.translated != nil }) { balloon in
                let frame = Self.frame(balloon.box, in: geo.size)
                BalloonLabel(balloon: balloon, fontSize: geo.size.height * 0.03)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
            }
        }
        .accessibilityHidden(true)   // VoiceOver reads the balloons from BalloonAccessibility, in reading order
    }

    /// A balloon's label in a page of `size`. The detector's text box sits inside the lettering's edges, so
    /// the original would peek out round a label of the same size; and a vertical Japanese column is too
    /// narrow for a translated word, which would shrink the whole label, so it is at least about half as
    /// wide as it is tall (kept on the page). shortcut: fixed 25% growth, use Vision's own text boxes if it
    /// ever covers a balloon's outline.
    static func frame(_ box: Panel, in size: CGSize) -> CGRect {
        let height = CGFloat(box.height) * size.height
        let width = min(max(CGFloat(box.width) * size.width * 1.25, height * 0.55), size.width)
        let x = min(max(CGFloat(box.centerX) * size.width, width / 2), size.width - width / 2)
        return CGRect(x: x - width / 2, y: CGFloat(box.centerY) * size.height - height * 0.625, width: width, height: height * 1.25)
    }
}

/// One translated balloon on the balloon's own paper colour, wrapped before it shrinks; hover fades it
/// so the page's own lettering, the real original, shows through.
private struct BalloonLabel: View {
    let balloon: BalloonTranslator.Balloon
    let fontSize: CGFloat
    @State private var hovering = false

    var body: some View {
        Text(balloon.translated ?? "")
            .font(.archivo(fontSize, weight: 700))
            .minimumScaleFactor(0.35)
            .multilineTextAlignment(.center)
            .foregroundColor(balloon.darkInk ? .black : .white)
            .padding(fontSize * 0.3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(balloon.paper, in: RoundedRectangle(cornerRadius: fontSize * 1.5, style: .continuous))
            .opacity(hovering ? 0 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .contentShape(Rectangle())   // a faded label must still be hovered, or it flickers back
            .onHover { hovering = $0 }
    }
}
