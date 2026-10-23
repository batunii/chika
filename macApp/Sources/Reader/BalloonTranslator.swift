import SwiftUI
import Vision
import Translation
import NaturalLanguage
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
        let paper: Color
        let darkInk: Bool
        var translated: String?
        var id: Panel { box }
    }

    @Published var isOn = false
    /// The visible pages' balloons that have text, by page.
    @Published private(set) var balloons: [Int: [Balloon]] = [:]
    /// Drives the reader's `.translationTask`: a new or invalidated one hands over a fresh session.
    @Published private(set) var configuration: TranslationSession.Configuration?
    @Published private(set) var reading = false
    @Published private(set) var translating = false
    @Published private(set) var failed = false
    private var url: URL?
    private var target = Locale.current.language
    private var work: Task<Void, Never>?
    /// The source language of the batch the session was last asked for (nil: not recognized).
    private var batchSource: String?

    /// The top bar's note, nil when there is nothing to say.
    var status: String? { failed ? "can't translate" : (reading && isOn) || translating ? "translating…" : nil }

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
        self.url = url
        self.target = target
        if !isOn { configuration = nil }
        guard isOn || aloud, !pages.isEmpty else { configuration = nil; return }
        reading = true
        let targetID = target.minimalIdentifier
        work = Task {
            await previous?.value   // one page's recognition at a time, however fast the pages turn
            for (page, image) in pages {
                if Task.isCancelled { return }
                var boxes = ReadingProgress.detection(url, page: page, rtl: rtl)?.bubbles
                if boxes == nil {
                    // Two pages mode never detects, and an edited page may never have been.
                    let found = await offMain { ReaderModel.detector.detect(image) }
                    if Task.isCancelled { return }
                    if let found { ReadingProgress.setDetection(url, page: page, found, revision: revision) }
                    boxes = found?.bubbles
                }
                let known = ReadingProgress.balloonTexts(url, page: page)
                for box in boxes ?? [] {
                    let stored = known[box]
                    let (text, paper) = await offMain {
                        (stored == nil ? await BalloonReader.text(of: box, in: image) : stored, BalloonReader.paper(of: box, in: image))
                    }
                    if Task.isCancelled { return }
                    if stored == nil, let text { ReadingProgress.setBalloonText(url, page: page, box: box, text: text, revision: revision) }
                    guard let text, !text.isEmpty else { continue }
                    balloons[page, default: []].append(Balloon(
                        box: box, original: text,
                        paper: Color(red: Double(paper.r) / 255, green: Double(paper.g) / 255, blue: Double(paper.b) / 255),
                        darkInk: BalloonText.inkIsDark(on: paper),
                        translated: ReadingProgress.translation(url, source: text, from: Self.language(of: text), target: targetID)))
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
        balloons = [:]
        configuration = nil
        reading = false
    }

    /// The reader's `.translationTask` session: translates the balloons still waiting in the session's
    /// source language, then asks for the next language's session.
    func translate(with session: TranslationSession) async {
        let source = batchSource
        let texts = pending.first { $0.source == source }?.texts ?? []
        guard let url, !texts.isEmpty else { return }
        let target = self.target
        translating = true
        defer { translating = false }
        do {
            // Prompts for the language download first when it is not installed.
            let responses = try await session.translations(from: texts.map { TranslationSession.Request(sourceText: $0) })
            for response in responses {
                ReadingProgress.setTranslation(url, source: response.sourceText, from: source, target: target.minimalIdentifier,
                                               text: response.targetText)
            }
            guard url == self.url, target == self.target else { return }   // stored, but the reader moved on
            let found = Dictionary(responses.map { ($0.sourceText, $0.targetText) }, uniquingKeysWith: { a, _ in a })
            for (page, list) in balloons {
                balloons[page] = list.map { var b = $0; b.translated = b.translated ?? found[b.original]; return b }
            }
            requestTranslation(pending.filter { $0.source != source })
        } catch {
            // An unsupported pair, a declined download, or no network to fetch the language.
            if !Task.isCancelled { failed = true }
        }
    }

    /// Texts on screen still to translate, in batches by language.
    private var pending: [(source: String?, texts: [String])] {
        Self.batches(balloons.values.joined().filter { $0.translated == nil }.map(\.original), target: target)
    }

    /// Distinct texts worth translating (with letters, not already in `target`) grouped by their
    /// recognized language: a session translates from one source language.
    static func batches(_ texts: [String], target: Locale.Language) -> [(source: String?, texts: [String])] {
        let groups = Dictionary(grouping: Set(texts).filter(BalloonText.isWorthTranslating), by: language(of:))
            .filter { source, _ in source.map { !BalloonText.sameLanguage($0, target.minimalIdentifier) } ?? true }
        return groups.map { ($0.key, $0.value.sorted()) }.sorted { ($0.source ?? "") < ($1.source ?? "") }
    }

    /// The text's language as a BCP 47 identifier, nil when it is not recognized.
    static func language(of text: String) -> String? {
        NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue
    }

    /// Asks for a session for the first batch's language (`batches`, else everything pending).
    private func requestTranslation(_ batches: [(source: String?, texts: [String])]? = nil) {
        guard let batch = (batches ?? pending).first else { return }
        batchSource = batch.source
        let source = batch.source.map { Locale.Language(identifier: $0) }
        if let configuration, configuration.source == source, configuration.target == target {
            self.configuration?.invalidate()
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
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
                BalloonLabel(balloon: balloon, fontSize: geo.size.height * 0.03)
                    // The detector's text box sits inside the lettering's edges, so the original would peek out
                    // round a label of the same size. shortcut: fixed 25% growth, use Vision's own text boxes if it
                    // ever covers a balloon's outline.
                    .frame(width: CGFloat(balloon.box.width) * geo.size.width * 1.25, height: CGFloat(balloon.box.height) * geo.size.height * 1.25)
                    .position(x: CGFloat(balloon.box.centerX) * geo.size.width, y: CGFloat(balloon.box.centerY) * geo.size.height)
            }
        }
        .accessibilityHidden(true)   // VoiceOver reads the balloons from BalloonAccessibility, in reading order
    }
}

/// One translated balloon on the balloon's own paper colour, shrunk to fit; hover shows the original.
private struct BalloonLabel: View {
    let balloon: BalloonTranslator.Balloon
    let fontSize: CGFloat
    @State private var original = false

    var body: some View {
        Text(original ? balloon.original : balloon.translated ?? "")
            .font(.archivo(fontSize, weight: 700))
            .minimumScaleFactor(0.05)
            .multilineTextAlignment(.center)
            .foregroundColor(balloon.darkInk ? .black : .white)
            .padding(fontSize * 0.3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(balloon.paper, in: RoundedRectangle(cornerRadius: fontSize * 1.5, style: .continuous))
            .onHover { original = $0 }
    }
}
