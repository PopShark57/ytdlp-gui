import Foundation

/// What the embedded engine in the iOS app can do, which shapes the arguments it is given.
///
/// The iOS app runs yt-dlp in-process with no ffmpeg: merging, audio conversion and tagging are
/// done by AVFoundation, which only reads and writes MP4-family files. Format selection has to
/// respect that, and a few options have no equivalent at all.
struct EmbeddedEngineCapabilities: Equatable, Sendable {
    /// Whether AV1 video may be chosen. Only devices that decode AV1 in hardware play it back
    /// well, so it is off elsewhere, which on YouTube caps quality at what H.264 offers.
    var allowsAV1: Bool
    /// Where partial downloads live until they finish (`--paths temp:`), so the user-visible
    /// Documents folder only ever shows finished files. `nil` keeps them beside the output.
    var temporaryDirectory: URL?

    init(allowsAV1: Bool = false, temporaryDirectory: URL? = nil) {
        self.allowsAV1 = allowsAV1
        self.temporaryDirectory = temporaryDirectory
    }
}

/// Argument building for yt-dlp running inside the iOS app.
///
/// It follows the desktop builder section by section (see `Docs/iOS-Architecture.md`), sharing
/// every section that means the same thing on both. The differences all come from the engine:
/// progress arrives through hooks rather than a template, there is no ffmpeg to locate, media is
/// processed by AVFoundation, and cookies can only come from an imported file.
extension ArgumentBuilder {

    /// The full argument vector for downloading `url` with the embedded engine.
    ///
    /// The host adds the engine plumbing itself (hooks, logger, cache and JavaScript runtime),
    /// so nothing here is invisible to the command preview.
    static func embeddedDownloadArguments(
        url: String,
        options: DownloadOptions,
        capabilities: EmbeddedEngineCapabilities
    ) -> [String] {
        var arguments: [String] = []

        arguments += configurationArguments(for: options)

        // --- Destination -------------------------------------------------------------
        arguments += outputDirectoryArguments(for: options)
        if let temporaryDirectory = capabilities.temporaryDirectory {
            arguments += ["--paths", "temp:" + temporaryDirectory.path(percentEncoded: false)]
        }
        arguments += fileNamingArguments(for: options)
        // The Files app sorts by modification date, so a file dated to the upload (yt-dlp's
        // default) would vanish to the bottom of the list the moment it arrives.
        arguments.append("--no-mtime")

        arguments += embeddedFormatArguments(for: options, capabilities: capabilities)
        arguments += playlistArguments(for: options)
        // AVFoundation can't mux yt-dlp's subtitle files, so they are always saved alongside.
        arguments += subtitleArguments(for: options, allowsEmbedding: false)
        arguments += artworkAndMetadataArguments(for: options)
        arguments += sponsorBlockArguments(for: options)
        arguments += archiveArguments(for: options)

        // --- Network and authentication ----------------------------------------------------
        arguments += cookieFileArguments(for: options)
        arguments += transferArguments(for: options)
        arguments += connectionArguments(for: options)

        arguments += CustomArgumentPolicy.safeArguments(from: options.customArguments, context: .embedded)
        arguments += endOfOptions(url: url)
        return arguments
    }

    /// Arguments for analysing `url` with the embedded engine. The host returns the info
    /// dictionary itself, so no `--dump-single-json` is needed, and it already keeps warnings,
    /// progress and colour out of the result.
    static func embeddedMetadataArguments(url: String, options: DownloadOptions) -> [String] {
        var arguments = ["--flat-playlist"]
        arguments += configurationArguments(for: options)
        arguments.append(playlistModeArgument(for: options))
        arguments += cookieFileArguments(for: options)
        arguments += connectionArguments(for: options)
        arguments += CustomArgumentPolicy.safeArguments(from: options.customArguments, context: .embedded)
        arguments += endOfOptions(url: url)
        return arguments
    }

    // MARK: - Format selection

    /// Format selector and container flags for the embedded engine.
    ///
    /// Video always ends up as MP4 whatever `options.container` says, because that is the only
    /// container AVFoundation can write that every Apple app plays.
    static func embeddedFormatArguments(
        for options: DownloadOptions,
        capabilities: EmbeddedEngineCapabilities
    ) -> [String] {
        switch options.kind {
        case .audio:
            let format = options.audioFormat.embeddedEngineEquivalent
            var arguments = ["--format", embeddedAudioFormatSelector, "--extract-audio"]
            arguments += ["--audio-format", format.ytdlpValue]
            if format.supportsQuality {
                arguments += ["--audio-quality", options.audioQuality.ytdlpValue]
            }
            return arguments

        case .video:
            let selector = embeddedVideoFormatSelector(
                maxHeight: options.videoQuality.maxHeight,
                allowsAV1: capabilities.allowsAV1
            )
            return ["--format", selector, "--merge-output-format", "mp4"]
        }
    }

    /// Prefers AAC sources, which AVFoundation can read and, for M4A and "Best", keep without
    /// re-encoding. The later alternatives accept anything so a site without AAC still works.
    static let embeddedAudioFormatSelector = "ba[ext=m4a]/ba[acodec^=mp4a]/ba/b"

    /// Builds the `-f` selector for video, which only accepts what AVFoundation can mux into MP4:
    /// H.264 or HEVC video (plus AV1 when `allowsAV1`) in MP4, with AAC audio.
    ///
    /// Like the desktop selector it tries separate streams at the cap, then a pre-muxed MP4 at
    /// the cap, then both again without the cap. After that come two last resorts, taken as is:
    /// any pre-muxed file, and finally any video and audio pair. The pair matters for sites that
    /// offer no pre-muxed format at all (WebM-only DASH, for one): without it, `b` would match
    /// nothing and the download would fail outright. When AVFoundation can't merge that pair,
    /// the host keeps both files with a warning, as yt-dlp does without ffmpeg.
    ///
    /// Audio is accepted either as `.m4a` or as any AAC stream, because HLS audio renditions
    /// are AAC with an `.mp4` extension and would otherwise rule out every separate stream.
    static func embeddedVideoFormatSelector(maxHeight: Int?, allowsAV1: Bool) -> String {
        let codecs = allowsAV1 ? "^(avc|h264|hvc|hev|h265|av01)" : "^(avc|h264|hvc|hev|h265)"
        let video = "[ext=mp4][vcodec~='\(codecs)']"
        let audio = "(ba[ext=m4a]/ba[acodec^=mp4a])"
        let uncapped = "bv*\(video)+\(audio)/b[ext=mp4]/b/bv*+ba"
        guard let maxHeight else {
            return uncapped
        }
        return "bv*[height<=?\(maxHeight)]\(video)+\(audio)/b[height<=?\(maxHeight)][ext=mp4]/" + uncapped
    }
}

extension AudioFormat {

    /// Whether the embedded engine can produce this format. iOS has no MP3 or Opus encoder
    /// that yt-dlp's output could be fed through.
    var isAvailableInEmbeddedEngine: Bool {
        switch self {
        case .best, .m4a, .alac, .flac, .wav: true
        case .mp3, .opus: false
        }
    }

    /// The format the embedded engine actually produces when asked for this one. MP3 and Opus
    /// can still arrive from options saved by an older build or by the Mac app; they become
    /// M4A, the closest lossy format iOS can encode, rather than failing the download.
    var embeddedEngineEquivalent: AudioFormat {
        isAvailableInEmbeddedEngine ? self : .m4a
    }
}
