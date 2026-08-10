import SwiftUI

/// Destination folder and filename template.
struct OutputCard: View {
    @Environment(AppModel.self) private var model
    @State private var showTemplateHelp = false

    var body: some View {
        @Bindable var composer = model.composer

        SectionCard(title: "Save to", systemImage: "folder") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(composer.options.outputDirectory.lastPathComponent)
                            .font(.callout.weight(.medium))
                        Text(displayPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .textSelection(.enabled)
                    }

                    Spacer(minLength: 8)

                    Button("Change…") { composer.chooseOutputDirectory() }
                        .help("Choose a different folder (⌘O)")

                    Button {
                        composer.revealOutputDirectory()
                    } label: {
                        Label("Open in Finder", systemImage: "arrow.up.forward.app")
                            .labelStyle(.iconOnly)
                    }
                    .help("Open this folder in Finder (⇧⌘O)")
                    .accessibilityLabel("Open output folder in Finder")
                }
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                }

                if !directoryIsWritable {
                    Label(
                        "This folder can't be written to. Choose another one before downloading.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                HStack(spacing: 8) {
                    TextField("File name template", text: $composer.options.outputTemplate)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                        .accessibilityLabel("Output file name template")

                    Menu {
                        ForEach(ArgumentBuilder.outputTemplatePresets) { preset in
                            Button {
                                composer.options.outputTemplate = preset.template
                            } label: {
                                Text(preset.name)
                                Text(preset.example)
                            }
                        }
                        Divider()
                        Button("Reset to Default") {
                            composer.options.outputTemplate = DownloadOptions.defaultOutputTemplate
                        }
                    } label: {
                        Label("Templates", systemImage: "textformat")
                            .labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Choose a ready-made naming pattern")
                    .accessibilityLabel("Filename template presets")
                }

                DisclosureGroup(isExpanded: $showTemplateHelp) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(templateHints, id: \.0) { token, meaning in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(token)
                                    .font(.caption.monospaced())
                                    .frame(width: 150, alignment: .leading)
                                Text(meaning)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Link(
                            "Full output template reference",
                            destination: URL(string: "https://github.com/yt-dlp/yt-dlp#output-template")!
                        )
                        .font(.caption)
                        .padding(.top, 4)
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Template placeholders")
                        .font(.caption)
                }
            }
        }
    }

    private var displayPath: String {
        let path = model.composer.options.outputDirectory.path(percentEncoded: false)
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private var directoryIsWritable: Bool {
        let path = model.composer.options.outputDirectory.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        // A folder that doesn't exist yet is fine: it gets created at download time.
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return true
        }
        return isDirectory.boolValue && FileManager.default.isWritableFile(atPath: path)
    }

    private var templateHints: [(String, String)] {
        [
            ("%(title)s", "Video title"),
            ("%(uploader)s", "Channel or uploader"),
            ("%(ext)s", "File extension — always include this"),
            ("%(id)s", "Site's own video ID"),
            ("%(upload_date>%Y-%m-%d)s", "Publication date, formatted"),
            ("%(playlist_index)02d", "Position in the playlist, zero-padded"),
            ("%(resolution)s", "Resolution of the chosen format"),
        ]
    }
}
