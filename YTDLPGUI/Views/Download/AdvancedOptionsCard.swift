import SwiftUI

/// Collapsible panel holding the less common yt-dlp features.
///
/// Everything here is off by default: the basic flow is paste, pick, download, and none of
/// this should get in the way of it.
struct AdvancedOptionsCard: View {
    @Environment(AppModel.self) private var model
    @Binding var isExpanded: Bool

    var body: some View {
        @Bindable var composer = model.composer

        SectionCard {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 18) {
                    subtitlesSection(composer)
                    Divider()
                    metadataSection(composer)
                    Divider()
                    sponsorBlockSection(composer)
                    Divider()
                    playlistSection(composer)
                    Divider()
                    networkSection(composer)
                    Divider()
                    filesSection(composer)
                    Divider()
                    customArgumentsSection(composer)
                }
                .padding(.top, 14)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape.2")
                        .foregroundStyle(.tint)
                    Text("Advanced Options")
                        .font(.headline)
                    if activeCount > 0 {
                        StatusPill(text: "\(activeCount) on", tone: .accent)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
        }
    }

    /// Number of non-default advanced settings, shown as a badge so an unexpected option is
    /// discoverable without expanding the whole panel.
    private var activeCount: Int {
        let options = model.composer.options
        let defaults = DownloadOptions()
        var count = 0
        if options.subtitleMode != defaults.subtitleMode { count += 1 }
        if options.embedSubtitles { count += 1 }
        if options.embedThumbnail { count += 1 }
        if options.embedMetadata { count += 1 }
        if options.embedChapters { count += 1 }
        if options.writeThumbnail { count += 1 }
        if options.writeInfoJSON { count += 1 }
        if options.sponsorBlockMode != .off { count += 1 }
        if options.downloadPlaylist { count += 1 }
        if !options.playlistItems.isEmpty { count += 1 }
        if options.useDownloadArchive { count += 1 }
        if options.cookieBrowser != .none { count += 1 }
        if !options.rateLimit.isEmpty { count += 1 }
        if options.concurrentFragments > 1 { count += 1 }
        if !options.proxy.isEmpty { count += 1 }
        if !options.userAgent.isEmpty { count += 1 }
        if options.restrictFilenames { count += 1 }
        if options.overwriteExisting { count += 1 }
        if !options.customArguments.isEmpty { count += 1 }
        return count
    }

    // MARK: - Sections

