import Foundation
import Testing
@testable import YTDLPGUI_iOS

@MainActor
@Suite("Download composer")
struct DownloadComposerTests {

    private let url = "https://www.youtube.com/watch?v=abc123"

    private func readyEnvironment() async throws -> AppTestEnvironment {
        let env = try AppTestEnvironment()
        await env.engine.start()
        #expect(env.engine.isReady)
        return env
    }

    // MARK: - Links

    @Test("Pasted text is reduced to the links in it")
    func urlHandling() async throws {
        let env = try await readyEnvironment()
        let composer = env.composer
        env.settings.autoAnalyzePastedURLs = false

        composer.setURLText("Watch this https://example.com/a and https://example.com/b later", analyzeIfEnabled: true)
        #expect(composer.detectedURLs == ["https://example.com/a", "https://example.com/b"])
        #expect(composer.isMultipleURLs)
        #expect(composer.downloadButtonTitle == "Download 2 Links")
        #expect(composer.canDownload)
        #expect(!composer.canAnalyze)

        composer.setURLText(url, analyzeIfEnabled: true)
        #expect(composer.detectedURLs == [url])
        #expect(composer.downloadButtonTitle == "Download")
        #expect(composer.canAnalyze)

        composer.setURLText("no links here", analyzeIfEnabled: true)
        #expect(composer.statusMessage == "No web address was found in that text.")
        #expect(!composer.hasValidURL)

        composer.clear()
        #expect(composer.urlText.isEmpty)
        #expect(composer.statusMessage == nil)
    }

    @Test("Nothing can be analysed or downloaded until the engine is ready")
    func waitsForEngine() throws {
        let env = try AppTestEnvironment()
        env.composer.urlText = url
        #expect(!env.composer.canAnalyze)
        #expect(!env.composer.canDownload)
        #expect(!env.composer.startDownload())
        #expect(env.queue.items.isEmpty)
    }

    @Test("A link pasted while the engine starts is analysed once it's ready")
    func autoAnalyzeAfterStart() async throws {
        let env = try AppTestEnvironment()
        env.analyzer.respond(with: .success(SampleInfo.video(url: url)))
        env.composer.setURLText(url, analyzeIfEnabled: true)
        #expect(env.composer.analysis == .idle)
        #expect(env.analyzer.calls.isEmpty)

        await env.engine.start()
        env.composer.engineDidBecomeReady()
        try await waitUntil("analysis") { env.composer.analysis.info != nil }
        #expect(env.composer.analysis.info?.title == "Sample Clip")
    }

    // MARK: - Analysis

    @Test("Analysis uses the embedded metadata arguments and loads the result")
    func analysisLoads() async throws {
        let env = try await readyEnvironment()
        env.analyzer.respond(with: .success(SampleInfo.video(url: url)), log: ["[youtube] abc123: Downloading webpage"])
        env.composer.setURLText(url, analyzeIfEnabled: true)

        try await waitUntil("analysis") { env.composer.analysis.info != nil }
        let argv = try #require(env.analyzer.calls.first)
        #expect(argv.contains("--flat-playlist"))
        #expect(!argv.contains("--dump-single-json"))
        #expect(Array(argv.suffix(2)) == ["--", url])
        #expect(env.composer.analysisLog == ["[youtube] abc123: Downloading webpage"])
        #expect(!env.composer.options.downloadPlaylist)
    }

    @Test("A link that is only a playlist turns playlist mode on")
    func playlistAdoption() async throws {
        let env = try await readyEnvironment()
        let playlistURL = "https://www.youtube.com/playlist?list=PL1"
        env.analyzer.respond(with: .success(SampleInfo.playlist(url: playlistURL)))
        env.composer.setURLText(playlistURL, analyzeIfEnabled: true)

        try await waitUntil("analysis") { env.composer.analysis.info != nil }
        #expect(env.composer.options.downloadPlaylist)
        #expect(env.composer.options.outputTemplate.hasPrefix("%(playlist_title|Downloads)s/"))
    }

