import Testing
import ChikaCore

struct ImageFolderTests {
    @Test func pagesAreTheImagesInNaturalOrder() {
        #expect(ImageFolder.pages(["p10.jpg", ".DS_Store", "p2.PNG", "notes.txt", "p1.webp", "extras"]) == ["p1.webp", "p2.PNG", "p10.jpg"])
    }

    @Test func onlyAFolderOfNothingButImagesIsAComic() {
        #expect(ImageFolder.isComic(["01.jpg", "02.jpg", ".DS_Store"]))
        #expect(!ImageFolder.isComic(["01.jpg", "Chapter 2"]))        // a subfolder
        #expect(!ImageFolder.isComic(["01.jpg", "One.cbz"]))          // an archive
        #expect(!ImageFolder.isComic([".DS_Store"]))
        #expect(!ImageFolder.isComic([]))
    }
}
