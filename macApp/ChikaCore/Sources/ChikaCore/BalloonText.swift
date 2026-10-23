import Foundation

/// Pure helpers for reading and translating speech balloons: where to crop, how to join the
/// recognized lines, what is worth translating and what colour to paint the translation on.
public enum BalloonText {
    /// The balloon grown by `pad` of its own size per side and clamped to the page, so text that
    /// touches the detected box's edge is not cut off before text recognition.
    public static func cropRect(_ balloon: Panel, pad: Float = 0.04) -> Panel {
        let dx = balloon.width * pad, dy = balloon.height * pad
        return Panel(left: max(balloon.left - dx, 0), top: max(balloon.top - dy, 0),
                     right: min(balloon.right + dx, 1), bottom: min(balloon.bottom + dy, 1))
    }

    /// Recognized lines (boxes in the crop, origin top-left) joined in reading order. Mostly
    /// taller-than-wide boxes are vertical Japanese columns, read right to left; otherwise lines
    /// read top to bottom. CJK text joins without spaces, other scripts with one.
    public static func join(_ lines: [(box: Panel, text: String)]) -> String {
        let vertical = lines.filter { $0.box.height > $0.box.width }.count * 2 > lines.count
        let ordered = lines.sorted { vertical ? $0.box.centerX > $1.box.centerX : $0.box.centerY < $1.box.centerY }
        let texts = ordered.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return texts.joined(separator: texts.contains(where: containsCJK) ? "" : " ")
    }

    /// Text with at least one letter; punctuation-only balloons ("!?", "…") are left alone.
    public static func isWorthTranslating(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.isAlphabetic }
    }

    /// Whether two BCP 47 identifiers name the same language and script ("en" and "en-GB" do,
    /// "zh-Hans" and "zh-Hant" do not), so text already in the target language is skipped.
    public static func sameLanguage(_ a: String, _ b: String) -> Bool {
        let x = Locale.Language(identifier: Locale.Language(identifier: a).maximalIdentifier)
        let y = Locale.Language(identifier: Locale.Language(identifier: b).maximalIdentifier)
        return x.languageCode == y.languageCode && x.script == y.script
    }

    /// The balloon's paper colour from a small RGBA sample of it (4 bytes a pixel): the average of
    /// the most common colour, so the lettering (the minority of pixels) does not darken it.
    public static func paperColor(rgba: [UInt8]) -> (r: UInt8, g: UInt8, b: UInt8) {
        var bins: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        for i in stride(from: 0, to: rgba.count - 3, by: 4) {
            let r = Int(rgba[i]), g = Int(rgba[i + 1]), b = Int(rgba[i + 2])
            let key = (r >> 5) << 6 | (g >> 5) << 3 | b >> 5   // 8 levels a channel
            let bin = bins[key] ?? (0, 0, 0, 0)
            bins[key] = (bin.count + 1, bin.r + r, bin.g + g, bin.b + b)
        }
        guard let top = bins.values.max(by: { $0.count < $1.count }) else { return (255, 255, 255) }
        return (UInt8(top.r / top.count), UInt8(top.g / top.count), UInt8(top.b / top.count))
    }

    /// Read aloud: the balloons read while region `step` of `regions` is on screen, in reading order.
    /// Each balloon belongs to the one region it overlaps most (the nearest when it overlaps none), so
    /// a balloon inside two padded, overlapping regions is read once. A step off the regions (a
    /// whole-page slot) reads none; pass `[.fullPage]` and step 0 for a whole page.
    public static func balloons(_ balloons: [Panel], inRegion step: Int, of regions: [Panel], rightToLeft: Bool) -> [Panel] {
        guard regions.indices.contains(step) else { return [] }
        return PanelOrdering.order(balloons.filter { owner(of: $0, in: regions) == step }, rightToLeft: rightToLeft)
    }

    /// Every balloon of a whole page, panel by panel in the panels' reading order (`regions`, already
    /// ordered for the direction), then in reading order within each panel, so a tall panel's balloons
    /// are all read before the next panel's.
    public static func balloons(_ balloons: [Panel], of regions: [Panel], rightToLeft: Bool) -> [Panel] {
        let regions = regions.isEmpty ? [.fullPage] : regions
        return regions.indices.flatMap { Self.balloons(balloons, inRegion: $0, of: regions, rightToLeft: rightToLeft) }
    }

    private static func owner(of balloon: Panel, in regions: [Panel]) -> Int {
        func rank(_ r: Panel) -> (Float, Float) {
            let overlap = max(min(balloon.right, r.right) - max(balloon.left, r.left), 0)
                * max(min(balloon.bottom, r.bottom) - max(balloon.top, r.top), 0)
            return (-overlap, hypot(balloon.centerX - r.centerX, balloon.centerY - r.centerY))
        }
        return regions.indices.min { rank(regions[$0]) < rank(regions[$1]) }!
    }

    /// Dark lettering on light paper, light on dark.
    public static func inkIsDark(on paper: (r: UInt8, g: UInt8, b: UInt8)) -> Bool {
        0.299 * Double(paper.r) + 0.587 * Double(paper.g) + 0.114 * Double(paper.b) > 128
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            switch $0.value {
            case 0x3040...0x30FF, 0x3400...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF66...0xFF9F: return true
            default: return false
            }
        }
    }
}
