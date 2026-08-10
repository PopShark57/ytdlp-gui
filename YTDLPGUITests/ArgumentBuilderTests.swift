import Foundation
import Testing

@testable import YTDLPGUI

@Suite("Argument builder")
struct ArgumentBuilderTests {

    private func makeOptions() -> DownloadOptions {
        var options = DownloadOptions()
        options.outputDirectory = URL(fileURLWithPath: "/tmp/downloads")
        return options
    }

    /// Finds the value that follows a flag, which is how every option is verified here.
    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    // MARK: - Structure

    @Test("URL is passed after a -- separator so a leading dash can't become a flag")
    func urlIsSeparated() {
        let arguments = ArgumentBuilder.downloadArguments(
            url: "-not-a-flag",
            options: makeOptions()
        )
        #expect(arguments.suffix(2) == ["--", "-not-a-flag"])
    }

    @Test("Machine-readable progress is always requested")
    func progressTemplateIsPresent() {
        let arguments = ArgumentBuilder.downloadArguments(url: "https://example.com/v", options: makeOptions())
        #expect(arguments.contains("--newline"))
        #expect(arguments.contains(ArgumentBuilder.downloadProgressTemplate))
        #expect(arguments.contains(ArgumentBuilder.postProcessTemplate))
        #expect(value(after: "--color", in: arguments) == "never")
    }

    @Test("Output directory and template are passed separately")
    func outputPaths() {
        var options = makeOptions()
        options.outputTemplate = "%(title)s.%(ext)s"
        let arguments = ArgumentBuilder.downloadArguments(url: "https://example.com/v", options: options)
        #expect(value(after: "--paths", in: arguments) == "/tmp/downloads")
        #expect(value(after: "--output", in: arguments) == "%(title)s.%(ext)s")
    }

    @Test("An empty template falls back to the default rather than producing an empty argument")
    func emptyTemplateFallsBack() {
        var options = makeOptions()
        options.outputTemplate = "   "
        let arguments = ArgumentBuilder.downloadArguments(url: "https://example.com/v", options: options)
        #expect(value(after: "--output", in: arguments) == DownloadOptions.defaultOutputTemplate)
    }

    @Test("ffmpeg location is forwarded when known")
    func ffmpegLocation() {
        let arguments = ArgumentBuilder.downloadArguments(
            url: "https://example.com/v",
            options: makeOptions(),
            ffmpegURL: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        )
        #expect(value(after: "--ffmpeg-location", in: arguments) == "/opt/homebrew/bin/ffmpeg")
    }

    // MARK: - Format selection

    @Test("Best quality prefers separate streams with a combined fallback")
    func bestQualitySelector() {
        #expect(ArgumentBuilder.videoFormatSelector(maxHeight: nil) == "bv*+ba/b")
    }

    @Test("A height cap is applied non-strictly, keeping formats of unknown height")
    func cappedSelector() {
        let selector = ArgumentBuilder.videoFormatSelector(maxHeight: 1080)
        #expect(selector == "bv*[height<=?1080]+ba/b[height<=?1080]/bv*+ba/b")
        // The final fallback must have no cap, so an unusual source still downloads.
        #expect(selector.hasSuffix("/bv*+ba/b"))
    }

    @Test(
        "Every video preset maps to its expected cap",
        arguments: [
            (VideoQuality.best, nil as Int?),
            (.uhd2160, 2160),
            (.qhd1440, 1440),
            (.fhd1080, 1080),
            (.hd720, 720),
            (.sd480, 480),
        ]
    )
    func qualityCaps(quality: VideoQuality, expected: Int?) {
        #expect(quality.maxHeight == expected)
    }

    @Test("Container preference sorts by resolution before extension")
    func containerSortOrder() {
        // Sorting by extension alone would pick a 480p MP4 over a 1080p WebM.
        #expect(ArgumentBuilder.formatSort(for: .mp4) == "res,ext:mp4:m4a")
        #expect(ArgumentBuilder.formatSort(for: .webm) == "res,ext:webm:webm")
        #expect(ArgumentBuilder.formatSort(for: .mkv) == nil)
        #expect(ArgumentBuilder.formatSort(for: .auto) == nil)
    }

    @Test("Choosing a container also sets the merge output format")
    func mergeOutputFormat() {
        var options = makeOptions()
        options.container = .mp4
        let arguments = ArgumentBuilder.downloadArguments(url: "https://example.com/v", options: options)
        #expect(value(after: "--merge-output-format", in: arguments) == "mp4")

        options.container = .auto
        let automatic = ArgumentBuilder.downloadArguments(url: "https://example.com/v", options: options)
        #expect(!automatic.contains("--merge-output-format"))
    }

