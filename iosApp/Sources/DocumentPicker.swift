import SwiftUI
import UniformTypeIdentifiers

/// System file picker for CBZ/ZIP archives. asCopy means iOS hands us our own temporary copy, so
/// no security-scoped bookmark bookkeeping is needed — the library moves it into app storage.
struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        var types: [UTType] = [.zip]
        if let cbz = UTType(filenameExtension: "cbz") { types.append(cbz) }
        if let cbr = UTType(filenameExtension: "cbr") { types.append(cbr) }
        if let rar = UTType(filenameExtension: "rar") { types.append(rar) }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
    }
}
