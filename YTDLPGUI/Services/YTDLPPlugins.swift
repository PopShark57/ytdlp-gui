import Foundation
import os

/// The app's own yt-dlp plugin, and the folder yt-dlp loads it from.
///
/// yt-dlp runs as a separate program here, so a fix that has to act inside yt-dlp, rather than
/// through its options, can only be a plugin. There is one: `ytdlpgui_thumbnail_naming.py` in
/// the app's resources, which keeps a thumbnail from taking the video's file name. (A Reddit
/// GIF's preview is a `.gif` too, so yt-dlp would otherwise write the preview first, skip the GIF
/// as already downloaded, and leave the still preview in its place.)
enum YTDLPPlugins {

    /// The first yt-dlp with `--plugin-dirs`. Older ones would reject the option and fail every
    /// download.
    static let minimumVersion = "2024.10.22"

    /// Whether a yt-dlp that reports this version (`2026.08.19`, or `2025.10.22.232815` for a
    /// nightly) can load the plugin. An unknown version can't be relied on.
    static func isSupported(version: String?) -> Bool {
        guard let version,
              let components = numericComponents(of: version),
              let minimum = numericComponents(of: minimumVersion) else { return false }
        return !components.lexicographicallyPrecedes(minimum)
    }

    /// The folder to pass to `--plugin-dirs`, written afresh once per launch so it always holds
    /// this build's plugin; `nil` when that failed.
    static let directory: URL? = install(into: defaultDirectory())

    /// Lays the plugin out where yt-dlp looks for it: `<directory>/<package>/yt_dlp_plugins/postprocessor/`.
    /// Returns `directory`, or `nil` when the plugin couldn't be written.
    static func install(
        into directory: URL,
        source: URL? = Bundle.main.url(forResource: "ytdlpgui_thumbnail_naming", withExtension: "py")
    ) -> URL? {
        guard let source else {
            logger.error("The yt-dlp plugin is missing from the app bundle")
            return nil
        }
        let package = directory.appending(path: "ytdlpgui", directoryHint: .isDirectory)
        let postprocessors = package.appending(path: "yt_dlp_plugins/postprocessor", directoryHint: .isDirectory)
        let fileManager = FileManager.default
        do {
            // Replaced whole, so a plugin a later build renames or drops doesn't linger.
            if fileManager.fileExists(atPath: package.path(percentEncoded: false)) {
                try fileManager.removeItem(at: package)
            }
            try fileManager.createDirectory(at: postprocessors, withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: postprocessors.appending(path: source.lastPathComponent))
            return directory
        } catch {
            logger.error("Couldn't install the yt-dlp plugin: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return base
            .appending(path: "YTDLPGUI", directoryHint: .isDirectory)
            .appending(path: "yt-dlp-plugins", directoryHint: .isDirectory)
    }

    /// The leading numeric parts of a version, e.g. [2026, 8, 19]; `nil` when it has none.
    private static func numericComponents(of version: String) -> [Int]? {
        let components = version
            .split(separator: ".")
            .lazy
            .map { Int($0) }
            .prefix { $0 != nil }
            .compactMap { $0 }
        return components.isEmpty ? nil : Array(components)
    }

    private static let logger = Logger(subsystem: "io.github.ytdlpgui.YTDLPGUI", category: "plugins")
}
