import Foundation
import Testing
@testable import YTDLPGUI_iOS

@Suite("Engine reply decoding")
struct EngineReplyDecoderTests {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    // MARK: - configure

    @Test("configure's versions become EngineInfo")
    func engineInfo() throws {
        let info = try EngineReplyDecoder.engineInfo(from: data("""
            {"ok": true, "python": "3.14.7", "yt_dlp": "2026.08.19", "yt_dlp_source": "updated",
             "ejs": "0.8.0", "certifi": null, "update_error": null}
            """))
        #expect(info == EngineInfo(
            pythonVersion: "3.14.7",
            ytdlpVersion: "2026.08.19",
            ytdlpSource: .updated,
            ejsVersion: "0.8.0",
            certifiVersion: nil,
            updateError: nil
        ))
    }

    @Test("An update that failed to load is reported alongside the bundled version")
    func engineInfoWithUpdateError() throws {
        let info = try EngineReplyDecoder.engineInfo(from: data("""
            {"ok": true, "python": "3.14.7", "yt_dlp": "2026.08.19", "yt_dlp_source": "somewhere",
             "update_error": "No module named 'yt_dlp.compat'"}
            """))
        #expect(info.ytdlpSource == .bundled)
        #expect(info.updateError == "No module named 'yt_dlp.compat'")
    }

    @Test("A failed configure carries the host's message and traceback")
    func configureFailure() {
        #expect(throws: EngineError.hostFailure(message: "boom", traceback: "Traceback …")) {
            try EngineReplyDecoder.engineInfo(from: data(#"{"ok": false, "error": "boom", "traceback": "Traceback …"}"#))
        }
        #expect(throws: EngineError.hostFailure(message: EngineReplyDecoder.unexplainedFailure, traceback: nil)) {
            try EngineReplyDecoder.engineInfo(from: data(#"{"ok": false}"#))
        }
        #expect(throws: EngineError.hostFailure(message: EngineReplyDecoder.unreadableReply, traceback: nil)) {
            try EngineReplyDecoder.engineInfo(from: data("not json"))
        }
    }

    // MARK: - analyze

    @Test("A successful analysis yields strict JSON, with NaN turned into null")
    func analysisInfo() throws {
        let json = try EngineReplyDecoder.analysisInfo(from: data("""
            {"ok": true, "info": {"id": "x", "title": "A/B \\"quoted\\"", "duration": NaN,
             "formats": [{"format_id": "18", "tbr": Infinity, "height": 360}]}}
            """), cancellationRequested: false)
        // Strict parsing, as `JSONDecoder` in `MediaInfoDecoder` does.
        let info = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(info["title"] as? String == "A/B \"quoted\"")
        #expect(info["duration"] is NSNull)
        let format = try #require((info["formats"] as? [[String: Any]])?.first)
        #expect(format["tbr"] is NSNull)
        #expect(format["height"] as? Int == 360)
    }

    @Test("Analysis failures map onto EngineError")
    func analysisFailures() {
        #expect(throws: EngineError.cancelled) {
            try EngineReplyDecoder.analysisInfo(from: data(#"{"ok": false, "error": "Cancelled", "log": [], "cancelled": true}"#), cancellationRequested: false)
        }
        #expect(throws: EngineError.analysisFailed(message: "Unsupported URL: x", logLines: ["[generic] x", "ERROR: Unsupported URL: x"])) {
            try EngineReplyDecoder.analysisInfo(
                from: data(#"{"ok": false, "error": "Unsupported URL: x", "log": ["[generic] x", 7, "ERROR: Unsupported URL: x"], "cancelled": false}"#),
                cancellationRequested: false
            )
        }
        #expect(throws: EngineError.hostFailure(message: "bad argv", traceback: "tb")) {
            try EngineReplyDecoder.analysisInfo(from: data(#"{"ok": false, "error": "bad argv", "traceback": "tb"}"#), cancellationRequested: false)
        }
        #expect(throws: EngineError.hostFailure(message: "The download engine finished the analysis without returning any information.", traceback: nil)) {
            try EngineReplyDecoder.analysisInfo(from: data(#"{"ok": true, "info": null}"#), cancellationRequested: false)
        }
    }

    @Test("Any failure after the user cancelled is reported as a cancellation")
    func analysisCancelledByUser() {
        #expect(throws: EngineError.cancelled) {
            try EngineReplyDecoder.analysisInfo(from: data(#"{"ok": false, "error": "The engine raised an error: JobCancelled"}"#), cancellationRequested: true)
        }
    }

    // MARK: - download

    @Test("Download results")
    func downloadResults() {
        #expect(EngineReplyDecoder.downloadResult(
            from: data(#"{"ok": true, "exit_code": 0, "cancelled": false, "files": ["/d/a.mp4", null, "/d/b.m4a"]}"#),
            cancellationRequested: false
        ) == EngineJobResult(exitCode: 0, wasCancelled: false, files: ["/d/a.mp4", "/d/b.m4a"], hostError: nil))

        #expect(EngineReplyDecoder.downloadResult(
            from: data(#"{"ok": true, "exit_code": 1, "cancelled": false, "files": []}"#),
            cancellationRequested: false
        ) == EngineJobResult(exitCode: 1, wasCancelled: false, files: [], hostError: nil))

        #expect(EngineReplyDecoder.downloadResult(
            from: data(#"{"ok": true, "cancelled": true}"#),
            cancellationRequested: true
        ) == .cancelled)

        #expect(EngineReplyDecoder.downloadResult(
            from: data(#"{"ok": false, "error": "Refusing --exec"}"#),
            cancellationRequested: false
        ) == .hostFailure("Refusing --exec"))

        #expect(EngineReplyDecoder.downloadResult(from: data("garbage"), cancellationRequested: false)
            == .hostFailure(EngineReplyDecoder.unreadableReply))
    }

    @Test("A host failure after the user cancelled is a cancellation, not an error")
    func downloadCancelledByUser() {
        #expect(EngineReplyDecoder.downloadResult(
            from: data(#"{"ok": false, "error": "The engine raised an error: JobCancelled"}"#),
            cancellationRequested: true
        ) == .cancelled)
    }

    @Test("An exit code that doesn't fit is replaced by the default")
    func hugeExitCode() {
        let result = EngineReplyDecoder.downloadResult(from: data(#"{"ok": true, "exit_code": 1e12}"#), cancellationRequested: false)
        #expect(result.exitCode == 0)
    }

    // MARK: - cancel and updates

    @Test("cancel reports whether the host found the job")
    func cancelReply() {
        #expect(EngineReplyDecoder.cancellationFoundJob(in: data(#"{"ok": true, "found": true}"#)) == true)
        #expect(EngineReplyDecoder.cancellationFoundJob(in: data(#"{"ok": true, "found": false}"#)) == false)
        #expect(EngineReplyDecoder.cancellationFoundJob(in: data(#"{"ok": true}"#)) == nil)
        #expect(EngineReplyDecoder.cancellationFoundJob(in: data(#"{"ok": false, "error": "x"}"#)) == nil)
    }

    @Test("Update check and install replies")
    func updates() throws {
        #expect(try EngineReplyDecoder.updateInfo(from: data(#"{"ok": true, "current": "2026.08.19", "latest": "2026.09.01", "is_newer": true}"#))
            == EngineUpdateInfo(currentVersion: "2026.08.19", latestVersion: "2026.09.01", isNewer: true))
        #expect(try EngineReplyDecoder.installedVersion(from: data(#"{"ok": true, "version": "2026.09.01"}"#)) == "2026.09.01")
        #expect(throws: EngineError.hostFailure(message: "SHA-256 mismatch", traceback: nil)) {
            try EngineReplyDecoder.installedVersion(from: data(#"{"ok": false, "error": "SHA-256 mismatch"}"#))
        }
        #expect(throws: EngineError.self) {
            try EngineReplyDecoder.updateInfo(from: data(#"{"ok": true, "current": "2026.08.19"}"#))
        }
    }
}
