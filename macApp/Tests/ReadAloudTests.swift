import XCTest
import ChikaCore
@testable import Chika

// Only the paths that say nothing: no test here produces audio.
@MainActor
final class ReadAloudTests: XCTestCase {
    private let box = Panel(left: 0.1, top: 0.1, right: 0.3, bottom: 0.3)
    private let english = Locale.Language(identifier: "en")

    private func balloon(_ original: String, translated: String? = nil) -> BalloonTranslator.Balloon {
        .init(box: box, original: original, language: BalloonText.languages(of: [original])[0], paper: .white, darkInk: true, translated: translated)
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

    // A manual step moves the model before `update` hears of it: the old view's wait must not step again.
    func testAViewNoLongerOnScreenNeverStepsOn() async throws {
        let speaker = BalloonSpeaker()
        var steps = 0
        speaker.onDone = { steps += 1 }
        speaker.isCurrent = { $0 == AnyHashable(2) }   // the reader already moved on to view 2
        speaker.isOn = true
        speaker.update(key: 1, lines: [], wait: 0.05)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(steps, 0)
        speaker.update(key: 2, lines: [], wait: 0.05)   // the new view still waits and steps on
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(steps, 1)
    }

    // The system voice follows Spoken Content's language, so a known language always gets its own voice.
    func testAKnownLanguageGetsItsOwnVoiceEvenTheUsersOwn() {
        let speaker = BalloonSpeaker()
        XCTAssertNil(speaker.voice(nil))
        let own = Locale.current.language.minimalIdentifier
        XCTAssertTrue(speaker.voice(own).map { BalloonText.sameLanguage($0.language, own) } ?? false)
        XCTAssertTrue(speaker.voice("en").map { BalloonText.sameLanguage($0.language, "en") } ?? false)
    }
}
