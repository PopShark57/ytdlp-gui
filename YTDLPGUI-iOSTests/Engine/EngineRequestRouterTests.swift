import Foundation
import Synchronization
import Testing
@testable import YTDLPGUI_iOS

/// Records every call and answers from a script, so routing can be checked without AVFoundation.
private final class FakeMediaProcessor: MediaProcessing {
    let calls = Mutex<[String]>([])
    let failure: MediaProcessingError?
    let probeResult: MediaProbe
    /// Makes every call wait this long (cancellably) before answering.
    let delay: Duration?

    init(failure: MediaProcessingError? = nil, probeResult: MediaProbe? = nil, delay: Duration? = nil) {
        self.failure = failure
        self.probeResult = probeResult ?? MediaProbe(
            durationSeconds: 12.5,
            tracks: [.init(kind: "video", codec: "avc1"), .init(kind: "audio", codec: nil)],
            isReadable: true
        )
        self.delay = delay
    }

    var recorded: [String] { calls.withLock { $0 } }

    private func perform(_ call: String) async throws {
        calls.withLock { $0.append(call) }
        if let delay {
            try await Task.sleep(for: delay)
        }
        if let failure {
            throw failure
        }
    }

    func merge(inputs: [URL], output: URL, container: MediaContainer) async throws {
        try await perform("merge \(inputs.map(\.path)) \(output.path) \(container.rawValue)")
    }

    func extractAudio(input: URL, output: URL, codec: AudioCodecRequest, bitrate: Int?) async throws -> URL {
        try await perform("extract \(input.path) \(output.path) \(codec.rawValue) \(bitrate.map(String.init) ?? "nil")")
        return output.deletingPathExtension().appendingPathExtension("m4a")
    }

    func embed(into file: URL, metadata: MediaMetadata?, artwork: URL?, chapters: [MediaChapter]?) async throws {
        let tags = metadata.map { "title=\($0.title ?? "-") track=\($0.track ?? "-") date=\($0.date ?? "-") purl=\($0.webpageURL ?? "-")" } ?? "no-metadata"
        let marks = chapters.map { $0.map { "\($0.start)-\($0.end):\($0.title)" }.joined(separator: ",") } ?? "no-chapters"
        try await perform("embed \(file.path) \(tags) artwork=\(artwork?.path ?? "-") \(marks)")
    }

    func convertImage(input: URL, output: URL, format: ImageFormat) async throws {
        try await perform("convert \(input.path) \(output.path) \(format.rawValue)")
    }

    func removeRanges(input: URL, output: URL, ranges: [ClosedRange<Double>]) async throws {
        try await perform("ranges \(ranges.map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ","))")
    }

    func probe(_ file: URL) async throws -> MediaProbe {
        try await perform("probe \(file.path)")
        return probeResult
    }
}

@Suite("Engine request routing")
struct EngineRequestRouterTests {

    private func ask(_ request: String, media: FakeMediaProcessor = FakeMediaProcessor()) async throws -> [String: Any] {
        let router = EngineRequestRouter(media: media)
        let answer = await router.answer(Data(request.utf8))
        // Answers must be strict JSON: Python's `json.loads` is what reads them.
        return try #require(try JSONSerialization.jsonObject(with: answer) as? [String: Any])
    }

    // MARK: - Media

