import Foundation
import os

/// Where the engine finds its Python runtime and keeps its data.
///
/// `standard` is the app's layout ("App data on device" in Docs/iOS-Architecture.md). Tests
/// and tools point an engine at other directories instead. Nothing here is persisted: the
/// container path changes when iOS reinstalls or updates the app, so the paths are resolved
/// afresh at every launch.
struct EngineConfiguration: Sendable {

    /// The directory holding `lib/python3.14`: the app bundle's `python` folder.
    var pythonHome: URL
    /// Placed at the front of `sys.path`, in order: the host package, then yt-dlp and its
    /// dependencies.
    var modulePaths: [URL]
    /// Where compiled byte code is cached, since the app bundle is read-only.
    var bytecodeCacheDirectory: URL?
    /// yt-dlp's own cache (`cachedir`): player scripts and challenge solutions.
    var cacheDirectory: URL
    /// Where installed yt-dlp updates live: one folder per update under `versions/`, and a
    /// `current` file naming the one to use. See "Installed updates" below.
    var updateRoot: URL
    /// Scratch space while an update is being installed.
    var stagingDirectory: URL
    /// The OS version, passed to the host for its diagnostics.
    var platformVersion: String

    /// The runtime inside the app bundle; caches and updates inside the app's container.
    static var standard: EngineConfiguration {
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        let engineSupport = URL.applicationSupportDirectory.appending(path: "Engine", directoryHint: .isDirectory)
        return EngineConfiguration(
            pythonHome: resources.appending(path: "python", directoryHint: .isDirectory),
            modulePaths: [
                resources.appending(path: "app", directoryHint: .isDirectory),
                resources.appending(path: "app_packages", directoryHint: .isDirectory),
            ],
            bytecodeCacheDirectory: URL.cachesDirectory.appending(path: "python-bytecode", directoryHint: .isDirectory),
            cacheDirectory: URL.cachesDirectory.appending(path: "yt-dlp", directoryHint: .isDirectory),
            updateRoot: engineSupport.appending(path: "yt-dlp", directoryHint: .isDirectory),
            stagingDirectory: engineSupport.appending(path: "staging", directoryHint: .isDirectory),
            platformVersion: currentPlatformVersion
        )
    }

    /// "18.2", or "18.2.1" when there is a patch version.
    static var currentPlatformVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let base = "\(version.majorVersion).\(version.minorVersion)"
        return version.patchVersion == 0 ? base : "\(base).\(version.patchVersion)"
    }

    /// Checks that the runtime is where it should be, so a broken install fails with a sentence
    /// rather than an interpreter error about `encodings`.
    func validateRuntime() throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: pythonHome.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw EngineError.startupFailed("the app's Python runtime is missing. Reinstalling YTDLP GUI should fix this.")
        }
    }

    /// Creates the cache folders. Failing to is not fatal: Python then compiles in memory, and
    /// yt-dlp works without its cache, only more slowly.
    func createCacheDirectories() {
        for directory in [bytecodeCacheDirectory, cacheDirectory].compactMap({ $0 }) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

}

// MARK: - Installed updates

/// Each yt-dlp update is installed into a folder of its own, `updateRoot/versions/<name>/`, and
/// the one-line file `updateRoot/current` names the folder to use.
///
/// The running interpreter imports yt-dlp lazily, from whichever folder it started with, for as
/// long as the app runs: every extractor is imported the first time a site is used, and the
/// challenge solver's scripts are read on each use. So no folder is changed or removed while the
/// app runs. Installing creates a new folder and then points `current` at it, reverting removes
/// only `current`, and folders nothing points at any more are deleted at the next launch, before
/// Python starts (`prepareUpdatesForLaunch()`).
extension EngineConfiguration {

    private static let logger = AppLog.engine

    /// Holds one folder per installed update.
    var versionsDirectory: URL {
        updateRoot.appending(path: "versions", directoryHint: .isDirectory)
    }

    /// Names the folder in `versionsDirectory` to use. No file means the bundled yt-dlp.
    var pointerFile: URL {
        updateRoot.appending(path: "current", directoryHint: .notDirectory)
    }

