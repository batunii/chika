/// Typing a page number in the reader: digits gather (the view drops them after a pause) and Return
/// jumps to the page they spell.
public enum PageJump {
    /// `typed` with `digit` added. A number longer than the page count's starts over from the new
    /// digit, so a slip never needs clearing first.
    public static func append(_ digit: Character, to typed: String, pageCount: Int) -> String {
        let next = typed + String(digit)
        return next.count > String(max(pageCount, 1)).count ? String(digit) : next
    }

    /// The 0-based page the typed digits name, clamped to the comic; nil for nothing typed.
    public static func page(_ typed: String, pageCount: Int) -> Int? {
        guard let number = Int(typed), pageCount > 0 else { return nil }
        return min(max(number, 1), pageCount) - 1
    }

    /// The page scrubber moved without a drag (the keyboard) to `value` with `visible` on screen (0-based,
    /// in page order; the thumb sits on the last): the page to go to, nil to stay. Down onto an earlier
    /// page of the spread on screen means the page before the spread, else that spread would come back
    /// and snap the thumb up to its last page again.
    public static func scrubbed(to value: Double, visible: [Int]) -> Int? {
        let page = Int(value.rounded())
        guard let first = visible.first, page != visible.last else { return nil }
        guard visible.contains(page) else { return page }
        return first > 0 ? first - 1 : nil
    }
}
