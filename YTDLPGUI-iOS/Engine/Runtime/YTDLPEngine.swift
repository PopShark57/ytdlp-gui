import Foundation
import os
import Synchronization

/// The embedded yt-dlp engine: a CPython interpreter running yt-dlp in-process.
///
/// One instance exists per process (`shared`). All methods are safe to call from any thread
/// or actor. Long-running work happens on dedicated threads, never on Swift's cooperative pool,
/// because a single yt-dlp call can block for many minutes.
///
/// Each analysis and download is one `ytdlpgui_host.dispatch` call on an `EngineThread`. What the
/// job reports on the way arrives through the C bridge's emit callback, which
/// `EngineCallbackHub` routes by job ID; what it asks of the app (merging, JavaScript) arrives
/// through the request callback and is answered by an `EngineRequestRouter`.
final class YTDLPEngine: Sendable {

    static let shared = YTDLPEngine()

    private enum StartPhase {
        case idle
        case starting(Task<EngineInfo, any Error>)
        case started(EngineInfo)
    }

    private let configuration: EngineConfiguration
    private let router: EngineRequestRouter
    private let hub = EngineCallbackHub.shared
    private let startPhase = Mutex(StartPhase.idle)
    private let restartRequired = Mutex(false)
    private let logger = AppLog.engine

    /// - Parameters:
    ///   - configuration: where the runtime and the engine's data live.
    ///   - requestRouter: what answers the host's media and JavaScript requests. The interpreter
    ///     is process-wide, so the router of the engine that started most recently answers for
    ///     every engine; in practice there is only `shared`.
    init(configuration: EngineConfiguration = .standard, requestRouter: EngineRequestRouter = EngineRequestRouter()) {
        self.configuration = configuration
        self.router = requestRouter
    }

    // MARK: - Starting

    /// Starts the interpreter and configures the host (once). Later calls return the same
    /// information without doing any work.
    ///
    /// Concurrent callers share one attempt. After a failure the next call tries again, but an
    /// interpreter that failed to initialise fails again at once with the same error: CPython
    /// cannot be restarted within a process. Only a failed `configure` is genuinely retried.
    func start() async throws -> EngineInfo {
        enum Next {
            case ready(EngineInfo)
            case wait(Task<EngineInfo, any Error>)
        }
        let next: Next = startPhase.withLock { phase in
            switch phase {
            case .started(let info):
                return .ready(info)
            case .starting(let attempt):
                return .wait(attempt)
            case .idle:
                let attempt = Task.detached(priority: .userInitiated) { try await self.performStart() }
                phase = .starting(attempt)
                return .wait(attempt)
            }
        }
        switch next {
        case .ready(let info):
            return info
        case .wait(let attempt):
            return try await attempt.value
        }
    }

    private func performStart() async throws -> EngineInfo {
        let startedAt = ContinuousClock.now
        let result = await EngineThread.run(named: "YTDLP GUI engine start") { [configuration, router] in
            Result { try Self.startSynchronously(configuration: configuration, router: router) }
        }
        startPhase.withLock { phase in
            if case .success(let info) = result {
                phase = .started(info)
            } else {
                phase = .idle
            }
        }
        switch result {
        case .success(let info):
            logger.info("Engine started in \((ContinuousClock.now - startedAt).formatted(), privacy: .public): yt-dlp \(info.ytdlpVersion, privacy: .public) (\(info.ytdlpSource.rawValue, privacy: .public)), Python \(info.pythonVersion, privacy: .public)")
        case .failure(let error):
            logger.error("Engine failed to start: \(error.localizedDescription, privacy: .public)")
        }
        return try result.get()
    }

    private static func startSynchronously(configuration: EngineConfiguration, router: EngineRequestRouter) throws -> EngineInfo {
        try configuration.validateRuntime()
        configuration.createCacheDirectories()
        // Only while nothing can be importing from the update folders: a retried start (after a
        // failed `configure`) finds the interpreter already running.
        if !PythonRuntime.isRunning {
            configuration.prepareUpdatesForLaunch()
        }
        EngineCallbackHub.shared.install(router)
        try PythonRuntime.start(
            pythonHome: configuration.pythonHome,
            modulePaths: configuration.modulePaths,
            bytecodeCache: configuration.bytecodeCacheDirectory
        )
        let payload = try encode(ConfigurePayload(
            cacheDirectory: configuration.cacheDirectory.path(percentEncoded: false),
            updateDirectory: configuration.activeUpdateDirectory?.path(percentEncoded: false),
            platformVersion: configuration.platformVersion
        ))
        do {
            return try EngineReplyDecoder.engineInfo(from: PythonRuntime.call("configure", payload: payload))
        } catch let error as EngineError {
            throw EngineError.startupFailed(error.localizedDescription)
        }
    }

