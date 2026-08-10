import Foundation

/// One of the external command-line tools the app depends on.
enum ExternalTool: String, CaseIterable, Identifiable, Sendable {
    case ytdlp = "yt-dlp"
    case ffmpeg = "ffmpeg"

    var id: String { rawValue }

    var displayName: String { rawValue }

    var homebrewFormula: String { rawValue }

    var installCommand: String { "brew install \(rawValue)" }

    /// A single command that installs several tools at once, rather than several commands
    /// concatenated into something unrunnable.
    static func installCommand(for tools: [ExternalTool]) -> String {
        let formulae = tools.isEmpty ? [ExternalTool.ytdlp] : tools
        return "brew install " + formulae.map(\.homebrewFormula).joined(separator: " ")
    }

    /// Arguments that make the tool print its version and exit.
    var versionArguments: [String] {
        switch self {
        case .ytdlp: ["--version"]
        case .ffmpeg: ["-version"]
        }
    }

    var symbolName: String {
        switch self {
        case .ytdlp: "arrow.down.app"
        case .ffmpeg: "film.stack"
        }
    }

    var purpose: String {
        switch self {
        case .ytdlp: "Downloads the media. Required."
        case .ffmpeg: "Merges video with audio, converts audio and embeds metadata. Strongly recommended."
        }
    }

    var isRequired: Bool { self == .ytdlp }
}

/// Where the app found a tool.
enum ToolSource: Equatable, Sendable {
    case automatic
    case userSelected

    var displayName: String {
        switch self {
        case .automatic: "Detected automatically"
        case .userSelected: "Chosen manually"
        }
    }
}

/// The result of looking for an external tool.
struct ToolStatus: Equatable, Sendable, Identifiable {
    var tool: ExternalTool
    var executableURL: URL?
    var version: String?
    var source: ToolSource = .automatic
    /// Set when a manually chosen path no longer exists or isn't executable.
    var problem: String?

    var id: String { tool.id }

    var isInstalled: Bool { executableURL != nil }

    static func missing(_ tool: ExternalTool) -> ToolStatus {
        ToolStatus(tool: tool, executableURL: nil, version: nil)
    }

    var displayPath: String {
        executableURL?.path(percentEncoded: false) ?? "Not found"
    }

    /// The real location behind a Homebrew symlink, when it differs from `executableURL`.
    var resolvedPath: String? {
        guard let executableURL else { return nil }
        let resolved = executableURL.resolvingSymlinksInPath()
        let original = executableURL.standardizedFileURL
        guard resolved.path(percentEncoded: false) != original.path(percentEncoded: false) else {
            return nil
        }
        return resolved.path(percentEncoded: false)
    }

    var isHomebrew: Bool {
        guard let path = executableURL?.resolvingSymlinksInPath().path(percentEncoded: false) else {
            return false
        }
        return path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/Cellar/")
            || path.hasPrefix("/usr/local/Homebrew/") || path.contains("/homebrew/")
    }

    var statusLabel: String {
        if let problem { return problem }
        if isInstalled { return version.map { "Version \($0)" } ?? "Installed" }
        return "Not installed"
    }
}
