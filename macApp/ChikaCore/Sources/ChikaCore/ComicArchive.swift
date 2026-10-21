import Foundation

/// File extensions we treat as comic page images.
private let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "bmp", "avif"]

/// True if `name` looks like an image entry we should render as a page.
public func isImageEntry(_ name: String) -> Bool {
    let clean = name.components(separatedBy: "/").last!.components(separatedBy: "\\").last!
    if clean.hasPrefix(".") || clean.hasPrefix("__MACOSX") { return false }
    let parts = clean.components(separatedBy: ".")
    let ext = parts.count > 1 ? parts.last!.lowercased() : ""
    return imageExtensions.contains(ext)
}
