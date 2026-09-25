import SwiftUI

/// Every stream the site offers, grouped the way yt-dlp thinks about them.
///
/// This is for reference: the app chooses the best streams that play everywhere by itself. People
/// who want a particular one can pass its ID with `-f` in Custom Arguments, which is why the ID is
/// shown and can be copied.
struct FormatListView: View {
    let info: MediaInfo

    var body: some View {
        List {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.formats) { format in
                        FormatRow(format: format)
                    }
                }
            }
        }
        .navigationTitle("Formats")
        .navigationBarTitleDisplayMode(.inline)
        .readableContentWidth()
        .safeAreaInset(edge: .top, spacing: 0) {
            Text("The app picks the best streams that play everywhere. To choose one yourself, add -f and its ID to Custom Arguments.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.bar)
        }
    }

    private struct FormatGroup {
        var title: String
        var formats: [MediaFormat]
    }

    private var groups: [FormatGroup] {
        let formats = info.displayFormats
        return [
            FormatGroup(title: "Video and Audio", formats: formats.filter(\.isCombined)),
            FormatGroup(title: "Video Only", formats: formats.filter(\.isVideoOnly)),
            FormatGroup(title: "Audio Only", formats: formats.filter(\.isAudioOnly)),
            // Many sites don't report codecs, so their streams can't be classified.
            FormatGroup(title: "Other", formats: formats.filter { !$0.isCombined && !$0.isVideoOnly && !$0.isAudioOnly }),
        ]
        .filter { !$0.formats.isEmpty }
    }
}

private struct FormatRow: View {
    let format: MediaFormat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(format.qualityLabel)
                    .font(.body.weight(.medium))
                    .monospacedDigit()
                Text(details)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("ID \(format.id)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if let size = format.sizeLabel {
                Text(size)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button {
                TextCopier.copy(format.id)
            } label: {
                Label("Copy Format ID", systemImage: "doc.on.doc")
            }
        }
    }

    private var details: String {
        var parts: [String] = []
        if !format.codecLabel.isEmpty { parts.append(format.codecLabel) }
        if let ext = format.ext { parts.append(ext.uppercased()) }
        if let range = format.dynamicRange, range != "SDR" { parts.append(range) }
        if let note = format.note, !note.isEmpty, note != format.qualityLabel { parts.append(note) }
        if let language = format.language, !language.isEmpty { parts.append(language) }
        return parts.isEmpty ? "No details reported" : parts.joined(separator: " · ")
    }
}

/// The videos in a playlist, as far as the site listed them.
struct PlaylistEntriesView: View {
    let info: MediaInfo

    var body: some View {
        List {
            Section {
                ForEach(info.playlistEntries) { entry in
                    PlaylistEntryRow(entry: entry)
                }
            } footer: {
                if let total = info.playlistCount, total > info.playlistEntries.count {
                    Text("Showing \(info.playlistEntries.count.formatted()) of \(total.formatted()) items.")
                }
            }
        }
        .navigationTitle(info.title)
        .navigationBarTitleDisplayMode(.inline)
        .readableContentWidth()
    }
}

private struct PlaylistEntryRow: View {
    let entry: PlaylistEntry

    var body: some View {
        ThumbnailRowLayout(thumbnailWidth: 88) {
            ThumbnailView(url: entry.thumbnailURL, placeholderSymbol: "film", cornerRadius: 6)
        } content: {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                if !details.isEmpty {
                    Text(details)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.index). \(entry.title)")
        .accessibilityValue(details)
        .contextMenu {
            if let url = entry.url {
                Button {
                    TextCopier.copy(url)
                } label: {
                    Label("Copy Link", systemImage: "link")
                }
            }
        }
    }

    private var details: String {
        var parts = ["#\(entry.index)"]
        if let duration = Format.duration(entry.duration) { parts.append(duration) }
        if let uploader = entry.uploader, !uploader.isEmpty { parts.append(uploader) }
        return parts.joined(separator: " · ")
    }
}
