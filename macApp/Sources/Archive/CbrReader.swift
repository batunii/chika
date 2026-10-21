import Foundation
import libarchive

/// Minimal read-only archive reader over libarchive's C API. We use the raw C library (not the
/// SwiftArchive wrapper) because we only need to read CBR/RAR entries; libarchive's BSD-licensed
/// RAR5 reader is compiled in via archive_read_support_format_all.
enum CbrReader {
    enum CbrError: LocalizedError {
        case open, read
        var errorDescription: String? {
            switch self {
            case .open: return "Could not open the archive"
            case .read: return "Could not read the archive"
            }
        }
    }

    /// Streams every regular-file entry whose name passes `keep` into its own file in `dir`, 64 KB
    /// at a time, so a big archive never sits in memory. Ordering is the caller's job.
    static func extract(at url: URL, into dir: URL, keep: (String) -> Bool) throws -> [(name: String, file: URL)] {
        guard let handle = archive_read_new() else { throw CbrError.open }
        defer { archive_read_free(handle) }
        _ = archive_read_support_format_all(handle)
        _ = archive_read_support_filter_all(handle)

        let openRc = url.path.withCString { archive_read_open_filename(handle, $0, 64 * 1024) }
        guard openRc == ARCHIVE_OK || openRc == ARCHIVE_WARN else { throw CbrError.open }

        var results: [(name: String, file: URL)] = []
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var entryPtr: OpaquePointer?
        while true {
            let rc = archive_read_next_header(handle, &entryPtr)
            if rc == ARCHIVE_EOF { break }
            guard rc == ARCHIVE_OK || rc == ARCHIVE_WARN, let entry = entryPtr else { throw CbrError.read }

            // AE_IFREG (0o100000) within the type mask (0o170000): regular files only.
            let isRegular = (UInt32(archive_entry_filetype(entry)) & 0o170000) == 0o100000
            var name = ""
            if let c = archive_entry_pathname(entry) { name = String(validatingUTF8: c) ?? "" }
            guard isRegular, !name.isEmpty, keep(name) else { _ = archive_read_data_skip(handle); continue }

            // Named by index, never by the entry path, so a "../" entry can't write outside `dir`.
            let file = dir.appendingPathComponent(String(results.count))
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw CbrError.read }
            let out = try FileHandle(forWritingTo: file)
            defer { try? out.close() }
            while true {
                let n = buffer.withUnsafeMutableBytes { archive_read_data(handle, $0.baseAddress, $0.count) }
                if n == 0 { break }
                guard n > 0 else { throw CbrError.read }
                try out.write(contentsOf: buffer[0..<n])
            }
            results.append((name, file))
        }
        return results
    }
}
