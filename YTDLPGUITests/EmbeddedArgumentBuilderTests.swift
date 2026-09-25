import Foundation
import Testing

@testable import YTDLPGUI

/// The argument rules for yt-dlp running inside the iOS app (`Docs/iOS-Architecture.md`).
///
/// The format selectors pinned here were checked against the bundled yt-dlp's own format
/// selection over YouTube-like, HLS-only, combined-only and WebM-only format lists; changing one
/// means re-running that check, not just updating the expected string.
@Suite("Embedded argument builder")
struct EmbeddedArgumentBuilderTests {

    private let url = "https://example.com/v"
    private let partials = URL(fileURLWithPath: "/tmp/Library/Caches/Partial Downloads")

    private func makeOptions() -> DownloadOptions {
        var options = DownloadOptions()
        options.outputDirectory = URL(fileURLWithPath: "/tmp/Documents")
        return options
    }

    private func download(
        _ options: DownloadOptions,
        url: String = "https://example.com/v",
        capabilities: EmbeddedEngineCapabilities = EmbeddedEngineCapabilities()
    ) -> [String] {
        ArgumentBuilder.embeddedDownloadArguments(url: url, options: options, capabilities: capabilities)
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    /// Every value that follows `flag`, for flags that may repeat (`--paths`).
    private func values(after flag: String, in arguments: [String]) -> [String] {
        arguments.indices.dropLast().filter { arguments[$0] == flag }.map { arguments[$0 + 1] }
    }

    // MARK: - Structure

    @Test("Every section appears in the documented order")
    func fullArgumentVector() {
        var options = makeOptions()
        options.kind = .video
        options.videoQuality = .fhd1080
        options.outputTemplate = "%(uploader)s/%(title)s.%(ext)s"
        options.restrictFilenames = true
        options.downloadPlaylist = true
        options.playlistItems = "1-3"
        options.subtitleMode = .both
        options.subtitleLanguages = "en,de"
        options.embedSubtitles = true
        options.embedThumbnail = true
        options.embedMetadata = true
        options.embedChapters = true
        options.writeThumbnail = true
        options.writeInfoJSON = true
        options.sponsorBlockMode = .remove
        options.sponsorBlockCategories = [.sponsor, .intro]
        options.useDownloadArchive = true
        options.downloadArchivePath = "/tmp/Library/Application Support/download-archive.txt"
        options.cookieBrowser = .safari
        options.cookieFilePath = "/tmp/Library/Application Support/Cookies/cookies.txt"
        options.rateLimit = "2M"
        options.concurrentFragments = 4
        options.proxy = "socks5://127.0.0.1:9050"
        options.userAgent = "Custom/1.0"
        options.customArguments = "--retries 5"

        let arguments = download(options, capabilities: EmbeddedEngineCapabilities(temporaryDirectory: partials))
        let selector = ArgumentBuilder.embeddedVideoFormatSelector(maxHeight: 1080, allowsAV1: false)

        #expect(arguments == [
            "--ignore-config",
            "--paths", "/tmp/Documents",
            "--paths", "temp:/tmp/Library/Caches/Partial Downloads",
            "--output", "%(uploader)s/%(title)s.%(ext)s",
            "--restrict-filenames",
            "--no-overwrites",
            "--no-mtime",
            "--format", selector, "--merge-output-format", "mp4",
            "--yes-playlist", "--playlist-items", "1-3",
            "--write-subs", "--write-auto-subs", "--sub-langs", "en,de",
            "--embed-thumbnail", "--embed-metadata", "--embed-chapters", "--write-thumbnail", "--write-info-json",
            "--sponsorblock-remove", "intro,sponsor",
            "--download-archive", "/tmp/Library/Application Support/download-archive.txt",
            "--cookies", "/tmp/Library/Application Support/Cookies/cookies.txt",
            "--limit-rate", "2M",
            "--concurrent-fragments", "4",
            "--proxy", "socks5://127.0.0.1:9050",
            "--user-agent", "Custom/1.0",
            "--retries", "5",
            "--", "https://example.com/v",
        ])
    }

    @Test("The URL comes last after --, even when it starts with a dash")
    func urlIsSeparated() {
        var options = makeOptions()
        options.customArguments = "--retries 5"
        let arguments = download(options, url: "-not-a-flag")
        #expect(arguments.suffix(2) == ["--", "-not-a-flag"])
        #expect(arguments.filter { $0 == "--" }.count == 1)
    }

    @Test("Engine plumbing is left to the host")
    func noPlumbing() {
        var options = makeOptions()
        options.ignoreUserConfig = true
        let arguments = download(options, capabilities: EmbeddedEngineCapabilities(allowsAV1: true, temporaryDirectory: partials))
        for flag in ["--newline", "--color", "--progress", "--progress-template", "--ffmpeg-location", "--dump-single-json"] {
            #expect(!arguments.contains(flag), "unexpected \(flag)")
        }
    }

    @Test("Files are dated when downloaded, so the Files app lists them as new")
    func noMtime() {
        #expect(download(makeOptions()).contains("--no-mtime"))
        var audio = makeOptions()
        audio.kind = .audio
        #expect(download(audio).contains("--no-mtime"))
    }

    @Test("Partial downloads go to the temporary folder only when one is given")
    func temporaryPath() {
        let withTemp = download(makeOptions(), capabilities: EmbeddedEngineCapabilities(temporaryDirectory: partials))
        #expect(values(after: "--paths", in: withTemp) == [
            "/tmp/Documents",
            "temp:/tmp/Library/Caches/Partial Downloads",
        ])

        let withoutTemp = download(makeOptions())
        #expect(values(after: "--paths", in: withoutTemp) == ["/tmp/Documents"])
    }

    @Test("Overwrite behaviour and the config file are handled as on the Mac")
    func sharedFileHandling() {
        var options = makeOptions()
        options.overwriteExisting = true
        options.ignoreUserConfig = false
        options.outputTemplate = "  "
        let arguments = download(options)
        #expect(arguments.contains("--force-overwrites"))
        #expect(!arguments.contains("--ignore-config"))
        #expect(value(after: "--output", in: arguments) == DownloadOptions.defaultOutputTemplate)
    }

    // MARK: - Video

    @Test(
        "Video selects MP4-compatible streams, with AV1 only where the device decodes it",
        arguments: [
            (nil as Int?, false,
             "bv*[ext=mp4][vcodec~='^(avc|h264|hvc|hev|h265)']+(ba[ext=m4a]/ba[acodec^=mp4a])/b[ext=mp4]/b/bv*+ba"),
            (nil, true,
             "bv*[ext=mp4][vcodec~='^(avc|h264|hvc|hev|h265|av01)']+(ba[ext=m4a]/ba[acodec^=mp4a])/b[ext=mp4]/b/bv*+ba"),
            (1080, false,
             "bv*[height<=?1080][ext=mp4][vcodec~='^(avc|h264|hvc|hev|h265)']+(ba[ext=m4a]/ba[acodec^=mp4a])"
                + "/b[height<=?1080][ext=mp4]"
                + "/bv*[ext=mp4][vcodec~='^(avc|h264|hvc|hev|h265)']+(ba[ext=m4a]/ba[acodec^=mp4a])/b[ext=mp4]/b/bv*+ba"),
            (2160, true,
             "bv*[height<=?2160][ext=mp4][vcodec~='^(avc|h264|hvc|hev|h265|av01)']+(ba[ext=m4a]/ba[acodec^=mp4a])"
                + "/b[height<=?2160][ext=mp4]"
                + "/bv*[ext=mp4][vcodec~='^(avc|h264|hvc|hev|h265|av01)']+(ba[ext=m4a]/ba[acodec^=mp4a])/b[ext=mp4]/b/bv*+ba"),
        ]
    )
    func videoSelector(maxHeight: Int?, allowsAV1: Bool, expected: String) {
        #expect(ArgumentBuilder.embeddedVideoFormatSelector(maxHeight: maxHeight, allowsAV1: allowsAV1) == expected)
    }

    @Test("Each quality preset caps the selector, and AV1 follows the device", arguments: VideoQuality.allCases)
    func videoArguments(quality: VideoQuality) {
        var options = makeOptions()
        options.videoQuality = quality

        for allowsAV1 in [false, true] {
            let arguments = download(options, capabilities: EmbeddedEngineCapabilities(allowsAV1: allowsAV1))
            let selector = value(after: "--format", in: arguments)
            #expect(selector == ArgumentBuilder.embeddedVideoFormatSelector(maxHeight: quality.maxHeight, allowsAV1: allowsAV1))
            #expect(selector?.contains("av01") == allowsAV1)
            if let height = quality.maxHeight {
                #expect(selector?.hasPrefix("bv*[height<=?\(height)]") == true)
            } else {
                #expect(selector?.contains("height") == false)
            }
            // The cap is dropped at the end so an unusual source still downloads something.
            #expect(selector?.hasSuffix("/b[ext=mp4]/b/bv*+ba") == true)
            #expect(!arguments.contains("--extract-audio"))
        }
    }

    @Test("Video always merges into MP4, whatever container was chosen", arguments: VideoContainer.allCases)
    func alwaysMP4(container: VideoContainer) {
        var options = makeOptions()
        options.container = container
        let arguments = download(options)
        #expect(value(after: "--merge-output-format", in: arguments) == "mp4")
        #expect(arguments.filter { $0 == "--merge-output-format" }.count == 1)
        #expect(!arguments.contains("--format-sort"))
    }

    // MARK: - Audio

    @Test(
        "Audio prefers AAC sources and converts only to formats iOS can encode",
        arguments: [
            (AudioFormat.best, "best", false),
            (.m4a, "m4a", true),
            (.alac, "alac", false),
            (.flac, "flac", false),
            (.wav, "wav", false),
            // No MP3 or Opus encoder on iOS: options saved elsewhere become M4A, keeping the bitrate.
            (.mp3, "m4a", true),
            (.opus, "m4a", true),
        ]
    )
    func audioArguments(format: AudioFormat, expectedFormat: String, passesQuality: Bool) {
        var options = makeOptions()
        options.kind = .audio
        options.audioFormat = format
        options.audioQuality = .kbps192
        options.container = .mp4

        let arguments = download(options)
        #expect(value(after: "--format", in: arguments) == "ba[ext=m4a]/ba[acodec^=mp4a]/ba/b")
        #expect(arguments.contains("--extract-audio"))
        #expect(value(after: "--audio-format", in: arguments) == expectedFormat)
        #expect(value(after: "--audio-quality", in: arguments) == (passesQuality ? "192K" : nil))
        #expect(!arguments.contains("--merge-output-format"))
    }

    @Test("The best-quality setting is passed through as VBR level 0")
    func audioBestQuality() {
        var options = makeOptions()
        options.kind = .audio
        options.audioFormat = .mp3
        options.audioQuality = .best
        #expect(value(after: "--audio-quality", in: download(options)) == "0")
    }

    @Test("Only formats with an iOS encoder are offered, and the rest map to M4A")
    func embeddedAudioFormats() {
        #expect(AudioFormat.allCases.filter(\.isAvailableInEmbeddedEngine) == [.best, .m4a, .alac, .flac, .wav])
        #expect(AudioFormat.mp3.embeddedEngineEquivalent == .m4a)
        #expect(AudioFormat.opus.embeddedEngineEquivalent == .m4a)
        for format in AudioFormat.allCases where format.isAvailableInEmbeddedEngine {
            #expect(format.embeddedEngineEquivalent == format)
        }
    }

    // MARK: - Subtitles

    @Test("Subtitles are saved alongside, never embedded, even when embedding is on")
    func subtitlesNeverEmbedded() {
        var options = makeOptions()
        options.subtitleMode = .manual
        options.subtitleLanguages = " en "
        options.embedSubtitles = true

        let arguments = download(options)
        #expect(arguments.contains("--write-subs"))
        #expect(!arguments.contains("--write-auto-subs"))
        #expect(value(after: "--sub-langs", in: arguments) == "en")
        #expect(!arguments.contains("--embed-subs"))

        // The Mac builder still embeds for the same options, so the difference is deliberate.
        #expect(ArgumentBuilder.downloadArguments(url: url, options: options).contains("--embed-subs"))
    }

    // MARK: - Cookies

    @Test("An imported cookies file is passed, browser cookies never are")
    func cookiesFile() {
        var options = makeOptions()
        options.cookieBrowser = .chrome
        options.cookieFilePath = "/tmp/Cookies/cookies.txt"

        let arguments = download(options)
        #expect(value(after: "--cookies", in: arguments) == "/tmp/Cookies/cookies.txt")
        #expect(!arguments.contains("--cookies-from-browser"))

        let metadata = ArgumentBuilder.embeddedMetadataArguments(url: url, options: options)
        #expect(value(after: "--cookies", in: metadata) == "/tmp/Cookies/cookies.txt")
        #expect(!metadata.contains("--cookies-from-browser"))
    }

    @Test("No cookies flag without a cookies file", arguments: ["", "   "])
    func noCookiesFile(path: String) {
        var options = makeOptions()
        options.cookieFilePath = path
        #expect(!download(options).contains("--cookies"))
        #expect(!ArgumentBuilder.embeddedMetadataArguments(url: url, options: options).contains("--cookies"))
    }

    // MARK: - Custom arguments

    @Test("Custom arguments that can't work in the app are removed, the rest kept")
    func embeddedCustomArgumentDenial() {
        var options = makeOptions()
        options.customArguments = "--cookies-from-browser safari --retries 5 -U --ffmpeg-location /opt/ffmpeg "
            + "--js-runtimes node --no-js-runtimes --remote-components ejs:github --update-to nightly "
            + "--exec id --no-part"

        let arguments = download(options)
        for flag in ["--cookies-from-browser", "-U", "--ffmpeg-location", "--js-runtimes", "--no-js-runtimes",
                     "--remote-components", "--update-to", "--exec"] {
            #expect(!arguments.contains(flag), "\(flag) should have been removed")
        }
        for token in ["safari", "/opt/ffmpeg", "node", "ejs:github", "nightly", "id"] {
            #expect(!arguments.contains(token), "\(token) should have been removed with its flag")
        }
        #expect(Array(arguments.suffix(5)) == ["--retries", "5", "--no-part", "--", url])

        let metadata = ArgumentBuilder.embeddedMetadataArguments(url: url, options: options)
        #expect(Array(metadata.suffix(5)) == ["--retries", "5", "--no-part", "--", url])
    }

    @Test("The Mac builder still passes options that only the embedded engine denies")
    func externalProcessKeepsEmbeddedOnlyFlags() {
        var options = makeOptions()
        options.customArguments = "--js-runtimes node --retries 5"
        let arguments = ArgumentBuilder.downloadArguments(url: url, options: options)
        #expect(value(after: "--js-runtimes", in: arguments) == "node")
    }

    // MARK: - Metadata

    @Test("Analysis arguments leave output handling to the host")
    func metadataArguments() {
        #expect(ArgumentBuilder.embeddedMetadataArguments(url: url, options: makeOptions()) == [
            "--flat-playlist",
            "--ignore-config",
            "--no-playlist",
            "--", url,
        ])
    }

    @Test("Analysis reuses playlist, cookie and connection settings, then custom arguments")
    func metadataWithOptions() {
        var options = makeOptions()
        options.ignoreUserConfig = false
        options.downloadPlaylist = true
        options.playlistItems = "1-3"
        options.cookieFilePath = "/tmp/cookies.txt"
        options.proxy = "http://127.0.0.1:8080"
        options.userAgent = "Custom/1.0"
        options.rateLimit = "1M"
        options.customArguments = "--extractor-args youtube:player_client=web --update"

        #expect(ArgumentBuilder.embeddedMetadataArguments(url: "-dash", options: options) == [
            "--flat-playlist",
            "--yes-playlist",
            "--cookies", "/tmp/cookies.txt",
            "--proxy", "http://127.0.0.1:8080",
            "--user-agent", "Custom/1.0",
            "--extractor-args", "youtube:player_client=web",
            "--", "-dash",
        ])
    }
}

