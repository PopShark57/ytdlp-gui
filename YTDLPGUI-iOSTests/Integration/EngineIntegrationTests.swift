import AVFoundation
import Foundation
import Testing
@testable import YTDLPGUI_iOS

/// Runs the whole engine — embedded Python, yt-dlp, the host, the bridge and the AVFoundation
/// post-processors — against media served from the loopback interface. No internet needed.
@Suite("Engine integration", .serialized, .timeLimit(.minutes(3)))
struct EngineIntegrationTests {

    // MARK: - Fixtures

    /// Copies the bundled fixtures into a fresh folder the test server can serve.
    private static func makeServedFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "engine-fixtures-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bundle = Bundle(for: FixtureBundleToken.self)
        for (name, ext) in [("dash-video", "mp4"), ("dash-audio", "m4a"), ("dash", "mpd"), ("progressive", "mp4")] {
            guard let source = bundle.url(forResource: name, withExtension: ext) else {
                throw FixtureError.missing("\(name).\(ext)")
            }
            try FileManager.default.copyItem(at: source, to: folder.appending(path: "\(name).\(ext)"))
        }
        return folder
    }

    private static func makeOutputFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "engine-output-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func options(kind: DownloadKind, output: URL) -> DownloadOptions {
        var options = DownloadOptions()
        options.kind = kind
        options.outputDirectory = output
        options.outputTemplate = "%(id)s.%(ext)s"
        // The generic extractor needs no config file, and the test must not pick one up.
        options.ignoreUserConfig = true
        return options
    }

    /// Runs a download to completion and returns everything it reported.
    private static func run(
        url: URL,
        options: DownloadOptions,
        capabilities: EmbeddedEngineCapabilities = EmbeddedEngineCapabilities()
    ) async throws -> (events: [EngineEvent], result: EngineJobResult) {
        _ = try await YTDLPEngine.shared.start()
        let argv = ArgumentBuilder.embeddedDownloadArguments(
            url: url.absoluteString,
            options: options,
            capabilities: capabilities
        )
        var events: [EngineEvent] = []
        var result: EngineJobResult?
        for await update in YTDLPEngine.shared.download(argv: argv, jobID: UUID()) {
            switch update {
            case .event(let event): events.append(event)
            case .finished(let finished): result = finished
            }
        }
        let finished = try #require(result, "The download stream ended without a result")
        return (events, finished)
    }

    private static func logLines(_ events: [EngineEvent]) -> [String] {
        events.compactMap { event in
            if case .log(_, let line) = event { return line }
            return nil
        }
    }

    private static func trackCounts(of file: URL) async throws -> (video: Int, audio: Int) {
        let asset = AVURLAsset(url: file)
        let video = try await asset.loadTracks(withMediaType: .video).count
        let audio = try await asset.loadTracks(withMediaType: .audio).count
        return (video, audio)
    }

    // MARK: - Tests

    @Test("The engine starts and reports the bundled versions")
    func engineStarts() async throws {
        let info = try await YTDLPEngine.shared.start()
        #expect(info.pythonVersion.hasPrefix("3.14"))
        #expect(!info.ytdlpVersion.isEmpty)
        #expect(info.ejsVersion != nil, "yt-dlp-ejs must be importable, or YouTube challenges can't be solved")
    }

    @Test("A single file downloads over HTTP and lands in the output folder")
    func downloadsProgressiveFile() async throws {
        let served = try Self.makeServedFolder()
        let output = try Self.makeOutputFolder()
        let server = try LocalHTTPServer(root: served)
        let base = try await server.start()
        defer { server.stop() }

        let (events, result) = try await Self.run(
            url: base.appending(path: "progressive.mp4"),
            options: Self.options(kind: .video, output: output)
        )

        #expect(result.isSuccess, "\(Self.logLines(events).joined(separator: "\n"))")
        let file = try #require(result.files.first.map(URL.init(fileURLWithPath:)))
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(file.deletingLastPathComponent().standardizedFileURL == output.standardizedFileURL)
        #expect(events.contains { if case .progress(_, .finished) = $0 { true } else { false } })
        #expect(events.contains { if case .file = $0 { true } else { false } })
        let tracks = try await Self.trackCounts(of: file)
        #expect(tracks.video == 1 && tracks.audio == 1)
    }

    @Test("Separate DASH video and audio are merged by AVFoundation into one MP4")
    func mergesDASHStreams() async throws {
        let served = try Self.makeServedFolder()
        let output = try Self.makeOutputFolder()
        let server = try LocalHTTPServer(root: served)
        let base = try await server.start()
        defer { server.stop() }

        let (events, result) = try await Self.run(
            url: base.appending(path: "dash.mpd"),
            options: Self.options(kind: .video, output: output)
        )

        let log = Self.logLines(events).joined(separator: "\n")
        #expect(result.isSuccess, "\(log)")
        let file = try #require(result.files.first.map(URL.init(fileURLWithPath:)), "\(log)")
        #expect(file.pathExtension == "mp4")
        let tracks = try await Self.trackCounts(of: file)
        #expect(tracks.video == 1, "\(log)")
        #expect(tracks.audio == 1, "\(log)")
        #expect(events.contains { if case .postProcessing("Merger", .started, _) = $0 { true } else { false } })

        // The separate parts (`dash.fv360.mp4`, `dash.fa96.m4a`) are deleted once merged, exactly
        // as with ffmpeg, so the merged file is all that remains.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: output.path)
            .filter { $0 != file.lastPathComponent }
        #expect(leftovers.isEmpty, "Left behind: \(leftovers)")
    }

    @Test("Audio is extracted and re-encoded to AAC in M4A")
    func extractsAudio() async throws {
        let served = try Self.makeServedFolder()
        let output = try Self.makeOutputFolder()
        let server = try LocalHTTPServer(root: served)
        let base = try await server.start()
        defer { server.stop() }

        var options = Self.options(kind: .audio, output: output)
        options.audioFormat = .m4a
        options.audioQuality = .kbps128
        let (events, result) = try await Self.run(url: base.appending(path: "dash.mpd"), options: options)

        let log = Self.logLines(events).joined(separator: "\n")
        #expect(result.isSuccess, "\(log)")
        let file = try #require(result.files.first.map(URL.init(fileURLWithPath:)), "\(log)")
        #expect(file.pathExtension == "m4a")
        let tracks = try await Self.trackCounts(of: file)
        #expect(tracks.video == 0 && tracks.audio == 1)
    }

    @Test("Audio can be written as lossless FLAC")
    func extractsFLAC() async throws {
        let served = try Self.makeServedFolder()
        let output = try Self.makeOutputFolder()
        let server = try LocalHTTPServer(root: served)
        let base = try await server.start()
        defer { server.stop() }

        var options = Self.options(kind: .audio, output: output)
        options.audioFormat = .flac
        let (events, result) = try await Self.run(url: base.appending(path: "dash.mpd"), options: options)

        let log = Self.logLines(events).joined(separator: "\n")
        #expect(result.isSuccess, "\(log)")
        let file = try #require(result.files.first.map(URL.init(fileURLWithPath:)), "\(log)")
        #expect(file.pathExtension == "flac")
        let audioFile = try AVAudioFile(forReading: file)
        #expect(audioFile.length > 0)
    }

    @Test("Analysis returns the formats yt-dlp found, readable by MediaInfoDecoder")
    func analyzesManifest() async throws {
        let served = try Self.makeServedFolder()
        let server = try LocalHTTPServer(root: served)
        let base = try await server.start()
        defer { server.stop() }

        _ = try await YTDLPEngine.shared.start()
        let url = base.appending(path: "dash.mpd").absoluteString
        let argv = ArgumentBuilder.embeddedMetadataArguments(url: url, options: DownloadOptions())
        let data = try await YTDLPEngine.shared.analyze(argv: argv, jobID: UUID())
        let info = try MediaInfoDecoder.decode(data, originalURL: url)

        #expect(info.formats.count == 2)
        #expect(info.formats.contains { $0.isVideoOnly })
        #expect(info.formats.contains { $0.isAudioOnly })
    }

    @Test("Analysis of an unreachable link fails with a classified error")
    func analysisFailureIsClassified() async throws {
        _ = try await YTDLPEngine.shared.start()
        // Port 9 (discard) on loopback refuses connections.
        let argv = ArgumentBuilder.embeddedMetadataArguments(url: "http://127.0.0.1:9/missing.mp4", options: DownloadOptions())
        do {
            _ = try await YTDLPEngine.shared.analyze(argv: argv, jobID: UUID())
            Issue.record("Analysis should have failed")
        } catch EngineError.analysisFailed(_, let logLines) {
            let failure = DownloadFailure.classify(logLines: logLines, exitCode: 1)
            #expect(failure.kind == .network || failure.kind == .unknown, "\(logLines)")
        }
    }

    @Test("Cancelling a running download stops it promptly and reports cancellation")
    func cancelsDownload() async throws {
        let served = try Self.makeServedFolder()
        let output = try Self.makeOutputFolder()
        // ~113 KB at 8 KB/s keeps the download running for well over ten seconds.
        let server = try LocalHTTPServer(root: served, bytesPerSecond: 8_000)
        let base = try await server.start()
        defer { server.stop() }

        _ = try await YTDLPEngine.shared.start()
        let jobID = UUID()
        let argv = ArgumentBuilder.embeddedDownloadArguments(
            url: base.appending(path: "progressive.mp4").absoluteString,
            options: Self.options(kind: .video, output: output),
            capabilities: EmbeddedEngineCapabilities()
        )
        let started = ContinuousClock.now
        var cancelledAt: ContinuousClock.Instant?
        var result: EngineJobResult?
        for await update in YTDLPEngine.shared.download(argv: argv, jobID: jobID) {
            switch update {
            case .event(.progress(_, .downloading)) where cancelledAt == nil:
                cancelledAt = .now
                YTDLPEngine.shared.cancel(jobID: jobID)
            case .finished(let finished):
                result = finished
            default:
                break
            }
        }
        let finished = try #require(result)
        #expect(finished.wasCancelled)
        #expect(!finished.isSuccess)
        let stoppedAfter = try #require(cancelledAt).duration(to: .now)
        #expect(stoppedAfter < .seconds(8), "Took \(stoppedAfter) to stop after cancelling (started \(started))")
    }

    @Test("Several downloads can run at the same time")
    func concurrentDownloads() async throws {
        let served = try Self.makeServedFolder()
        let server = try LocalHTTPServer(root: served)
        let base = try await server.start()
        defer { server.stop() }
        _ = try await YTDLPEngine.shared.start()

        let results = try await withThrowingTaskGroup(of: EngineJobResult.self) { group in
            for index in 0..<3 {
                let output = try Self.makeOutputFolder()
                let url = base.appending(path: index == 1 ? "dash.mpd" : "progressive.mp4")
                let options = Self.options(kind: .video, output: output)
                group.addTask { try await Self.run(url: url, options: options).result }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.count == 3)
        #expect(results.allSatisfy { $0.isSuccess })
    }
}

