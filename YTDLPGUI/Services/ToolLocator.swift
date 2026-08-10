import Foundation

/// Finds `yt-dlp`, `ffmpeg` and `brew` on disk and reads their versions.
///
/// A GUI app launched from Finder does not inherit the shell's `PATH`, so simply asking the
/// environment where a tool lives finds nothing. Instead the well-known install locations are
/// probed directly, then whatever `PATH` we did inherit is scanned as a fallback.
enum ToolLocator {

    // MARK: - Search locations

    /// Directories checked for command-line tools, in priority order.
    static var searchDirectories: [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var directories = [
            URL(fileURLWithPath: "/opt/homebrew/bin"),   // Homebrew on Apple silicon
            URL(fileURLWithPath: "/usr/local/bin"),      // Homebrew on Intel, manual installs
            URL(fileURLWithPath: "/opt/local/bin"),      // MacPorts
            home.appending(path: ".local/bin"),          // pipx, pip --user
            home.appending(path: "bin"),
            URL(fileURLWithPath: "/usr/bin"),
            URL(fileURLWithPath: "/bin"),
        ]

        // `pip3 install --user yt-dlp` lands in a version-numbered directory.
        let pythonBase = home.appending(path: "Library/Python")
        if let versions = try? FileManager.default.contentsOfDirectory(
            at: pythonBase,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            directories.append(contentsOf: versions.map { $0.appending(path: "bin") })
        }

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            directories.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0))
            })
        }

        var seen = Set<String>()
        return directories.filter { seen.insert($0.path(percentEncoded: false)).inserted }
    }

    /// The first executable named `name` found in the search directories.
    static func findExecutable(named name: String) -> URL? {
        for directory in searchDirectories {
            let candidate = directory.appending(path: name)
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    static func isExecutable(_ url: URL) -> Bool {
        let path = url.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    // MARK: - Status

    /// Locates a tool and reads its version.
    ///
    /// - Parameter userSelectedPath: A path the user picked in Settings. It always wins, and if
    ///   it has since been deleted or moved the returned status says so rather than silently
    ///   falling back, because a silent fallback would make the Settings screen lie.
    static func status(for tool: ExternalTool, userSelectedPath: String?) async -> ToolStatus {
        if let userSelectedPath, !userSelectedPath.isEmpty {
            let url = URL(fileURLWithPath: userSelectedPath)
            if isExecutable(url) {
                let version = await readVersion(of: tool, at: url)
                return ToolStatus(tool: tool, executableURL: url, version: version, source: .userSelected)
            }
            return ToolStatus(
                tool: tool,
                executableURL: nil,
                version: nil,
                source: .userSelected,
                problem: "The chosen file is missing or not executable"
            )
        }

        guard let url = findExecutable(named: tool.rawValue) else {
            return .missing(tool)
        }
        let version = await readVersion(of: tool, at: url)
        return ToolStatus(tool: tool, executableURL: url, version: version, source: .automatic)
    }

    /// Runs the tool's version command and extracts a short version string.
    static func readVersion(of tool: ExternalTool, at url: URL) async -> String? {
        let configuration = ProcessConfiguration(executableURL: url, arguments: tool.versionArguments)
        guard let output = try? await ProcessRunner.run(configuration, timeout: 15),
              output.isSuccess else { return nil }
        return parseVersion(of: tool, from: output.trimmedOutput)
    }

    /// - `yt-dlp --version` prints a bare version such as `2026.07.04`.
    /// - `ffmpeg -version` prints `ffmpeg version 8.1.2 Copyright (c) …` plus a wall of build info.
    static func parseVersion(of tool: ExternalTool, from output: String) -> String? {
        guard let firstLine = output.split(separator: "\n").first.map(String.init) else { return nil }
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        switch tool {
        case .ytdlp:
            return trimmed.split(separator: " ").first.map(String.init)
        case .ffmpeg:
            let tokens = trimmed.split(separator: " ").map(String.init)
            if let index = tokens.firstIndex(of: "version"), tokens.indices.contains(index + 1) {
                return tokens[index + 1]
            }
            return trimmed
        }
    }

    // MARK: - Homebrew

    /// The `brew` executable, when Homebrew is installed.
    static func homebrewExecutable() -> URL? {
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            let url = URL(fileURLWithPath: path)
            if isExecutable(url) { return url }
        }
        return findExecutable(named: "brew")
    }

    static var isHomebrewInstalled: Bool { homebrewExecutable() != nil }
}