/// The `--cookies` flag the Mac builder gained alongside the embedded one.
@Suite("Argument builder cookies file")
struct ArgumentBuilderCookieFileTests {

    private let url = "https://example.com/v"

    private func makeOptions() -> DownloadOptions {
        var options = DownloadOptions()
        options.outputDirectory = URL(fileURLWithPath: "/tmp/downloads")
        return options
    }

    @Test("A cookies file is passed to downloads and analysis, next to browser cookies")
    func cookiesFileOnMac() throws {
        var options = makeOptions()
        options.cookieBrowser = .firefox
        options.cookieFilePath = "/Users/me/cookies.txt"
        options.rateLimit = "2M"

        for arguments in [
            ArgumentBuilder.downloadArguments(url: url, options: options),
            ArgumentBuilder.metadataArguments(url: url, options: options),
        ] {
            let index = try #require(arguments.firstIndex(of: "--cookies"))
            #expect(arguments[index + 1] == "/Users/me/cookies.txt")
            #expect(Array(arguments[(index - 2)..<index]) == ["--cookies-from-browser", "firefox"])
        }
    }

    @Test("Nothing changes when no cookies file is set", arguments: ["", "  "])
    func noCookiesFileOnMac(path: String) {
        var options = makeOptions()
        options.cookieFilePath = path
        #expect(!ArgumentBuilder.downloadArguments(url: url, options: options).contains("--cookies"))
        #expect(!ArgumentBuilder.metadataArguments(url: url, options: options).contains("--cookies"))
    }

    @Test("The default Mac command is unchanged by the shared sections")
    func defaultMacCommand() {
        let arguments = ArgumentBuilder.downloadArguments(url: url, options: makeOptions())
        #expect(arguments == [
            "--newline", "--color", "never",
            "--progress", "--progress-template", ArgumentBuilder.downloadProgressTemplate,
            "--progress-template", ArgumentBuilder.postProcessTemplate,
            "--ignore-config",
            "--paths", "/tmp/downloads",
            "--output", "%(title)s.%(ext)s",
            "--no-overwrites",
            "--format", "bv*+ba/b",
            "--no-playlist",
            "--", url,
        ])
        #expect(ArgumentBuilder.metadataArguments(url: url, options: makeOptions()) == [
            "--dump-single-json", "--no-warnings", "--no-progress", "--color", "never", "--flat-playlist",
            "--ignore-config",
            "--no-playlist",
            "--", url,
        ])
    }
}