    // MARK: - Audio

    @Test("Audio downloads extract and convert")
    func audioArguments() {
        var options = makeOptions()
        options.kind = .audio
        options.audioFormat = .mp3
        options.audioQuality = .kbps192

        let arguments = ArgumentBuilder.downloadArguments(url: "https://example.com/v", options: options)
        #expect(arguments.contains("--extract-audio"))
        #expect(value(after: "--format", in: arguments) == "bestaudio/best")
        #expect(value(after: "--audio-format", in: arguments) == "mp3")
        #expect(value(after: "--audio-quality", in: arguments) == "192K")
    }

    @Test("Quality is omitted for formats where it has no meaning")
    func losslessAudioSkipsQuality() {
        var options = makeOptions()
        options.kind = .audio
        options.audioFormat = .flac
        let arguments = ArgumentBuilder.downloadArguments(url: "https://example.com/v", options: options)
        #expect(!arguments.contains("--audio-quality"))
    }

    @Test("Audio downloads never pass video-only flags")
    func audioSkipsMerge() {
        var options = makeOptions()
        options.kind = .audio
        options.container = .mp4
        let arguments = ArgumentBuilder.downloadArguments(url: "https://example.com/v", options: options)
        #expect(!arguments.contains("--merge-output-format"))
        #expect(!arguments.contains("--format-sort"))
    }

    // MARK: - Playlists

    @Test("Playlist handling is always explicit")
    func playlistFlags() {
        var options = makeOptions()
        options.downloadPlaylist = false
        var arguments = ArgumentBuilder.downloadArguments(url: "https://example.com/v", options: options)
        #expect(arguments.contains("--no-playlist"))
        #expect(!arguments.contains("--yes-playlist"))

        options.downloadPlaylist = true
        options.playlistItems = "1-5"
        arguments = ArgumentBuilder.downloadArguments(url: "https://example.com/v", options: options)
        #expect(arguments.contains("--yes-playlist"))
        #expect(value(after: "--playlist-items", in: arguments) == "1-5")
    }

    @Test("Item selection is ignored when playlist downloading is off")
    func playlistItemsRequirePlaylistMode() {
        var options = makeOptions()
        options.downloadPlaylist = false
        options.playlistItems = "1-5"
        let arguments = ArgumentBuilder.downloadArguments(url: "https://example.com/v", options: options)
        #expect(!arguments.contains("--playlist-items"))
    }

    // MARK: - Subtitles and metadata

    @Test("Subtitle mode maps onto the right pair of flags")
    func subtitleFlags() {
        var options = makeOptions()
        options.subtitleMode = .both
        options.subtitleLanguages = "en,de"
        options.embedSubtitles = true

        let arguments = ArgumentBuilder.downloadArguments(url: "https://example.com/v", options: options)
        #expect(arguments.contains("--write-subs"))
        #expect(arguments.contains("--write-auto-subs"))
        #expect(value(after: "--sub-langs", in: arguments) == "en,de")
        #expect(arguments.contains("--embed-subs"))
    }

    @Test("Subtitles are not embedded into an audio-only download")
    func noEmbeddedSubtitlesForAudio() {
        var options = makeOptions()
        options.kind = .audio
        options.subtitleMode = .manual
        options.embedSubtitles = true
        let arguments = ArgumentBuilder.downloadArguments(url: "https://example.com/v", options: options)
        #expect(!arguments.contains("--embed-subs"))
    }

    @Test("Nothing subtitle-related is passed when subtitles are off")
    func subtitlesOff() {
        var options = makeOptions()
        options.subtitleMode = .off
        options.embedSubtitles = true
        let arguments = ArgumentBuilder.downloadArguments(url: "https://example.com/v", options: options)
        #expect(!arguments.contains("--write-subs"))
        #expect(!arguments.contains("--sub-langs"))
        #expect(!arguments.contains("--embed-subs"))
    }

    // MARK: - SponsorBlock

    @Test("SponsorBlock categories are sorted so the command is stable")
    func sponsorBlock() {
        var options = makeOptions()
        options.sponsorBlockMode = .remove
        options.sponsorBlockCategories = [.selfpromo, .sponsor, .intro]

        let arguments = ArgumentBuilder.downloadArguments(url: "https://example.com/v", options: options)
        #expect(value(after: "--sponsorblock-remove", in: arguments) == "intro,selfpromo,sponsor")
        #expect(!arguments.contains("--sponsorblock-mark"))
    }

