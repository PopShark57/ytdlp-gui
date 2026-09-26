import Foundation
import Testing
@testable import YTDLPGUI_iOS

/// The installed-update layout: one folder per update, a pointer to the one in use, and nothing
/// the running engine imports from ever changed while the app runs.
@Suite("Engine configuration: installed updates")
struct EngineConfigurationTests {

    /// A configuration whose engine folders live in a throwaway directory.
    private final class Sandbox {
        let root: URL
        let configuration: EngineConfiguration

        init() {
            root = FileManager.default.temporaryDirectory
                .appending(path: "EngineConfigurationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            let engine = root.appending(path: "Engine", directoryHint: .isDirectory)
            configuration = EngineConfiguration(
                pythonHome: root.appending(path: "python", directoryHint: .isDirectory),
                modulePaths: [],
                bytecodeCacheDirectory: nil,
                cacheDirectory: root.appending(path: "Caches/yt-dlp", directoryHint: .isDirectory),
                updateRoot: engine.appending(path: "yt-dlp", directoryHint: .isDirectory),
                stagingDirectory: engine.appending(path: "staging", directoryHint: .isDirectory),
                platformVersion: "18.0"
            )
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        /// A folder holding a (stand-in) yt-dlp, as an installed update would.
        @discardableResult
        func makeUpdate(at folder: URL, marker: String = "A") throws -> URL {
            let package = folder.appending(path: "yt_dlp", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try Data("__version__ = '\(marker)'\n".utf8).write(to: package.appending(path: "version.py"))
            return folder
        }

        func writePointer(_ text: String) throws {
            try FileManager.default.createDirectory(at: configuration.updateRoot, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: configuration.pointerFile)
        }

        func exists(_ url: URL) -> Bool {
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        }

        var versionNames: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: configuration.versionsDirectory.path(percentEncoded: false))) ?? []).sorted()
        }
    }

    @Test("With nothing installed there is no update, and tidying creates nothing")
    func noUpdate() {
        let sandbox = Sandbox()
        #expect(sandbox.configuration.activeUpdateDirectory == nil)
        sandbox.configuration.prepareUpdatesForLaunch()
        #expect(sandbox.configuration.activeUpdateDirectory == nil)
        #expect(!sandbox.exists(sandbox.configuration.pointerFile))
        #expect(sandbox.versionNames.isEmpty)
    }

    @Test("An activated folder is the update in use")
    func activation() throws {
        let sandbox = Sandbox()
        let configuration = sandbox.configuration
        let folder = configuration.makeNewUpdateDirectory()
        #expect(!sandbox.exists(folder))
        #expect(folder.deletingLastPathComponent().standardizedFileURL == configuration.versionsDirectory.standardizedFileURL)
        #expect(configuration.makeNewUpdateDirectory() != folder)

        try sandbox.makeUpdate(at: folder)
        try configuration.activate(folder)
        #expect(configuration.activeUpdateDirectory?.standardizedFileURL == folder.standardizedFileURL)
    }

    @Test("A legacy update, straight in the update folder, moves into a folder of its own and stays in use")
    func legacyMigration() throws {
        let sandbox = Sandbox()
        let configuration = sandbox.configuration
        try sandbox.makeUpdate(at: configuration.updateRoot, marker: "legacy")
        let ejs = configuration.updateRoot.appending(path: "yt_dlp_ejs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: ejs, withIntermediateDirectories: true)

        configuration.prepareUpdatesForLaunch()
        let active = try #require(configuration.activeUpdateDirectory)
        #expect(active.lastPathComponent.hasPrefix("legacy-"))
        #expect(sandbox.exists(active.appending(path: "yt_dlp/version.py")))
        #expect(sandbox.exists(active.appending(path: "yt_dlp_ejs")))
        #expect(!sandbox.exists(configuration.updateRoot.appending(path: "yt_dlp")))
        #expect(!sandbox.exists(configuration.updateRoot.appending(path: "yt_dlp_ejs")))
        #expect(sandbox.versionNames == [active.lastPathComponent])

        // A second launch changes nothing.
        configuration.prepareUpdatesForLaunch()
        #expect(configuration.activeUpdateDirectory?.lastPathComponent == active.lastPathComponent)
    }

    @Test("A pointer to a missing folder, a path, or unreadable bytes means no update")
    func unusablePointers() throws {
        let sandbox = Sandbox()
        let configuration = sandbox.configuration
        try sandbox.makeUpdate(at: configuration.versionsDirectory.appending(path: "real", directoryHint: .isDirectory))
        let outside = try sandbox.makeUpdate(at: configuration.updateRoot.appending(path: "outside", directoryHint: .isDirectory))

        for pointer in ["missing", "..", "../outside", "real/../real", "real/yt_dlp", "", "  \n"] {
            try sandbox.writePointer(pointer)
            #expect(configuration.activeUpdateDirectory == nil, "pointer: \(pointer)")
        }
        try FileManager.default.createDirectory(at: configuration.updateRoot, withIntermediateDirectories: true)
        try Data([0xFF, 0xFE, 0x00, 0x80]).write(to: configuration.pointerFile)
        #expect(configuration.activeUpdateDirectory == nil)

        // A folder without yt-dlp in it isn't an update either.
        try FileManager.default.createDirectory(
            at: configuration.versionsDirectory.appending(path: "empty", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try sandbox.writePointer("empty")
        #expect(configuration.activeUpdateDirectory == nil)

        // Tidying drops the bad pointer and every folder, and leaves what isn't its own alone.
        try sandbox.writePointer("missing\n")
        configuration.prepareUpdatesForLaunch()
        #expect(!sandbox.exists(configuration.pointerFile))
        #expect(sandbox.versionNames.isEmpty)
        #expect(sandbox.exists(outside))

        // Surrounding whitespace, as an editor might leave, is fine.
        try sandbox.makeUpdate(at: configuration.versionsDirectory.appending(path: "real", directoryHint: .isDirectory))
        try sandbox.writePointer("real\n")
        #expect(configuration.activeUpdateDirectory?.lastPathComponent == "real")
    }

    @Test("Tidying keeps only the update in use, and removes the staging area")
    func garbageCollection() throws {
        let sandbox = Sandbox()
        let configuration = sandbox.configuration
        let old = try sandbox.makeUpdate(at: configuration.makeNewUpdateDirectory(), marker: "old")
        let current = try sandbox.makeUpdate(at: configuration.makeNewUpdateDirectory(), marker: "current")
        try configuration.activate(current)
        try FileManager.default.createDirectory(
            at: configuration.stagingDirectory.appending(path: "leftover/unpacked", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )

        configuration.prepareUpdatesForLaunch()
        #expect(!sandbox.exists(old))
        #expect(sandbox.exists(current.appending(path: "yt_dlp/version.py")))
        #expect(sandbox.versionNames == [current.lastPathComponent])
        #expect(!sandbox.exists(configuration.stagingDirectory))
        #expect(configuration.activeUpdateDirectory?.lastPathComponent == current.lastPathComponent)
    }

    @Test("Going back to the bundled yt-dlp removes only the pointer")
    func deactivation() throws {
        let sandbox = Sandbox()
        let configuration = sandbox.configuration
        let current = try sandbox.makeUpdate(at: configuration.makeNewUpdateDirectory())
        try configuration.activate(current)

        try configuration.deactivate()
        #expect(configuration.activeUpdateDirectory == nil)
        #expect(!sandbox.exists(configuration.pointerFile))
        // The running engine may still be importing from it.
        #expect(sandbox.exists(current.appending(path: "yt_dlp/version.py")))
        // And again, with nothing to remove.
        try configuration.deactivate()

        // It goes at the next launch.
        configuration.prepareUpdatesForLaunch()
        #expect(!sandbox.exists(current))
    }

    @Test("Preparing for an install creates the versions folder")
    func prepareUpdateFolder() throws {
        let sandbox = Sandbox()
        try sandbox.configuration.prepareUpdateFolder()
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: sandbox.configuration.versionsDirectory.path(percentEncoded: false),
            isDirectory: &isDirectory
        ) && isDirectory.boolValue)
    }
}
