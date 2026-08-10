import Foundation

/// Thin, stateless wrapper around the `yt-dlp` executable.
///
/// The service owns *how* yt-dlp is invoked; it deliberately holds no UI state, so it can be
/// created on demand wherever the current tool paths are known.
struct YTDLPService: Sendable {
    let executableURL: URL
    let ffmpegURL: URL?

    // MARK: - Metadata

    struct AnalysisFailure: LocalizedError, Sendable {
        var failure: DownloadFailure
        var logLines: [String]

        var errorDescription: String? { failure.title }
        var recoverySuggestion: String? { failure.recoverySuggestion }
    }

    /// Runs `yt-dlp --dump-single-json` and decodes the result.
    func fetchMediaInfo(url: String, options: DownloadOptions) async throws -> MediaInfo {
        let configuration = ProcessConfiguration(
            executableURL: executableURL,
            arguments: ArgumentBuilder.metadataArguments(url: url, options: options)
        )

        let output: ProcessRunner.CollectedOutput
        do {
            output = try await ProcessRunner.run(configuration, timeout: 120)
        } catch {
            throw AnalysisFailure(
                failure: DownloadFailure(kind: .unknown, underlyingMessage: error.localizedDescription),
                logLines: [error.localizedDescription]
            )
        }

        let errorLines = output.standardError
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        guard output.isSuccess else {
            throw AnalysisFailure(
                failure: DownloadFailure.classify(logLines: errorLines, exitCode: output.result.exitCode),
                logLines: errorLines
            )
        }

        guard let data = output.standardOutput.data(using: .utf8), !data.isEmpty else {
            throw AnalysisFailure(
                failure: DownloadFailure(
                    kind: .unknown,
                    underlyingMessage: "yt-dlp returned no information for this URL."
                ),
                logLines: errorLines
            )
        }

        do {
            return try MediaInfoDecoder.decode(data, originalURL: url)
        } catch {
            throw AnalysisFailure(
                failure: DownloadFailure(
                    kind: .unknown,
                    underlyingMessage: "Couldn't read the information yt-dlp returned: \(error.localizedDescription)"
                ),
                logLines: errorLines
            )
        }
    }

    // MARK: - Downloading

    /// Creates (but does not start) the process for a download.
    func makeDownloadSession(url: String, options: DownloadOptions) -> ProcessSession {
        let configuration = ProcessConfiguration(
            executableURL: executableURL,
            arguments: ArgumentBuilder.downloadArguments(
                url: url,
                options: options,
                ffmpegURL: ffmpegURL
            ),
            // Running in the destination keeps any relative path yt-dlp reports resolvable.
            currentDirectoryURL: options.outputDirectory
        )
        return ProcessSession(configuration: configuration)
    }

    /// The command the preview shows for a given URL and options.
    func previewCommand(url: String, options: DownloadOptions) -> String {
        ShellQuoting.commandLine(
            executable: executableURL.path(percentEncoded: false),
            arguments: ArgumentBuilder.downloadArguments(url: url, options: options, ffmpegURL: ffmpegURL)
        )
    }

    // MARK: - Updating

    /// How yt-dlp should be updated, which depends on how it was installed.
    ///
    /// `yt-dlp -U` refuses to touch a Homebrew-managed install (and rightly so: it would leave
    /// the formula out of sync), so Homebrew installs are upgraded through `brew` instead.
    enum UpdateStrategy: Equatable, Sendable {
        case selfUpdate
        case homebrew(brewURL: URL)
        case unmanaged

        var explanation: String {
            switch self {
            case .selfUpdate:
                "Runs yt-dlp's built-in updater."
            case .homebrew:
                "yt-dlp was installed with Homebrew, so it will be updated with `brew upgrade yt-dlp`."
            case .unmanaged:
                "This copy of yt-dlp can't update itself. Update it the same way you installed it."
            }
        }
    }

    /// Chooses an update strategy for the current install.
    func updateStrategy(status: ToolStatus) -> UpdateStrategy {
        if status.isHomebrew, let brew = ToolLocator.homebrewExecutable() {
            return .homebrew(brewURL: brew)
        }
        // A pip or pipx install can self-update; a system-managed one usually can't, but
        // yt-dlp itself reports that far more accurately than we could guess.
        return .selfUpdate
    }

    /// Builds the process for an update, so the caller can stream its output into a log view.
    func makeUpdateSession(strategy: UpdateStrategy) -> ProcessSession? {
        switch strategy {
        case .selfUpdate:
            ProcessSession(configuration: ProcessConfiguration(
                executableURL: executableURL,
                arguments: ["--update"]
            ))
        case .homebrew(let brewURL):
            ProcessSession(configuration: ProcessConfiguration(
                executableURL: brewURL,
                arguments: ["upgrade", "yt-dlp"],
                // Homebrew is noisy and interactive-ish unless told otherwise.
                additionalEnvironment: [
                    "HOMEBREW_NO_AUTO_UPDATE": "1",
                    "HOMEBREW_NO_ENV_HINTS": "1",
                    "HOMEBREW_COLOR": "0",
                ]
            ))
        case .unmanaged:
            nil
        }
    }
}
