/// Geometry for the reader's panel editor. Rects are normalized page coordinates like every Panel;
/// list edits return a new list in reading order.
public enum PanelEditing {
    /// The shortest side a drawn or resized panel keeps, as a fraction of the page.
    public static let minSide: Float = 0.02

    /// The panel spanned by a drag from (ax, ay) to (bx, by), clamped to the page. A side shorter
    /// than `minSide` grows toward the drag point, so a resize's fixed corner (a) stays put.
    public static func rect(_ ax: Float, _ ay: Float, _ bx: Float, _ by: Float) -> Panel {
        let (left, right) = span(ax, bx), (top, bottom) = span(ay, by)
        return Panel(left: left, top: top, right: right, bottom: bottom)
    }

    /// `panel` moved by (dx, dy), stopped at the page's edges with its size kept.
    public static func moved(_ panel: Panel, dx: Float, dy: Float) -> Panel {
        let dx = min(max(dx, -panel.left), 1 - panel.right), dy = min(max(dy, -panel.top), 1 - panel.bottom)
        return Panel(left: panel.left + dx, top: panel.top + dy, right: panel.right + dx, bottom: panel.bottom + dy)
    }

    /// `panel` grown by `delta` on every side (shrunk when negative), kept on the page and no side
    /// shorter than `minSide`.
    public static func resized(_ panel: Panel, by delta: Float) -> Panel {
        let dx = max(delta, (minSide - panel.width) / 2), dy = max(delta, (minSide - panel.height) / 2)
        return rect(panel.left - dx, panel.top - dy, panel.right + dx, panel.bottom + dy)
    }

    /// The panels at `indices` replaced by their bounding box, read where the earliest of them was.
    public static func merged(_ panels: [Panel], _ indices: Set<Int>) -> [Panel] {
        let picked = indices.filter(panels.indices.contains).sorted()
        guard let first = picked.first, picked.count > 1 else { return panels }
        var out = panels
        out[first] = picked.map { panels[$0] }.reduce(panels[first]) {
            Panel(left: min($0.left, $1.left), top: min($0.top, $1.top), right: max($0.right, $1.right), bottom: max($0.bottom, $1.bottom))
        }
        for i in picked.dropFirst().reversed() { out.remove(at: i) }
        return out
    }

    /// The panel at `index` cut into two halves read one after the other: `across` cuts along a
    /// horizontal line (top, then bottom), otherwise along a vertical one (left then right, or right
    /// then left when reading right to left). A panel too small to halve is left as it is.
    public static func split(_ panels: [Panel], at index: Int, across: Bool, rightToLeft: Bool) -> [Panel] {
        guard panels.indices.contains(index) else { return panels }
        let p = panels[index]
        guard (across ? p.height : p.width) >= 2 * minSide else { return panels }
        var first = p, second = p
        if across { first.bottom = p.centerY; second.top = p.centerY } else { first.right = p.centerX; second.left = p.centerX }
        if !across && rightToLeft { swap(&first, &second) }
        var out = panels
        out.replaceSubrange(index...index, with: [first, second])
        return out
    }

    /// The panel at `index` moved `delta` places in the reading order, stopped at either end.
    public static func reordered(_ panels: [Panel], moving index: Int, by delta: Int) -> [Panel] {
        guard panels.indices.contains(index) else { return panels }
        var out = panels
        out.insert(out.remove(at: index), at: min(max(index + delta, 0), panels.count - 1))
        return out
    }

    /// The smallest panel (of `among`, if given) containing (x, y), so a panel drawn inside a bigger
    /// one can still be picked.
    public static func hit(_ panels: [Panel], x: Float, y: Float, among: Set<Int>? = nil) -> Int? {
        panels.indices.filter { i in
            let p = panels[i]
            return (among?.contains(i) ?? true) && x >= p.left && x <= p.right && y >= p.top && y <= p.bottom
        }.min { panels[$0].area < panels[$1].area }
    }

    private static func span(_ a: Float, _ b: Float) -> (Float, Float) {
        let a = min(max(a, 0), 1), b = min(max(b, 0), 1)
        guard abs(b - a) < minSide else { return (min(a, b), max(a, b)) }
        let low = b < a ? a - minSide : a
        let shift = max(0, -low) - max(0, low + minSide - 1)   // slide back inside the page
        return (low + shift, low + minSide + shift)
    }
}
