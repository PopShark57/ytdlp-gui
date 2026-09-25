import Foundation
import Testing
@testable import YTDLPGUI_iOS

@Suite("Engine event decoding")
struct EngineEventDecoderTests {

    private func decode(_ json: String) -> EngineEvent? {
        EngineEventDecoder.decode(Data(json.utf8))
    }

    // MARK: - log

    @Test("Log lines keep their level and text")
    func logLines() {
        #expect(decode(#"{"type": "log", "level": "warning", "message": "WARNING: [youtube] Slow down"}"#)
            == .log(.warning, "WARNING: [youtube] Slow down"))
        #expect(decode(#"{"type": "log", "level": "debug", "message": "[debug] Loading extractor"}"#)
            == .log(.debug, "[debug] Loading extractor"))
        #expect(decode(#"{"type": "log", "level": "error", "message": "ERROR: Unsupported URL"}"#)
            == .log(.error, "ERROR: Unsupported URL"))
    }

    @Test("An unknown or missing level is treated as info; a numeric message becomes text")
    func lenientLogs() {
        #expect(decode(#"{"type": "log", "level": "trace", "message": "x"}"#) == .log(.info, "x"))
        #expect(decode(#"{"type": "log", "message": "y"}"#) == .log(.info, "y"))
        #expect(decode(#"{"type": "log", "level": "info", "message": 42}"#) == .log(.info, "42"))
    }

    @Test("A log event without a message is skipped")
    func logWithoutMessage() {
        #expect(decode(#"{"type": "log", "level": "info"}"#) == nil)
        #expect(decode(#"{"type": "log", "level": "info", "message": null}"#) == nil)
        #expect(decode(#"{"type": "log", "level": "info", "message": ["a"]}"#) == nil)
    }

    // MARK: - progress

    @Test("Progress with nulls, NaN and Infinity leaves those fields empty")
    func progressWithMissingValues() {
        let event = decode("""
            {"type": "progress", "status": "downloading", "downloaded_bytes": 1024,
             "total_bytes": null, "total_bytes_estimate": 4096.7, "speed": NaN, "eta": 12.9,
             "elapsed": Infinity, "fragment_index": "3", "fragment_count": 10, "filename": "/tmp/a.part"}
            """)
        var expected = DownloadProgressSnapshot()
        expected.downloadedBytes = 1024
        expected.totalBytes = 4096
        expected.etaSeconds = 12
        expected.fragmentIndex = 3
        expected.fragmentCount = 10
        expected.filename = "/tmp/a.part"
        #expect(event == .progress(expected, status: .downloading))
    }

    @Test("The exact total wins over the estimate, as in ProgressParser")
    func totalPreferredOverEstimate() {
        let event = decode(#"{"type": "progress", "status": "downloading", "downloaded_bytes": 5, "total_bytes": 100, "total_bytes_estimate": 90, "speed": 2.5}"#)
        guard case .progress(let snapshot, .downloading)? = event else {
            Issue.record("Expected a progress event, got \(String(describing: event))")
            return
        }
        #expect(snapshot.totalBytes == 100)
        #expect(snapshot.speedBytesPerSecond == 2.5)
        #expect(snapshot.fractionCompleted == 0.05)
    }

    @Test("A finished tick drops its stale speed and ETA and reports the whole size")
    func finishedTickIsNormalised() {
        let event = decode(#"{"type": "progress", "status": "finished", "downloaded_bytes": 90, "total_bytes": 100, "speed": 1000, "eta": 3, "filename": "a.mp4"}"#)
        var expected = DownloadProgressSnapshot()
        expected.downloadedBytes = 100
        expected.totalBytes = 100
        expected.filename = "a.mp4"
        #expect(event == .progress(expected, status: .finished))
    }

    @Test("Odd types never trap: booleans, huge numbers, text and containers become nil")
    func oddProgressTypes() {
        let event = decode("""
            {"type": "progress", "status": "error", "downloaded_bytes": true, "total_bytes": 1e300,
             "total_bytes_estimate": "lots", "speed": [1], "eta": {"s": 1}, "elapsed": "2.5",
             "fragment_index": -1, "fragment_count": 9.99e18, "filename": ""}
            """)
        var expected = DownloadProgressSnapshot()
        expected.elapsedSeconds = 2.5
        expected.fragmentIndex = -1
        #expect(event == .progress(expected, status: .error))
    }

    @Test("An unknown progress status still carries its numbers")
    func unknownProgressStatus() {
        let event = decode(#"{"type": "progress", "status": "resuming", "downloaded_bytes": 7}"#)
        var expected = DownloadProgressSnapshot()
        expected.downloadedBytes = 7
        #expect(event == .progress(expected, status: .downloading))
    }

    // MARK: - postprocess, item, file

    @Test("Post-processing stages")
    func postProcessing() {
        #expect(decode(#"{"type": "postprocess", "status": "started", "postprocessor": "Merger", "filepath": null}"#)
            == .postProcessing(name: "Merger", status: .started, filePath: nil))
        #expect(decode(#"{"type": "postprocess", "status": "finished", "postprocessor": "ExtractAudio", "filepath": "/d/a.m4a"}"#)
            == .postProcessing(name: "ExtractAudio", status: .finished, filePath: "/d/a.m4a"))
        #expect(decode(#"{"type": "postprocess", "status": "paused"}"#)
            == .postProcessing(name: "Processing", status: .processing, filePath: nil))
    }

    @Test("Item info tolerates numeric ids, string durations and unusable URLs")
    func item() {
        let event = decode("""
            {"type": "item", "id": 12345, "title": "Caf\\u00e9", "uploader": "", "thumbnail": "not a url",
             "duration": "61.5", "webpage_url": "https://example.com/watch?v=1", "extractor": "generic",
             "playlist_index": 2, "playlist_count": null}
            """)
        let expected = EngineItemInfo(
            id: "12345",
            title: "Café",
            uploader: nil,
            thumbnailURL: nil,
            durationSeconds: 61.5,
            webpageURL: URL(string: "https://example.com/watch?v=1"),
            extractor: "generic",
            playlistIndex: 2,
            playlistCount: nil
        )
        #expect(event == .item(expected))
    }

    @Test("File events need a path")
    func file() {
        #expect(decode(#"{"type": "file", "path": "/Documents/a b.mp4"}"#) == .file(path: "/Documents/a b.mp4"))
        #expect(decode(#"{"type": "file", "path": ""}"#) == nil)
        #expect(decode(#"{"type": "file"}"#) == nil)
    }

    @Test("Unknown types and malformed JSON are skipped", arguments: [
        #"{"type": "telemetry", "value": 1}"#,
        #"{"level": "info", "message": "no type"}"#,
        #"[1, 2, 3]"#,
        #"{"type": "log", "message": "#,
        "",
    ])
    func skipped(json: String) {
        #expect(decode(json) == nil)
    }
}
