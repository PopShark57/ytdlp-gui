import SwiftUI

/// One finished or failed download in the history.
struct HistoryRowView: View {
    let entry: HistoryEntry

    var body: some View {
        ThumbnailRowLayout(thumbnailWidth: 80) {
            ThumbnailView(url: entry.thumbnailURL, placeholderSymbol: entry.kind.symbolName, cornerRadius: 6)
                .opacity(entry.succeeded ? 1 : 0.6)
        } content: {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.headline)
                    .lineLimit(2)

                Text(entry.summaryLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(2)

                if !entry.succeeded {
                    Label(entry.failureTitle ?? "Download failed", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.red)
                } else if entry.isFileMissing {
                    Label("File moved or deleted", systemImage: "questionmark.folder")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.title)
        .accessibilityValue(entry.accessibilityStatus)
    }
}

extension HistoryEntry {
    /// When, in what format, and how big: "2 hr ago · 1080p · 48.2 MB".
    var summaryLine: String {
        var parts = [Format.relativeDate(date), formatSummary]
        if let size = Format.bytes(fileSizeBytes) { parts.append(size) }
        return parts.joined(separator: " · ")
    }

    /// A successful download whose file is no longer where it was saved.
    var isFileMissing: Bool {
        succeeded && !fileExists
    }

    /// The file, when it's still there to open or share.
    var existingOutputURL: URL? {
        fileExists ? outputURL : nil
    }

    var accessibilityStatus: String {
        var parts = [succeeded ? "Downloaded" : "Failed", summaryLine]
        if !succeeded, let failureTitle { parts.append(failureTitle) }
        if isFileMissing { parts.append("File moved or deleted") }
        return parts.joined(separator: ", ")
    }
}
