import Foundation
import Observation

/// Tracks whether `yt-dlp` and `ffmpeg` are available, and drives yt-dlp updates.
@MainActor
@Observable
final class Toolchain {

    private(set) var ytdlp: ToolStatus = .missing(.ytdlp)
    private(set) var ffmpeg: ToolStatus = .missing(.ffmpeg)
    private(set) var isRefreshing = false
    private(set) var hasCompletedFirstCheck = false

    // Update state
    private(set) var isUpdating = false
    private(set) var updateLog: [String] = []
    private(set) var updateSummary: String?
    private(set) var updateDidFail = false

    private let settings: AppSettings
    private var updateSession: ProcessSession?

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// True once the required tool is present and the app can actually download something.
    var isReady: Bool { ytdlp.isInstalled }

    /// ffmpeg is optional but almost always needed in practice.
    var canMergeStreams: Bool { ffmpeg.isInstalled }

    var isHomebrewInstalled: Bool { ToolLocator.isHomebrewInstalled }

    /// A service bound to the currently detected executables, or `nil` when yt-dlp is missing.
    var service: YTDLPService? {
        guard let executableURL = ytdlp.executableURL else { return nil }
        return YTDLPService(executableURL: executableURL, ffmpegURL: ffmpeg.executableURL)
    }

    // MARK: - Detection

    func refresh() async {
        isRefreshing = true
        defer {
            isRefreshing = false
            hasCompletedFirstCheck = true
        }

        // Both probes run concurrently; each spawns a short-lived `--version` process.
        async let ytdlpStatus = ToolLocator.status(
            for: .ytdlp,
            userSelectedPath: settings.ytdlpPathOverride.isEmpty ? nil : settings.ytdlpPathOverride
        )
        async let ffmpegStatus = ToolLocator.status(
            for: .ffmpeg,
            userSelectedPath: settings.ffmpegPathOverride.isEmpty ? nil : settings.ffmpegPathOverride
        )

        ytdlp = await ytdlpStatus
        ffmpeg = await ffmpegStatus
    }

    // MARK: - Manual selection

    func setExecutablePath(_ path: String, for tool: ExternalTool) async {
        switch tool {
        case .ytdlp: settings.ytdlpPathOverride = path
        case .ffmpeg: settings.ffmpegPathOverride = path
        }
        await refresh()
    }

    func resetExecutablePath(for tool: ExternalTool) async {
        switch tool {
        case .ytdlp: settings.ytdlpPathOverride = ""
        case .ffmpeg: settings.ffmpegPathOverride = ""
        }
        await refresh()
    }

    func status(for tool: ExternalTool) -> ToolStatus {
        switch tool {
        case .ytdlp: ytdlp
        case .ffmpeg: ffmpeg
        }
    }

    // MARK: - Updating yt-dlp

    var updateStrategy: YTDLPService.UpdateStrategy? {
        service?.updateStrategy(status: ytdlp)
    }

    /// Runs the appropriate update command, streaming its output into `updateLog`.
    func updateYTDLP() async {
        guard !isUpdating, let service, let strategy = updateStrategy else { return }
        guard let session = service.makeUpdateSession(strategy: strategy) else {
            updateSummary = strategy.explanation
            updateDidFail = true
            return
        }

        isUpdating = true
        updateDidFail = false
        updateSummary = nil
        updateLog = ["$ \(session.configuration.displayCommand)"]
        updateSession = session

        defer {
            isUpdating = false
            updateSession = nil
        }

        do {
            try session.start()
        } catch {
            updateLog.append(error.localizedDescription)
            updateSummary = error.localizedDescription
            updateDidFail = true
            return
        }

        var result: ProcessResult?
        for await event in session.events {
            switch event {
            case .standardOutput(let line), .standardError(let line):
                updateLog.append(line)
                if updateLog.count > 500 { updateLog.removeFirst(updateLog.count - 500) }
            case .finished(let processResult):
                result = processResult
            }
        }

        let previousVersion = ytdlp.version
        await refresh()

        guard let result else {
            updateSummary = "The update command didn't report a result."
            updateDidFail = true
            return
        }

        if result.isSuccess {
            updateDidFail = false
            if let newVersion = ytdlp.version, newVersion != previousVersion {
                updateSummary = "Updated to \(newVersion)."
            } else {
                updateSummary = "yt-dlp is already up to date."
            }
        } else {
            updateDidFail = true
            updateSummary = updateLog.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                ?? "The update failed with exit code \(result.exitCode)."
        }
    }

    func cancelUpdate() {
        updateSession?.cancel()
    }

    func clearUpdateLog() {
        updateLog.removeAll()
        updateSummary = nil
        updateDidFail = false
    }
}