    // MARK: - Jobs

    /// Extracts metadata without downloading.
    ///
    /// Starts the engine first if nobody has yet. Cancelling the calling task cancels the job.
    ///
    /// - Parameters:
    ///   - argv: yt-dlp arguments from `ArgumentBuilder.embeddedMetadataArguments`.
    ///   - jobID: identifies the job for `cancel(jobID:)`.
    ///   - onLog: receives each output line as it is produced, on an engine thread.
    /// - Returns: the info dictionary as JSON — the same document `yt-dlp --dump-single-json`
    ///   prints — ready for `MediaInfoDecoder.decode`.
    /// - Throws: `EngineError.analysisFailed` when yt-dlp reports an error, `.cancelled` when
    ///   cancelled, `.hostFailure` for anything else.
    func analyze(
        argv: [String],
        jobID: UUID,
        onLog: @escaping @Sendable (EngineLogLevel, String) -> Void = { _, _ in }
    ) async throws -> Data {
        let job = EngineJob(id: jobID, destination: .analysis(onLog))
        guard hub.register(job) else {
            throw EngineError.hostFailure(message: "This link is already being analysed.", traceback: nil)
        }
        defer {
            hub.unregister(job)
            job.close()
        }
        return try await withTaskCancellationHandler {
            _ = try await start()
            guard !job.isCancellationRequested else { throw EngineError.cancelled }
            let payload = try Self.encode(JobPayload(jobID: job.id, argv: argv))
            let reply = await EngineThread.run(named: "YTDLP GUI analysis") {
                PythonRuntime.call("analyze", payload: payload)
            }
            return try EngineReplyDecoder.analysisInfo(from: reply, cancellationRequested: job.isCancellationRequested)
        } onCancel: {
            cancel(jobID: jobID)
        }
    }

