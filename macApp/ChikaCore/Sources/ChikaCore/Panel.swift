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

    /// The pixels this panel covers in a `width` x `height` image (origin top-left), for cropping:
    /// rounded outward so no edge of the panel is cut, clamped to the image, and at least 1 px.
    public func pixelRect(width: Int, height: Int) -> (x: Int, y: Int, width: Int, height: Int) {
        let w = Float(width), h = Float(height)
        let x0 = min(max((left * w).rounded(.down), 0), w - 1)
        let y0 = min(max((top * h).rounded(.down), 0), h - 1)
        let x1 = min(max((right * w).rounded(.up), x0 + 1), w)
        let y1 = min(max((bottom * h).rounded(.up), y0 + 1), h)
        return (Int(x0), Int(y0), Int(x1 - x0), Int(y1 - y0))
    }
}
