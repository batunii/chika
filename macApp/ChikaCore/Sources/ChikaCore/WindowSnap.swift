import CoreGraphics   // CGRect geometry; Foundation alone lacks it outside AppKit

/// Where the peek window sits on its screen: dropped near a corner it snaps into it, a margin in
/// from the edges, and it reopens where it was left. Screen coordinates, y up (AppKit's).
public enum WindowSnap {
    public enum Corner: Equatable, Sendable { case topLeft, topRight, bottomLeft, bottomRight }

    public static let margin: CGFloat = 16
    /// How close to its snapped place a dropped window has to be.
    public static let reach: CGFloat = 48

    /// The corner of `area` that `frame` is within `reach` of (on both axes), or nil.
    public static func corner(near frame: CGRect, in area: CGRect, reach: CGFloat = reach) -> Corner? {
        let inset = area.insetBy(dx: margin, dy: margin)
        let left = abs(frame.minX - inset.minX), right = abs(inset.maxX - frame.maxX)
        let bottom = abs(frame.minY - inset.minY), top = abs(inset.maxY - frame.maxY)
        guard min(left, right) <= reach, min(bottom, top) <= reach else { return nil }
        switch (left <= right, top <= bottom) {
        case (true, true): return .topLeft
        case (false, true): return .topRight
        case (true, false): return .bottomLeft
        case (false, false): return .bottomRight
        }
    }

    /// The origin that puts a window of `size` in `corner` of `area`.
    public static func origin(_ corner: Corner, size: CGSize, in area: CGRect) -> CGPoint {
        let inset = area.insetBy(dx: margin, dy: margin)
        let leftSide = corner == .topLeft || corner == .bottomLeft
        let top = corner == .topLeft || corner == .topRight
        return CGPoint(x: leftSide ? inset.minX : inset.maxX - size.width,
                       y: top ? inset.maxY - size.height : inset.minY)
    }

    /// Where a window of `size` reopens, `saved` being its last frame on that screen: in the same
    /// corner if it was in one, else with the same top-left. Nil when `saved` is off the screen now
    /// (it shrank or rearranged), so the window centres instead.
    public static func restore(_ saved: CGRect, size: CGSize, in area: CGRect) -> CGPoint? {
        guard area.intersects(saved) else { return nil }
        if let corner = corner(near: saved, in: area, reach: 1) { return origin(corner, size: size, in: area) }
        return CGPoint(x: saved.minX, y: saved.maxY - size.height)
    }
}