    /// Runs a download. The stream yields events as they happen and always ends with exactly
    /// one `.finished` update, even when the engine could not start the job.
    ///
    /// Starts the engine first if nobody has yet. If whoever iterates the stream stops (their
    /// task is cancelled, or they drop the stream), the download is cancelled too, so no job
    /// runs on unobserved.
    ///
    /// - Parameter argv: yt-dlp arguments from `ArgumentBuilder.embeddedDownloadArguments`.
    func download(argv: [String], jobID: UUID) -> AsyncStream<EngineJobUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(of: EngineJobUpdate.self, bufferingPolicy: .unbounded)
        let job = EngineJob(id: jobID, destination: .download(continuation))
        guard hub.register(job) else {
            continuation.yield(.finished(.hostFailure("This download is already running.")))
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [self] termination in
            if case .cancelled = termination {
                cancel(jobID: jobID)
            }
        }
        Task.detached(priority: .userInitiated) { [self] in
            let result = await runDownload(job, argv: argv)
            hub.unregister(job)
            job.finish(with: result)
        }
        return stream
    }

    private func runDownload(_ job: EngineJob, argv: [String]) async -> EngineJobResult {
        do {
            _ = try await start()
            guard !job.isCancellationRequested else { return .cancelled }
            let payload = try Self.encode(JobPayload(jobID: job.id, argv: argv))
            let reply = await EngineThread.run(named: "YTDLP GUI download") {
                PythonRuntime.call("download", payload: payload)
            }
            return EngineReplyDecoder.downloadResult(from: reply, cancellationRequested: job.isCancellationRequested)
        } catch {
            return job.isCancellationRequested ? .cancelled : .hostFailure(error.localizedDescription)
        }
    }

    /// Asks a running analysis or download to stop. yt-dlp keeps its partial files so a retry
    /// resumes where it left off. Safe to call for a job that already finished.
    ///
    /// Returns at once: the job's in-flight media or JavaScript work is cancelled, and the host
    /// is told on a background thread. The job then ends through its own path, as cancelled.
    func cancel(jobID: UUID) {
        guard let job = hub.job(withID: jobID.uuidString), job.requestCancellation() else { return }
        hub.cancelRequests(forJob: job.id)
        // Before the interpreter is up, the job hasn't reached the host; it checks the flag
        // before it does.
        guard PythonRuntime.isRunning else { return }
        EngineThread.detach(named: "YTDLP GUI cancel") { [hub] in
            Self.cancelInHost(job, hub: hub)
        }
    }

    /// Tells the host to stop `job`.
    ///
    /// A job whose thread has checked the cancellation flag but not yet reached the host's job
    /// table is reported as not found. On a busy device that window can last a while, so the
    /// cancel is repeated, backing off to once a second, for as long as the job is still running.
    private static func cancelInHost(_ job: EngineJob, hub: EngineCallbackHub) {
        guard let payload = try? encode(CancelPayload(jobID: job.id)) else { return }
        var delay = 0.05
        while hub.isRegistered(job) {
            let reply = PythonRuntime.call("cancel", payload: payload)
            guard EngineReplyDecoder.cancellationFoundJob(in: reply) == false else { return }
            Thread.sleep(forTimeInterval: delay)
            delay = min(delay * 2, 1)
        }
    }

    // MARK: Updating yt-dlp

    /// Asks PyPI for the newest yt-dlp release.
    func checkForUpdate() async throws -> EngineUpdateInfo {
        _ = try await start()
        let reply = await EngineThread.run(named: "YTDLP GUI update check") {
            PythonRuntime.call("check_update", payload: Data("{}".utf8))
        }
        return try EngineReplyDecoder.updateInfo(from: reply)
    }

    /// Downloads, verifies and installs the newest yt-dlp release (with the matching
    /// yt-dlp-ejs). Takes effect the next time the app launches, because a running interpreter
    /// cannot safely swap out a package it has already imported.
    ///
    /// The update goes into a new folder, so the one the running engine imports from is never
    /// touched and downloads carry on unaffected (see `EngineConfiguration`'s installed updates).
    func installLatestUpdate() async throws -> String {
        _ = try await start()
        try configuration.prepareUpdateFolder()
        let destination = configuration.makeNewUpdateDirectory()
        let payload = try Self.encode(InstallPayload(
            stagingDirectory: configuration.stagingDirectory.path(percentEncoded: false),
            updateDirectory: destination.path(percentEncoded: false)
        ))
        let reply = await EngineThread.run(named: "YTDLP GUI update install") {
            PythonRuntime.call("install_update", payload: payload)
        }
        let version = try EngineReplyDecoder.installedVersion(from: reply)
        try configuration.activate(destination)
        restartRequired.withLock { $0 = true }
        return version
    }

    /// Uses the bundled yt-dlp from the next launch. Only the pointer to the installed update is
    /// removed; its folder, which the running engine may still import from, goes at the next
    /// launch.
    func revertToBundledVersion() throws {
        try configuration.deactivate()
        // A restart matters only if the running interpreter imported the update; reverting an
        // update installed during this session cancels the restart it asked for.
        let loadedSource: YTDLPSource? = startPhase.withLock { phase in
            if case .started(let info) = phase { return info.ytdlpSource }
            return nil
        }
        restartRequired.withLock { $0 = loadedSource == .updated }
    }

    /// Whether an installed update is waiting for the app to restart.
    var isRestartRequired: Bool { restartRequired.withLock { $0 } }

    // MARK: - Payloads

    private static func encode(_ payload: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(payload)
    }
}

// MARK: - Command payloads

private struct ConfigurePayload: Encodable {
    var cacheDirectory: String
    var updateDirectory: String?
    var platformVersion: String

    enum CodingKeys: String, CodingKey {
        case cacheDirectory = "cache_dir"
        case updateDirectory = "update_dir"
        case platformVersion = "platform_version"
    }

    /// Written by hand so a missing update directory is an explicit `null`, as the protocol says.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cacheDirectory, forKey: .cacheDirectory)
        try container.encode(updateDirectory, forKey: .updateDirectory)
        try container.encode(platformVersion, forKey: .platformVersion)
    }
}

private struct JobPayload: Encodable {
    var jobID: String
    var argv: [String]

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case argv
    }
}

private struct CancelPayload: Encodable {
    var jobID: String

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
    }
}

private struct InstallPayload: Encodable {
    var stagingDirectory: String
    var updateDirectory: String

    enum CodingKeys: String, CodingKey {
        case stagingDirectory = "staging_dir"
        case updateDirectory = "update_dir"
    }
}
