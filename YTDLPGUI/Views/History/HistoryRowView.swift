import SwiftUI

struct HistoryRowView: View {
    let entry: HistoryEntry
    var status: HistoryFileStatus?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ThumbnailView(
                url: entry.thumbnailURL,
                width: 80,
                height: 45,
                placeholderSymbol: entry.options?.backend == .galleryDL ? "photo.stack" : entry.kind.symbolName
            )
            .padding(.top, 2)
            .opacity(entry.succeeded ? 1 : 0.55)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(entry.succeeded ? Color.green : Color.red)
                        .imageScale(.small)
                        .accessibilityHidden(true)

                    Text(entry.title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 8) {
                    Text(Format.relativeDate(entry.date))
                    Text("·")
                    Text(entry.formatSummary)
                    if let size = Format.bytes(entry.fileSizeBytes) {
                        Text("·")
                        Text(size).monospacedDigit()
                    }
                    if let duration = Format.duration(entry.durationSeconds) {
                        Text("·")
                        Text(duration).monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if entry.succeeded {
                    successDetail
                    if let notice = entry.fileListNotice { Text(notice).font(.caption) }
                } else {
                    failureDetail
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actions
                .padding(.top, 2)
        }
        .padding(.vertical, 7)
        .help(entry.sourceURL)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var successDetail: some View {
        if let path = entry.outputPath {
            HStack(spacing: 5) {
                Image(systemName: status?.isMissing != true ? "doc" : "doc.badge.ellipsis")
                    .imageScale(.small)
                    .foregroundStyle(status?.isMissing != true ? Color.secondary : Color.orange)
                Text(displayPath(path))
                    .font(.caption)
                    .foregroundStyle(status?.isMissing != true ? Color.secondary : Color.orange)
                    .lineLimit(1)
                    .truncationMode(.head)
                if let status, status.missingCount > 0 {
                    Text(status.recordedCount == 1 ? "File moved or deleted" : "\(status.missingCount) listed files missing")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private var failureDetail: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let title = entry.failureTitle {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
            }
            if let detail = entry.failureDetail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            if let files = status?.existingURLs, !files.isEmpty {
                iconButton("Reveal in Finder", "magnifyingglass") {
                    FinderIntegration.reveal(files)
                }
            }
            iconButton("Copy source URL", "link") {
                Pasteboard.copy(entry.sourceURL)
            }
        }
    }

    private func iconButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
    }

    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private var accessibilityLabel: String {
        var parts = [entry.title, entry.succeeded ? "completed" : "failed", Format.relativeDate(entry.date)]
        if let failureTitle = entry.failureTitle { parts.append(failureTitle) }
        return parts.joined(separator: ", ")
    }
}
