/// Fills coverage gaps. If the detected panels leave a large rectangular region of the page
/// uncovered, that region was most likely a panel the model missed — so we add it as a panel.
///
/// The page is sampled on a grid and we repeatedly carve out the *largest empty rectangle* of
/// uncovered cells: each one big enough (and not a thin sliver) becomes an extra panel, then is
/// marked covered so the next-largest hole can be found. Using maximal rectangles — rather than
/// connected components — is what makes this work on real pages: the thin margin/gutter frame that
/// surrounds and connects everything never forms a large rectangle, so it's ignored, while a genuine
/// missed panel (bounded by its neighbours) is isolated cleanly. Ordering/numbering happens
/// afterwards in the pipeline. Works in normalized `[0,1]` coordinates.
public enum PanelGapFiller {

    public struct Config: Sendable {
        /// An empty rectangle must cover at least this fraction of the page to become a panel.
        public var minAreaFraction: Float
        /// ...and each side must be at least this fraction of the page (rejects thin margin strips).
        public var minSideFraction: Float
        /// Sampling resolution (cells per axis).
        public var grid: Int
        /// Safety cap on how many missed panels to recover from one page.
        public var maxFills: Int

        public init(minAreaFraction: Float = 0.07, minSideFraction: Float = 0.12, grid: Int = 64, maxFills: Int = 8) {
            self.minAreaFraction = minAreaFraction
            self.minSideFraction = minSideFraction
            self.grid = grid
            self.maxFills = maxFills
        }
    }

    public static func fill(_ panels: [Panel], config: Config = Config()) -> [Panel] {
        if panels.isEmpty { return panels }
        let n = config.grid

        // Mark a cell covered if its centre falls inside any panel.
        var covered = [Bool](repeating: false, count: n * n)
        for gy in 0..<n {
            let cy = (Float(gy) + 0.5) / Float(n)
            for gx in 0..<n {
                let cx = (Float(gx) + 0.5) / Float(n)
                covered[gy * n + gx] = panels.contains {
                    cx >= $0.left && cx <= $0.right && cy >= $0.top && cy <= $0.bottom
                }
            }
        }

        let cellArea = 1 / Float(n * n)
        var gaps: [Panel] = []
        for _ in 0..<config.maxFills {
            guard let rect = largestEmptyRectangle(covered, n) else { break }
            // The largest empty rectangle only shrinks each pass, so once it's below the area
            // threshold nothing larger remains — stop.
            if Float(rect.cells) * cellArea < config.minAreaFraction { break }
            // Always claim the rectangle so the next pass finds a different hole; only emit it as a
            // panel if it isn't a thin sliver (a margin/gutter strip rather than a real panel).
            let wFrac = Float(rect.x1 - rect.x0 + 1) / Float(n)
            let hFrac = Float(rect.y1 - rect.y0 + 1) / Float(n)
            for yy in rect.y0...rect.y1 { for xx in rect.x0...rect.x1 { covered[yy * n + xx] = true } }
            if wFrac >= config.minSideFraction && hFrac >= config.minSideFraction {
                gaps.append(Panel(
                    left: Float(rect.x0) / Float(n),
                    top: Float(rect.y0) / Float(n),
                    right: Float(rect.x1 + 1) / Float(n),
                    bottom: Float(rect.y1 + 1) / Float(n)
                ))
            }
        }

        return gaps.isEmpty ? panels : panels + gaps
    }

    private struct Rect { let x0: Int, y0: Int, x1: Int, y1: Int, cells: Int }

    /// Largest axis-aligned rectangle of uncovered cells, via the classic histogram method (build a
    /// column-height histogram per row, then find the largest rectangle in that histogram). Returns
    /// nil if nothing is uncovered.
    private static func largestEmptyRectangle(_ covered: [Bool], _ n: Int) -> Rect? {
        var height = [Int](repeating: 0, count: n)
        var best: Rect?
        for y in 0..<n {
            for x in 0..<n {
                height[x] = covered[y * n + x] ? 0 : height[x] + 1
            }
            // Largest rectangle in this histogram (row y is the bottom edge), tracking its bounds.
            var stack: [Int] = [] // indices of increasing bar heights
            var x = 0
            while x <= n {
                let h = x < n ? height[x] : 0
                while let last = stack.last, height[last] >= h {
                    let barHeight = height[stack.removeLast()]
                    let left = stack.last.map { $0 + 1 } ?? 0
                    let right = x - 1
                    if barHeight > 0 {
                        let cells = barHeight * (right - left + 1)
                        if best == nil || cells > best!.cells {
                            best = Rect(x0: left, y0: y - barHeight + 1, x1: right, y1: y, cells: cells)
                        }
                    }
                }
                if x < n { stack.append(x) }
                x += 1
            }
        }
        return best
    }
}
