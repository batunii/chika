import Testing
import ChikaCore

struct NaturalOrderTests {
    @Test func embeddedNumbersSortNumerically() {
        let sorted = ["page10.jpg", "page2.jpg", "page1.jpg"].sorted(by: NaturalOrder.isOrderedBefore)
        #expect(sorted == ["page1.jpg", "page2.jpg", "page10.jpg"])
    }

    @Test func leadingZerosCompareEqualToUnpadded() {
        #expect(NaturalOrder.compare("page002", "page2") == 0)
    }

    @Test func comparisonIsCaseInsensitive() {
        #expect(NaturalOrder.compare("Page1", "page1") == 0)
        #expect(NaturalOrder.compare("Apple", "banana") < 0)
    }

    @Test func prefixSortsBeforeLongerString() {
        #expect(NaturalOrder.compare("page", "page1") < 0)
    }

    @Test func mixedSegmentsSortPerSegment() {
        let sorted = ["ch2-page10", "ch10-page1", "ch2-page9"].sorted(by: NaturalOrder.isOrderedBefore)
        #expect(sorted == ["ch2-page9", "ch2-page10", "ch10-page1"])
    }
}

struct IsImageEntryTests {
    @Test func acceptsCommonImageExtensions() {
        for name in ["p.jpg", "p.JPEG", "p.png", "p.webp", "p.gif", "p.bmp", "p.avif"] {
            #expect(isImageEntry(name), "expected \(name) to be an image entry")
        }
    }

    @Test func rejectsNonImagesAndMetadata() {
        #expect(!isImageEntry("info.txt"))
        #expect(!isImageEntry("ComicInfo.xml"))
        #expect(!isImageEntry("noextension"))
    }

    @Test func rejectsHiddenAndMacOsxEntries() {
        #expect(!isImageEntry(".hidden.jpg"))
        #expect(!isImageEntry("__MACOSX-resource.jpg"))
        #expect(!isImageEntry("__MACOSX/._page1.jpg"))
    }

    @Test func usesLeafNameForNestedEntries() {
        #expect(isImageEntry("vol1/ch2/page3.png"))
        #expect(isImageEntry("vol1\\ch2\\page3.png"))
        #expect(!isImageEntry("vol1/.thumbs/.cover.png"))
    }
}
