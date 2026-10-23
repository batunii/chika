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

    /// A window of `aspect`'s shape at `width`, scaled down (keeping the shape) to fit inside `area`'s
    /// margins, since a webtoon page can be many screens tall; then no smaller than `minimum`, the
    /// picture fitting inside.
    public static func size(_ aspect: CGSize, width: CGFloat, in area: CGRect, minimum: CGSize = .zero) -> CGSize {
        let room = area.insetBy(dx: margin, dy: margin).size
        let height = width * aspect.height / aspect.width
        let scale = min(1, room.width / width, room.height / height)
        return CGSize(width: max(width * scale, minimum.width), height: max(height * scale, minimum.height))
    }

    /// Where a window of `size` reopens, `saved` being its last frame on that screen: in the same
    /// corner if it was in one, else with the same top-left, pulled back inside `area` (keeping its
    /// top-left on screen if it is too big). Nil when `saved` is off the screen now (it shrank or
    /// rearranged), so the window centres instead.
    public static func restore(_ saved: CGRect, size: CGSize, in area: CGRect) -> CGPoint? {
        guard area.intersects(saved) else { return nil }
        if let corner = corner(near: saved, in: area, reach: 1) { return origin(corner, size: size, in: area) }
        // The old frame touching the screen says nothing about the new size, which can land off it.
        return CGPoint(x: max(min(saved.minX, area.maxX - size.width), area.minX),
                       y: min(max(saved.maxY - size.height, area.minY), area.maxY - size.height))
    }
}
