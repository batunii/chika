/// A folder of page images read as one comic, from the names of its entries (files and subfolders).
public enum ImageFolder {
    /// The pages among a folder's entry names, in reading order.
    public static func pages(_ names: [String]) -> [String] {
        names.filter(isImageEntry).sorted(by: NaturalOrder.isOrderedBefore)
    }

    /// Whether a folder with these entries is one comic: at least one image and nothing else but hidden
    /// files, so a folder of archives, of chapter folders or of mixed files is not.
    public static func isComic(_ names: [String]) -> Bool {
        let visible = names.filter { !$0.hasPrefix(".") }
        return !visible.isEmpty && visible.allSatisfy(isImageEntry)
    }
}
