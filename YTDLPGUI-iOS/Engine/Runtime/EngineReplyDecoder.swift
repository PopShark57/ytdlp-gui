import Foundation

/// Reads the host's replies to commands ("Commands" in Docs/iOS-Architecture.md).
///
/// Every reply is an object whose `ok` says whether the command worked; failures carry an
/// `error` sentence and, when Python raised, a `traceback`.
enum EngineReplyDecoder {

    static let unreadableReply = "The download engine sent an answer the app couldn't read."
    static let unexplainedFailure = "The download engine failed without saying why."

    // MARK: - configure / version

    static func engineInfo(from data: Data) throws -> EngineInfo {
        let reply = try successfulReply(from: data)
        guard let python = EngineJSON.nonEmptyString(reply["python"]),
              let ytdlp = EngineJSON.nonEmptyString(reply["yt_dlp"]) else {
            throw EngineError.hostFailure(message: "The download engine didn't report which versions it's running.", traceback: nil)
        }
        return EngineInfo(
            pythonVersion: python,
            ytdlpVersion: ytdlp,
            ytdlpSource: EngineJSON.string(reply["yt_dlp_source"]).flatMap(YTDLPSource.init(rawValue:)) ?? .bundled,
            ejsVersion: EngineJSON.nonEmptyString(reply["ejs"]),
            certifiVersion: EngineJSON.nonEmptyString(reply["certifi"]),
            updateError: EngineJSON.nonEmptyString(reply["update_error"])
        )
    }

    // MARK: - analyze

    /// The info dictionary of a successful analysis, as JSON ready for `MediaInfoDecoder`.
    ///
    /// The host embeds the dictionary as an object, so it is re-serialised here. That costs one
    /// extra pass over a document the envelope check has already parsed, and in exchange any
    /// `NaN` an extractor produced becomes `null`, which `JSONDecoder` would otherwise reject
    /// along with the whole analysis.
    ///
    /// - Parameter cancellationRequested: whether the app asked the job to stop. A job
    ///   interrupted mid-flight can fail in ways that don't look like a cancellation, and the
    ///   person who pressed Cancel should see it reported as one.
    static func analysisInfo(from data: Data, cancellationRequested: Bool) throws -> Data {
        guard let reply = EngineJSON.object(from: data) else {
            throw EngineError.hostFailure(message: unreadableReply, traceback: nil)
        }
        if EngineJSON.bool(reply["ok"]) == true {
            guard let info = reply["info"] as? [String: Any] else {
                throw EngineError.hostFailure(message: "The download engine finished the analysis without returning any information.", traceback: nil)
            }
            guard let json = EngineJSON.data(from: info) else {
                throw EngineError.hostFailure(message: "The information about this link couldn't be read.", traceback: nil)
            }
            return json
        }
        if cancellationRequested || EngineJSON.bool(reply["cancelled"]) == true {
            throw EngineError.cancelled
        }
        let message = errorMessage(in: reply)
        if let log = reply["log"] as? [Any] {
            throw EngineError.analysisFailed(message: message, logLines: EngineJSON.strings(log))
        }
        throw EngineError.hostFailure(message: message, traceback: EngineJSON.nonEmptyString(reply["traceback"]))
    }

    // MARK: - download

    /// How a download ended. Never throws: every failure becomes the job's `hostError`.
    static func downloadResult(from data: Data, cancellationRequested: Bool) -> EngineJobResult {
        guard let reply = EngineJSON.object(from: data) else {
            return cancellationRequested ? .cancelled : .hostFailure(unreadableReply)
        }
        guard EngineJSON.bool(reply["ok"]) == true else {
            return cancellationRequested ? .cancelled : .hostFailure(errorMessage(in: reply))
        }
        let cancelled = EngineJSON.bool(reply["cancelled"]) ?? false
        let exitCode = EngineJSON.int(reply["exit_code"]).flatMap { Int32(exactly: $0) } ?? (cancelled ? 101 : 0)
        return EngineJobResult(
            exitCode: exitCode,
            wasCancelled: cancelled,
            files: EngineJSON.strings(reply["files"]),
            hostError: nil
        )
    }

    // MARK: - cancel

    /// Whether the host found the job it was asked to cancel, or `nil` when the reply doesn't say.
    static func cancellationFoundJob(in data: Data) -> Bool? {
        guard let reply = EngineJSON.object(from: data), EngineJSON.bool(reply["ok"]) == true else { return nil }
        return EngineJSON.bool(reply["found"])
    }

    // MARK: - Updates

    static func updateInfo(from data: Data) throws -> EngineUpdateInfo {
        let reply = try successfulReply(from: data)
        guard let current = EngineJSON.nonEmptyString(reply["current"]),
              let latest = EngineJSON.nonEmptyString(reply["latest"]) else {
            throw EngineError.hostFailure(message: "The update check didn't return version numbers.", traceback: nil)
        }
        return EngineUpdateInfo(
            currentVersion: current,
            latestVersion: latest,
            isNewer: EngineJSON.bool(reply["is_newer"]) ?? false
        )
    }

    /// The version an update installed.
    static func installedVersion(from data: Data) throws -> String {
        let reply = try successfulReply(from: data)
        guard let version = EngineJSON.nonEmptyString(reply["version"]) else {
            throw EngineError.hostFailure(message: "The update was installed but didn't report its version.", traceback: nil)
        }
        return version
    }

    // MARK: - Envelope

    /// The reply object, or the host's failure as an `EngineError.hostFailure`.
    static func successfulReply(from data: Data) throws -> [String: Any] {
        guard let reply = EngineJSON.object(from: data) else {
            throw EngineError.hostFailure(message: unreadableReply, traceback: nil)
        }
        guard EngineJSON.bool(reply["ok"]) == true else {
            throw EngineError.hostFailure(
                message: errorMessage(in: reply),
                traceback: EngineJSON.nonEmptyString(reply["traceback"])
            )
        }
        return reply
    }

    private static func errorMessage(in reply: [String: Any]) -> String {
        EngineJSON.nonEmptyString(reply["error"]) ?? unexplainedFailure
    }
}
