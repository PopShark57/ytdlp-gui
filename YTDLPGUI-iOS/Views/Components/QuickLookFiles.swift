import QuickLook
import SwiftUI

extension View {
    /// Previews `files` in Quick Look, starting with the first, whenever it is set to a non-empty
    /// list; swiping moves between them. Dismissing the preview empties the list again.
    func quickLookFiles(_ files: Binding<[URL]>) -> some View {
        modifier(QuickLookFiles(files: files))
    }
}

/// Quick Look over several files, such as every video of a playlist.
///
/// `quickLookPreview(_:in:)` shows the files in `in:` starting at the selection, and treats a
/// selection that isn't among them as none. So the files are set first and the selection
/// follows them.
private struct QuickLookFiles: ViewModifier {
    @Binding var files: [URL]
    @State private var selection: URL?

    func body(content: Content) -> some View {
        content
            .quickLookPreview($selection, in: files)
            .onChange(of: files) { _, files in
                selection = files.first
            }
            .onChange(of: selection) { _, selection in
                if selection == nil, !files.isEmpty {
                    files = []
                }
            }
    }
}
