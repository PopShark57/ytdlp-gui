import SwiftUI

/// One row in the download queue.
struct QueueRowView: View {
    @Environment(AppModel.self) private var model
    let item: DownloadItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ThumbnailView(
                url: item.thumbnailURL,
                width: 96,
                height: 54,
                placeholderSymbol: item.options.kind.symbolName
            )
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                titleRow
                statusRow
                progressRow
                if let failure = item.failure, item.state == .failed {
                    failureRow(failure)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actionButtons
                .padding(.top, 2)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Rows

    private var titleRow: some View {
        HStack(spacing: 6) {
            Text(item.displayTitle)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            if item.isPlaylist {
                StatusPill(text: "playlist", systemImage: "list.number", tone: .accent)
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            Image(systemName: item.phase.symbolName)
                .foregroundStyle(phaseColor)
                .imageScale(.small)
                .accessibilityHidden(true)

            Text(item.phase.displayName)
                .font(.callout)
                .foregroundStyle(phaseColor)

            Text("·")
                .foregroundStyle(.tertiary)

            Text(item.displaySubtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private var progressRow: some View {
        switch item.state {
        case .active:
            VStack(alignment: .leading, spacing: 4) {
                if let fraction = item.progress.fractionCompleted, !item.phase.isIndeterminate {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }

                HStack(spacing: 10) {
                    ForEach(activeStats, id: \.self) { stat in
                        Text(stat)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .lineLimit(1)
            }
            .padding(.top, 1)

        case .completed:
            HStack(spacing: 8) {
                if let name = item.outputURL?.lastPathComponent {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let size = Format.bytes(item.completedFileSize) {
                    Text(size)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

        case .queued, .cancelled, .failed:
            EmptyView()
        }
    }

    private func failureRow(_ failure: DownloadFailure) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(failure.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
            if let suggestion = failure.recoverySuggestion {
                Text(suggestion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 1)
    }

    // MARK: - Actions

    private var actionButtons: some View {
        HStack(spacing: 4) {
            if item.canRevealInFinder, let url = item.outputURL {
                iconButton("Reveal in Finder", "magnifyingglass") {
                    FinderIntegration.reveal(url)
                }
            }
            if item.canRetry {
                iconButton("Retry", "arrow.clockwise") {
                    model.queue.retry(item)
                }
            }
            if item.canCancel {
                iconButton("Cancel", "stop.circle") {
                    model.queue.cancel(item)
                }
            }
            iconButton("Show log", "text.alignleft") {
                model.showLog(for: item)
            }
            if item.state != .active {
                iconButton("Remove", "xmark") {
                    model.queue.remove(item)
                }
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

    // MARK: - Derived

    private var activeStats: [String] {
        var stats: [String] = []
        if let percent = item.progress.percentLabel, !item.phase.isIndeterminate {
            stats.append(percent)
        }
        if let size = item.progress.sizeLabel { stats.append(size) }
        if let speed = item.progress.speedLabel { stats.append(speed) }
        if let eta = item.progress.etaLabel { stats.append(eta + " left") }
        if let fragments = item.progress.fragmentLabel, item.progress.totalBytes == nil {
            stats.append(fragments)
        }
        if item.isPlaylist, let total = item.playlistCount, total > 0 {
            stats.append("item \(min(item.completedItemCount + 1, total)) of \(total)")
        }
        if stats.isEmpty, let name = item.progress.displayFilename { stats.append(name) }
        return stats
    }

    private var phaseColor: Color {
        switch item.state {
        case .completed: .green
        case .failed: .red
        case .cancelled: .secondary
        case .active: .primary
        case .queued: .secondary
        }
    }

    private var accessibilityLabel: String {
        var parts = [item.displayTitle, item.phase.displayName]
        if item.state == .active {
            if let percent = item.progress.percentLabel { parts.append(percent) }
            if let eta = item.progress.etaLabel { parts.append("\(eta) remaining") }
        }
        if let failure = item.failure { parts.append(failure.title) }
        return parts.joined(separator: ", ")
    }
}
