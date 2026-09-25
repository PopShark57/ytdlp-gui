import SwiftUI

/// The less common yt-dlp features.
///
/// Everything here starts at its default: the everyday flow is paste, choose, download, and none
/// of this should get in its way. The row that opens this screen shows how many options differ
/// from their defaults, so an unexpected one is easy to find again.
struct AdvancedOptionsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmsReset = false

    var body: some View {
        @Bindable var composer = model.composer

        Form {
            filenameSection(composer)
            subtitlesSection(composer)
            metadataSection(composer)
            sponsorBlockSection(composer)
            playlistSection(composer)
            archiveSection(composer)
            networkSection(composer)
            cookiesSection
            customArgumentsSection(composer)
            resetSection
        }
        .readableContentWidth()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Advanced Options")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Filename

    @ViewBuilder
    private func filenameSection(_ composer: DownloadComposer) -> some View {
        @Bindable var composer = composer

        Section {
            TextField("Filename template", text: $composer.options.outputTemplate, axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1...3)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Filename template")

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
                Label("Presets", systemImage: "text.badge.plus")
            }
            .accessibilityHint("Replaces the template with a ready-made naming pattern")

            NavigationLink {
                TemplatePlaceholdersView()
            } label: {
                Label("Placeholders", systemImage: "curlybraces")
            }

            ExplainedToggle(
                title: "Restrict to plain ASCII",
                explanation: "Avoids accents, emoji and spaces, which some older apps and servers mishandle.",
                isOn: $composer.options.restrictFilenames
            )
            ExplainedToggle(
                title: "Overwrite existing files",
                explanation: "When off, a download that already exists is skipped.",
                isOn: $composer.options.overwriteExisting
            )
        } header: {
            Text("Filename")
        } footer: {
            Text(filenameFooter(for: composer.options.outputTemplate))
        }
    }

    private func filenameFooter(for template: String) -> String {
        if let preset = ArgumentBuilder.outputTemplatePresets.first(where: { $0.template == template }) {
            return "For example: \(preset.example)"
        }
        return "Always end with .%(ext)s so each file keeps the right extension. A / starts a folder."
    }

    // MARK: - Subtitles

    @ViewBuilder
    private func subtitlesSection(_ composer: DownloadComposer) -> some View {
        @Bindable var composer = composer

        Section {
            Picker(selection: $composer.options.subtitleMode) {
                ForEach(SubtitleMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            } label: {
                Text("Subtitles")
            }

            if composer.options.subtitleMode.isEnabled {
                LabeledContent("Languages") {
                    TextField("Languages", text: $composer.options.subtitleLanguages, prompt: Text("en"))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityHint("Comma-separated language codes, for example en,es")
                }
            }
        } header: {
            Text("Subtitles")
        } footer: {
            if composer.options.subtitleMode.isEnabled {
                Text(verbatim: "Comma-separated codes such as en,es. “all” downloads every language, and en.* matches regional variants. On iPhone and iPad, subtitles are saved as separate files next to the video.")
            } else {
                Text("On iPhone and iPad, subtitles are saved as separate files next to the video.")
            }
        }
    }

    // MARK: - Metadata

    @ViewBuilder
    private func metadataSection(_ composer: DownloadComposer) -> some View {
        @Bindable var composer = composer

        Section("Metadata & Artwork") {
            ExplainedToggle(
                title: "Embed thumbnail as cover art",
                explanation: "Shows artwork in Music, TV, Files and Photos.",
                isOn: $composer.options.embedThumbnail
            )
            ExplainedToggle(
                title: "Embed metadata",
                explanation: "Writes the title, artist, description and upload date into the file.",
                isOn: $composer.options.embedMetadata
            )
            ExplainedToggle(
                title: "Embed chapters",
                explanation: "Adds chapter markers where the source provides them.",
                isOn: $composer.options.embedChapters
            )
            ExplainedToggle(
                title: "Save thumbnail as an image",
                explanation: "Keeps the artwork as a separate JPEG next to the download.",
                isOn: $composer.options.writeThumbnail
            )
            ExplainedToggle(
                title: "Save metadata as .info.json",
                explanation: "Everything yt-dlp knows about the media, in machine-readable form.",
                isOn: $composer.options.writeInfoJSON
            )
        }
    }

    // MARK: - SponsorBlock

    @ViewBuilder
    private func sponsorBlockSection(_ composer: DownloadComposer) -> some View {
        @Bindable var composer = composer

        Section {
            Picker("Segments", selection: $composer.options.sponsorBlockMode) {
                ForEach(SponsorBlockMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
        } header: {
            Text("SponsorBlock")
        } footer: {
            Text(composer.options.sponsorBlockMode.mobileHelpText)
        }

        if composer.options.sponsorBlockMode != .off {
            Section {
                ForEach(SponsorBlockCategory.allCases) { category in
                    Toggle(category.displayName, isOn: binding(for: category))
                }
            } header: {
                Text("Categories")
            } footer: {
                Text("Segment data comes from the community-run SponsorBlock service and is only available for YouTube.")
            }
        }
    }

    private func binding(for category: SponsorBlockCategory) -> Binding<Bool> {
        let composer = model.composer
        return Binding {
            composer.options.sponsorBlockCategories.contains(category)
        } set: { isOn in
            if isOn {
                composer.options.sponsorBlockCategories.insert(category)
            } else {
                composer.options.sponsorBlockCategories.remove(category)
            }
        }
    }

    // MARK: - Playlist

    @ViewBuilder
    private func playlistSection(_ composer: DownloadComposer) -> some View {
        @Bindable var composer = composer

        Section {
            ExplainedToggle(
                title: "Download the whole playlist",
                explanation: "When off, a link that points into a playlist downloads only that one video.",
                isOn: $composer.options.downloadPlaylist
            )

            if composer.options.downloadPlaylist {
                LabeledContent("Items") {
                    TextField("Items", text: $composer.options.playlistItems, prompt: Text("All"))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .accessibilityHint("For example 1-5, or 2,4,8")
                }
            }
        } header: {
            Text("Playlist")
        } footer: {
            if composer.options.downloadPlaylist {
                Text("Ranges and lists both work, for example 1-5,8. Use 5: for the fifth onwards, or -3 for the last three.")
            }
        }
    }

    // MARK: - Archive

    @ViewBuilder
    private func archiveSection(_ composer: DownloadComposer) -> some View {
        @Bindable var composer = composer

        Section {
            ExplainedToggle(
                title: "Skip what's already downloaded",
                explanation: "Remembers every video downloaded with this on, and skips it next time. Useful for keeping up with a playlist or channel.",
                isOn: $composer.options.useDownloadArchive
            )
        } header: {
            Text("Archive")
        } footer: {
            Text("The app keeps the archive file for you, so there's nothing to choose.")
        }
    }

    // MARK: - Network

    @ViewBuilder
    private func networkSection(_ composer: DownloadComposer) -> some View {
        @Bindable var composer = composer

        Section {
            LabeledContent("Speed Limit") {
                TextField("Speed limit", text: $composer.options.rateLimit, prompt: Text("Unlimited"))
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .accessibilityHint("Bytes per second, for example 500K or 2M")
            }

            Stepper(value: $composer.options.concurrentFragments, in: 1...16) {
                LabeledContent("Parallel Fragments", value: composer.options.concurrentFragments.formatted())
            }
            .accessibilityHint("Downloads several pieces of a stream at once")

            LabeledContent("Proxy") {
                TextField("Proxy", text: $composer.options.proxy, prompt: Text("None"))
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityHint("For example socks5://host:port")
            }

            LabeledContent("User Agent") {
                TextField("User agent", text: $composer.options.userAgent, prompt: Text("Default"))
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        } header: {
            Text("Network")
        } footer: {
            Text("Speed limits are in bytes per second, such as 500K or 2M. More parallel fragments can be faster for streamed video, but are heavier on the server. A proxy looks like http://host:port or socks5://host:port.")
        }
    }

    // MARK: - Cookies

    private var cookiesSection: some View {
        Section {
            NavigationLink {
                CookiesView()
            } label: {
                LabeledContent {
                    Text(cookieStatus)
                } label: {
                    Label("Cookies", systemImage: "key")
                }
            }
        } header: {
            Text("Sign-In")
        } footer: {
            Text("Cookies from a signed-in browser let yt-dlp download private, members-only and age-restricted media. They're also in Settings › Cookies.")
        }
    }

    private var cookieStatus: String {
        guard let summary = model.cookies.summary else { return "None" }
        return summary.domains.count == 1 ? "1 site" : "\(summary.domains.count.formatted()) sites"
    }

    // MARK: - Custom arguments

    @ViewBuilder
    private func customArgumentsSection(_ composer: DownloadComposer) -> some View {
        @Bindable var composer = composer

        Section {
            TextField(
                "Custom arguments",
                text: $composer.options.customArguments,
                prompt: Text(verbatim: "--extractor-args \"youtube:player_client=web\""),
                axis: .vertical
            )
            .font(.system(.body, design: .monospaced))
            .lineLimit(1...5)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityLabel("Custom yt-dlp arguments")

            if let message = composer.customArgumentBlockMessage {
                WarningRow(message: message, systemImage: "exclamationmark.shield.fill", tint: .red)
                    .foregroundStyle(.red)
            }

            if let parsed = parsedArgumentsDescription(composer.options.customArguments) {
                Text(parsed)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Custom Arguments")
        } footer: {
            Text("Added after everything above, so they win any conflict. Quotes group words, but nothing goes through a shell. Options that run programs, load code or configuration, or can't work on iPhone and iPad are blocked.")
        }
    }

    /// Shows how the text was split into arguments, since quoting mistakes are otherwise invisible.
    private func parsedArgumentsDescription(_ input: String) -> String? {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let inspection = CustomArgumentPolicy.inspect(input, context: .embedded)
        let arguments = inspection.safeArguments.map { "“\($0)”" }.joined(separator: " ")
        if inspection.isBlocked {
            return arguments.isEmpty ? "Nothing is left once blocked options are removed." : "Used: \(arguments)"
        }
        let count = inspection.safeArguments.count
        return "\(count == 1 ? "1 argument" : "\(count) arguments"): \(arguments)"
    }

    // MARK: - Reset

    private var resetSection: some View {
        Section {
            Button("Reset Advanced Options", role: .destructive) {
                confirmsReset = true
            }
            .disabled(model.composer.customizedAdvancedOptionCount == 0)
            .confirmationDialog(
                "Reset all advanced options?",
                isPresented: $confirmsReset,
                titleVisibility: .visible
            ) {
                Button("Reset Advanced Options", role: .destructive) {
                    model.composer.resetAdvancedOptions()
                }
            } message: {
                Text("Video or audio and the quality you chose stay as they are.")
            }
        }
    }
}

extension SponsorBlockMode {
    /// The shared description, adjusted where the iPhone and iPad engine works differently:
    /// cutting segments uses AVFoundation, not ffmpeg.
    var mobileHelpText: String {
        switch self {
        case .remove: "Removes the selected segments from the file, and adjusts its chapters to match."
        case .off, .mark: helpText
        }
    }
}

/// yt-dlp's filename placeholders, explained.
private struct TemplatePlaceholdersView: View {
    private let placeholders: [(token: String, meaning: String)] = [
        ("%(title)s", "Video title"),
        ("%(uploader)s", "Channel or uploader"),
        ("%(ext)s", "File extension — always include this"),
        ("%(id)s", "The site's own video ID"),
        ("%(upload_date>%Y-%m-%d)s", "Publication date, formatted"),
        ("%(playlist_title)s", "Name of the playlist"),
        ("%(playlist_index)02d", "Position in the playlist, zero-padded"),
        ("%(resolution)s", "Resolution of the chosen format"),
        ("%(duration_string)s", "Length, such as 4:21"),
    ]

    var body: some View {
        List {
            Section {
                ForEach(placeholders, id: \.token) { placeholder in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: placeholder.token)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Text(placeholder.meaning)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .contextMenu {
                        Button {
                            TextCopier.copy(placeholder.token)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
                }
            } footer: {
                Text(verbatim: "A slash starts a folder, for example %(uploader)s/%(title)s.%(ext)s. Touch and hold a placeholder to copy it.")
            }

            if let reference = URL(string: "https://github.com/yt-dlp/yt-dlp#output-template") {
                Section {
                    Link(destination: reference) {
                        Label("Full Template Reference", systemImage: "safari")
                    }
                }
            }
        }
        .navigationTitle("Placeholders")
        .navigationBarTitleDisplayMode(.inline)
        .readableContentWidth()
    }
}

#Preview {
    NavigationStack {
        AdvancedOptionsView()
    }
    .environment(AppModel())
}
