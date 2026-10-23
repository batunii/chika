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

    /// The balloon's text in reading order, "" when there is none.
    static func text(of balloon: Panel, in page: CGImage) async -> String {
        guard let crop = crop(BalloonText.cropRect(balloon), of: page) else { return "" }
        // The Swift request (macOS 15) reads vertical Japanese columns; VNRecognizeTextRequest
        // finds nothing in them. Accurate by default; the language is detected per crop.
        var request = RecognizeTextRequest()
        request.automaticallyDetectsLanguage = true
        guard let lines = try? await request.perform(on: crop) else { return "" }
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

    /// The top bar's note, nil when there is nothing to say.
    var status: String? { failed ? "can't translate" : reading || translating ? "translating…" : nil }

    /// Reads (or recalls) the balloons of `pages` and asks for their translations into `target`.
    /// Pass no pages to clear. Work for the pages shown before stops. `revision` is the reader's
    /// (ReaderModel.revision): what is read is stored only while the file still matches it.
    func show(_ pages: [(page: Int, image: CGImage)], of url: URL, revision: String?, rtl: Bool, target: Locale.Language) {
        work?.cancel()
        balloons = [:]
        failed = false
        reading = false
        self.url = url
        self.target = target
        guard isOn, !pages.isEmpty else { configuration = nil; return }
        reading = true
        let targetID = target.minimalIdentifier
        work = Task {
            for (page, image) in pages {
                var boxes = ReadingProgress.detection(url, page: page, rtl: rtl)?.bubbles
                if boxes == nil {
                    // Two pages mode never detects, and an edited page may never have been.
                    let found = await Task.detached(priority: .userInitiated) { ReaderModel.detector.detect(image) }.value
                    if Task.isCancelled { return }
                    if let found { ReadingProgress.setDetection(url, page: page, found, revision: revision) }
                    boxes = found?.bubbles
                }
                let known = ReadingProgress.balloonTexts(url, page: page)
                for box in boxes ?? [] {
                    let stored = known[box]
                    let (text, paper) = await Task.detached(priority: .userInitiated) {
                        (stored == nil ? await BalloonReader.text(of: box, in: image) : stored!, BalloonReader.paper(of: box, in: image))
                    }.value
                    if Task.isCancelled { return }
                    if stored == nil { ReadingProgress.setBalloonText(url, page: page, box: box, text: text, revision: revision) }
                    guard !text.isEmpty else { continue }
                    balloons[page, default: []].append(Balloon(
                        box: box, original: text,
                        paper: Color(red: Double(paper.r) / 255, green: Double(paper.g) / 255, blue: Double(paper.b) / 255),
                        darkInk: BalloonText.inkIsDark(on: paper),
                        translated: ReadingProgress.translation(url, source: text, target: targetID)))
                }
                requestTranslation()   // this page's balloons translate while the next page is read
            }
            reading = false
        }
    }

    /// The reader's `.translationTask` session: translates every balloon still waiting.
    func translate(with session: TranslationSession) async {
        let texts = pending
        guard let url, !texts.isEmpty else { return }
        let target = self.target
        translating = true
        defer { translating = false }
        do {
            // Prompts for the language download first when it is not installed.
            let responses = try await session.translations(from: texts.map { TranslationSession.Request(sourceText: $0) })
            for response in responses {
                ReadingProgress.setTranslation(url, source: response.sourceText, target: target.minimalIdentifier, text: response.targetText)
            }
            guard url == self.url, target == self.target else { return }   // stored, but the reader moved on
            let found = Dictionary(responses.map { ($0.sourceText, $0.targetText) }, uniquingKeysWith: { a, _ in a })
            for (page, list) in balloons {
                balloons[page] = list.map { var b = $0; b.translated = b.translated ?? found[b.original]; return b }
            }
        } catch {
            // An unsupported pair, a declined download, or no network to fetch the language.
            if !Task.isCancelled { failed = true }
        }
    }

    /// Distinct texts on screen still to translate: not yet translated, with letters, and not
    /// already in the target language.
    private var pending: [String] {
        let texts = balloons.values.joined().filter { $0.translated == nil }.map(\.original)
        return Array(Set(texts)).filter { text in
            guard BalloonText.isWorthTranslating(text) else { return false }
            guard let language = NLLanguageRecognizer.dominantLanguage(for: text) else { return true }
            return !BalloonText.sameLanguage(language.rawValue, target.minimalIdentifier)
        }.sorted()
    }

    private func requestTranslation() {
        let texts = pending
        guard !texts.isEmpty else { return }
        // One source for the whole batch: a page is in one language, give or take its sound effects.
        let source = NLLanguageRecognizer.dominantLanguage(for: texts.joined(separator: "\n")).map { Locale.Language(identifier: $0.rawValue) }
        if let configuration, configuration.source == source, configuration.target == target {
            self.configuration?.invalidate()
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }
}

/// Translate's labels over one page, in the page's own coordinates: inside the page's transform, so
/// they follow camera tweens, zoom and pan, and under the night filter like the page itself.
struct BalloonLabels: View {
    let balloons: [BalloonTranslator.Balloon]

    var body: some View {
        GeometryReader { geo in
            ForEach(balloons.filter { $0.translated != nil }) { balloon in
                BalloonLabel(balloon: balloon, fontSize: geo.size.height * 0.03)
                    .frame(width: CGFloat(balloon.box.width) * geo.size.width, height: CGFloat(balloon.box.height) * geo.size.height)
                    .position(x: CGFloat(balloon.box.centerX) * geo.size.width, y: CGFloat(balloon.box.centerY) * geo.size.height)
            }
        }
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(balloon.translated ?? "")
            .accessibilityHint("Original: \(balloon.original)")
    }
}
