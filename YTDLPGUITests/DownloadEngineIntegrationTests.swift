import Foundation
import Testing

@testable import YTDLPGUI

/// Drives the whole download pipeline against the real `yt-dlp` binary.
///
/// No network is involved: a short clip is generated with ffmpeg and handed to yt-dlp as a
/// `file://` URL, which exercises argument building, process launching, progress parsing, phase
/// tracking, output-path detection and history recording exactly as a real download would.
///
/// The suite skips itself when yt-dlp or ffmpeg aren't installed, so a checkout without them
/// still has a green test run.
@MainActor
@Suite("Download engine integration", .enabled(if: IntegrationSupport.isAvailable), .serialized)
struct DownloadEngineIntegrationTests {

    // MARK: - Fixture

    // Nested types don't inherit the suite's isolation, so this is annotated explicitly.
    @MainActor
    private final class Fixture {
        let root: URL
        let outputDirectory: URL
        let clipURL: URL
        let model: AppModel

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "ytdlpgui-tests-\(UUID().uuidString)")
            outputDirectory = root.appending(path: "out")
            clipURL = root.appending(path: "Clip.mp4")

            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            try IntegrationSupport.makeTestClip(at: clipURL)

            let defaults = UserDefaults(suiteName: "integration-\(UUID().uuidString)")!
            let settings = AppSettings(defaults: defaults)
            // Notifications would raise a system permission prompt in a test run.
            settings.notifyWhenComplete = false
            settings.revealWhenComplete = false