    @Test("SponsorBlock is skipped when no categories are chosen")
    func sponsorBlockWithoutCategories() {
        var options = makeOptions()
        options.sponsorBlockMode = .mark
        options.sponsorBlockCategories = []
        let arguments = ArgumentBuilder.downloadArguments(url: "https://example.com/v", options: options)
        #expect(!arguments.contains("--sponsorblock-mark"))
    }

    // MARK: - Network

    @Test("Network options are only present when set")
    func networkOptions() {
        var options = makeOptions()
        let bare = ArgumentBuilder.downloadArguments(url: "https://example.com/v", options: options)
        #expect(!bare.contains("--limit-rate"))
        #expect(!bare.contains("--proxy"))
        #expect(!bare.contains("--user-agent"))
        #expect(!bare.contains("--cookies-from-browser"))
        #expect(!bare.contains("--concurrent-fragments"))

        options.rateLimit = "2M"
        options.proxy = "socks5://127.0.0.1:9050"
        options.userAgent = "Custom/1.0"
        options.cookieBrowser = .safari
        options.concurrentFragments = 4

        let full = ArgumentBuilder.downloadArguments(url: "https://example.com/v", options: options)
        #expect(value(after: "--limit-rate", in: full) == "2M")
        #expect(value(after: "--proxy", in: full) == "socks5://127.0.0.1:9050")
        #expect(value(after: "--user-agent", in: full) == "Custom/1.0")
        #expect(value(after: "--cookies-from-browser", in: full) == "safari")
        #expect(value(after: "--concurrent-fragments", in: full) == "4")
    }

    @Test("A single fragment is the default and needs no flag")
    func singleFragment() {
        var options = makeOptions()
        options.concurrentFragments = 1
        let arguments = ArgumentBuilder.downloadArguments(url: "https://example.com/v", options: options)
        #expect(!arguments.contains("--concurrent-fragments"))
    }

    // MARK: - Custom arguments

    @Test("Custom arguments are split respecting quotes and placed before the URL")
    func customArguments() {
        var options = makeOptions()
        options.customArguments = #"--extractor-args "youtube:player_client=web" --retries 5"#

        let arguments = ArgumentBuilder.downloadArguments(url: "https://example.com/v", options: options)
        #expect(value(after: "--extractor-args", in: arguments) == "youtube:player_client=web")
        #expect(value(after: "--retries", in: arguments) == "5")

        // They must come last so a power user can override anything the UI set.
        let customIndex = arguments.firstIndex(of: "--retries")!
        let separatorIndex = arguments.firstIndex(of: "--")!
        #expect(customIndex < separatorIndex)
    }

    @Test("Overwrite behaviour is always stated explicitly")
    func overwriteFlags() {
        var options = makeOptions()
        options.overwriteExisting = false
        #expect(ArgumentBuilder.downloadArguments(url: "u", options: options).contains("--no-overwrites"))

        options.overwriteExisting = true
        #expect(ArgumentBuilder.downloadArguments(url: "u", options: options).contains("--force-overwrites"))
    }

    @Test("The user's yt-dlp.conf is ignored by default so the preview stays truthful")
    func ignoreConfig() {
        var options = makeOptions()
        #expect(options.ignoreUserConfig)
        #expect(ArgumentBuilder.downloadArguments(url: "u", options: options).contains("--ignore-config"))

        options.ignoreUserConfig = false
        #expect(!ArgumentBuilder.downloadArguments(url: "u", options: options).contains("--ignore-config"))
    }

    // MARK: - Metadata command

    @Test("Analysis dumps JSON without downloading")
    func metadataArguments() {
        let arguments = ArgumentBuilder.metadataArguments(url: "https://example.com/v", options: makeOptions())
        #expect(arguments.contains("--dump-single-json"))
        #expect(arguments.contains("--flat-playlist"))
        #expect(arguments.suffix(2) == ["--", "https://example.com/v"])
        // Nothing that would write to disk.
        #expect(!arguments.contains("--paths"))
        #expect(!arguments.contains("--output"))
    }

    @Test("Analysis reuses the cookie and proxy settings so gated media can be inspected")
    func metadataUsesAuthOptions() {
        var options = makeOptions()
        options.cookieBrowser = .firefox
        options.proxy = "http://127.0.0.1:8080"
        let arguments = ArgumentBuilder.metadataArguments(url: "https://example.com/v", options: options)
        #expect(value(after: "--cookies-from-browser", in: arguments) == "firefox")
        #expect(value(after: "--proxy", in: arguments) == "http://127.0.0.1:8080")
    }
}
