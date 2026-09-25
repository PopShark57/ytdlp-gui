import Foundation

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
    /// Where an installed yt-dlp update lives.
    var updateDirectory: URL
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
            updateDirectory: engineSupport.appending(path: "yt-dlp", directoryHint: .isDirectory),
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

    /// Whether an installed update is present for the host to try.
    var hasInstalledUpdate: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: updateDirectory.path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
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

    /// Creates the folder that holds updates, excluded from backups because an update can always
    /// be downloaded again and is several megabytes.
    func prepareUpdateFolder() throws {
        var folder = updateDirectory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }
}
