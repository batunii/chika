/// Compares strings so that embedded numbers sort numerically rather than lexicographically,
/// e.g. "page2" < "page10". Comic archives almost always name pages with un-padded numbers, so a
/// plain string sort would put page10 before page2. Comparison is case-insensitive.
public enum NaturalOrder {
    public static func compare(_ a: String, _ b: String) -> Int {
        // Walk UTF-16 units like Kotlin's Char so the order (and lengths) match Android exactly.
        let a = Array(a.utf16), b = Array(b.utf16)
        var i = 0
        var j = 0
        while i < a.count && j < b.count {
            let ca = a[i]
            let cb = b[j]
            if isDigit(ca) && isDigit(cb) {
                // Gather full runs of digits and compare as numbers (ignoring leading zeros).
                let startA = i
                let startB = j
                while i < a.count && isDigit(a[i]) { i += 1 }
                while j < b.count && isDigit(b[j]) { j += 1 }
                let numA = trimZeros(a[startA..<i])
                let numB = trimZeros(b[startB..<j])
                if numA.count != numB.count { return numA.count - numB.count }
                if numA != numB { return numA.lexicographicallyPrecedes(numB) ? -1 : 1 }
            } else {
                let cmp = Int(lowercase(ca)) - Int(lowercase(cb))
                if cmp != 0 { return cmp }
                i += 1
                j += 1
            }
        }
        return (a.count - i) - (b.count - j)
    }

    public static func isOrderedBefore(_ a: String, _ b: String) -> Bool { compare(a, b) < 0 }

    /// Kotlin's `Char.isDigit()`: Unicode category Nd (so fullwidth/Arabic-Indic digits count).
    private static func isDigit(_ u: UInt16) -> Bool {
        Unicode.Scalar(u)?.properties.generalCategory == .decimalNumber
    }

    /// Kotlin's `Char.lowercaseChar()` (a 1:1 mapping); a lone surrogate or multi-unit mapping stays as is.
    private static func lowercase(_ u: UInt16) -> UInt16 {
        guard let mapped = Unicode.Scalar(u)?.properties.lowercaseMapping.utf16, mapped.count == 1 else { return u }
        return mapped.first!
    }

    /// Kotlin's `trimStart('0').ifEmpty { "0" }`.
    private static func trimZeros(_ digits: ArraySlice<UInt16>) -> [UInt16] {
        let trimmed = digits.drop { $0 == 0x30 }
        return trimmed.isEmpty ? [0x30] : Array(trimmed)
    }
}
