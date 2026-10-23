import XCTest
import AppKit
import CoreText
import Translation
import ChikaCore
@testable import Chika

@MainActor
final class BalloonTranslationTests: XCTestCase {
    private var dir: URL!
    private let comic = Bundle(for: BalloonTranslationTests.self).url(forResource: "SyntheticManga", withExtension: "cbz")!
    // A white balloon on grey artwork, with two vertical Japanese columns in it.
    private let balloon = Panel(left: 100.0 / 600, top: 100.0 / 800, right: 300.0 / 600, bottom: 500.0 / 800)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ReadingProgress.defaults = UserDefaults(suiteName: "chika.tests")!   // never the real app settings
        ReadingProgress.databaseURL = dir.appendingPathExtension("sqlite")
    }

    override func tearDown() async throws {
        ReadingProgress.defaults.removePersistentDomain(forName: "chika.tests")
        ReadingProgress.defaults = .standard
        try? FileManager.default.removeItem(at: dir)
        for suffix in ["", "-wal", "-shm"] {   // WAL mode keeps two side files next to the database
            try? FileManager.default.removeItem(atPath: ReadingProgress.databaseURL.path + suffix)
        }
    }

    private func page() -> CGImage {
        let ctx = CGContext(data: nil, width: 600, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 100, y: 300, width: 200, height: 400))   // CG's origin is bottom-left
        let text = NSAttributedString(string: "今日はいい天気ですね\nどこへ行こうか", attributes: [
            .font: CTFontCreateWithName("Hiragino Sans W6" as CFString, 40, nil), .foregroundColor: NSColor.black,
            NSAttributedString.Key(kCTVerticalFormsAttributeName as String): true])
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text), CFRange(),
                                             CGPath(rect: CGRect(x: 120, y: 320, width: 160, height: 360), transform: nil),
                                             [kCTFrameProgressionAttributeName: CTFrameProgression.rightToLeft.rawValue] as CFDictionary)
        CTFrameDraw(frame, ctx)
        return ctx.makeImage()!
    }

    func testTextsAndTranslationsRoundTripAndClearWithTheComic() throws {
        let a = dir.appendingPathComponent("A.cbz"), b = dir.appendingPathComponent("B.cbz")
        try FileManager.default.copyItem(at: comic, to: a)
        try FileManager.default.copyItem(at: comic, to: b)
        let other = Panel(left: 0.5, top: 0.5, right: 0.9, bottom: 0.9)

        ReadingProgress.setBalloonText(a, page: 1, box: balloon, text: "今日は", revision: ReadingProgress.revision(a))
        ReadingProgress.setBalloonText(a, page: 1, box: other, text: "", revision: ReadingProgress.revision(a))   // read, nothing there: not read again
        ReadingProgress.setBalloonText(a, page: 1, box: balloon, text: "今日はいい", revision: ReadingProgress.revision(a))   // replaces
        XCTAssertEqual(ReadingProgress.balloonTexts(a, page: 1), [balloon: "今日はいい", other: ""])
        XCTAssertEqual(ReadingProgress.balloonTexts(a, page: 2), [:])
        XCTAssertEqual(ReadingProgress.balloonTexts(a, page: 1, version: BalloonReader.version + 1), [:])   // another reader reads again

        ReadingProgress.setTranslation(a, source: "今日は", target: "en", text: "Today")
        ReadingProgress.setTranslation(a, source: "今日は", target: "fr", text: "Aujourd'hui")
        XCTAssertEqual(ReadingProgress.translation(a, source: "今日は", target: "en"), "Today")
        XCTAssertEqual(ReadingProgress.translation(a, source: "今日は", target: "fr"), "Aujourd'hui")
        XCTAssertNil(ReadingProgress.translation(a, source: "今日は", target: "de"))

        ReadingProgress.setBalloonText(b, page: 1, box: balloon, text: "どこ", revision: ReadingProgress.revision(b))
        ReadingProgress.setTranslation(b, source: "どこ", target: "en", text: "Where")
        ReadingProgress.clear(a)
        XCTAssertEqual(ReadingProgress.balloonTexts(a, page: 1), [:])
        XCTAssertNil(ReadingProgress.translation(a, source: "今日は", target: "en"))
        XCTAssertEqual(ReadingProgress.balloonTexts(b, page: 1), [balloon: "どこ"])
        XCTAssertEqual(ReadingProgress.translation(b, source: "どこ", target: "en"), "Where")
    }

    // Real Vision text recognition on a rendered balloon of vertical Japanese.
    func testReadsVerticalJapaneseInReadingOrder() async throws {
        let image = page()
        let text = await BalloonReader.text(of: balloon, in: image)
        XCTAssertTrue(text.hasPrefix("今日は"), text)   // the right-hand column first
        XCTAssertTrue(text.contains("天気"), text)
        XCTAssertTrue(text.contains("行こう"), text)
        let paper = BalloonReader.paper(of: balloon, in: image)
        XCTAssertGreaterThan(paper.r, 240)   // white paper, not the black lettering or the grey artwork
        XCTAssertGreaterThan(paper.b, 240)
    }

    // The translator reads the stored balloons of a page once, stores the text, and asks for Japanese.
    func testTranslatorReadsAPageOnceAndAsksForItsLanguage() async throws {
        let url = dir.appendingPathComponent("A.cbz")
        try FileManager.default.copyItem(at: comic, to: url)
        ReadingProgress.setDetection(url, page: 0, PageDetection(leftToRight: [.fullPage], rightToLeft: [.fullPage], bubbles: [balloon]),
                                     revision: ReadingProgress.revision(url))
        let translator = BalloonTranslator()
        translator.isOn = true
        let english = Locale.Language(identifier: "en")
        translator.show([(0, page())], of: url, revision: ReadingProgress.revision(url), rtl: false, target: english)
        let deadline = Date.now + 30
        while translator.reading, Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(translator.reading)

        let read = try XCTUnwrap(translator.balloons[0]?.first)
        XCTAssertEqual(read.box, balloon)
        XCTAssertTrue(read.original.contains("天気"), read.original)
        XCTAssertEqual(ReadingProgress.balloonTexts(url, page: 0)[balloon], read.original)
        XCTAssertEqual(translator.configuration?.source?.languageCode, .japanese)
        XCTAssertEqual(translator.configuration?.target, english)

        // Stored translations come back without a session; text already in the target is left alone.
        ReadingProgress.setTranslation(url, source: read.original, target: "en", text: "Nice weather")
        translator.show([(0, page())], of: url, revision: ReadingProgress.revision(url), rtl: false, target: english)
        while translator.reading, Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(translator.balloons[0]?.first?.translated, "Nice weather")

        translator.isOn = false
        translator.show([(0, page())], of: url, revision: ReadingProgress.revision(url), rtl: false, target: english)
        XCTAssertTrue(translator.balloons.isEmpty)
        XCTAssertNil(translator.configuration)
    }
}
