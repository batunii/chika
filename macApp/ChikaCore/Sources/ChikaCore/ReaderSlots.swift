/// Page + slot state machine of the reader, pulled out so it is testable. Slots on a page:
/// -1 = whole-page intro, 0..<n = panels, n = whole-page outro. `regions == nil` = this page's
/// panels are not detected yet. Fixes the audit bug where a placeholder [fullPage] counted as a
/// real panel (back-page landed on panel 2; fast taps skipped undetected pages).
public struct ReaderSlots: Equatable, Sendable {
    /// "Land on the outro once regions are known" (backward page turns, restored progress).
    public static let outroSentinel = Int.max

    public var page: Int
    public var step: Int
    public var regions: [Panel]?

    public init(page: Int = 0, step: Int = -1, regions: [Panel]? = nil) {
        self.page = page
        self.step = step
        self.regions = regions
    }

    public var panelCount: Int { regions?.count ?? 0 }
    public var onPanel: Bool { 0 <= step && step < panelCount }
    public var isFullPage: Bool { !onPanel }
    public var camera: Panel { onPanel ? regions![step] : .fullPage }

    public enum Move: Equatable, Sendable { case moved, blocked, nextPage, previousPage }

    /// Detection landed.
    public mutating func setRegions(_ r: [Panel]) {
        regions = r
        step = min(step, r.count) // resolves outroSentinel and any stray step past the outro
    }

    public mutating func advance(by delta: Int, pageCount: Int) -> Move {
        guard let regions else {
            // Unknown panels: only whole-page slots can be left; otherwise wait for detection.
            if delta > 0 && step == Self.outroSentinel { return turnToNextPage(pageCount) }
            if delta < 0 && step == Self.outroSentinel { step = -1; return .moved }
            if delta < 0 && step == -1 { return turnToPreviousPage() }
            return .blocked
        }
        let n = regions.count
        let next = min(step, n) + delta
        if next > n { return turnToNextPage(pageCount) }
        if next < -1 { return turnToPreviousPage() }
        step = next
        return .moved
    }

    public mutating func showWholePage() { step = -1 }

    private mutating func turnToNextPage(_ pageCount: Int) -> Move {
        guard page + 1 < pageCount else { return .blocked }
        page += 1; step = -1; regions = nil
        return .nextPage
    }

    private mutating func turnToPreviousPage() -> Move {
        guard page > 0 else { return .blocked }
        page -= 1; step = Self.outroSentinel; regions = nil
        return .previousPage
    }
}