/// Live checks against YouTube. They only run when `YTDLPGUI_LIVE_TESTS=1` is set for the test
/// runner (`TEST_RUNNER_YTDLPGUI_LIVE_TESTS=1 xcodebuild test …`), because they need the network
/// and a site outside the project's control.
@Suite("Live YouTube", .serialized, .timeLimit(.minutes(5)),
       .enabled(if: ProcessInfo.processInfo.environment["YTDLPGUI_LIVE_TESTS"] == "1"))
struct LiveYouTubeTests {

    /// "Me at the zoo" — 19 seconds, the first video on YouTube, and yt-dlp's own test fixture.
    static let url = "https://www.youtube.com/watch?v=jNQXAC9IVRw"

    @Test("Analysis solves YouTube's JavaScript challenges in JavaScriptCore")
    func analyzes() async throws {
        _ = try await YTDLPEngine.shared.start()
        let lines = LogCollector()
        let argv = ArgumentBuilder.embeddedMetadataArguments(url: Self.url, options: DownloadOptions())
        let data = try await YTDLPEngine.shared.analyze(argv: argv, jobID: UUID()) { _, line in lines.append(line) }
        let info = try MediaInfoDecoder.decode(data, originalURL: Self.url)
        let challengeLines = lines.all.filter { $0.localizedCaseInsensitiveContains("challenge") }
        print("JS challenge log:\n" + challengeLines.joined(separator: "\n"))
        // yt-dlp warns (and loses formats) when no runtime could solve a challenge.
        #expect(!challengeLines.contains { $0.hasPrefix("WARNING:") }, "\(challengeLines)")
        #expect(info.title.localizedCaseInsensitiveContains("zoo"))
        #expect(info.formats.contains { $0.isVideoOnly }, "\(lines.all.joined(separator: "\n"))")
        #expect(info.formats.contains { $0.isAudioOnly })
    }

