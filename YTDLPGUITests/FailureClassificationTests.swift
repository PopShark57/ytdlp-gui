import Foundation
import Testing

@testable import YTDLPGUI

/// Most of these messages were captured verbatim from real yt-dlp runs, which is the only way
/// to be confident the substring matching still holds.
@Suite("Failure classification")
struct FailureClassificationTests {

    private func classify(_ line: String) -> DownloadFailure.Kind {
        DownloadFailure.classify(logLines: [line], exitCode: 1).kind
    }

    @Test("YouTube's bot check is recognised and points at the cookie setting")
    func botCheck() {
        let failure = DownloadFailure.classify(
            logLines: ["ERROR: [youtube] jNQXAC9IVRw: Sign in to confirm you’re not a bot. Use --cookies-from-browser or --cookies for the authentication."],
            exitCode: 1
        )
        #expect(failure.kind == .botCheck)
        #expect(failure.recoverySuggestion?.contains("cookies from browser") == true)
    }

    @Test("Rate limiting is distinguished from a generic network failure")
    func rateLimited() {
        #expect(classify("WARNING: [youtube] Unable to download webpage: HTTP Error 429: Too Many Requests") == .rateLimited)
        #expect(DownloadFailure(kind: .rateLimited, underlyingMessage: nil).isWorthRetrying)
    }

    @Test(
        "Common failures map to their own kind",
        arguments: [
            ("ERROR: [youtube] abc: Video unavailable", DownloadFailure.Kind.unavailable),
            ("ERROR: [youtube] abc: This video is private", .privateOrMembersOnly),
            ("ERROR: [generic] Unsupported URL: https://example.com", .unsupportedSite),
            ("ERROR: The uploader has not made this video available in your country", .geoRestricted),
            ("ERROR: Postprocessing: ffmpeg not found. Please install or provide the path using --ffmpeg-location", .ffmpegMissing),
            ("ERROR: unable to open for writing: [Errno 13] Permission denied: '/x/y.mp4'", .fileSystem),
            ("ERROR: No space left on device", .diskFull),
            ("ERROR: unable to download video data: <urlopen error [Errno 8] nodename nor servname provided>", .network),
        ]
    )
    func classifications(line: String, expected: DownloadFailure.Kind) {
        #expect(classify(line) == expected)
    }

    @Test("An unrecognised error is reported honestly rather than mislabelled")
    func unknownFailure() {
        let failure = DownloadFailure.classify(logLines: ["ERROR: something entirely new"], exitCode: 1)
        #expect(failure.kind == .unknown)
        #expect(failure.underlyingMessage == "something entirely new")
        #expect(failure.recoverySuggestion?.contains("log") == true)
    }

    @Test("The ERROR prefix is stripped from the message shown to the user")
    func stripsPrefix() {
        let failure = DownloadFailure.classify(logLines: ["ERROR: [x] plain message"], exitCode: 1)
        #expect(failure.underlyingMessage == "[x] plain message")
    }

    @Test("yt-dlp's bug-report boilerplate is trimmed off")
    func trimsBoilerplate() {
        let failure = DownloadFailure.classify(
            logLines: ["ERROR: Something broke; please report this issue on https://github.com/yt-dlp/yt-dlp/issues"],
            exitCode: 1
        )
        #expect(failure.underlyingMessage == "Something broke")
    }

    @Test("The last error wins when several were printed")
    func prefersLastError() {
        let failure = DownloadFailure.classify(
            logLines: [
                "WARNING: [youtube] Falling back to a different client",
                "ERROR: first problem",
                "ERROR: [youtube] abc: Video unavailable",
            ],
            exitCode: 1
        )
        #expect(failure.kind == .unavailable)
    }

    @Test("Only transient failures are marked as worth retrying unchanged")
    func retryability() {
        #expect(DownloadFailure(kind: .network, underlyingMessage: nil).isWorthRetrying)
        #expect(DownloadFailure(kind: .unknown, underlyingMessage: nil).isWorthRetrying)
        // Retrying these without changing a setting would just fail again.
        #expect(!DownloadFailure(kind: .botCheck, underlyingMessage: nil).isWorthRetrying)
        #expect(!DownloadFailure(kind: .unavailable, underlyingMessage: nil).isWorthRetrying)
        #expect(!DownloadFailure(kind: .cancelled, underlyingMessage: nil).isWorthRetrying)
    }

