import QuickLook
import SwiftUI

/// One history entry in full, with everything that can be done with it.
struct HistoryDetailView: View {
    let entryID: HistoryEntry.ID

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var quickLookURL: URL?
    @State private var photoError: String?
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
        .quickLookPreview($quickLookURL)
        .modifier(PhotoSaveErrorAlert(errorMessage: $photoError))
        .onAppear {
            retainedEntry = model.history.entries.first { $0.id == entryID }
        }
    }

    private func list(for entry: HistoryEntry) -> some View {
        List {
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
                if let name = entry.fileName {
                    LabeledContent("File") {
                        Text(name)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }
                if entry.isFileMissing {
                    WarningRow(message: "The file has been moved or deleted. Download it again to get a new copy.")
                }
                LabeledContent("Link") {
                    Text(URLDetection.displayString(for: entry.sourceURL))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }

            Section {
                HistoryEntryActionItems(
                    entry: entry,
                    onOpen: { quickLookURL = $0 },
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

    private func saveToPhotos(_ url: URL) {
        Task {
            do {
                try await model.library.saveToPhotos(url)
                model.composer.showStatus("Saved to Photos.")
            } catch {
                photoError = error.localizedDescription
            }
        }
    }
}
