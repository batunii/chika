/// A comic archive container format.
public enum ComicFormat: Sendable { case cbz, cbr, unknown }

/// Detects a comic's container format from its leading bytes, falling back to the file extension.
/// Shared by every platform so all route a file the same way — a mislabeled ".cbz" that is really
/// a RAR (common in the wild) is opened as CBR everywhere, not just on one platform.
public enum ComicFormatDetector {
    private static let zipMagic: [UInt8] = [0x50, 0x4B, 0x03, 0x04]             // "PK\x03\x04"
    private static let zipEmpty: [UInt8] = [0x50, 0x4B, 0x05, 0x06]             // empty archive
    private static let rarMagic: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07] // "Rar!\x1a\x07"

    /// - Parameters:
    ///   - head: the first bytes of the file (8 is plenty); fewer is fine, magic just won't match.
    ///   - fileExtension: the file's extension (without the dot), used only when magic is absent.
    public static func detect(head: [UInt8], fileExtension: String) -> ComicFormat {
        if head.starts(with: zipMagic) || head.starts(with: zipEmpty) { return .cbz }
        if head.starts(with: rarMagic) { return .cbr }
        switch fileExtension.lowercased() {
        case "cbz", "zip": return .cbz
        case "cbr", "rar": return .cbr
        default: return .unknown
        }
    }
}
