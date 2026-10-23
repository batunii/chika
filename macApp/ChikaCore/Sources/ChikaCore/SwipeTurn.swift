/// A two-finger horizontal swipe turns one page per gesture. The fingers' travel adds up from the
/// gesture's start; once it is long enough and mostly sideways the page turns, and the rest of the
/// gesture is ignored. Swiping toward the left reads on in left-to-right comics and toward the right
/// in right-to-left ones, as the page would be pushed aside.
public struct SwipeTurn: Equatable, Sendable {
    /// Points of sideways travel that turn the page.
    public static let distance: Float = 60
    private var dx: Float = 0, dy: Float = 0, turned = false

    public init() {}

    /// A new gesture started: forget the last one.
    public mutating func begin() { self = SwipeTurn() }

    /// The fingers moved by (dx, dy) points, dx > 0 toward the right. Returns, once per gesture,
    /// true for the next page in reading order or false for the previous one; nil otherwise.
    public mutating func moved(dx: Float, dy: Float, rightToLeft: Bool) -> Bool? {
        guard !turned else { return nil }
        self.dx += dx
        self.dy += dy
        // Twice as sideways as up or down, so a vertical scroll that drifts never turns.
        guard abs(self.dx) >= Self.distance, abs(self.dx) > 2 * abs(self.dy) else { return nil }
        turned = true
        return (self.dx > 0) == rightToLeft
    }
}
