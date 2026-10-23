import SwiftUI
import AVFoundation
import ChikaCore

/// Read aloud: speaks the balloons of the view on screen one at a time with AVSpeechSynthesizer, then
/// asks the reader to step on. The text comes from Translate's reading (BalloonTranslator), so there
/// is one recognizer and one cache. The reader hands each view's lines to `update`.
@MainActor
final class BalloonSpeaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    struct Line: Hashable {
        let page: Int
        let box: Panel
        let text: String
        /// BCP 47; nil = not recognized, spoken with the system voice.
        let language: String?
    }

    @Published var isOn = false {
        didSet { if !isOn { stop() } }
    }
    /// The balloon being spoken, outlined on the page.
    @Published private(set) var current: Line?
    /// AVSpeechUtterance's rate, from Settings.
    var rate = AVSpeechUtteranceDefaultSpeechRate
    /// The view's lines are done (or it had none and its wait is over): the reader steps on.
    var onDone: () -> Void = {}
    /// Whether `key` is still the view on screen. A manual step (here or in the peek window) moves the
    /// model at once but reaches `update` only on SwiftUI's next pass; until then the old view must
    /// neither speak on nor step again, or the view just chosen is skipped.
    var isCurrent: (AnyHashable) -> Bool = { _ in true }

    private let synthesizer = AVSpeechSynthesizer()
    private var key: AnyHashable?
    private var lines: [Line] = []
    private var next = 0
    private var finished = false
    private var spoken: ObjectIdentifier?
    private var beat: Task<Void, Never>?
    private var voices: [String: AVSpeechSynthesisVoice?] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// The balloon's spoken line: its translation when Translate is on and has one, else the text
    /// read off the page. Nil when there is nothing to say (no letters).
    static func line(_ balloon: BalloonTranslator.Balloon, page: Int, translate: Bool, target: Locale.Language) -> Line? {
        let translated = translate ? balloon.translated : nil
        let text = translated ?? balloon.original
        guard BalloonText.isWorthTranslating(text) else { return nil }
        let language = translated != nil ? target.minimalIdentifier : balloon.language
        return Line(page: page, box: balloon.box, text: text, language: language)
    }

    /// The view on screen (`key`) and its lines in reading order, nil while its page or text is still
    /// coming. A new key interrupts the speech and starts the new view from its first line; the same key
    /// with new lines (a translation came in) carries on where it is. A view with no lines waits `wait`
    /// seconds before stepping on, so a wordless panel still gets a look.
    func update(key: AnyHashable, lines: [Line]?, wait: Double) {
        guard isOn else { return }
        if key != self.key {
            silence()
            self.key = key
            self.lines = []
            next = 0
            finished = false
        }
        guard let lines else { beat?.cancel(); beat = nil; return }
        self.lines = lines
        guard !finished, current == nil else { return }
        if lines.isEmpty {
            guard beat == nil else { return }
            beat = Task {
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                beat = nil
                guard let key = self.key, isCurrent(key) else { return }
                done()
            }
        } else {
            beat?.cancel()
            beat = nil
            speakNext()
        }
    }

    private func speakNext() {
        guard next < lines.count else { done(); return }
        let line = lines[next]
        next += 1
        let utterance = AVSpeechUtterance(string: line.text)
        utterance.voice = voice(line.language)
        utterance.rate = rate
        utterance.postUtteranceDelay = 0.25   // a breath between balloons
        spoken = ObjectIdentifier(utterance)
        current = line
        synthesizer.speak(utterance)
    }

    private func done() {
        current = nil
        finished = true
        onDone()
    }

    /// A voice for the language, nil (the system voice) when it is unknown or has no voice. Never nil for
    /// the user's own language: the system voice follows the separate Spoken Content language.
    func voice(_ language: String?) -> AVSpeechSynthesisVoice? {
        guard let language else { return nil }
        if let known = voices[language] { return known }
        let found = AVSpeechSynthesisVoice(language: language)
            ?? AVSpeechSynthesisVoice.speechVoices().first { BalloonText.sameLanguage($0.language, language) }
        voices[language] = found
        return found
    }

    private func silence() {
        beat?.cancel()
        beat = nil
        spoken = nil
        current = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Stops speaking and forgets the view, so turning it on again starts the view over.
    func stop() {
        silence()
        key = nil
        lines = []
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            // A stopped utterance's late callback must not move on.
            guard self.isOn, id == self.spoken else { return }
            self.spoken = nil
            self.current = nil
            guard let key = self.key, self.isCurrent(key) else { return }
            self.speakNext()
        }
    }
}

/// Read aloud's outline round the balloon being spoken, in the page's own coordinates (inside the
/// page's transform, like Translate's labels).
struct SpokenBalloon: View {
    let box: Panel?

    var body: some View {
        GeometryReader { geo in
            if let box {
                let line = max(geo.size.height * 0.004, 2)
                // Round Translate's label, not the detector's box, which sits inside the lettering.
                let frame = BalloonLabels.frame(box, in: geo.size).insetBy(dx: -line, dy: -line)
                RoundedRectangle(cornerRadius: geo.size.height * 0.02, style: .continuous)
                    .stroke(Chika.ochre.opacity(0.85), lineWidth: line)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