    @Test("Several missing tools produce one runnable brew command, not two joined together")
    func combinedInstallCommand() {
        #expect(ExternalTool.installCommand(for: [.ytdlp, .ffmpeg]) == "brew install yt-dlp ffmpeg")
        #expect(ExternalTool.installCommand(for: [.ffmpeg]) == "brew install ffmpeg")
        #expect(ExternalTool.installCommand(for: []) == "brew install yt-dlp")
    }

    @Test("Every failure kind has a title, and only cancellation lacks advice")
    func everyKindIsPresentable() {
        let kinds: [DownloadFailure.Kind] = [
            .toolMissing("yt-dlp"), .invalidURL, .unsupportedSite, .unavailable,
            .privateOrMembersOnly, .geoRestricted, .ageRestricted, .authenticationRequired,
            .botCheck, .rateLimited, .network, .postProcessing, .ffmpegMissing,
            .fileSystem, .diskFull, .cancelled, .unknown,
        ]
        for kind in kinds {
            let failure = DownloadFailure(kind: kind, underlyingMessage: nil)
            #expect(!failure.title.isEmpty)
            #expect(!failure.symbolName.isEmpty)
            if kind == .cancelled {
                #expect(failure.recoverySuggestion == nil)
            } else {
                #expect(failure.recoverySuggestion?.isEmpty == false)
            }
        }
    }
}

@Suite("Formatting")
struct FormattingTests {

    @Test("Byte counts are human readable, and missing values stay missing")
    func bytes() {
        #expect(Format.bytes(nil) == nil)
        #expect(Format.bytes(-5) == nil)
        #expect(Format.bytes(1_306_616)?.contains("MB") == true)
    }

    @Test("Speed is only shown when it is meaningful")
    func speed() {
        #expect(Format.speed(nil) == nil)
        #expect(Format.speed(0) == nil)
        #expect(Format.speed(.nan) == nil)
        #expect(Format.speed(1_500_000)?.hasSuffix("/s") == true)
    }

    @Test("Durations use clock notation and pad correctly")
    func duration() {
        #expect(Format.duration(19) == "0:19")
        #expect(Format.duration(61) == "1:01")
        #expect(Format.duration(3_845) == "1:04:05")
        #expect(Format.duration(nil) == nil)
        #expect(Format.duration(-1) == nil)
    }

    @Test("A zero ETA reads as finishing rather than as zero seconds")
    func eta() {
        #expect(Format.eta(0) == "finishing")
        #expect(Format.eta(nil) == nil)
        #expect(Format.eta(-1) == nil)
        #expect(Format.eta(90) != nil)
    }

    @Test("Percentages are clamped to the 0–100 range")
    func percent() {
        #expect(Format.percent(nil) == nil)
        #expect(Format.percent(0.5)?.contains("50") == true)
        #expect(Format.percent(1.5)?.contains("100") == true)
        #expect(Format.percent(-0.5)?.contains("0") == true)
    }

    @Test("Large counts are abbreviated")
    func compactCount() {
        #expect(Format.compactCount(403_947_630) == "403.9M")
        #expect(Format.compactCount(1_500_000_000) == "1.5B")
        #expect(Format.compactCount(12_000) == "12K")
        #expect(Format.compactCount(nil) == nil)
    }

    @Test("Only a well-formed YYYYMMDD string parses as an upload date")
    func uploadDateParsing() {
        #expect(Format.parseUploadDate("20050424") != nil)
        #expect(Format.parseUploadDate("2005") == nil)
        #expect(Format.parseUploadDate("not-a-date") == nil)
        #expect(Format.parseUploadDate(nil) == nil)
    }

