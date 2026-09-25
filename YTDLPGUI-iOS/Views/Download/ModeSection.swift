import SwiftUI

/// Video or audio, and the quality or format that goes with it.
struct ModeSection: View {
    @Environment(AppModel.self) private var model

    private var options: DownloadOptions { model.composer.options }

    var body: some View {
        @Bindable var composer = model.composer

        Section {
            Picker("Download as", selection: $composer.options.kind) {
                ForEach(DownloadKind.allCases) { kind in
                    Label(kind.displayName, systemImage: kind.symbolName)
                        .tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Download as")

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
        } header: {
            Text("Format")
        } footer: {
            Text(footer)
        }
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
