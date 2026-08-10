import Foundation

/// Turns a `DownloadOptions` value into a yt-dlp argument vector.
///
/// Every function here is pure, which is what makes the generated command both unit-testable
/// and safe to show in the preview: what the preview renders is exactly the array handed to
/// `Process.arguments`, with no shell in between.
enum ArgumentBuilder {

    /// Marker prefixed to machine-readable download progress lines.
    static let progressMarker = "@@YTDLPGUI-DL@@"
    /// Marker prefixed to machine-readable post-processing lines.
    static let postProcessMarker = "@@YTDLPGUI-PP@@"
    /// Field separator inside a progress line. A tab cannot appear in yt-dlp's numeric fields
    /// and is vanishingly unlikely in a filename, which is emitted last regardless.
    static let fieldSeparator = "\t"

    /// The `--progress-template` value that produces parseable download progress.
    static var downloadProgressTemplate: String {
        let fields = [
            "%(progress.status)s",
            "%(progress.downloaded_bytes)s",
            "%(progress.total_bytes)s",
            "%(progress.total_bytes_estimate)s",
            "%(progress.speed)s",
            "%(progress.eta)s",
            "%(progress.elapsed)s",
            "%(progress.fragment_index)s",
            "%(progress.fragment_count)s",
            "%(progress.filename)s",
        ]
        return "download:" + progressMarker + fields.joined(separator: fieldSeparator)
    }

    /// The `--progress-template` value that reports post-processing stages.
    static var postProcessTemplate: String {
        "postprocess:" + postProcessMarker
            + ["%(progress.status)s", "%(progress.postprocessor)s"].joined(separator: fieldSeparator)
    }

    // MARK: - Download

    /// Builds the full argument vector for downloading `url`.
    ///
    /// - Parameter ffmpegURL: Passed through as `--ffmpeg-location` when known. yt-dlp otherwise
    ///   looks for ffmpeg on `PATH`, which a Finder-launched app cannot be relied upon to have.
    static func downloadArguments(
        url: String,
        options: DownloadOptions,
        ffmpegURL: URL? = nil
    ) -> [String] {
        var arguments: [String] = []

        // --- Machine-readable output -------------------------------------------------
        arguments += ["--newline", "--color", "never"]
        arguments += ["--progress", "--progress-template", downloadProgressTemplate]
        arguments += ["--progress-template", postProcessTemplate]

        if options.ignoreUserConfig {
            arguments.append("--ignore-config")
        }

        // --- Destination -------------------------------------------------------------
        arguments += ["--paths", options.outputDirectory.path(percentEncoded: false)]
        let template = options.outputTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        arguments += ["--output", template.isEmpty ? DownloadOptions.defaultOutputTemplate : template]

        if options.restrictFilenames { arguments.append("--restrict-filenames") }
        arguments.append(options.overwriteExisting ? "--force-overwrites" : "--no-overwrites")

        if let ffmpegURL {
            arguments += ["--ffmpeg-location", ffmpegURL.path(percentEncoded: false)]
        }

        // --- Format ------------------------------------------------------------------
        arguments += formatArguments(for: options)

        // --- Playlists ---------------------------------------------------------------
        arguments.append(options.downloadPlaylist ? "--yes-playlist" : "--no-playlist")
        let items = options.playlistItems.trimmingCharacters(in: .whitespacesAndNewlines)
        if options.downloadPlaylist, !items.isEmpty {
            arguments += ["--playlist-items", items]
        }

        // --- Subtitles ---------------------------------------------------------------
        if options.subtitleMode.isEnabled {
            if options.subtitleMode.writesManual { arguments.append("--write-subs") }
            if options.subtitleMode.writesAutomatic { arguments.append("--write-auto-subs") }
            let languages = options.subtitleLanguages.trimmingCharacters(in: .whitespacesAndNewlines)
            if !languages.isEmpty {
                arguments += ["--sub-langs", languages]
            }
            // Embedding only makes sense for a container that can carry a subtitle track.
            if options.embedSubtitles, options.kind == .video {
                arguments.append("--embed-subs")
            }
        }

        // --- Metadata and artwork ------------------------------------------------------
        if options.embedThumbnail { arguments.append("--embed-thumbnail") }
        if options.embedMetadata { arguments.append("--embed-metadata") }
        if options.embedChapters { arguments.append("--embed-chapters") }
        if options.writeThumbnail { arguments.append("--write-thumbnail") }
        if options.writeInfoJSON { arguments.append("--write-info-json") }

        // --- SponsorBlock ---------------------------------------------------------------
        if options.sponsorBlockMode != .off, !options.sponsorBlockCategories.isEmpty {
            let categories = options.sponsorBlockCategories
                .map(\.rawValue)
                .sorted()
                .joined(separator: ",")
            switch options.sponsorBlockMode {
            case .mark: arguments += ["--sponsorblock-mark", categories]
            case .remove: arguments += ["--sponsorblock-remove", categories]
            case .off: break
            }
        }

        // --- Archive ---------------------------------------------------------------------
        let archivePath = options.downloadArchivePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if options.useDownloadArchive, !archivePath.isEmpty {
            arguments += ["--download-archive", archivePath]
        }

        // --- Network and authentication ----------------------------------------------------
        if let browser = options.cookieBrowser.ytdlpValue {
            arguments += ["--cookies-from-browser", browser]
        }
        let rateLimit = options.rateLimit.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rateLimit.isEmpty {
            arguments += ["--limit-rate", rateLimit]
        }
        if options.concurrentFragments > 1 {
            arguments += ["--concurrent-fragments", String(options.concurrentFragments)]
        }
        let proxy = options.proxy.trimmingCharacters(in: .whitespacesAndNewlines)
        if !proxy.isEmpty {
            arguments += ["--proxy", proxy]
        }
        let userAgent = options.userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !userAgent.isEmpty {
            arguments += ["--user-agent", userAgent]
        }

        // --- Escape hatch -------------------------------------------------------------------
        // Appended last so a power user can override anything above.
        arguments += ShellQuoting.split(options.customArguments)

        // `--` guarantees a URL beginning with a dash is treated as a URL and never as a flag.
        arguments += ["--", url]
        return arguments
    }