    @Test("Transferred size reads naturally whether or not the total is known")
    func transferred() {
        #expect(Format.transferred(downloaded: 1_000_000, total: 5_000_000)?.contains(" of ") == true)
        #expect(Format.transferred(downloaded: 1_000_000, total: nil)?.contains(" of ") == false)
        #expect(Format.transferred(downloaded: nil, total: nil) == nil)
    }
}

@Suite("Download options")
struct DownloadOptionsTests {

    @Test("Options survive a round trip through JSON, so the last setup is restored at launch")
    func codableRoundTrip() throws {
        var options = DownloadOptions()
        options.kind = .audio
        options.audioFormat = .flac
        options.sponsorBlockCategories = [.sponsor, .intro]
        options.customArguments = "--retries 3"
        options.outputDirectory = URL(fileURLWithPath: "/tmp/x")

        let data = try JSONEncoder().encode(options)
        let decoded = try JSONDecoder().decode(DownloadOptions.self, from: data)
        #expect(decoded == options)
    }

    @Test("The format summary describes the chosen preset")
    func formatSummary() {
        var options = DownloadOptions()
        options.kind = .video
        options.videoQuality = .fhd1080
        options.container = .mp4
        #expect(options.formatSummary == "1080p · MP4")

        options.kind = .audio
        options.audioFormat = .mp3
        options.audioQuality = .kbps192
        #expect(options.formatSummary == "MP3 · 192 kbps")

        // Bitrate is meaningless for a lossless format, so it is left out.
        options.audioFormat = .flac
        #expect(options.formatSummary == "FLAC")
    }

    @Test("Only lossy formats advertise a quality setting")
    func qualitySupport() {
        #expect(AudioFormat.mp3.supportsQuality)
        #expect(AudioFormat.opus.supportsQuality)
        #expect(!AudioFormat.flac.supportsQuality)
        #expect(!AudioFormat.wav.supportsQuality)
        #expect(!AudioFormat.best.supportsQuality)
    }
}

@Suite("Progress snapshot")
struct ProgressSnapshotTests {

    @Test("Progress is nil rather than zero when the total size is unknown")
    func unknownTotal() {
        var snapshot = DownloadProgressSnapshot()
        snapshot.downloadedBytes = 1_000
        #expect(snapshot.fractionCompleted == nil)
        #expect(snapshot.percentLabel == nil)
    }

    @Test("Progress is clamped even if the counters overshoot")
    func clamping() {
        var snapshot = DownloadProgressSnapshot()
        snapshot.downloadedBytes = 200
        snapshot.totalBytes = 100
        #expect(snapshot.fractionCompleted == 1.0)
    }

    @Test("A zero total doesn't divide by zero")
    func zeroTotal() {
        var snapshot = DownloadProgressSnapshot()
        snapshot.downloadedBytes = 0
        snapshot.totalBytes = 0
        #expect(snapshot.fractionCompleted == nil)
    }

    @Test("Post-processing phases render an indeterminate bar")
    func indeterminatePhases() {
        #expect(DownloadPhase.merging.isIndeterminate)
        #expect(DownloadPhase.extractingAudio.isIndeterminate)
        #expect(!DownloadPhase.downloading.isIndeterminate)
        #expect(!DownloadPhase.completed.isIndeterminate)
    }
}

@Suite("Log buffer")
struct LogBufferTests {

    @Test("The buffer is capped but still reports how much was produced")
    func capping() {
        var buffer = LogBuffer()
        for index in 0..<(LogBuffer.limit + 500) {
            buffer.append("line \(index)")
        }
        #expect(buffer.lines.count == LogBuffer.limit)
        #expect(buffer.totalLineCount == LogBuffer.limit + 500)
        #expect(buffer.isTruncated)
        // The newest lines are the ones kept.
        #expect(buffer.lines.last == "line \(LogBuffer.limit + 499)")
    }

    @Test("A short log is not marked as truncated")
    func notTruncated() {
        var buffer = LogBuffer()
        buffer.append("only line")
        #expect(!buffer.isTruncated)
        #expect(buffer.joined == "only line")
    }
}