    @Test("An analysis failure is classified from yt-dlp's output")
    func analysisFailure() async throws {
        let env = try await readyEnvironment()
        let log = ["[youtube] abc123: Downloading webpage", "ERROR: [youtube] abc123: Private video. Sign in if you've been granted access"]
        env.analyzer.respond(with: .failure(.analysisFailed(message: "Private video", logLines: log)))
        env.composer.setURLText(url, analyzeIfEnabled: true)

        try await waitUntil("failure") {
            if case .failed = env.composer.analysis { return true }
            return false
        }
        guard case .failed(let failure) = env.composer.analysis else { return }
        #expect(failure.kind == .privateOrMembersOnly)
        #expect(env.composer.analysisLog == log)
    }

    @Test("A cancelled analysis goes back to idle; other errors are reported as they are")
    func analysisCancelledAndUnknown() async throws {
        let env = try await readyEnvironment()
        env.analyzer.respond(with: .failure(.cancelled))
        env.composer.setURLText(url, analyzeIfEnabled: true)
        try await waitUntil("analysis attempted") { env.analyzer.calls.count == 1 }
        try await waitUntil("idle") { env.composer.analysis == .idle }

        env.analyzer.respond(with: .failure(.hostFailure(message: "The host crashed.", traceback: nil)))
        env.composer.analyze()
        try await waitUntil("failure") { env.composer.analysis != .analyzing }
        #expect(env.composer.analysis == .failed(DownloadFailure(kind: .unknown, underlyingMessage: "The host crashed.")))
    }

    // MARK: - Advisories

    @Test("Advisories speak about what this device can produce")
    func advisories() async throws {
        let env = try await readyEnvironment()
        let composer = env.composer
        #expect(composer.advisories.isEmpty)

        composer.options.videoQuality = .uhd2160
        #expect(composer.advisories.contains { $0.contains("only in AV1") })
        composer.options.videoQuality = .fhd1080
        #expect(!composer.advisories.contains { $0.contains("only in AV1") })

        composer.options.subtitleMode = .manual
        composer.options.embedSubtitles = true
        #expect(composer.advisories.contains { $0.contains("separate files") })
        composer.options.subtitleMode = .off
        #expect(!composer.advisories.contains { $0.contains("separate files") })

        composer.options.kind = .audio
        composer.options.audioFormat = .mp3
        #expect(composer.advisories.contains { $0.contains("M4A") })
        composer.options.audioFormat = .flac
        #expect(!composer.advisories.contains { $0.contains("M4A") })

        composer.options.sponsorBlockMode = .remove
        composer.options.sponsorBlockCategories = []
        #expect(composer.advisories.contains { $0.contains("SponsorBlock") })

        composer.options.customArguments = "--cookies-from-browser safari"
        #expect(composer.advisories.first == composer.customArgumentBlockMessage)
        // Nothing mentions ffmpeg or a folder to choose on iOS.
        #expect(!composer.advisories.contains { $0.contains("ffmpeg") || $0.contains("archive file") })
    }

    @Test("The AV1 advisory for Best appears only when a YouTube analysis shows more than 1080p")
    func av1AdvisoryForBest() async throws {
        let env = try await readyEnvironment()
        env.analyzer.respond(with: .success(SampleInfo.video(url: url, maxHeight: 2160)))
        env.composer.setURLText(url, analyzeIfEnabled: true)
        #expect(!env.composer.advisories.contains { $0.contains("only in AV1") })
        try await waitUntil("analysis") { env.composer.analysis.info != nil }
        #expect(env.composer.advisories.contains { $0.contains("only in AV1") })
    }

    @Test("A missing cookies file is pointed out")
    func missingCookiesAdvisory() async throws {
        let env = try await readyEnvironment()
        try CookieStoreTests.importSampleCookies(into: env)
        #expect(!env.composer.advisories.contains { $0.contains("cookies") })

        try FileManager.default.removeItem(at: env.cookies.storedFileURL)
        #expect(env.composer.advisories.contains { $0.contains("cookies file is missing") })
    }