    /// yt-dlp's default clients currently get every format of this video without a challenge,
    /// so this asks for the `web_embedded` client, whose stream URLs always carry an "n"
    /// challenge, and downloads through the solved URLs.
    @Test("A challenge-protected client is solved in JavaScriptCore and its URLs download")
    func solvesChallengeInJavaScriptCore() async throws {
        let output = FileManager.default.temporaryDirectory.appending(path: "live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var options = DownloadOptions()
        options.kind = .audio
        options.audioFormat = .best
        options.outputDirectory = output
        options.customArguments = "--extractor-args youtube:player_client=web_embedded"

        _ = try await YTDLPEngine.shared.start()
        let argv = ArgumentBuilder.embeddedDownloadArguments(url: Self.url, options: options, capabilities: EmbeddedEngineCapabilities())
        var log: [String] = []
        var result: EngineJobResult?
        for await update in YTDLPEngine.shared.download(argv: argv, jobID: UUID()) {
            switch update {
            case .event(.log(_, let line)): log.append(line)
            case .finished(let finished): result = finished
            default: break
            }
        }
        let finished = try #require(result)
        print("Challenge-client log:\n" + log.joined(separator: "\n"))
        #expect(log.contains { $0.contains("Solving JS challenges using jsc") }, "\(log.joined(separator: "\n"))")
        #expect(finished.isSuccess, "\(log.joined(separator: "\n"))")
        #expect(!finished.files.isEmpty)
    }

    @Test("The best video downloads and is merged into a playable MP4")
    func downloadsVideo() async throws {
        let output = FileManager.default.temporaryDirectory.appending(path: "live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var options = DownloadOptions()
        options.kind = .video
        options.outputDirectory = output
        options.embedMetadata = true
        options.embedThumbnail = true

        _ = try await YTDLPEngine.shared.start()
        let argv = ArgumentBuilder.embeddedDownloadArguments(url: Self.url, options: options, capabilities: EmbeddedEngineCapabilities())
        var log: [String] = []
        var result: EngineJobResult?
        for await update in YTDLPEngine.shared.download(argv: argv, jobID: UUID()) {
            switch update {
            case .event(.log(_, let line)): log.append(line)
            case .finished(let finished): result = finished
            default: break
            }
        }
        let finished = try #require(result)
        #expect(finished.isSuccess, "\(log.joined(separator: "\n"))")
        let file = try #require(finished.files.first.map(URL.init(fileURLWithPath:)))
        let asset = AVURLAsset(url: file)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        #expect(try await asset.load(.duration).seconds > 15)
    }

    @Test("Audio downloads as M4A")
    func downloadsAudio() async throws {
        let output = FileManager.default.temporaryDirectory.appending(path: "live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var options = DownloadOptions()
        options.kind = .audio
        options.audioFormat = .m4a
        options.outputDirectory = output

        _ = try await YTDLPEngine.shared.start()
        let argv = ArgumentBuilder.embeddedDownloadArguments(url: Self.url, options: options, capabilities: EmbeddedEngineCapabilities())
        var log: [String] = []
        var result: EngineJobResult?
        for await update in YTDLPEngine.shared.download(argv: argv, jobID: UUID()) {
            switch update {
            case .event(.log(_, let line)): log.append(line)
            case .finished(let finished): result = finished
            default: break
            }
        }
        let finished = try #require(result)
        #expect(finished.isSuccess, "\(log.joined(separator: "\n"))")
        let file = try #require(finished.files.first.map(URL.init(fileURLWithPath:)))
        #expect(file.pathExtension == "m4a")
    }
}

// MARK: - Support

private final class FixtureBundleToken {}

private enum FixtureError: Error {
    case missing(String)
}

/// Collects log lines delivered on the engine's threads.
private final class LogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
