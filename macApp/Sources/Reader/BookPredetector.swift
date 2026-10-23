import AppKit
import ChikaCore

/// Detects every page of a comic in the background after it is imported or opened, and stores the
/// results (ReadingProgress.setDetection), so turning onto any page, and the peek window, finds its
/// panels at once. One comic at a time, at utility priority, with its own detector so it never waits
/// on the reader's. Pages already stored by this detector version are skipped.
@MainActor
final class BookPredetector {
    static let shared = BookPredetector()
    private nonisolated static let detector = CoreMLPanelDetector()

    private var waiting: [URL] = []
    private var running: (url: URL, task: Task<Void, Never>)?

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BookPredetector.shared.cancelAll() }
        }
    }

    /// Queues `url`; a comic already queued or running is not added twice.
    func add(_ url: URL) {
        guard running?.url != url, !waiting.contains(url) else { return }
        waiting.append(url)
        startNext()
    }

    /// Drops `url` (call before its file or rows go): a page still being detected is not saved.
    func cancel(_ url: URL) {
        waiting.removeAll { $0 == url }
        guard running?.url == url else { return }
        running?.task.cancel()
        running = nil
        startNext()
    }

    func cancelAll() {
        waiting = []
        running?.task.cancel()
        running = nil
    }

    private func startNext() {
        guard running == nil, !waiting.isEmpty else { return }
        let url = waiting.removeFirst()
        let done = ReadingProgress.detectedPages(url)
        // Tests swap the database between cases: a job only ever writes to the store it started in.
        let store = ReadingProgress.databaseURL
        let task = Task.detached(priority: .utility) {
            if let pages = try? ComicOpener.open(url) {
                for page in 0..<pages.pageCount where !done.contains(page) {
                    if Task.isCancelled { return }
                    // The reader's own decode (same size limit), uncached so the reader's cache keeps its pages.
                    guard let data = try? pages.readPage(page),
                          let image = PageLoader.decodeSampled(data: data, maxDim: PageLoader.defaultMaxDimension),
                          let found = Self.detector.detect(image) else { continue }
                    // Cancelling and saving both run on the main actor, so a dropped comic never gets a late row.
                    await MainActor.run {
                        if !Task.isCancelled, ReadingProgress.databaseURL == store { ReadingProgress.setDetection(url, page: page, found) }
                    }
                }
            }
            await MainActor.run {
                guard !Task.isCancelled else { return }   // cancel() already moved on
                BookPredetector.shared.running = nil
                BookPredetector.shared.startNext()
            }
        }
        running = (url, task)
    }
}
