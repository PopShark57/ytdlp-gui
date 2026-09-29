import SwiftUI

/// Video or audio, and the quality or format that goes with it.
struct ModeSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var options: DownloadOptions { model.composer.options }

    var body: some View {
        @Bindable var composer = model.composer

        Section {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Choose your format").font(.headline)
                    Spacer()
                    Text("02")
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: 12))
                    : AnyLayout(HStackLayout(spacing: 12))
                layout {
                    ForEach(DownloadKind.allCases) { kind in
                        formatButton(kind)
                    }
                }
            }
            .padding(.vertical, 8)

            switch composer.options.kind {
            case .video:
                Picker(selection: $composer.options.videoQuality) {
                    ForEach(VideoQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                } label: {
                    Label("Quality", systemImage: "sparkles.tv")
                }
            case .audio:
                Picker(selection: $composer.options.audioFormat) {
                    ForEach(audioFormats) { format in
                        Text(format.displayName).tag(format)
                    }
                } label: {
                    Label("Format", systemImage: "waveform")
                }

                if composer.options.audioFormat.supportsQuality {
                    Picker(selection: $composer.options.audioQuality) {
                        ForEach(AudioQuality.allCases) { quality in
                            Text(quality.displayName).tag(quality)
                        }
                    } label: {
                        Label("Bitrate", systemImage: "dial.medium")
                    }
                }
            }
        } footer: {
            Text(footer)
        }
    }

    private func formatButton(_ kind: DownloadKind) -> some View {
        let selected = options.kind == kind
        return Button {
            model.composer.options.kind = kind
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: kind == .video ? "play.rectangle.fill" : "waveform")
                        .font(.title2)
                    Spacer(minLength: 4)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.body)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.displayName).font(.headline)
                    Text(kind == .video ? "Picture & sound" : "Just the audio")
                        .font(.caption)
                        .foregroundStyle(selected ? MobileTheme.accent : Color.secondary)
                }
            }
            .foregroundStyle(selected ? MobileTheme.accent : .primary)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? MobileTheme.accent.opacity(0.12) : MobileTheme.canvas,
                        in: .rect(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(selected ? MobileTheme.accent.opacity(0.7) : MobileTheme.accent.opacity(0.12),
                                  lineWidth: selected ? 1.5 : 1)
            }
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.displayName)
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("format-\(kind.rawValue)")
    }

    /// The formats this device can produce, plus the current choice if it isn't one of them (an
    /// older saved choice such as MP3), so the picker never has a selection it can't show. The
    /// advisories explain what happens to it.
    private var audioFormats: [AudioFormat] {
        var formats = model.composer.availableAudioFormats
        if !formats.contains(options.audioFormat) {
            formats.append(options.audioFormat)
        }
        return formats
    }

    private var footer: String {
        switch options.kind {
        case .video:
            var text = "Saved as MP4 — plays everywhere on iPhone, iPad and Mac."
            if let available = model.composer.analysis.info?.maximumHeight,
               let requested = options.videoQuality.maxHeight,
               requested > available {
                text += " This source offers up to \(available)p, so you'll get the closest match."
            }
            return text
        case .audio:
            return options.audioFormat.helpText
        }
    }
}
