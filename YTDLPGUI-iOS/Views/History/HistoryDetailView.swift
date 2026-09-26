import QuickLook
import SwiftUI

/// One history entry in full, with everything that can be done with it.
struct HistoryDetailView: View {
    let entryID: HistoryEntry.ID

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var previewFiles: [URL] = []
    @State private var photoError: String?
    /// The files Photos can take, worked out off the main actor when the screen appears.
    @State private var photoFiles: [URL]?
    /// Keeps the entry on screen while the view animates away after it was removed.
    @State private var retainedEntry: HistoryEntry?

    private var entry: HistoryEntry? {
        model.history.entries.first { $0.id == entryID } ?? retainedEntry
    }

    var body: some View {
        Group {
            if let entry {
                list(for: entry)
                    .navigationTitle(entry.title)
            } else {
                ContentUnavailableView(
                    "Removed from History",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("This download is no longer in the history.")
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .quickLookFiles($previewFiles)
        .modifier(PhotoSaveErrorAlert(errorMessage: $photoError))
        .onAppear {
            retainedEntry = model.history.entries.first { $0.id == entryID }
        }
        .task(id: entryID) {
            guard let entry else { return }
            photoFiles = await MediaLibrary.photosCompatibleFiles(among: entry.existingOutputURLs)
        }
    }

    private func list(for entry: HistoryEntry) -> some View {
        let files = entry.outputURLs
        let existingFiles = entry.existingOutputURLs
        return List {
            Section {
                header(for: entry)
            }

            if !entry.succeeded {
                Section("Problem") {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.failureTitle ?? "Download failed")
                                .font(.headline)
                            if let detail = entry.failureDetail {
                                Text(detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }

            Section("Details") {
                LabeledContent("Date", value: Format.absoluteDate(entry.date))
                LabeledContent("Format", value: entry.formatSummary)
                if let size = Format.bytes(entry.fileSizeBytes) {
                    LabeledContent("Size", value: size)
                }
                if let duration = Format.duration(entry.durationSeconds) {
                    LabeledContent("Length", value: duration)
                }
                if files.count <= 1, let name = entry.fileName {
                    LabeledContent("File") {
                        Text(name)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }
                if entry.succeeded, let warning = MissingFiles.warning(missing: files.count - existingFiles.count, of: files.count) {
                    WarningRow(message: warning + " Download again to get a new copy.")
                }
                LabeledContent("Link") {
                    Text(URLDetection.displayString(for: entry.sourceURL))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }

            if files.count > 1 {
                Section("Files (\(files.count))") {
                    ForEach(files, id: \.self) { file in
                        FileNameRow(url: file, isMissing: !existingFiles.contains(file))
                    }
                }
            }

            Section {
                HistoryEntryActionItems(
                    entry: entry,
                    photoFiles: photoFiles,
                    onOpen: { previewFiles = $0 },
                    onSaveToPhotos: saveToPhotos,
                    onDelete: {
                        dismiss()
                        model.history.remove(entry)
                    }
                )
            }
        }
        .readableContentWidth()
    }

    private func header(for entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ThumbnailView(url: entry.thumbnailURL, placeholderSymbol: entry.kind.symbolName, cornerRadius: 12)
                .frame(maxWidth: 480)
            Text(entry.title)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
            Label(
                entry.succeeded ? "Downloaded" : "Failed",
                systemImage: entry.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .font(.subheadline.weight(.medium))
            .foregroundStyle(entry.succeeded ? .green : .red)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func saveToPhotos(_ files: [URL]) {
        saveHistoryFilesToPhotos(files, model: model, errorMessage: $photoError)
    }
}
