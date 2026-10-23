import Foundation

extension URL {
    /// The title a comic shows under: a file's name without its extension, a folder comic's whole
    /// name, so "Vol.01/" stays "Vol.01" rather than "Vol".
    public var comicTitle: String { hasDirectoryPath ? lastPathComponent : deletingPathExtension().lastPathComponent }
}