    @Test("media.merge passes paths and container through")
    func merge() async throws {
        let media = FakeMediaProcessor()
        let answer = try await ask(#"{"op": "media.merge", "inputs": ["/p/v.mp4", "/p/a.m4a"], "output": "/p/o.mp4", "container": "mp4"}"#, media: media)
        #expect(answer["ok"] as? Bool == true)
        #expect(media.recorded == ["merge [\"/p/v.mp4\", \"/p/a.m4a\"] /p/o.mp4 mp4"])
    }

    @Test("An unsupported input is flagged so the host keeps the original file")
    func unsupported() async throws {
        let media = FakeMediaProcessor(failure: .unsupported("WebM can't be merged on iPhone and iPad."))
        let answer = try await ask(#"{"op": "media.merge", "inputs": ["/p/v.webm"], "output": "/p/o.mp4", "container": "mp4"}"#, media: media)
        #expect(answer["ok"] as? Bool == false)
        #expect(answer["unsupported"] as? Bool == true)
        #expect(answer["error"] as? String == "WebM can't be merged on iPhone and iPad.")
    }

    @Test("Other failures are not flagged as unsupported")
    func failed() async throws {
        let media = FakeMediaProcessor(failure: .failed("The disk is full."))
        let answer = try await ask(#"{"op": "media.convert_image", "input": "/t.webp", "output": "/t.jpg", "format": "jpg"}"#, media: media)
        #expect(answer["ok"] as? Bool == false)
        #expect(answer["unsupported"] as? Bool == false)
        #expect(answer["error"] as? String == "The disk is full.")
    }

    @Test("media.extract_audio answers with the path actually written")
    func extractAudio() async throws {
        let media = FakeMediaProcessor()
        let answer = try await ask(#"{"op": "media.extract_audio", "input": "/p/in.mp4", "output": "/p/out.aac", "codec": "aac", "bitrate": 192000.0}"#, media: media)
        #expect(answer["ok"] as? Bool == true)
        #expect(answer["output"] as? String == "/p/out.m4a")
        #expect(media.recorded == ["extract /p/in.mp4 /p/out.aac aac 192000"])

        let lossless = FakeMediaProcessor()
        _ = try await ask(#"{"op": "media.extract_audio", "input": "/p/in.mp4", "output": "/p/out.flac", "codec": "flac", "bitrate": null}"#, media: lossless)
        #expect(lossless.recorded == ["extract /p/in.mp4 /p/out.flac flac nil"])
    }

    @Test("media.embed reads tags leniently and skips unusable chapters")
    func embed() async throws {
        let media = FakeMediaProcessor()
        let answer = try await ask("""
            {"op": "media.embed", "path": "/p/a.m4a",
             "metadata": {"title": "Song", "track": 3, "date": 20240101, "purl": "https://example.com/v", "genre": null},
             "artwork": "/p/cover.jpg",
             "chapters": [{"start": 0, "end": 5.5, "title": "Intro"}, {"start": "x", "end": 9}, {"start": 5.5, "end": 60}]}
            """, media: media)
        #expect(answer["ok"] as? Bool == true)
        #expect(media.recorded == ["embed /p/a.m4a title=Song track=3 date=20240101 purl=https://example.com/v artwork=/p/cover.jpg 0.0-5.5:Intro,5.5-60.0:"])
    }

    @Test("media.embed with nothing optional given")
    func embedNothing() async throws {
        let media = FakeMediaProcessor()
        _ = try await ask(#"{"op": "media.embed", "path": "/p/a.mp4", "metadata": null, "artwork": null, "chapters": null}"#, media: media)
        #expect(media.recorded == ["embed /p/a.mp4 no-metadata artwork=- no-chapters"])
    }

    @Test("media.remove_ranges accepts ordered pairs and rejects reversed ones")
    func removeRanges() async throws {
        let media = FakeMediaProcessor()
        let answer = try await ask(#"{"op": "media.remove_ranges", "input": "/i.mp4", "output": "/o.mp4", "ranges": [[1, 2.5], [10, 10]]}"#, media: media)
        #expect(answer["ok"] as? Bool == true)
        #expect(media.recorded == ["ranges 1.0-2.5,10.0-10.0"])

        let reversed = FakeMediaProcessor()
        let rejected = try await ask(#"{"op": "media.remove_ranges", "input": "/i.mp4", "output": "/o.mp4", "ranges": [[5, 1]]}"#, media: reversed)
        #expect(rejected["ok"] as? Bool == false)
        #expect((rejected["error"] as? String)?.contains("“ranges”") == true)
        #expect(reversed.recorded.isEmpty)
    }

    @Test("media.probe is encoded field by field, with non-finite durations as null")
    func probe() async throws {
        let answer = try await ask(#"{"op": "media.probe", "path": "/p/in.mp4"}"#)
        #expect(answer["ok"] as? Bool == true)
        #expect(answer["duration"] as? Double == 12.5)
        #expect(answer["readable"] as? Bool == true)
        let tracks = try #require(answer["tracks"] as? [[String: Any]])
        #expect(tracks.count == 2)
        #expect(tracks[0]["kind"] as? String == "video" && tracks[0]["codec"] as? String == "avc1")
        #expect(tracks[1]["codec"] is NSNull)

        let odd = FakeMediaProcessor(probeResult: MediaProbe(durationSeconds: .nan, tracks: [], isReadable: false))
        let unreadable = try await ask(#"{"op": "media.probe", "path": "/p/in.webm"}"#, media: odd)
        #expect(unreadable["duration"] is NSNull)
        #expect(unreadable["readable"] as? Bool == false)
    }

    // MARK: - JavaScript

    @Test("js.run answers with what the script logged")
    func javaScript() async throws {
        let answer = try await ask(#"{"op": "js.run", "script": "console.log(6 * 7); console.error('careful'); console.log('döne')", "timeout": 10}"#)
        #expect(answer["ok"] as? Bool == true)
        #expect(answer["stdout"] as? String == "42\ndöne")
        #expect(answer["stderr"] as? String == "careful")
    }

    @Test("A throwing script is an error that names the line")
    func javaScriptException() async throws {
        let answer = try await ask(#"{"op": "js.run", "script": "var a = 1;\nnope();"}"#)
        #expect(answer["ok"] as? Bool == false)
        #expect(answer["unsupported"] as? Bool == false)
        #expect((answer["error"] as? String)?.contains("line 2") == true)
    }

    // MARK: - Malformed requests

    @Test("Malformed requests are answered with an explanation", arguments: [
        (#"{"op": "media.nope"}"#, "media.nope"),
        (#"{"inputs": []}"#, "without saying what it wanted"),
        ("definitely not json", "couldn't read"),
        (#"{"op": "media.convert_image", "input": "/t.webp", "format": "jpg"}"#, "“output”"),
        (#"{"op": "media.convert_image", "input": "/t.webp", "output": "/t.gif", "format": "gif"}"#, "“format”"),
        (#"{"op": "media.merge", "inputs": [], "output": "/o.mp4", "container": "mp4"}"#, "“inputs”"),
        (#"{"op": "media.merge", "inputs": ["/v.mp4", 3], "output": "/o.mp4", "container": "mp4"}"#, "“inputs”"),
        (#"{"op": "media.probe", "path": ""}"#, "“path”"),
        (#"{"op": "js.run"}"#, "“script”"),
    ])
    func malformed(request: String, fragment: String) async throws {
        let media = FakeMediaProcessor()
        let answer = try await ask(request, media: media)
        #expect(answer["ok"] as? Bool == false)
        #expect(answer["unsupported"] as? Bool == false)
        let message = try #require(answer["error"] as? String)
        #expect(message.contains(fragment), "“\(message)” should mention \(fragment)")
        #expect(media.recorded.isEmpty)
    }

    @Test("A cancelled media task answers “Cancelled.”")
    func cancelledTask() async throws {
        let router = EngineRequestRouter(media: FakeMediaProcessor(delay: .seconds(30)))
        let task = Task { await router.answer(Data(#"{"op": "media.probe", "path": "/slow"}"#.utf8)) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let answer = try #require(try JSONSerialization.jsonObject(with: await task.value) as? [String: Any])
        #expect(answer["ok"] as? Bool == false)
        #expect(answer["error"] as? String == "Cancelled.")
    }
}

@Suite("Engine callback hub")
struct EngineCallbackHubTests {

    private func answer(_ hub: EngineCallbackHub, _ request: String, job: String) async throws -> [String: Any] {
        try parse(await rawAnswer(hub, request, job: job))
    }

    /// The hub blocks its caller, as the C bridge's Python thread is blocked; never do that on
    /// the cooperative pool.
    private func rawAnswer(_ hub: EngineCallbackHub, _ request: String, job: String) async -> Data {
        await EngineThread.run(named: "test request") {
            hub.answerRequest(Data(request.utf8), forJob: job)
        }
    }

    private func parse(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("A request for a job the app doesn't know is still answered")
    func unknownJob() async throws {
        let media = FakeMediaProcessor()
        let hub = EngineCallbackHub(router: EngineRequestRouter(media: media))
        let reply = try await answer(hub, #"{"op": "media.probe", "path": "/p/x.mp4"}"#, job: "not-a-job")
        #expect(reply["ok"] as? Bool == true)
        #expect(media.recorded == ["probe /p/x.mp4"])
    }

    @Test("Without a router the host still gets an answer")
    func noRouter() async throws {
        let reply = try await answer(EngineCallbackHub(), #"{"op": "media.probe", "path": "/p/x.mp4"}"#, job: "x")
        #expect(reply["ok"] as? Bool == false)
    }

    @Test("A cancelled job's requests are refused without doing the work")
    func cancelledJobRefused() async throws {
        let media = FakeMediaProcessor()
        let hub = EngineCallbackHub(router: EngineRequestRouter(media: media))
        let (_, continuation) = AsyncStream.makeStream(of: EngineJobUpdate.self)
        let job = EngineJob(id: UUID(), destination: .download(continuation))
        #expect(hub.register(job))
        #expect(job.requestCancellation())
        let reply = try await answer(hub, #"{"op": "media.probe", "path": "/p/x.mp4"}"#, job: job.id)
        #expect(reply["error"] as? String == "Cancelled.")
        #expect(media.recorded.isEmpty)
    }

    @Test("Cancelling a job cancels the media work it is waiting on")
    func cancelInFlight() async throws {
        let hub = EngineCallbackHub(router: EngineRequestRouter(media: FakeMediaProcessor(delay: .seconds(30))))
        let (_, continuation) = AsyncStream.makeStream(of: EngineJobUpdate.self)
        let job = EngineJob(id: UUID(), destination: .download(continuation))
        #expect(hub.register(job))
        let pending = Task { await rawAnswer(hub, #"{"op": "media.probe", "path": "/slow"}"#, job: job.id) }
        try await Task.sleep(for: .milliseconds(200))
        let started = ContinuousClock.now
        _ = job.requestCancellation()
        hub.cancelRequests(forJob: job.id)
        let reply = try parse(await pending.value)
        #expect(reply["error"] as? String == "Cancelled.")
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test("Events reach their own job, in order, and nothing arrives after the result")
    func eventRouting() async {
        let hub = EngineCallbackHub()
        let (stream, continuation) = AsyncStream.makeStream(of: EngineJobUpdate.self)
        let job = EngineJob(id: UUID(), destination: .download(continuation))
        let (otherStream, otherContinuation) = AsyncStream.makeStream(of: EngineJobUpdate.self)
        let other = EngineJob(id: UUID(), destination: .download(otherContinuation))
        #expect(hub.register(job) && hub.register(other))
        #expect(!hub.register(EngineJob(id: UUID(uuidString: job.id) ?? UUID(), destination: .download(continuation))))

        hub.deliver(eventJSON: Data(#"{"type": "log", "level": "info", "message": "one"}"#.utf8), toJob: job.id)
        hub.deliver(eventJSON: Data(#"{"type": "log", "level": "info", "message": "other"}"#.utf8), toJob: other.id)
        hub.deliver(eventJSON: Data(#"{"type": "file", "path": "/d/a.mp4"}"#.utf8), toJob: job.id)
        hub.deliver(eventJSON: Data(#"{"type": "log", "message": "nobody"}"#.utf8), toJob: "unknown")
        hub.deliver(eventJSON: Data("not json".utf8), toJob: job.id)
        hub.unregister(job)
        job.finish(with: .cancelled)
        job.deliver(.log(.info, "late"))
        other.finish(with: .hostFailure("x"))

        var updates: [EngineJobUpdate] = []
        for await update in stream { updates.append(update) }
        #expect(updates == [.event(.log(.info, "one")), .event(.file(path: "/d/a.mp4")), .finished(.cancelled)])
        var otherUpdates: [EngineJobUpdate] = []
        for await update in otherStream { otherUpdates.append(update) }
        #expect(otherUpdates == [.event(.log(.info, "other")), .finished(.hostFailure("x"))])
    }

    @Test("An analysis receives only its log lines, and none after it closes")
    func analysisLogs() {
        let lines = Mutex<[String]>([])
        let job = EngineJob(id: UUID(), destination: .analysis { level, line in
            lines.withLock { $0.append("\(level.rawValue): \(line)") }
        })
        job.deliver(.log(.warning, "WARNING: a"))
        job.deliver(.file(path: "/d/a.mp4"))
        job.deliver(.progress(DownloadProgressSnapshot(), status: .downloading))
        job.close()
        job.deliver(.log(.info, "late"))
        #expect(lines.withLock { $0 } == ["warning: WARNING: a"])
    }
}
