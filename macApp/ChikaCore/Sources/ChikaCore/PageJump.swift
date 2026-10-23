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
}
