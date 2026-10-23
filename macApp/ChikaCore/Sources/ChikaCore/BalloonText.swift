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