    // MARK: - Options and the preview

    @Test("The command preview is the embedded argument vector, shell-quoted")
    func commandPreview() async throws {
        let env = try await readyEnvironment()
        let composer = env.composer
        #expect(composer.commandPreview.hasPrefix("yt-dlp "))
        #expect(composer.commandPreview.hasSuffix(" -- URL"))

        composer.setURLText(url, analyzeIfEnabled: false)
        let expected = ShellQuoting.commandLine(
            executable: "yt-dlp",
            arguments: ArgumentBuilder.embeddedDownloadArguments(
                url: url,
                options: DownloadOptionsResolver(storage: env.storage, cookies: env.cookies).resolve(composer.options),
                capabilities: env.engine.capabilities
            )
        )
        #expect(composer.commandPreview == expected)
        #expect(composer.commandPreview.contains(ShellQuoting.quote(env.storage.downloadsDirectory.path(percentEncoded: false))))
        #expect(composer.commandPreview.hasSuffix("-- '\(url)'") || composer.commandPreview.hasSuffix("-- \(url)"))
        #expect(!composer.commandPreview.contains("--cookies "))

        try CookieStoreTests.importSampleCookies(into: env)
        #expect(composer.commandPreview.contains("--cookies " + ShellQuoting.quote(env.cookies.storedFileURL.path(percentEncoded: false))))
    }

    @Test("The command preview masks credentials")
    func commandPreviewRedactsSecrets() async throws {
        let env = try await readyEnvironment()
        let composer = env.composer
        composer.setURLText(url, analyzeIfEnabled: false)
        composer.options.customArguments = "--password s3cret -2 123456"
        composer.options.proxy = "socks5://user:pass@proxy.test:1080"

        let preview = composer.commandPreview
        #expect(!preview.contains("s3cret"))
        #expect(!preview.contains("123456"))
        #expect(!preview.contains("user:pass"))
        #expect(preview.contains("--password PRIVATE"))
        #expect(preview.contains("socks5://PRIVATE@proxy.test:1080"))
        // Only the display is masked.
        #expect(composer.options.customArguments == "--password s3cret -2 123456")
    }

    @Test("Queued options carry this install's paths; the composer's own options don't")
    func optionNormalisation() async throws {
        let env = try await readyEnvironment()
        try CookieStoreTests.importSampleCookies(into: env)
        let composer = env.composer
        composer.options.useDownloadArchive = true
        composer.options.audioFormat = .opus
        composer.setURLText(url, analyzeIfEnabled: false)

        #expect(composer.startDownload())
        let item = try #require(env.queue.items.first)
        #expect(item.options.outputDirectory == env.storage.downloadsDirectory)
        #expect(item.options.cookieFilePath == env.cookies.storedFileURL.path(percentEncoded: false))
        #expect(item.options.downloadArchivePath == env.storage.downloadArchiveURL.path(percentEncoded: false))
        #expect(item.options.audioFormat == .m4a)
        #expect(item.options.ignoreUserConfig)

        #expect(composer.options.cookieFilePath.isEmpty)
        #expect(composer.options.downloadArchivePath.isEmpty)
        #expect(composer.options.audioFormat == .opus)
        #expect(env.settings.storedOptions.cookieFilePath.isEmpty)
        #expect(composer.urlText.isEmpty)
        #expect(composer.statusMessage == "Added 1 download to the queue.")
    }

