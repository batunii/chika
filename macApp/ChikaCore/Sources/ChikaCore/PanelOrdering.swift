/// Sorts detected panels into reading order using a **recursive X-Y cut with straddle tolerance**.
///
/// Comics are read in rows (top→bottom), and within a row left→right (Western) or right→left (manga).
/// At each step we look for a straight cut that separates the panels into two groups:
///  - a **horizontal** cut (preferred) stacks the groups top→bottom — i.e. rows;
///  - a **vertical** cut arranges them by reading direction — i.e. columns.
/// A panel is allowed to poke slightly across a cut (up to `straddleTolerance` of its own length) and
/// is assigned to whichever side holds most of it — so a row of not-perfectly-aligned panels still
/// splits into one row. A panel that genuinely spans two rows (a tall panel beside stacked ones) makes
/// the horizontal cut impossible, so we cut vertically first — separating the tall panel from the
/// stack — then recurse, which is exactly the case a naive "group by row overlap" gets wrong.
public enum PanelOrdering {

    /// A panel may cross a cut line by up to this fraction of its own height/width and still be
    /// assigned cleanly to one side (handles slightly misaligned panels in the same row).
    private static let straddleTolerance: Float = 0.25

    /// In the no-clean-cut fallback, panels whose tops are within this fraction of the page height
    /// are treated as one row (so a vertically-staggered row still reads left→right).
    private static let rowBand: Float = 0.12

    public static func order(_ panels: [Panel], rightToLeft: Bool = false) -> [Panel] {
        if panels.count <= 1 { return panels }
        return cut(panels, rightToLeft)
    }

    private static func cut(_ panels: [Panel], _ rightToLeft: Bool) -> [Panel] {
        if panels.count <= 1 { return panels }

        // Prefer a horizontal cut → rows, read top to bottom.
        if let (top, bottom) = findCut(panels, vertical: false) {
            return cut(top, rightToLeft) + cut(bottom, rightToLeft)
        }

        // Otherwise a vertical cut → columns, read by direction (right group first for manga).
        if let (left, right) = findCut(panels, vertical: true) {
            return rightToLeft ? cut(right, rightToLeft) + cut(left, rightToLeft)
                : cut(left, rightToLeft) + cut(right, rightToLeft)
        }

        // No clean cut (a big panel overlaps everything, so neither axis splits). Best effort: cluster
        // into rows by top — tolerant of vertical stagger — then read rows top→bottom and within a row
        // by reading direction. This keeps a staggered bottom row (e.g. a panel beside a shorter one)
        // in left→right order instead of "whichever starts higher first".
        let byTop = panels.sorted { $0.top < $1.top }
        var rows: [[Panel]] = []
        for p in byTop {
            if let row = rows.last, p.top - row[0].top <= rowBand { rows[rows.count - 1].append(p) } else { rows.append([p]) }
        }
        return rows.flatMap { row in
            rightToLeft ? row.sorted { $0.left > $1.left } : row.sorted { $0.left < $1.left }
        }
    }

    /// Tries to split `panels` into two non-empty groups along one axis. `vertical` = false cuts
    /// horizontally (returns top group, bottom group); true cuts vertically (left group, right group).
    /// Scans candidate cut lines (panel trailing edges); a line is valid only if every panel sits on
    /// one side or straddles by at most `straddleTolerance` of its length. Returns nil if no line works.
    private static func findCut(_ panels: [Panel], vertical: Bool) -> ([Panel], [Panel])? {
        let start = { (p: Panel) -> Float in vertical ? p.left : p.top }
        let end = { (p: Panel) -> Float in vertical ? p.right : p.bottom }

        let ends = panels.map(end)
        let maxEnd = ends.max()!
        let candidates = Set(ends).sorted()
        for line in candidates {
            if line >= maxEnd { continue } // wouldn't leave anything below/right
            var first: [Panel] = []  // top (or left) side
            var second: [Panel] = [] // bottom (or right) side
            var valid = true
            for p in panels {
                let s = start(p), e = end(p)
                if e <= line { first.append(p) }
                else if s >= line { second.append(p) }
                else {
                    let len = max(e - s, 1e-4)
                    let crossDepth = min(e - line, line - s) // how far it pokes onto the thinner side
                    if crossDepth / len > straddleTolerance { valid = false; break }
                    if line - s >= e - line { first.append(p) } else { second.append(p) } // majority side
                }
            }
            if valid && !first.isEmpty && !second.isEmpty { return (first, second) }
        }
        return nil
    }
}
