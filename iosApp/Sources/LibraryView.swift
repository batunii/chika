import SwiftUI

/// Root screen: imported comics + import button. The pipeline demo stays reachable from the
/// toolbar until ML detection lands on iOS.
struct LibraryView: View {
    @StateObject private var library = LibraryStore()
    @State private var showPicker = false

    var body: some View {
        NavigationStack {
            Group {
                if library.comics.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "books.vertical")
                            .font(.system(size: 44))
                            .foregroundColor(.secondary)
                        Text("No comics yet")
                            .font(.headline)
                        Text("Tap + to import a CBZ from Files")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } else {
                    List {
                        ForEach(library.comics, id: \.self) { url in
                            NavigationLink(value: url) {
                                Label(
                                    url.deletingPathExtension().lastPathComponent,
                                    systemImage: "book.closed"
                                )
                                .lineLimit(2)
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets { library.delete(library.comics[index]) }
                        }
                    }
                }
            }
            .navigationTitle("Chika")
            .navigationDestination(for: URL.self) { url in
                ReaderView(comicURL: url)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showPicker = true } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    NavigationLink {
                        PipelineDemoView()
                    } label: {
                        Image(systemName: "rectangle.split.2x2")
                    }
                }
            }
            .sheet(isPresented: $showPicker) {
                DocumentPicker { urls in
                    for url in urls { library.importComic(from: url) }
                }
            }
        }
    }
}