    @Test("An analysed link that is already queued isn't queued again, and stays in the field")
    func duplicateAnalysedLink() async throws {
        let env = try await readyEnvironment()
        let composer = env.composer
        env.analyzer.respond(with: .success(SampleInfo.video(url: url)))
        composer.setURLText(url, analyzeIfEnabled: true)
        try await waitUntil("analysis") { composer.analysis.info != nil }
        #expect(composer.startDownload())
        #expect(composer.statusMessage == "Added “Sample Clip” to the queue.")
        _ = try await waitForJobs(1, on: env.downloader)

        composer.setURLText(url, analyzeIfEnabled: true)
        try await waitUntil("second analysis") { composer.analysis.info != nil }
        #expect(!composer.startDownload())
        #expect(composer.statusMessage == "That link is already in the queue.")
        #expect(composer.urlText == url)
        #expect(env.queue.items.count == 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(env.downloader.jobs.count == 1)
    }

    @Test("Custom arguments the engine refuses block downloading")
    func blockedCustomArguments() async throws {
        let env = try await readyEnvironment()
        let composer = env.composer
        composer.setURLText(url, analyzeIfEnabled: false)
        composer.options.customArguments = "--js-runtimes node --no-mtime"

        #expect(composer.hasBlockedCustomArguments)
        #expect(!composer.canDownload)
        #expect(!composer.canAnalyze)
        #expect(!composer.startDownload())
        #expect(composer.statusMessage == composer.customArgumentBlockMessage)
        #expect(env.queue.items.isEmpty)
        #expect(!composer.commandPreview.contains("--js-runtimes"))
    }

    @Test("Only the formats this device can encode are offered")
    func availableAudioFormats() async throws {
        let env = try await readyEnvironment()
        #expect(env.composer.availableAudioFormats == [.best, .m4a, .alac, .flac, .wav])
    }

    @Test("Customised advanced options are counted, and reset leaves the main choices alone")
    func customisedCountAndReset() async throws {
        let env = try await readyEnvironment()
        let composer = env.composer
        #expect(composer.customizedAdvancedOptionCount == 0)

        composer.options.kind = .audio
        composer.options.videoQuality = .hd720
        composer.options.audioFormat = .flac
        composer.options.audioQuality = .kbps128
        composer.options.container = .mkv
        composer.options.cookieFilePath = "/somewhere/cookies.txt"
        composer.options.downloadArchivePath = "/somewhere/archive.txt"
        #expect(composer.customizedAdvancedOptionCount == 0)

        composer.options.outputTemplate = "%(uploader)s - %(title)s.%(ext)s"
        composer.options.embedThumbnail = true
        composer.options.sponsorBlockCategories = [.sponsor, .intro]
        composer.options.concurrentFragments = 4
        composer.options.customArguments = "--no-mtime"
        #expect(composer.customizedAdvancedOptionCount == 5)

        composer.resetAdvancedOptions()
        #expect(composer.customizedAdvancedOptionCount == 0)
        #expect(composer.options.outputTemplate == DownloadOptions.defaultOutputTemplate)
        #expect(composer.options.kind == .audio)
        #expect(composer.options.videoQuality == .hd720)
        #expect(composer.options.audioFormat == .flac)
        #expect(composer.options.audioQuality == .kbps128)
    }

    @Test("Stored options start without paths from an earlier install")
    func storedOptionsAreCleaned() throws {
        let env = try AppTestEnvironment()
        var remembered = DownloadOptions()
        remembered.kind = .audio
        remembered.cookieFilePath = "/old/cookies.txt"
        remembered.downloadArchivePath = "/old/archive.txt"
        remembered.cookieBrowser = .safari
        env.settings.rememberOptions(remembered)

        let composer = DownloadComposer(
            settings: env.settings,
            engine: env.engine,
            queue: env.queue,
            storage: env.storage,
            cookies: env.cookies,
            analyzer: env.analyzer
        )
        #expect(composer.options.kind == .audio)
        #expect(composer.options.cookieFilePath.isEmpty)
        #expect(composer.options.downloadArchivePath.isEmpty)
        #expect(composer.options.cookieBrowser == .none)
        #expect(composer.options.outputDirectory == env.storage.downloadsDirectory)
        #expect(composer.customizedAdvancedOptionCount == 0)
    }
}
