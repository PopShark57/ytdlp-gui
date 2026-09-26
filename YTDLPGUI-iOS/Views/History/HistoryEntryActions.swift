import SwiftUI
import UIKit

/// Everything that can be done with a history entry, as rows or menu items.
///
/// Used for both the context menu in the list and the actions on the detail screen, so the two
/// always offer the same things under the same conditions.
struct HistoryEntryActionItems: View {
    let entry: HistoryEntry
    /// The files Photos can take, when the caller has worked them out (the detail screen does,
    /// in a task). Otherwise saving is offered for any video or picture, and the files are
    /// checked when saving.
    var photoFiles: [URL]?
    /// Shows the files in Quick Look.
    var onOpen: ([URL]) -> Void
    var onSaveToPhotos: ([URL]) -> Void
    var onDelete: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        let files = model.history.existingFiles(of: entry)
        if !files.isEmpty {
            Button {
                onOpen(files)
            } label: {
                Label("Open", systemImage: "eye")
            }
            ShareLink(items: files) {
                Label(files.count > 1 ? "Share \(files.count) Files" : "Share", systemImage: "square.and.arrow.up")
            }
            let photos = photoFiles ?? files.filter { MediaLibrary.isPhotosMediaType($0) }
            if !photos.isEmpty {
                Button {
                    onSaveToPhotos(photos)
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

/// Saves a history entry's files to Photos and says how it went: a status message on success,
/// `errorMessage` (shown by `PhotoSaveErrorAlert`) on failure.
@MainActor
func saveHistoryFilesToPhotos(_ files: [URL], model: AppModel, errorMessage: Binding<String?>) {
    Task {
        do {
            let saved = try await model.library.saveToPhotos(files)
            model.composer.showStatus(saved > 1 ? "Saved \(saved) files to Photos." : "Saved to Photos.")
        } catch {
            errorMessage.wrappedValue = error.localizedDescription
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
