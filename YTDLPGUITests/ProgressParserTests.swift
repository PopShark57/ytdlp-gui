import Foundation
import Testing

@testable import YTDLPGUI

/// The sample lines here were captured from a real yt-dlp 2026.07.04 run, so the parser is
/// tested against the format the tool actually emits rather than an assumed one.
@Suite("Progress parser")
struct ProgressParserTests {

    private let marker = ArgumentBuilder.progressMarker
    private let postMarker = ArgumentBuilder.postProcessMarker
    private let separator = ArgumentBuilder.fieldSeparator

    private func progressLine(_ fields: [String]) -> String {
        marker + fields.joined(separator: separator)
    }

    // MARK: - Download progress

    @Test("A downloading tick is parsed into byte counts, speed and ETA")
    func downloadingTick() throws {
        let line = progressLine([
            "downloading", "523264", "1306616", "NA",
            "306543.893546962", "2", "1.7084829807281494", "NA", "NA",
            "/tmp/out/Sample_Clip.mp4",
        ])

        guard case .progress(let snapshot) = ProgressParser.parse(line) else {
            Issue.record("Expected a progress event")
            return
        }

        #expect(snapshot.downloadedBytes == 523_264)
        #expect(snapshot.totalBytes == 1_306_616)
        #expect(snapshot.speedBytesPerSecond == 306_543.893546962)
        #expect(snapshot.etaSeconds == 2)
        #expect(snapshot.elapsedSeconds == 1.7084829807281494)
        #expect(snapshot.filename == "/tmp/out/Sample_Clip.mp4")
        #expect(snapshot.displayFilename == "Sample_Clip.mp4")

        let fraction = try #require(snapshot.fractionCompleted)
        #expect(abs(fraction - 0.4005) < 0.001)
    }

    @Test("yt-dlp's NA placeholder becomes nil, not a bogus zero")
    func missingFieldsAreNil() {
        let line = progressLine([
            "downloading", "1024", "NA", "NA", "NA", "NA", "NA", "NA", "NA", "NA",
        ])

        guard case .progress(let snapshot) = ProgressParser.parse(line) else {
            Issue.record("Expected a progress event")
            return
        }

        #expect(snapshot.downloadedBytes == 1_024)
        #expect(snapshot.totalBytes == nil)
        #expect(snapshot.speedBytesPerSecond == nil)
        #expect(snapshot.etaSeconds == nil)
        #expect(snapshot.filename == nil)
        // Without a total there is no percentage to show; an indeterminate bar is correct.
        #expect(snapshot.fractionCompleted == nil)
    }

    @Test("The estimated total is used when the exact total is unknown")
    func totalBytesEstimateFallback() {
        let line = progressLine([
            "downloading", "500", "NA", "2000", "NA", "NA", "NA", "NA", "NA", "NA",
        ])
        guard case .progress(let snapshot) = ProgressParser.parse(line) else {
            Issue.record("Expected a progress event")
            return
        }
        #expect(snapshot.totalBytes == 2_000)
        #expect(snapshot.fractionCompleted == 0.25)
    }

    @Test("Fragment counts drive progress for streams with no known size")
    func fragmentProgress() {
        let line = progressLine([
            "downloading", "NA", "NA", "NA", "NA", "NA", "NA", "25", "100", "stream.mp4",
        ])
        guard case .progress(let snapshot) = ProgressParser.parse(line) else {
            Issue.record("Expected a progress event")
            return
        }
        #expect(snapshot.fractionCompleted == 0.25)
        #expect(snapshot.fragmentLabel == "fragment 25 of 100")
    }

    @Test("The finished tick clears the stale speed and ETA and pins progress to complete")
    func finishedTick() {
        let line = progressLine([
            "finished", "1306616", "1306616", "NA",
            "306913.46381435054", "NA", "4.257278203964233", "NA", "NA",
            "/tmp/out/Sample_Clip.mp4",
        ])

        guard case .downloadFinished(let snapshot) = ProgressParser.parse(line) else {
            Issue.record("Expected a downloadFinished event")
            return
        }
        #expect(snapshot.etaSeconds == nil)
        #expect(snapshot.speedBytesPerSecond == nil)
        #expect(snapshot.fractionCompleted == 1.0)
    }

    @Test("A filename containing the separator survives, because it is read last")
    func filenameWithSeparator() {
        let awkward = "/tmp/A\tB.mp4"
        let line = progressLine([
            "downloading", "1", "2", "NA", "NA", "NA", "NA", "NA", "NA", awkward,
        ])
        guard case .progress(let snapshot) = ProgressParser.parse(line) else {
            Issue.record("Expected a progress event")
            return
        }
        #expect(snapshot.filename == awkward)
    }

