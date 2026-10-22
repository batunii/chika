/// A comic container format. CB7 converts like CBR (libarchive reads both); PDF is read with PDFKit.
public enum ComicFormat: Sendable { case cbz, cbr, cb7, pdf, unknown }

/// Detects a comic's container format from its leading bytes, falling back to the file extension.
/// Shared by every platform so all route a file the same way — a mislabeled ".cbz" that is really
/// a RAR (common in the wild) is opened as CBR everywhere, not just on one platform.
public enum ComicFormatDetector {
    private static let zipMagic: [UInt8] = [0x50, 0x4B, 0x03, 0x04]             // "PK\x03\x04"
    private static let zipEmpty: [UInt8] = [0x50, 0x4B, 0x05, 0x06]             // empty archive
    private static let rarMagic: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07] // "Rar!\x1a\x07"
    private static let sevenZipMagic: [UInt8] = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C] // "7z\xbc\xaf\x27\x1c"
    private static let pdfMagic: [UInt8] = [0x25, 0x50, 0x44, 0x46, 0x2D]          // "%PDF-"

    /// - Parameters:
    ///   - head: the first bytes of the file (8 is plenty); fewer is fine, magic just won't match.
    ///   - fileExtension: the file's extension (without the dot), used only when magic is absent.
    public static func detect(head: [UInt8], fileExtension: String) -> ComicFormat {
        if head.starts(with: zipMagic) || head.starts(with: zipEmpty) { return .cbz }
        if head.starts(with: rarMagic) { return .cbr }
        if head.starts(with: sevenZipMagic) { return .cb7 }
        if head.starts(with: pdfMagic) { return .pdf }
        switch fileExtension.lowercased() {
        case "cbz", "zip": return .cbz
        case "cbr", "rar": return .cbr
        case "cb7", "7z": return .cb7
        case "pdf": return .pdf
        default: return .unknown
        }
    }
}
