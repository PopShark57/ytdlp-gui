import SwiftUI

/// One download in the queue: what it is, what it's doing and how far along it is.
struct QueueRowView: View {
    let item: DownloadItem

    var body: some View {
        ThumbnailRowLayout(thumbnailWidth: 88) {
            ThumbnailView(url: item.thumbnailURL, placeholderSymbol: item.options.kind.symbolName, cornerRadius: 6)
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle)
                    .font(.headline)
                    .lineLimit(2)
                Text(item.displaySubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                PhaseLabel(phase: item.phase, state: item.state)
                    .font(.subheadline)
                    .padding(.top, 1)

                stateDetail

                if let playlistProgress = item.playlistProgressLabel {
                    Text(playlistProgress)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.displayTitle)
        .accessibilityValue(item.accessibilityStatus)
    }

    @ViewBuilder
    private var stateDetail: some View {
        switch item.state {
        case .active:
            DownloadProgressBar(item: item)
            if let stats = item.progressStatsLine {
                Text(stats)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(2)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: stats)
            }
        case .completed:
            if let file = item.completedFileLine {
                Text(file)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .failed:
            if let failure = item.failure {
                Text(failure.title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.red)
            }
        case .queued, .cancelled:
            EmptyView()
        }
    }
}

/// Determinate while the size is known and bytes are moving; indeterminate while yt-dlp is
/// resolving, merging or otherwise working without a byte count.
struct DownloadProgressBar: View {
    let item: DownloadItem

    var body: some View {
        if let fraction = item.progress.fractionCompleted, !item.phase.isIndeterminate {
            ProgressView(value: fraction)
                .animation(.linear(duration: 0.2), value: fraction)
        } else {
            ProgressView()
                .progressViewStyle(.linear)
        }
    }
}

// MARK: - Derived text

extension DownloadItem {
    /// Percent · speed · time left · size, leaving out whatever isn't known yet.
    var progressStatsLine: String? {
        var parts: [String] = []
        if !phase.isIndeterminate, let percent = progress.percentLabel { parts.append(percent) }
        if let speed = progress.speedLabel { parts.append(speed) }
        if let eta = progress.etaLabel { parts.append("\(eta) left") }
        if let size = progress.sizeLabel { parts.append(size) }
        if parts.isEmpty, let fragments = progress.fragmentLabel { parts.append(fragments) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The finished file's name and size, or how many files there are for a playlist.
    var completedFileLine: String? {
        let files = outputURLs.count > 1 ? "\(outputURLs.count) files" : outputURL?.lastPathComponent
        let parts = [files, Format.bytes(completedFileSize)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Item 3 of 10" while a playlist downloads, "10 of 10 downloaded" afterwards.
    var playlistProgressLabel: String? {
        guard isPlaylist, let total = playlistCount, total > 0 else { return nil }
        switch state {
        case .active:
            return "Item \(min(completedItemCount + 1, total)) of \(total)"
        case .completed, .failed, .cancelled:
            return "\(completedItemCount) of \(total) downloaded"
        case .queued:
            return nil
        }
    }

    /// Everything the row shows, as one sentence for VoiceOver.
    var accessibilityStatus: String {
        var parts = [phase.displayName]
        switch state {
        case .active:
            if let stats = progressStatsLine { parts.append(stats) }
        case .completed:
            if let file = completedFileLine { parts.append(file) }
        case .failed:
            if let failure { parts.append(failure.title) }
        case .queued, .cancelled:
            break
        }
        if let playlistProgressLabel { parts.append(playlistProgressLabel) }
        return parts.joined(separator: ", ")
    }

    /// Every finished file still where the download left it, in the order they were finished.
    var existingOutputURLs: [URL] {
        guard state == .completed else { return [] }
        let files = outputURLs.isEmpty ? outputURL.map { [$0] } ?? [] : outputURLs
        return files.filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }
}
