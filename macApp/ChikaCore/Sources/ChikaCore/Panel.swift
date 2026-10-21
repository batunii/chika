/// A detected panel as a rectangle in normalized page coordinates: each edge is a fraction in
/// `[0, 1]` of the page width/height. Normalized coordinates make panels independent of the
/// resolution the page happened to be decoded/detected at, so the reader can map them onto a bitmap
/// of any size.
public struct Panel: Equatable, Hashable, Codable, Sendable {
    public var left: Float
    public var top: Float
    public var right: Float
    public var bottom: Float

    public init(left: Float, top: Float, right: Float, bottom: Float) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    public var width: Float { max(right - left, 0) }
    public var height: Float { max(bottom - top, 0) }
    public var area: Float { width * height }
    public var centerX: Float { (left + right) / 2 }
    public var centerY: Float { (top + bottom) / 2 }

    /// A panel covering the whole page, used as the per-page "zoomed-out" view and as a fallback.
    public static let fullPage = Panel(left: 0, top: 0, right: 1, bottom: 1)
}
