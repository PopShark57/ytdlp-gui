import SwiftUI

/// The result of analysing a link: what it is, what's on offer, or why it couldn't be read.
struct AnalysisSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.composer.analysis {
        case .idle:
            EmptyView()
        case .analyzing:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Getting details…")
                        Text("Playlists and slow sites can take a few seconds.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }
        case .loaded(let info):
            MediaInfoSection(info: info)
        case .failed(let failure):
            AnalysisFailureSection(failure: failure)
        }
    }
}

// MARK: - Loaded

/// What yt-dlp found at the link.
private struct MediaInfoSection: View {
    let info: MediaInfo

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Section {
            header

            if let uploader = info.displayUploader {
                detailRow("Uploader", value: uploader, systemImage: "person.crop.circle")
            }
            if let duration = Format.duration(info.duration) {
                detailRow(info.isPlaylist ? "Total Length" : "Duration", value: duration, systemImage: "clock")
            }
            if let resolution = info.resolutionLabel {
                detailRow("Resolution", value: resolution, systemImage: "aspectratio")
            }
            if let date = info.uploadDate {
                detailRow("Published", value: Format.mediumDate(date), systemImage: "calendar")
            }
            if let views = Format.compactCount(info.viewCount) {
                detailRow("Views", value: views, systemImage: "eye")
            }
            if let site = siteName(for: info) {
                detailRow("Site", value: site, systemImage: "globe")
            }

            if info.isPlaylist, !info.playlistEntries.isEmpty {
                NavigationLink {
                    PlaylistEntriesView(info: info)
                } label: {
                    detailRow(
                        "Playlist Items",
                        value: (info.playlistCount ?? info.playlistEntries.count).formatted(),
                        systemImage: "list.number"
                    )
                }
            }

            if !info.displayFormats.isEmpty {
                NavigationLink {
                    FormatListView(info: info)
                } label: {
                    detailRow("Formats", value: info.displayFormats.count.formatted(), systemImage: "square.stack.3d.up")
                }
            }

            if !info.subtitleLanguages.isEmpty {
                detailRow("Subtitles", value: summarize(info.subtitleLanguages), systemImage: "captions.bubble")
            }
            if !info.automaticCaptionLanguages.isEmpty {
                detailRow(
                    "Auto Captions",
                    value: languageCount(info.automaticCaptionLanguages.count),
                    systemImage: "text.bubble"
                )
            }
            if info.chapterCount > 0 {
                detailRow("Chapters", value: info.chapterCount.formatted(), systemImage: "list.bullet.indent")
            }
        } header: {
            Text(info.isPlaylist ? "Playlist" : "Details")
        }
    }

    private var header: some View {
        let isWide = horizontalSizeClass == .regular
        let layout = isWide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 12))

        return layout {
            ThumbnailView(
                url: info.thumbnailURL,
                placeholderSymbol: info.isPlaylist ? "list.and.film" : "film",
                cornerRadius: 10
            )
            .frame(maxWidth: isWide ? 240 : .infinity)

            VStack(alignment: .leading, spacing: 8) {
                Text(info.title)
                    .font(.headline)
                    .lineLimit(3)
                    .textSelection(.enabled)

                if !badges.isEmpty {
                    FlowLayout {
                        ForEach(badges, id: \.text) { badge in
                            StatusBadge(text: badge.text, systemImage: badge.symbol, tint: badge.tint)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private struct Badge {
        var text: String
        var symbol: String
        var tint: Color
    }

    private var badges: [Badge] {
        var badges: [Badge] = []
        if info.isLive {
            badges.append(Badge(text: "Live", symbol: "dot.radiowaves.left.and.right", tint: .red))
        }
        if info.isPlaylist {
            let count = info.playlistCount ?? info.playlistEntries.count
            badges.append(Badge(text: count == 1 ? "1 item" : "\(count.formatted()) items", symbol: "list.number", tint: .accentColor))
        }
        if (info.ageLimit ?? 0) >= 18 {
            badges.append(Badge(text: "18+", symbol: "exclamationmark.shield", tint: .orange))
        }
        return badges
    }

    /// The site's own domain ("youtube.com") reads better than yt-dlp's extractor key
    /// ("Youtube"), which is the fallback when the page address is unknown.
    private func siteName(for info: MediaInfo) -> String? {
        if let host = info.webpageURL?.host(), !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return info.extractor
    }

    private func detailRow(_ title: String, value: String, systemImage: String) -> some View {
        LabeledContent {
            Text(value)
                .multilineTextAlignment(.trailing)
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    private func summarize(_ languages: [String]) -> String {
        if languages.count <= 4 { return languages.joined(separator: ", ") }
        return languages.prefix(3).joined(separator: ", ") + " and \(languages.count - 3) more"
    }

    private func languageCount(_ count: Int) -> String {
        count == 1 ? "1 language" : "\(count.formatted()) languages"
    }
}

// MARK: - Failed

/// Why the link couldn't be read, what to try, and yt-dlp's own words for those who want them.
private struct AnalysisFailureSection: View {
    let failure: DownloadFailure

    @Environment(AppModel.self) private var model
    @State private var showsDetails = false

    var body: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(failure.title)
                        .font(.headline)
                    if let message = failure.underlyingMessage {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .textSelection(.enabled)
                    }
                }
            } icon: {
                Image(systemName: failure.symbolName)
                    .foregroundStyle(.red)
            }

            if let suggestion = failure.recoverySuggestion {
                Text(suggestion)
                    .font(.subheadline)
            }

            Button {
                model.composer.analyze()
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            .disabled(!model.composer.canAnalyze || !model.engine.isReady)

            Button {
                showsDetails = true
            } label: {
                Label("Show Details", systemImage: "text.alignleft")
            }
            .disabled(model.composer.analysisLog.isEmpty)
            .sheet(isPresented: $showsDetails) {
                AnalysisLogSheet(lines: model.composer.analysisLog)
            }
        } header: {
            Text("Couldn't Get Details")
        }
    }
}

/// yt-dlp's output from the failed analysis.
private struct AnalysisLogSheet: View {
    let lines: [String]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LogConsoleView(lines: lines, totalLineCount: lines.count, title: "Analysis")
                .navigationTitle("Details")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
