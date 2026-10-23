import XCTest
import ChikaCore
@testable import Chika

// Only the paths that say nothing: no test here produces audio.
@MainActor
final class ReadAloudTests: XCTestCase {
    private let box = Panel(left: 0.1, top: 0.1, right: 0.3, bottom: 0.3)
    private let english = Locale.Language(identifier: "en")

    private func balloon(_ original: String, translated: String? = nil) -> BalloonTranslator.Balloon {
        .init(box: box, original: original, paper: .white, darkInk: true, translated: translated)
    }

    func testSpeaksTheTranslationOnlyWithTranslateOn() {
        let read = balloon("今日はいい天気ですね", translated: "Nice weather today")
        let translated = BalloonSpeaker.line(read, page: 2, translate: true, target: english)
        XCTAssertEqual(translated?.text, "Nice weather today")
        XCTAssertEqual(translated?.language, "en")
        XCTAssertEqual(translated?.page, 2)
        let original = BalloonSpeaker.line(read, page: 2, translate: false, target: english)
        XCTAssertEqual(original?.text, "今日はいい天気ですね")
        XCTAssertEqual(original?.language, "ja")
        XCTAssertEqual(BalloonSpeaker.line(balloon("今日はいい天気ですね"), page: 2, translate: true, target: english)?.text,
                       "今日はいい天気ですね")   // not translated yet
        XCTAssertNil(BalloonSpeaker.line(balloon("!?…"), page: 2, translate: false, target: english))
    }

    func testAWordlessViewWaitsThenStepsOnOnce() async throws {
        let speaker = BalloonSpeaker()
        var steps = 0
        speaker.onDone = { steps += 1 }
        speaker.update(key: 1, lines: [], wait: 0.05)
        XCTAssertEqual(steps, 0)   // off: nothing happens
        speaker.isOn = true
        speaker.update(key: 1, lines: [], wait: 0.05)
        speaker.update(key: 1, lines: [], wait: 0.05)   // the same view again: one wait
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(steps, 1)
        speaker.update(key: 1, lines: [], wait: 0.05)   // done with this view until it changes
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(steps, 1)
    }

    func testAViewStillComingInOrTurningOffCancelsTheWait() async throws {
        let speaker = BalloonSpeaker()
        var steps = 0
        speaker.onDone = { steps += 1 }
        speaker.isOn = true
        speaker.update(key: 1, lines: [], wait: 0.1)
        speaker.update(key: 1, lines: nil, wait: 0.1)   // its text is being read after all
        speaker.update(key: 2, lines: [], wait: 0.1)
        speaker.isOn = false
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(steps, 0)
        XCTAssertNil(speaker.current)
    }
}
