import Testing
import ChikaCore

/// The shared format-detection logic every platform routes imports through. Magic bytes win over the
/// extension so a mislabeled file opens the same way everywhere — the parity-critical case.
struct ComicFormatDetectorTests {
    let zipMagic: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
    let rarMagic: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]

    @Test func zipMagicIsCbz() {
        #expect(ComicFormatDetector.detect(head: zipMagic, fileExtension: "cbz") == .cbz)
    }

    @Test func rarMagicIsCbr() {
        #expect(ComicFormatDetector.detect(head: rarMagic, fileExtension: "cbr") == .cbr)
    }

    @Test func rarBytesUnderCbzExtensionStillCbr() {
        // The case that matters: a .cbz that is really a RAR must convert, not copy in broken.
        #expect(ComicFormatDetector.detect(head: rarMagic, fileExtension: "cbz") == .cbr)
    }

    @Test func zipBytesUnderCbrExtensionStillCbz() {
        #expect(ComicFormatDetector.detect(head: zipMagic, fileExtension: "cbr") == .cbz)
    }

    @Test func noMagicFallsBackToExtension() {
        let junk: [UInt8] = [0x00, 0x11, 0x22, 0x33]
        #expect(ComicFormatDetector.detect(head: junk, fileExtension: "cbr") == .cbr)
        #expect(ComicFormatDetector.detect(head: junk, fileExtension: "rar") == .cbr)
        #expect(ComicFormatDetector.detect(head: junk, fileExtension: "zip") == .cbz)
        #expect(ComicFormatDetector.detect(head: junk, fileExtension: "CBZ") == .cbz) // case-insensitive
        #expect(ComicFormatDetector.detect(head: junk, fileExtension: "epub") == .unknown)
    }

    @Test func emptyHeadFallsBackToExtension() {
        #expect(ComicFormatDetector.detect(head: [], fileExtension: "cbr") == .cbr)
        #expect(ComicFormatDetector.detect(head: [], fileExtension: "") == .unknown)
    }

    @Test func sevenZipAndPdfByMagicThenExtension() {
        #expect(ComicFormatDetector.detect(head: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0, 4], fileExtension: "cbz") == .cb7)
        #expect(ComicFormatDetector.detect(head: Array("%PDF-1.7".utf8), fileExtension: "cbz") == .pdf)
        #expect(ComicFormatDetector.detect(head: [], fileExtension: "CB7") == .cb7)
        #expect(ComicFormatDetector.detect(head: [], fileExtension: "pdf") == .pdf)
    }
}
