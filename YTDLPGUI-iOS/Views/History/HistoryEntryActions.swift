import SwiftUI
import UIKit

/// Everything that can be done with a history entry, as rows or menu items.
///
/// Used for both the context menu in the list and the actions on the detail screen, so the two
/// always offer the same things under the same conditions.
struct HistoryEntryActionItems: View {
    let entry: HistoryEntry
    var onOpen: (URL) -> Void
    var onSaveToPhotos: (URL) -> Void
    var onDelete: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        if let url = entry.existingOutputURL {
            Button {
                onOpen(url)
            } label: {
                Label("Open", systemImage: "eye")
            }
            ShareLink(item: url) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            if model.library.canSaveToPhotos(url) {
                Button {
                    onSaveToPhotos(url)
                } label: {
                    Label("Save to Photos", systemImage: "photo.badge.plus")
                }
            }
        }

        Button {
            model.downloadAgain(entry)
        } label: {
            Label("Download Again", systemImage: "arrow.down.circle")
        }

        Button {
            model.loadIntoComposer(entry)
        } label: {
            Label("Edit Options and Download", systemImage: "slider.horizontal.3")
        }

        Button {
            TextCopier.copy(entry.sourceURL)
            model.composer.showStatus("Link copied.")
        } label: {
            Label("Copy Link", systemImage: "link")
        }

        Button(role: .destructive, action: onDelete) {
            Label("Remove from History", systemImage: "trash")
        }
    }
}

/// Explains why saving to Photos failed, with a way into Settings for permission problems.
struct PhotoSaveErrorAlert: ViewModifier {
    @Binding var errorMessage: String?
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content
            .alert(
                "Couldn't Save to Photos",
                isPresented: Binding {
                    errorMessage != nil
                } set: { isPresented in
                    if !isPresented { errorMessage = nil }
                },
                presenting: errorMessage
            ) { _ in
                Button("OK", role: .cancel) {}
                if let settings = URL(string: UIApplication.openSettingsURLString) {
                    Button("Open Settings") { openURL(settings) }
                }
            } message: { message in
                Text(message)
            }
    }
}