    // MARK: - Format selection

    /// Format selector, sort order and container flags.
    static func formatArguments(for options: DownloadOptions) -> [String] {
        switch options.kind {
        case .audio:
            var arguments = ["--format", "bestaudio/best", "--extract-audio"]
            arguments += ["--audio-format", options.audioFormat.ytdlpValue]
            if options.audioFormat.supportsQuality {
                arguments += ["--audio-quality", options.audioQuality.ytdlpValue]
            }
            return arguments

        case .video:
            var arguments = ["--format", videoFormatSelector(maxHeight: options.videoQuality.maxHeight)]
            if let sort = formatSort(for: options.container) {
                arguments += ["--format-sort", sort]
            }
            if let container = options.container.mergeOutputFormat {
                arguments += ["--merge-output-format", container]
            }
            return arguments
        }
    }

    /// Builds the `-f` selector.
    ///
    /// The chain prefers separate best-video + best-audio streams (which yt-dlp merges with
    /// ffmpeg), falls back to a pre-muxed file at the same cap, and finally drops the cap
    /// altogether so an unusual source still downloads *something* rather than failing. The
    /// `<=?` form is deliberate: it keeps formats whose height is unknown instead of rejecting
    /// them, which some extractors rely on.
    static func videoFormatSelector(maxHeight: Int?) -> String {
        guard let maxHeight else {
            return "bv*+ba/b"
        }
        return "bv*[height<=?\(maxHeight)]+ba/b[height<=?\(maxHeight)]/bv*+ba/b"
    }

    /// Container preference expressed as a sort order.
    ///
    /// Resolution is listed first on purpose. Sorting by extension alone would happily pick a
    /// 480p MP4 over a 1080p WebM, which is not what "prefer MP4" means to anyone.
    static func formatSort(for container: VideoContainer) -> String? {
        switch container {
        case .auto, .mkv: nil
        case .mp4: "res,ext:mp4:m4a"
        case .webm: "res,ext:webm:webm"
        }
    }

    // MARK: - Metadata

    /// Arguments for analysing a URL without downloading anything.
    ///
    /// `--flat-playlist` keeps playlist analysis fast: a 200-video playlist would otherwise
    /// require 200 extractor round-trips before the UI could show anything. It has no effect on
    /// a single video, which is still fully described.
    static func metadataArguments(url: String, options: DownloadOptions) -> [String] {
        var arguments = [
            "--dump-single-json",
            "--no-warnings",
            "--no-progress",
            "--color", "never",
            "--flat-playlist",
        ]
        if options.ignoreUserConfig {
            arguments.append("--ignore-config")
        }
        arguments.append(options.downloadPlaylist ? "--yes-playlist" : "--no-playlist")

        if let browser = options.cookieBrowser.ytdlpValue {
            arguments += ["--cookies-from-browser", browser]
        }
        let proxy = options.proxy.trimmingCharacters(in: .whitespacesAndNewlines)
        if !proxy.isEmpty {
            arguments += ["--proxy", proxy]
        }
        let userAgent = options.userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !userAgent.isEmpty {
            arguments += ["--user-agent", userAgent]
        }
        arguments += ShellQuoting.split(options.customArguments)
        arguments += ["--", url]
        return arguments
    }

    // MARK: - Output templates

    /// Ready-made `--output` templates offered in the UI.
    struct OutputTemplatePreset: Identifiable, Hashable, Sendable {
        var id: String { template }
        var name: String
        var template: String
        var example: String
    }

    static let outputTemplatePresets: [OutputTemplatePreset] = [
        .init(
            name: "Title",
            template: "%(title)s.%(ext)s",
            example: "Me at the zoo.mp4"
        ),
        .init(
            name: "Uploader and title",
            template: "%(uploader)s - %(title)s.%(ext)s",
            example: "jawed - Me at the zoo.mp4"
        ),
        .init(
            name: "Folder per uploader",
            template: "%(uploader)s/%(title)s.%(ext)s",
            example: "jawed/Me at the zoo.mp4"
        ),
        .init(
            name: "Date and title",
            template: "%(upload_date>%Y-%m-%d)s - %(title)s.%(ext)s",
            example: "2005-04-24 - Me at the zoo.mp4"
        ),
        .init(
            name: "Numbered playlist",
            template: "%(playlist_title|Downloads)s/%(playlist_index|0)02d - %(title)s.%(ext)s",
            example: "My Playlist/01 - Me at the zoo.mp4"
        ),
    ]
}