    /// The installed update to use, if any: the folder `current` names, when it holds yt-dlp.
    ///
    /// Anything else, such as a pointer naming a missing folder or a path rather than one folder
    /// name, means no update, and the bundled yt-dlp is used.
    var activeUpdateDirectory: URL? {
        guard let data = try? Data(contentsOf: pointerFile),
              let name = Self.versionName(in: data) else { return nil }
        let folder = versionsDirectory.appending(path: name, directoryHint: .isDirectory)
        guard Self.isDirectory(folder.appending(path: "yt_dlp", directoryHint: .isDirectory)) else { return nil }
        return folder
    }

    /// A folder for the next update, which doesn't exist yet. The host installs into it, and
    /// `activate(_:)` then makes it the one to use.
    func makeNewUpdateDirectory() -> URL {
        versionsDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    /// Makes `directory`, a folder in `versionsDirectory`, the update used from the next launch.
    func activate(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: updateRoot, withIntermediateDirectories: true)
        try Data(directory.lastPathComponent.utf8).write(to: pointerFile, options: .atomic)
    }

    /// Uses the bundled yt-dlp from the next launch. Only the pointer is removed: the running
    /// engine may still be importing from the folder it named.
    func deactivate() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: pointerFile.path(percentEncoded: false)) {
            try fileManager.removeItem(at: pointerFile)
        }
    }

    /// Creates the folders that hold updates. The whole `Engine` folder is excluded from backups,
    /// because an update can always be downloaded again and is several megabytes.
    func prepareUpdateFolder() throws {
        try FileManager.default.createDirectory(at: versionsDirectory, withIntermediateDirectories: true)
        var engineFolder = updateRoot.deletingLastPathComponent()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? engineFolder.setResourceValues(values)
    }

    /// Tidies the update folders. Must run before Python starts, when nothing can be importing
    /// from them.
    ///
    /// An update installed by an earlier build, straight into `updateRoot`, is moved into a
    /// folder of its own and used. Then every folder but the one in use is deleted, with the
    /// staging area and a pointer that names nothing usable. Failures are logged and otherwise
    /// ignored: the worst outcome is the bundled yt-dlp, or a folder left for the next launch.
    func prepareUpdatesForLaunch() {
        let fileManager = FileManager.default
        migrateLegacyUpdate()

        let active = activeUpdateDirectory
        if active == nil, fileManager.fileExists(atPath: pointerFile.path(percentEncoded: false)) {
            remove(pointerFile, reason: "names no usable update")
        }
        let versions = (try? fileManager.contentsOfDirectory(
            at: versionsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        for folder in versions where folder.lastPathComponent != active?.lastPathComponent {
            remove(folder, reason: "no longer in use")
        }
        if fileManager.fileExists(atPath: stagingDirectory.path(percentEncoded: false)) {
            remove(stagingDirectory, reason: "left over from an update")
        }
    }

    /// Earlier builds kept one update directly in `updateRoot` (`yt_dlp/`, `yt_dlp_ejs/`).
    private func migrateLegacyUpdate() {
        let packages = ["yt_dlp", "yt_dlp_ejs"].filter {
            Self.isDirectory(updateRoot.appending(path: $0, directoryHint: .isDirectory))
        }
        guard !packages.isEmpty else { return }
        let fileManager = FileManager.default
        let destination = versionsDirectory.appending(path: "legacy-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            for package in packages {
                try fileManager.moveItem(
                    at: updateRoot.appending(path: package, directoryHint: .isDirectory),
                    to: destination.appending(path: package, directoryHint: .isDirectory)
                )
            }
        } catch {
            Self.logger.error("Couldn't move the installed yt-dlp update into its own folder: \(error.localizedDescription, privacy: .public)")
        }
        // Whatever arrived is used, as long as it includes yt-dlp itself.
        guard activeUpdateDirectory == nil,
              Self.isDirectory(destination.appending(path: "yt_dlp", directoryHint: .isDirectory)) else { return }
        do {
            try activate(destination)
        } catch {
            Self.logger.error("Couldn't select the moved yt-dlp update: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func remove(_ item: URL, reason: String) {
        do {
            try FileManager.default.removeItem(at: item)
        } catch {
            Self.logger.error("Couldn't delete \(item.lastPathComponent, privacy: .public), \(reason, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The folder name in a pointer file: a single path component, never a path.
    private static func versionName(in data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains(".."), !name.contains("\0") else { return nil }
        return name
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