            model = AppModel(
                settings: settings,
                history: HistoryStore(fileURL: root.appending(path: "history.json"))
            )
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }

        var sourceURL: String {
            URL(fileURLWithPath: clipURL.path(percentEncoded: false)).absoluteString
        }

        func makeOptions() -> DownloadOptions {
            var options = DownloadOptions()
            options.outputDirectory = outputDirectory
            options.outputTemplate = "%(title)s.%(ext)s"
            // yt-dlp refuses file:// URLs unless this is passed; it also proves the custom
            // argument field reaches the real process.
            options.customArguments = "--enable-file-urls"
            return options
        }
    }

    /// Polls until `condition` holds or the deadline passes.
    private func wait(
        timeout: Duration = .seconds(90),
        until condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    // MARK: - Tests

    @Test("A video download completes and reports the file it produced")
    func videoDownloadCompletes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        await fixture.model.toolchain.refresh()
        try #require(fixture.model.toolchain.isReady, "yt-dlp should have been detected")

        let item = fixture.model.queue.enqueue(url: fixture.sourceURL, options: fixture.makeOptions())

        let finished = await wait { item.state.isFinished }
        #expect(finished, "the download did not finish in time")
        #expect(item.state == .completed, "failed: \(item.failure?.title ?? "unknown")\n\(item.log.joined)")
        #expect(item.phase == .completed)

        let outputURL = try #require(item.outputURL, "no output path was detected")
        #expect(FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)))
        #expect(outputURL.lastPathComponent == "Clip.mp4")
        #expect((item.completedFileSize ?? 0) > 0)
        #expect(item.progress.fractionCompleted == 1.0)
    }

    @Test("Audio extraction reports the converted file, not the intermediate video")
    func audioExtractionReportsFinalFile() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        await fixture.model.toolchain.refresh()
        try #require(fixture.model.toolchain.canMergeStreams, "ffmpeg should have been detected")

        var options = fixture.makeOptions()
        options.kind = .audio
        options.audioFormat = .mp3
        options.audioQuality = .kbps192

        let item = fixture.model.queue.enqueue(url: fixture.sourceURL, options: options)
        let finished = await wait { item.state.isFinished }

        #expect(finished, "the download did not finish in time")
        #expect(item.state == .completed, "failed: \(item.failure?.title ?? "unknown")\n\(item.log.joined)")

        // The deliverable is the mp3 produced by the post-processor, not the mp4 that was
        // downloaded first and then deleted.
        let outputURL = try #require(item.outputURL)
        #expect(outputURL.pathExtension == "mp3")
        #expect(FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)))
    }

    @Test("Post-processing stages are observed as they happen")
    func postProcessingPhasesAreSeen() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        await fixture.model.toolchain.refresh()
        try #require(fixture.model.toolchain.canMergeStreams)

        var options = fixture.makeOptions()
        options.kind = .audio
        options.audioFormat = .mp3

        let item = fixture.model.queue.enqueue(url: fixture.sourceURL, options: options)
        _ = await wait { item.state.isFinished }

        // The structured post-processing markers must have reached the log, which is what the
        // phase display is driven from.
        #expect(item.log.lines.contains { $0.hasPrefix(ArgumentBuilder.postProcessMarker) })
        #expect(item.log.lines.contains { $0.contains("ExtractAudio") })
    }

    @Test("A completed download is recorded in history")
    func historyIsRecorded() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        await fixture.model.toolchain.refresh()
        let item = fixture.model.queue.enqueue(url: fixture.sourceURL, options: fixture.makeOptions())
        _ = await wait { item.state.isFinished }

        let entry = try #require(fixture.model.history.entries.first)
        #expect(entry.succeeded)
        #expect(entry.sourceURL == fixture.sourceURL)
        #expect(entry.outputPath != nil)
        // The options are stored so "Download again" reproduces the original request.
        #expect(entry.options?.customArguments == "--enable-file-urls")
    }

    @Test("Cancelling a running download stops it and leaves no completed state")
    func cancellation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        await fixture.model.toolchain.refresh()

        var options = fixture.makeOptions()
        // Slow the transfer right down so there is a window in which to cancel it.
        options.rateLimit = "4K"

        let item = fixture.model.queue.enqueue(url: fixture.sourceURL, options: options)

        let started = await wait(timeout: .seconds(30)) {
            item.state == .active && item.progress.downloadedBytes != nil
        }
        #expect(started, "the download never started")

        fixture.model.queue.cancel(item)

        let stopped = await wait(timeout: .seconds(30)) { item.state.isFinished }
        #expect(stopped, "the download did not stop after being cancelled")
        #expect(item.state == .cancelled)
        #expect(item.failure?.kind == .cancelled)
    }

    @Test("A bad URL fails with a classified error rather than hanging or crashing")
    func invalidSourceFails() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        await fixture.model.toolchain.refresh()

        var options = fixture.makeOptions()
        options.customArguments = ""
        let missing = fixture.root.appending(path: "does-not-exist.mp4")
        let item = fixture.model.queue.enqueue(
            url: URL(fileURLWithPath: missing.path(percentEncoded: false)).absoluteString,
            options: options
        )

        let finished = await wait(timeout: .seconds(60)) { item.state.isFinished }
        #expect(finished)
        #expect(item.state == .failed)
        #expect(item.failure != nil)
        #expect(!(item.failure?.title.isEmpty ?? true))
    }

    @Test("The concurrency limit is respected")
    func concurrencyLimit() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        await fixture.model.toolchain.refresh()
        fixture.model.settings.maximumConcurrentDownloads = 1

        var options = fixture.makeOptions()
        options.rateLimit = "8K"
        options.outputTemplate = "%(title)s-%(autonumber)s.%(ext)s"

        let first = fixture.model.queue.enqueue(url: fixture.sourceURL, options: options)
        let second = fixture.model.queue.enqueue(url: fixture.sourceURL, options: options)

        _ = await wait(timeout: .seconds(30)) { first.state == .active }
        // With a limit of one, the second item must still be waiting its turn.
        #expect(second.state == .queued)
        #expect(fixture.model.queue.activeCount == 1)

        fixture.model.queue.cancelAll()
        _ = await wait(timeout: .seconds(30)) { !fixture.model.queue.isBusy }
    }
}

// MARK: - Support

/// Prerequisites for the integration suite.
enum IntegrationSupport {

    /// Both tools must be present; without them the suite is skipped rather than failed.
    static var isAvailable: Bool {
        ToolLocator.findExecutable(named: "yt-dlp") != nil
            && ToolLocator.findExecutable(named: "ffmpeg") != nil
    }

    /// Generates a short silent-ish test clip with ffmpeg.
    static func makeTestClip(at url: URL) throws {
        guard let ffmpeg = ToolLocator.findExecutable(named: "ffmpeg") else {
            throw IntegrationError.ffmpegMissing
        }

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-v", "error", "-y",
            "-f", "lavfi", "-i", "testsrc=size=320x180:rate=15:duration=3",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
            "-c:v", "libx264", "-preset", "ultrafast",
            "-c:a", "aac", "-shortest",
            url.path(percentEncoded: false),
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw IntegrationError.clipGenerationFailed
        }
    }

    enum IntegrationError: Error {
        case ffmpegMissing
        case clipGenerationFailed
    }
}
