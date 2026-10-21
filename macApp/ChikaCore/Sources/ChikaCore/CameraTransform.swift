/// Where to draw the full page bitmap (top-left + scaled size, in container pixels) so that a given
/// `Panel` region fills the container with "contain" fit (whole panel visible, aspect preserved,
/// centered). The same math handles the full-page view (panel = whole page) and any sub-panel.
public struct PageDraw: Equatable, Sendable {
    public let left: Float
    public let top: Float
    public let scaledWidth: Float
    public let scaledHeight: Float
}

/// Computes the `PageDraw` that frames `camera` (a normalized page rect) inside a container of size
/// `containerW` x `containerH`, given the page bitmap's pixel size. `fill` < 1 leaves padding around
/// the framed region so panels don't touch the screen edges.
public func computePageDraw(
    camera: Panel,
    bitmapW: Int,
    bitmapH: Int,
    containerW: Float,
    containerH: Float,
    fill: Float = 0.98
) -> PageDraw {
    let bw = max(Float(bitmapW), 1)
    let bh = max(Float(bitmapH), 1)

    // Camera region in bitmap pixels.
    let camW = max(camera.width * bw, 1)
    let camH = max(camera.height * bh, 1)
    let camCx = camera.centerX * bw
    let camCy = camera.centerY * bh

    // Scale so the camera region fits the container (contain), with a little padding.
    let scale = min(containerW / camW, containerH / camH) * fill

    let scaledWidth = bw * scale
    let scaledHeight = bh * scale
    let left = containerW / 2 - camCx * scale
    let top = containerH / 2 - camCy * scale

    return PageDraw(left: left, top: top, scaledWidth: scaledWidth, scaledHeight: scaledHeight)
}
