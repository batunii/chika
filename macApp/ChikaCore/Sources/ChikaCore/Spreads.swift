/// Two-page spread layout: which pages share the screen. The cover (page 0) and any wide page (a
/// scanned double page) stand alone; the rest pair up in reading order, so facing pages land
/// together the way they were printed. `wide` grows as pages are decoded, so pairs can shift
/// after a wide page is found; pages before it keep their pairs.
public enum Spreads {
    /// Every spread in reading order; each holds one or two page indices, first-read first.
    public static func pairs(pageCount: Int, wide: Set<Int> = []) -> [[Int]] {
        var result: [[Int]] = []
        var i = 0
        while i < pageCount {
            if i == 0 || i + 1 == pageCount || wide.contains(i) || wide.contains(i + 1) {
                result.append([i])
                i += 1
            } else {
                result.append([i, i + 1])
                i += 2
            }
        }
        return result
    }

    /// The spread that shows `page`.
    public static func spread(containing page: Int, pageCount: Int, wide: Set<Int> = []) -> [Int] {
        pairs(pageCount: pageCount, wide: wide).first { $0.contains(page) } ?? [page]
    }
}