    @ViewBuilder
    private func subtitlesSection(_ composer: DownloadComposer) -> some View {
        @Bindable var composer = composer

        OptionGroup(title: "Subtitles", systemImage: "captions.bubble") {
            Picker("Download", selection: $composer.options.subtitleMode) {
                ForEach(SubtitleMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .frame(maxWidth: 320)

            if composer.options.subtitleMode.isEnabled {
                TextField("Languages", text: $composer.options.subtitleLanguages)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .help("Comma-separated language codes, for example: en,es,fr. Use \"all\" for everything available.")

                Text("Comma-separated codes such as `en,es`. `all` downloads every language, and `en.*` matches regional variants.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ExplainedToggle(
                    title: "Embed subtitles in the video file",
                    subtitle: composer.options.kind == .audio
                        ? "Not available for audio-only downloads."
                        : "MP4 and MKV only. The separate subtitle file is kept as well.",
                    isOn: $composer.options.embedSubtitles
                )
                .disabled(composer.options.kind == .audio)
            }
        }
    }

    @ViewBuilder
    private func metadataSection(_ composer: DownloadComposer) -> some View {
        @Bindable var composer = composer

        OptionGroup(title: "Metadata & artwork", systemImage: "tag") {
            ExplainedToggle(
                title: "Embed thumbnail as cover art",
                subtitle: "Shows artwork in Music, QuickTime Player and Finder.",
                isOn: $composer.options.embedThumbnail
            )
            ExplainedToggle(
                title: "Embed metadata",
                subtitle: "Writes title, artist, description and upload date into the file.",
                isOn: $composer.options.embedMetadata
            )
            ExplainedToggle(
                title: "Embed chapters",
                subtitle: "Adds chapter markers where the source provides them.",
                isOn: $composer.options.embedChapters
            )
            ExplainedToggle(
                title: "Save thumbnail as a separate image",
                subtitle: nil,
                isOn: $composer.options.writeThumbnail
            )
            ExplainedToggle(
                title: "Save metadata as a .info.json file",
                subtitle: "Everything yt-dlp knows about the media, in machine-readable form.",
                isOn: $composer.options.writeInfoJSON
            )
        }
    }

    @ViewBuilder
    private func sponsorBlockSection(_ composer: DownloadComposer) -> some View {
        @Bindable var composer = composer

        OptionGroup(title: "SponsorBlock", systemImage: "scissors") {
            Picker("Segments", selection: $composer.options.sponsorBlockMode) {
                ForEach(SponsorBlockMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .frame(maxWidth: 320)

            Text(composer.options.sponsorBlockMode.helpText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if composer.options.sponsorBlockMode != .off {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)],
                    alignment: .leading,
                    spacing: 4
                ) {
                    ForEach(SponsorBlockCategory.allCases) { category in
                        Toggle(category.displayName, isOn: binding(for: category, composer: composer))
                            .font(.callout)
                    }
                }

                Text("Segment data comes from the community-run SponsorBlock service and is only available for YouTube.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func binding(for category: SponsorBlockCategory, composer: DownloadComposer) -> Binding<Bool> {
        Binding(
            get: { composer.options.sponsorBlockCategories.contains(category) },
            set: { isOn in
                if isOn {
                    composer.options.sponsorBlockCategories.insert(category)
                } else {
                    composer.options.sponsorBlockCategories.remove(category)
                }
            }
        )
    }

    @ViewBuilder
    private func playlistSection(_ composer: DownloadComposer) -> some View {
        @Bindable var composer = composer

        OptionGroup(title: "Playlists", systemImage: "list.number") {
            ExplainedToggle(
                title: "Download the whole playlist",
                subtitle: "When off, a URL that points into a playlist downloads only that one item.",
                isOn: $composer.options.downloadPlaylist
            )

            if composer.options.downloadPlaylist {
                TextField("Items", text: $composer.options.playlistItems, prompt: Text("All items"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .help("Examples: 1-5 for the first five, 2,4,8 for specific items, -3 for the last three.")

                Text("Ranges and lists both work: `1-5`, `2,4,8`, `5:` from the fifth onwards, `-3` for the last three.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ExplainedToggle(
                title: "Keep an archive of what's been downloaded",
                subtitle: "Skips anything already listed in the file. Useful for re-running the same playlist.",
                isOn: $composer.options.useDownloadArchive
            )

            if composer.options.useDownloadArchive {
                HStack(spacing: 8) {
                    TextField("Archive file", text: $composer.options.downloadArchivePath, prompt: Text("Choose a file…"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                    Button("Choose…") {
                        let current = composer.options.downloadArchivePath.isEmpty
                            ? nil
                            : URL(fileURLWithPath: composer.options.downloadArchivePath)
                        if let url = FinderIntegration.chooseArchiveFile(startingAt: current) {
                            composer.options.downloadArchivePath = url.path(percentEncoded: false)
                        }
                    }
                }
                .frame(maxWidth: 460)
            }
        }
    }

    @ViewBuilder
    private func networkSection(_ composer: DownloadComposer) -> some View {
        @Bindable var composer = composer

        OptionGroup(title: "Network & sign-in", systemImage: "network") {
            Picker("Use cookies from browser", selection: $composer.options.cookieBrowser) {
                ForEach(CookieBrowser.allCases) { browser in
                    Text(browser.displayName).tag(browser)
                }
            }
            .frame(maxWidth: 340)

            if composer.options.cookieBrowser != .none {
                Text("yt-dlp reads the cookies of that browser so private, members-only and age-restricted media can be downloaded. The browser may need to be closed first, and macOS will ask for permission the first time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Speed limit").font(.callout)
                    TextField("Unlimited", text: $composer.options.rateLimit)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                        .help("For example 500K or 2M, in bytes per second.")
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Parallel fragments").font(.callout)
                    Stepper(
                        value: $composer.options.concurrentFragments,
                        in: 1...16
                    ) {
                        Text("\(composer.options.concurrentFragments)")
                            .monospacedDigit()
                            .frame(width: 24, alignment: .leading)
                    }
                    .help("Downloads several pieces of a fragmented stream at once. Higher is faster but heavier on the server.")
                }
            }

            TextField("Proxy", text: $composer.options.proxy, prompt: Text("http://host:port or socks5://host:port"))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 400)

            TextField("User agent", text: $composer.options.userAgent, prompt: Text("Default"))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 400)
        }
    }

    @ViewBuilder
    private func filesSection(_ composer: DownloadComposer) -> some View {
        @Bindable var composer = composer

        OptionGroup(title: "Files", systemImage: "doc") {
            ExplainedToggle(
                title: "Restrict filenames to plain ASCII",
                subtitle: "Avoids accents, emoji and spaces. Helpful for external drives and older systems.",
                isOn: $composer.options.restrictFilenames
            )
            ExplainedToggle(
                title: "Overwrite existing files",
                subtitle: "When off, a download that already exists is skipped.",
                isOn: $composer.options.overwriteExisting
            )
        }
    }

    @ViewBuilder
    private func customArgumentsSection(_ composer: DownloadComposer) -> some View {
        @Bindable var composer = composer

        OptionGroup(title: "Custom yt-dlp arguments", systemImage: "terminal") {
            TextField(
                "Extra arguments",
                text: $composer.options.customArguments,
                prompt: Text("--extractor-args \"youtube:player_client=web\""),
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(.callout, design: .monospaced))
            .lineLimit(1...4)

            Text("Appended after everything above, so they win any conflict. Quoted strings are honoured, but nothing is passed through a shell — no globbing, no variable expansion, no command substitution.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !composer.options.customArguments.isEmpty {
                let parsed = ShellQuoting.split(composer.options.customArguments)
                Text("Parsed as \(parsed.count) argument\(parsed.count == 1 ? "" : "s"): \(parsed.map { "“\($0)”" }.joined(separator: ", "))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}

/// A titled block of related controls inside the advanced panel.
struct OptionGroup<Content: View>: View {
    var title: String
    var systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
