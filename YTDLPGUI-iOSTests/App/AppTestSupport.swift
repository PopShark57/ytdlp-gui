import Foundation
import Synchronization
@testable import YTDLPGUI_iOS

// Fakes for the outside world, and a builder that wires the app's parts together around them,
// each test in its own temporary folder and UserDefaults suite.

// MARK: - Engine fakes

/// Stands in for the embedded engine's download side. Each call to `download` becomes a `Job`
/// that the test drives by sending events and finishing it.
final class FakeDownloadEngine: DownloadEngine {

    struct Job: Sendable {
        let id: UUID
        let argv: [String]
        fileprivate let continuation: AsyncStream<EngineJobUpdate>.Continuation

        func send(_ event: EngineEvent) {
            continuation.yield(.event(event))
        }

        func finish(_ result: EngineJobResult) {
            continuation.yield(.finished(result))
            continuation.finish()
        }

        func succeed(files: [String] = []) {
            finish(EngineJobResult(exitCode: 0, wasCancelled: false, files: files, hostError: nil))
        }

        func fail(exitCode: Int32 = 1, hostError: String? = nil) {
            finish(EngineJobResult(exitCode: exitCode, wasCancelled: false, files: [], hostError: hostError))
        }
    }

    private struct State {
        var jobs: [Job] = []
        var cancelledJobIDs: [UUID] = []
    }

    private let state = Mutex(State())

    func download(argv: [String], jobID: UUID) -> AsyncStream<EngineJobUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(of: EngineJobUpdate.self)
        state.withLock { $0.jobs.append(Job(id: jobID, argv: argv, continuation: continuation)) }
        return stream
    }

    /// Behaves like the real engine: the job ends with a cancelled result.
    func cancel(jobID: UUID) {
        let job = state.withLock { state -> Job? in
            state.cancelledJobIDs.append(jobID)
            return state.jobs.first { $0.id == jobID }
        }
        job?.finish(EngineJobResult(exitCode: 101, wasCancelled: true, files: [], hostError: nil))
    }

    var jobs: [Job] { state.withLock { $0.jobs } }
    var cancelledJobIDs: [UUID] { state.withLock { $0.cancelledJobIDs } }
}

/// Stands in for the analysis side of the engine.
final class FakeAnalysisEngine: AnalysisEngine {

    enum Outcome: Sendable {
        case success(Data)
        case failure(EngineError)
    }

    private struct State {
        var outcome: Outcome = .failure(.hostFailure(message: "The test didn't say how analysis should answer.", traceback: nil))
        var log: [String] = []
        var calls: [[String]] = []
        var cancelledJobIDs: [UUID] = []
    }

    private let state = Mutex(State())

    func respond(with outcome: Outcome, log: [String] = []) {
        state.withLock {
            $0.outcome = outcome
            $0.log = log
        }
    }

    func analyze(
        argv: [String],
        jobID: UUID,
        onLog: @escaping @Sendable (EngineLogLevel, String) -> Void
    ) async throws -> Data {
        let (outcome, log) = state.withLock { state in
            state.calls.append(argv)
            return (state.outcome, state.log)
        }
        for line in log { onLog(.info, line) }
        switch outcome {
        case .success(let data): return data
        case .failure(let error): throw error
        }
    }

    func cancel(jobID: UUID) {
        state.withLock { $0.cancelledJobIDs.append(jobID) }
    }

    var calls: [[String]] { state.withLock { $0.calls } }
}

/// Stands in for the interpreter's lifecycle and yt-dlp updates.
final class FakeEngineRuntime: EngineRuntime {

    static let info = EngineInfo(
        pythonVersion: "3.14.7",
        ytdlpVersion: "2026.8.19",
        ytdlpSource: .bundled,
        ejsVersion: "0.8.0",
        certifiVersion: "2026.7.22"
    )

    private struct State {
        var startError: EngineError?
        var startCount = 0
        var restartRequired = false
    }

    private let state = Mutex(State())

    func failStarts(with error: EngineError?) {
        state.withLock { $0.startError = error }
    }

    var startCount: Int { state.withLock { $0.startCount } }

    func start() async throws -> EngineInfo {
        let error = state.withLock { state -> EngineError? in
            state.startCount += 1
            return state.startError
        }
        if let error { throw error }
        return Self.info
    }

    var isRestartRequired: Bool { state.withLock { $0.restartRequired } }

    func checkForUpdate() async throws -> EngineUpdateInfo {
        EngineUpdateInfo(currentVersion: "2026.8.19", latestVersion: "2026.9.1", isNewer: true)
    }

    func installLatestUpdate() async throws -> String {
        state.withLock { $0.restartRequired = true }
        return "2026.9.1"
    }

    func revertToBundledVersion() throws {
        state.withLock { $0.restartRequired = false }
    }
}

// MARK: - Clipboard fake

@MainActor
final class FakeClipboard: ClipboardLinkDetecting {
    var changeCount = 0
    var holdsLink = false
    private(set) var detectionCount = 0

    func containsProbableWebURL() async -> Bool {
        detectionCount += 1
        return holdsLink
    }
}

// MARK: - Environment

struct TestSetupError: Error, CustomStringConvertible {
    var description: String
}