    @Test("A malformed progress line degrades to plain information instead of crashing")
    func malformedProgressLine() {
        guard case .information = ProgressParser.parse(marker + "downloading\t1") else {
            Issue.record("Expected an information event")
            return
        }
    }

    // MARK: - Post-processing

    @Test("Post-processing stages are reported with their start and end")
    func postProcessing() {
        guard case .postProcessing(let startName, let startFinished) =
                ProgressParser.parse(postMarker + "started" + separator + "ExtractAudio") else {
            Issue.record("Expected a postProcessing event")
            return
        }
        #expect(startName == "ExtractAudio")
        #expect(startFinished == false)

        guard case .postProcessing(_, let endFinished) =
                ProgressParser.parse(postMarker + "finished" + separator + "ExtractAudio") else {
            Issue.record("Expected a postProcessing event")
            return
        }
        #expect(endFinished)
    }

    @Test(
        "Known post-processors map onto readable phases",
        arguments: [
            ("Merger", DownloadPhase.merging),
            ("ExtractAudio", .extractingAudio),
            ("VideoRemuxer", .remuxing),
            ("EmbedSubtitle", .embeddingSubtitles),
            ("EmbedThumbnail", .embeddingThumbnail),
            ("Metadata", .writingMetadata),
            ("ModifyChapters", .removingSegments),
            ("MoveFiles", .movingFiles),
        ]
    )
    func postProcessorPhases(name: String, expected: DownloadPhase) {
        #expect(DownloadPhase.forPostProcessor(name) == expected)
    }

    @Test("An unknown post-processor still produces a sensible label")
    func unknownPostProcessor() {
        #expect(DownloadPhase.forPostProcessor("SomeNewThing") == .postProcessing("SomeNewThing"))
        #expect(DownloadPhase.postProcessing("SomeNewThing").displayName == "Processing · SomeNewThing")
    }

    // MARK: - Output paths

    @Test("The download destination is captured")
    func downloadDestination() {
        guard case .destination(let path, let stage) =
                ProgressParser.parse("[download] Destination: out/Sample_Clip.mp4") else {
            Issue.record("Expected a destination event")
            return
        }
        #expect(path == "out/Sample_Clip.mp4")
        #expect(stage == "download")
    }

    @Test("Audio extraction reports the real deliverable, which differs from the download")
    func extractAudioDestination() {
        guard case .destination(let path, let stage) =
                ProgressParser.parse("[ExtractAudio] Destination: out/Sample_Clip.mp3") else {
            Issue.record("Expected a destination event")
            return
        }
        #expect(path == "out/Sample_Clip.mp3")
        #expect(stage == "ExtractAudio")
    }

    @Test("A merged file's quoted path is unwrapped")
    func mergerPath() {
        guard case .merged(let path) =
                ProgressParser.parse(#"[Merger] Merging formats into "/tmp/out/Video.mkv""#) else {
            Issue.record("Expected a merged event")
            return
        }
        #expect(path == "/tmp/out/Video.mkv")
    }

    @Test("Metadata stages also reveal the final path")
    func metadataPath() {
        guard case .destination(let path, _) =
                ProgressParser.parse(#"[Metadata] Adding metadata to "out/Sample_Clip.mp3""#) else {
            Issue.record("Expected a destination event")
            return
        }
        #expect(path == "out/Sample_Clip.mp3")
    }

    @Test("An already-present file is recognised rather than treated as a failure")
    func alreadyDownloaded() {
        guard case .alreadyDownloaded(let path) =
                ProgressParser.parse("[download] /tmp/out/Video.mp4 has already been downloaded") else {
            Issue.record("Expected an alreadyDownloaded event")
            return
        }
        #expect(path == "/tmp/out/Video.mp4")
    }

    @Test("Playlist position is extracted")
    func playlistItem() {
        guard case .playlistItem(let index, let total) =
                ProgressParser.parse("[download] Downloading item 3 of 12") else {
            Issue.record("Expected a playlistItem event")
            return
        }
        #expect(index == 3)
        #expect(total == 12)
    }

    // MARK: - Diagnostics

    @Test("Errors and warnings are separated from ordinary output")
    func errorsAndWarnings() {
        guard case .error(let message) =
                ProgressParser.parse("ERROR: [youtube] abc: Video unavailable") else {
            Issue.record("Expected an error event")
            return
        }
        #expect(message == "[youtube] abc: Video unavailable")

        guard case .warning(let warning) = ProgressParser.parse("WARNING: Falling back") else {
            Issue.record("Expected a warning event")
            return
        }
        #expect(warning == "Falling back")

        guard case .information = ProgressParser.parse("[youtube] Extracting URL: https://x") else {
            Issue.record("Expected an information event")
            return
        }
    }

    @Test("Blank lines never crash the parser")
    func blankLine() {
        guard case .information = ProgressParser.parse("   ") else {
            Issue.record("Expected an information event")
            return
        }
    }
}
