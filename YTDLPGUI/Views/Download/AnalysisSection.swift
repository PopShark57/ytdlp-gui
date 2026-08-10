import SwiftUI

/// Shows the result of analysing a URL: metadata, playlist contents, or the reason it failed.
struct AnalysisSection: View {
    @Environment(AppModel.self) private var model

    private var composer: DownloadComposer { model.composer }

    var body: some View {
        switch composer.analysis {
        case .idle:
            EmptyView()
        case .analyzing:
            loadingCard
        case .loaded(let info):
            MediaInfoCard(info: info)
        case .failed(let failure):
            AdvisoryBanner(
                kind: .error,
                title: failure.title,
                message: [failure.underlyingMessage, failure.recoverySuggestion]
                    .compactMap { $0 }
                    .joined(separator: "\n\n"),
                actionTitle: "Try Again"
            ) {
                composer.analyze()
            }
        }
    }

    private var loadingCard: some View {
        SectionCard {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Asking yt-dlp about this address…")
                        .font(.callout)
                    Text("Playlists and slow sites can take a few seconds.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }
}

/// The metadata card shown after a successful analysis.
struct MediaInfoCard: View {
    let info: MediaInfo
    @State private var showAllFormats = false
    @State private var showPlaylistItems = false

    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 14) {
                header

                if !metadataRows.isEmpty {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)],
                        alignment: .leading,
                        spacing: 6
                    ) {
                        ForEach(metadataRows, id: \.label) { row in
                            MetadataRow(label: row.label, value: row.value, systemImage: row.symbol)
                        }
                    }
                }

                if info.isPlaylist, !info.playlistEntries.isEmpty {
                    playlistSection
                }

                if !info.displayFormats.isEmpty {
                    formatsSection
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ThumbnailView(
                url: info.thumbnailURL,
                width: 160,
                height: 90,
                cornerRadius: 8,
                placeholderSymbol: info.isPlaylist ? "list.and.film" : "film"
            )

            VStack(alignment: .leading, spacing: 6) {
                Text(info.title)
                    .font(.headline)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if let uploader = info.displayUploader {
                    Label(uploader, systemImage: "person.crop.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    if info.isPlaylist {
                        StatusPill(
                            text: "\(info.playlistCount ?? info.playlistEntries.count) items",
                            systemImage: "list.number",
                            tone: .accent
                        )
                    }
                    if info.isLive {
                        StatusPill(text: "Live", systemImage: "dot.radiowaves.left.and.right", tone: .negative)
                    }
                    if let extractor = info.extractor {
                        StatusPill(text: extractor, systemImage: "globe")
                    }
                    if (info.ageLimit ?? 0) >= 18 {
                        StatusPill(text: "18+", systemImage: "exclamationmark.shield", tone: .warning)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Metadata

    private struct Row {
        var label: String
        var value: String
        var symbol: String
    }

    private var metadataRows: [Row] {
        var rows: [Row] = []
        if let duration = Format.duration(info.duration) {
            rows.append(Row(label: "Duration", value: duration, symbol: "clock"))
        }
        if let resolution = info.resolutionLabel {
            rows.append(Row(label: "Resolution", value: resolution, symbol: "rectangle.on.rectangle"))
        }
        if let date = info.uploadDate {
            rows.append(Row(label: "Published", value: Format.mediumDate(date), symbol: "calendar"))
        }
        if let views = Format.compactCount(info.viewCount) {
            rows.append(Row(label: "Views", value: views, symbol: "eye"))
        }
        if info.chapterCount > 0 {
            rows.append(Row(label: "Chapters", value: "\(info.chapterCount)", symbol: "list.bullet.indent"))
        }
        if !info.subtitleLanguages.isEmpty {
            rows.append(Row(
                label: "Subtitles",
                value: summarize(info.subtitleLanguages),
                symbol: "captions.bubble"
            ))
        }
        if !info.automaticCaptionLanguages.isEmpty {
            rows.append(Row(
                label: "Auto captions",
                value: "\(info.automaticCaptionLanguages.count) languages",
                symbol: "text.bubble"
            ))
        }
        return rows
    }

    private func summarize(_ languages: [String]) -> String {
        if languages.count <= 4 { return languages.joined(separator: ", ") }
        return languages.prefix(3).joined(separator: ", ") + " +\(languages.count - 3) more"
    }

    // MARK: - Playlist

    private var playlistSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: $showPlaylistItems) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(info.playlistEntries.prefix(50)) { entry in
                        HStack(spacing: 8) {
                            Text("\(entry.index)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 28, alignment: .trailing)
                            Text(entry.title)
                                .font(.callout)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if let duration = Format.duration(entry.duration) {
                                Text(duration)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    if info.playlistEntries.count > 50 {
                        Text("…and \(info.playlistEntries.count - 50) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Playlist contents")
                    .font(.subheadline.weight(.medium))
            }
        }
    }

    // MARK: - Formats

    private var formatsSection: some View {
        DisclosureGroup(isExpanded: $showAllFormats) {
            VStack(spacing: 0) {
                ForEach(Array(info.displayFormats.prefix(showAllFormats ? 40 : 0).enumerated()), id: \.element.id) { index, format in
                    HStack(spacing: 10) {
                        Text(format.qualityLabel)
                            .font(.callout.monospacedDigit())
                            .frame(width: 78, alignment: .leading)

                        Text(format.ext?.uppercased() ?? "—")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .leading)

                        Text(format.codecLabel.isEmpty ? "—" : format.codecLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        if format.isVideoOnly {
                            StatusPill(text: "video only", tone: .neutral)
                        } else if format.isAudioOnly {
                            StatusPill(text: "audio only", tone: .neutral)
                        }

                        if let size = format.sizeLabel {
                            Text(size)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .trailing)
                        }
                    }
                    .padding(.vertical, 4)

                    if index < info.displayFormats.prefix(40).count - 1 {
                        Divider()
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Text("Available formats")
                    .font(.subheadline.weight(.medium))
                Text("\(info.displayFormats.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
