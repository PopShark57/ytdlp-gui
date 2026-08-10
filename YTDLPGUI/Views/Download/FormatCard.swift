import SwiftUI

/// Video / audio choice and the quality preset.
struct FormatCard: View {
    @Environment(AppModel.self) private var model

    private var availableHeight: Int? {
        model.composer.analysis.info?.maximumHeight
    }

    var body: some View {
        @Bindable var composer = model.composer

        SectionCard(title: "Format", systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 16) {
                Picker("", selection: $composer.options.kind) {
                    ForEach(DownloadKind.allCases) { kind in
                        Label(kind.displayName, systemImage: kind.symbolName)
                            .tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Download type")

                switch composer.options.kind {
                case .video: videoOptions(composer: composer)
                case .audio: audioOptions(composer: composer)
                }
            }
        }
    }

    // MARK: - Video

    @ViewBuilder
    private func videoOptions(composer: DownloadComposer) -> some View {
        @Bindable var composer = composer

        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Quality")
                    .font(.subheadline.weight(.medium))

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 92), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(VideoQuality.allCases) { quality in
                        QualityChip(
                            title: quality.shortName,
                            isSelected: composer.options.videoQuality == quality,
                            isUnavailable: isUnavailable(quality)
                        ) {
                            composer.options.videoQuality = quality
                        }
                        .help(helpText(for: quality))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Container")
                    .font(.subheadline.weight(.medium))

                Picker("Container", selection: $composer.options.container) {
                    ForEach(VideoContainer.allCases) { container in
                        Text(container.displayName).tag(container)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 200)
                .help(composer.options.container.helpText)
                .accessibilityLabel("Container format")

                Text(composer.options.container.helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Best video and best audio are downloaded separately and merged with ffmpeg whenever that gives a better result than a single pre-combined file.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func isUnavailable(_ quality: VideoQuality) -> Bool {
        guard let availableHeight, let requested = quality.maxHeight else { return false }
        return requested > availableHeight
    }

    private func helpText(for quality: VideoQuality) -> String {
        if isUnavailable(quality), let availableHeight {
            return "\(quality.displayName) — this source only offers up to \(availableHeight)p, so you'll get the closest match."
        }
        return quality.displayName
    }

    // MARK: - Audio

    @ViewBuilder
    private func audioOptions(composer: DownloadComposer) -> some View {
        @Bindable var composer = composer

        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Format")
                    .font(.subheadline.weight(.medium))

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 104), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(AudioFormat.allCases) { format in
                        QualityChip(
                            title: format.displayName,
                            isSelected: composer.options.audioFormat == format,
                            isUnavailable: format != .best && !model.toolchain.canMergeStreams
                        ) {
                            composer.options.audioFormat = format
                        }
                        .help(format.helpText)
                    }
                }
            }

            Text(composer.options.audioFormat.helpText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if composer.options.audioFormat.supportsQuality {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bitrate")
                        .font(.subheadline.weight(.medium))

                    Picker("Bitrate", selection: $composer.options.audioQuality) {
                        ForEach(AudioQuality.allCases) { quality in
                            Text(quality.displayName).tag(quality)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 200)
                    .help("Target bitrate for the converted audio")
                    .accessibilityLabel("Audio bitrate")
                }
            }
        }
    }
}

/// A selectable preset chip.
struct QualityChip: View {
    var title: String
    var isSelected: Bool
    var isUnavailable: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(background)
                .foregroundStyle(foreground)
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                            lineWidth: 1
                        )
                }
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(isUnavailable ? "\(title), not offered by this source" : title)
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor))
    }

    private var foreground: Color {
        if isSelected { return .primary }
        return isUnavailable ? .secondary : .primary
    }
}
