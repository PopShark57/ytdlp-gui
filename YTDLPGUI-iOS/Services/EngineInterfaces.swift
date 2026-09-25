import Foundation

// The slices of `YTDLPEngine` that the app layer depends on.
//
// Each consumer names only what it uses, so the queue, the composer and the engine controller can
// be exercised in tests with scripted fakes instead of a real Python interpreter. The app itself
// always passes `YTDLPEngine.shared`, which conforms to all three.

/// Runs downloads, for `DownloadQueue`.
protocol DownloadEngine: Sendable {
    /// Starts a download. The stream ends with exactly one `.finished` update.
    func download(argv: [String], jobID: UUID) -> AsyncStream<EngineJobUpdate>

    /// Asks a running job to stop, keeping its partial files. Safe for a job that already ended.
    func cancel(jobID: UUID)
}

/// Extracts metadata without downloading, for `DownloadComposer`.
protocol AnalysisEngine: Sendable {
    func analyze(
        argv: [String],
        jobID: UUID,
        onLog: @escaping @Sendable (EngineLogLevel, String) -> Void
    ) async throws -> Data

    func cancel(jobID: UUID)
}

/// Starts the interpreter and manages yt-dlp updates, for `EngineController`.
protocol EngineRuntime: Sendable {
    func start() async throws -> EngineInfo
    var isRestartRequired: Bool { get }
    func checkForUpdate() async throws -> EngineUpdateInfo
    func installLatestUpdate() async throws -> String
    func revertToBundledVersion() throws
}

extension YTDLPEngine: DownloadEngine, AnalysisEngine, EngineRuntime {}
