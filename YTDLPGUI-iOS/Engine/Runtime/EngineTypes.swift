import Foundation

// Value types exchanged between the embedded yt-dlp engine and the rest of the app.
//
// Each one mirrors a JSON object produced by the Python host (PythonHost/ytdlpgui_host); the
// wire format is documented in Docs/iOS-Architecture.md. Nothing here knows about Python.

// MARK: - Engine information

/// Where the yt-dlp package the engine imported came from.
enum YTDLPSource: String, Codable, Sendable {
    /// The copy compiled into the app bundle.
    case bundled
    /// A newer copy the user installed from PyPI, stored in Application Support.
    case updated
}

/// Versions of everything the embedded engine is built from.
struct EngineInfo: Equatable, Sendable {
    var pythonVersion: String
    var ytdlpVersion: String
    var ytdlpSource: YTDLPSource
    /// Version of the yt-dlp-ejs challenge-solver scripts, when importable.
    var ejsVersion: String?
    /// Version of the certifi CA bundle, when importable.
    var certifiVersion: String?
    /// Why an installed update couldn't be used, when the engine fell back to the bundled copy.
    var updateError: String? = nil
}

/// A yt-dlp release available on PyPI.
struct EngineUpdateInfo: Equatable, Sendable {
    var currentVersion: String
    var latestVersion: String
    var isNewer: Bool
}

// MARK: - Events

enum EngineLogLevel: String, Sendable {
    case debug
    case info
    case warning
    case error
}

/// yt-dlp's own name for the state of a progress tick.
enum EngineProgressStatus: String, Sendable {
    case downloading
    case finished
    case error
}

enum EnginePostProcessStatus: String, Sendable {
    case started
    case processing
    case finished
}

/// What the engine knows about the item it is about to download.
///
/// Arrives before any bytes move, so a queue row can show a title and thumbnail even when the
/// user never pressed Analyze.
struct EngineItemInfo: Equatable, Sendable {
    var id: String?
    var title: String?
    var uploader: String?
    var thumbnailURL: URL?
    var durationSeconds: Double?
    var webpageURL: URL?
    var extractor: String?
    /// 1-based position within a playlist, when downloading one.
    var playlistIndex: Int?
    var playlistCount: Int?
}

/// One structured thing a running job reported.
enum EngineEvent: Equatable, Sendable {
    /// A line of yt-dlp output, formatted as the command-line tool would print it
    /// (`WARNING: …`, `ERROR: …`, `[youtube] …`), so the macOS failure classifier and log
    /// view work unchanged.
    case log(EngineLogLevel, String)
    case progress(DownloadProgressSnapshot, status: EngineProgressStatus)
    case postProcessing(name: String, status: EnginePostProcessStatus, filePath: String?)
    case item(EngineItemInfo)
    /// A finished file at its final location. `isMain` is false for a file kept beside the main
    /// one, such as the audio track of a video and audio pair that couldn't be merged.
    case file(path: String, isMain: Bool = true)
}

/// How a download job ended.
struct EngineJobResult: Equatable, Sendable {
    /// yt-dlp's exit status: 0 for success, 1 for errors, 101 when cancelled.
    var exitCode: Int32
    var wasCancelled: Bool
    /// Final paths of every file the job produced.
    var files: [String]
    /// Set when the host itself failed (bad arguments, a crash) rather than yt-dlp reporting
    /// an error through the log.
    var hostError: String?

    var isSuccess: Bool { exitCode == 0 && !wasCancelled && hostError == nil }

    /// A job the app stopped, reported the way yt-dlp reports a cancelled download.
    static let cancelled = EngineJobResult(exitCode: 101, wasCancelled: true, files: [], hostError: nil)

    /// A job the engine itself could not run.
    static func hostFailure(_ message: String) -> EngineJobResult {
        EngineJobResult(exitCode: 1, wasCancelled: false, files: [], hostError: message)
    }
}

/// What a download job's stream delivers: any number of events, then exactly one result.
enum EngineJobUpdate: Equatable, Sendable {
    case event(EngineEvent)
    case finished(EngineJobResult)
}

// MARK: - Errors

enum EngineError: LocalizedError, Equatable, Sendable {
    /// The interpreter or the host module could not be started.
    case startupFailed(String)
    /// A call was made before `start()` succeeded.
    case notStarted
    /// The host reported a failure for a command.
    case hostFailure(message: String, traceback: String?)
    /// Analysis finished with yt-dlp reporting an error; `logLines` holds its output.
    case analysisFailed(message: String, logLines: [String])
    case cancelled

    var errorDescription: String? {
        switch self {
        case .startupFailed(let message): "The download engine couldn't start: \(message)"
        case .notStarted: "The download engine hasn't started yet."
        case .hostFailure(let message, _): message
        case .analysisFailed(let message, _): message
        case .cancelled: "Cancelled."
        }
    }
}