/// The app's parts, wired together around the fakes, in a throwaway folder.
@MainActor
final class AppTestEnvironment {

    let root: URL
    let suiteName: String
    let defaults: UserDefaults

    let downloader = FakeDownloadEngine()
    let analyzer = FakeAnalysisEngine()
    let runtime = FakeEngineRuntime()
    let clipboard = FakeClipboard()
    let status = StatusCenter()
    var sharedLinks: [SharedLink] = []

    let settings: AppSettings
    let storage: StorageManager
    let cookies: CookieStore
    let history: HistoryStore
    let notifications: NotificationService
    let library: MediaLibrary
    let engine: EngineController
    let queueStoreURL: URL
    private(set) var queue: DownloadQueue
    private(set) var composer: DownloadComposer

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "YTDLPGUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        suiteName = "YTDLPGUITests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw TestSetupError(description: "Couldn't create a UserDefaults suite.")
        }
        self.defaults = defaults

        settings = AppSettings(defaults: defaults)
        // Keeps tests from asking for notification permission in the test host.
        settings.notifyWhenComplete = false

        let applicationSupport = root.appending(path: "Application Support", directoryHint: .isDirectory)
        storage = StorageManager(
            documentsDirectory: root.appending(path: "Documents", directoryHint: .isDirectory),
            cachesDirectory: root.appending(path: "Caches", directoryHint: .isDirectory),
            applicationSupportDirectory: applicationSupport
        )
        cookies = CookieStore(fileURL: applicationSupport.appending(path: "Cookies/cookies.txt"), defaults: defaults)
        history = HistoryStore(fileURL: applicationSupport.appending(path: "YTDLPGUI/history.json"))
        notifications = NotificationService()
        library = MediaLibrary()
        engine = EngineController(runtime: runtime, temporaryDirectory: storage.partialDownloadsDirectory)
        queueStoreURL = applicationSupport.appending(path: "YTDLPGUI/queue.json")

        let queue = DownloadQueue(
            settings: settings,
            engine: engine,
            downloader: downloader,
            history: history,
            notifications: notifications,
            library: library,
            storage: storage,
            cookies: cookies,
            store: QueueStore(fileURL: queueStoreURL)
        )
        self.queue = queue
        composer = DownloadComposer(
            settings: settings,
            engine: engine,
            queue: queue,
            storage: storage,
            cookies: cookies,
            analyzer: analyzer,
            status: status
        )
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    /// A second queue over the same saved state, as after a relaunch.
    func makeRelaunchedQueue() -> DownloadQueue {
        DownloadQueue(
            settings: settings,
            engine: engine,
            downloader: downloader,
            history: history,
            notifications: notifications,
            library: library,
            storage: storage,
            cookies: cookies,
            store: QueueStore(fileURL: queueStoreURL)
        )
    }

    func makeAppModel() -> AppModel {
        AppModel(
            settings: settings,
            engine: engine,
            history: history,
            notifications: notifications,
            library: library,
            cookies: cookies,
            storage: storage,
            queue: queue,
            composer: composer,
            background: BackgroundActivity(settings: settings, setIdleTimerDisabled: { _ in }, requestsBackgroundTime: false),
            status: status,
            clipboard: clipboard,
            drainSharedInbox: { [weak self] in
                let links = self?.sharedLinks ?? []
                self?.sharedLinks = []
                return links
            }
        )
    }

    /// Writes a file into the downloads folder, as a finished download would.
    @discardableResult
    func makeDownloadedFile(named name: String, bytes: Int = 1_024) throws -> URL {
        let url = storage.downloadsDirectory.appending(path: name)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }
}

// MARK: - Waiting

struct WaitTimeout: Error, CustomStringConvertible {
    var description: String
}

/// Polls until `condition` holds, letting the queue's tasks run in between.
@MainActor
func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(5),
    _ condition: () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else {
            throw WaitTimeout(description: "Timed out waiting for: \(description)")
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// Waits for the fake engine to have received at least `count` download jobs, and returns them.
@MainActor
func waitForJobs(_ count: Int, on engine: FakeDownloadEngine) async throws -> [FakeDownloadEngine.Job] {
    try await waitUntil("\(count) download job(s) to start") { engine.jobs.count >= count }
    return engine.jobs
}

/// Minimal `yt-dlp --dump-single-json` documents.
enum SampleInfo {
    static func video(url: String, title: String = "Sample Clip", maxHeight: Int = 1080, extractor: String = "Youtube") -> Data {
        let json: [String: Any] = [
            "id": "abc123",
            "title": title,
            "uploader": "Uploader",
            "duration": 42,
            "webpage_url": url,
            "extractor_key": extractor,
            "formats": [
                ["format_id": "18", "ext": "mp4", "height": 360, "vcodec": "avc1.42001E", "acodec": "mp4a.40.2"],
                ["format_id": "top", "ext": "mp4", "height": maxHeight, "vcodec": "av01.0.08M.08", "acodec": "none"],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }

    static func playlist(url: String) -> Data {
        let json: [String: Any] = [
            "_type": "playlist",
            "id": "PL1",
            "title": "A Playlist",
            "webpage_url": url,
            "entries": [
                ["id": "a", "title": "First", "url": "https://example.com/a"],
                ["id": "b", "title": "Second", "url": "https://example.com/b"],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }
}
