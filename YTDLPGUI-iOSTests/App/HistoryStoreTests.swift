import Foundation
import Testing
@testable import YTDLPGUI_iOS

/// History keeps what it found on disk for each entry, worked out off the main actor, so the
/// History tab never touches the file system while it draws; and it writes only what changed.
@MainActor
@Suite("History store")
struct HistoryStoreTests {

    private func makeEntry(for files: [URL], succeeded: Bool = true) -> HistoryEntry {
        HistoryEntry(
            title: "Clip",
            sourceURL: "https://example.com/v",
            outputPath: files.last?.path(percentEncoded: false),
            outputPaths: files.map { $0.path(percentEncoded: false) },
            formatSummary: "Best",
            kind: .video,
            succeeded: succeeded
        )
    }

    @Test("A new entry is checked, and a missing file is noticed when the store refreshes")
    func refresh() async throws {
        let env = try AppTestEnvironment()
        try FileManager.default.createDirectory(at: env.storage.downloadsDirectory, withIntermediateDirectories: true)
        let file = try env.makeDownloadedFile(named: "clip.mp4")
        let entry = makeEntry(for: [file])

        env.history.add(entry)
        // Not checked yet is not the same as missing.
        #expect(!env.history.isFileMissing(entry))
        try await waitUntil("file status") { env.history.fileStatus[entry.id] != nil }
        #expect(env.history.existingFiles(of: entry).map(\.standardizedFileURL) == [file.standardizedFileURL])
        #expect(!env.history.hasMissingFiles)

        try FileManager.default.removeItem(at: file)
        // Nothing changes until the store looks again.
        #expect(!env.history.isFileMissing(entry))
        env.history.refreshFileStatus()
        try await waitUntil("missing file noticed") { env.history.isFileMissing(entry) }
        #expect(env.history.hasMissingFiles)
        #expect(env.history.existingFiles(of: entry).isEmpty)

        env.history.removeMissingFiles()
        #expect(env.history.entries.isEmpty)
        #expect(!env.history.hasMissingFiles)
        #expect(env.history.fileStatus.isEmpty)
    }

    @Test("Failed downloads are never reported as missing their files")
    func failedEntries() async throws {
        let env = try AppTestEnvironment()
        let entry = makeEntry(for: [], succeeded: false)
        env.history.add(entry)
        try await waitUntil("file status") { env.history.fileStatus[entry.id] != nil }
        #expect(!env.history.isFileMissing(entry))
        #expect(!env.history.hasMissingFiles)
        env.history.removeMissingFiles()
        #expect(env.history.entries.count == 1)
    }

    @Test("History loaded at launch is checked in the background")
    func checkedAfterLoading() async throws {
        let env = try AppTestEnvironment()
        let missing = makeEntry(for: [env.storage.downloadsDirectory.appending(path: "gone.mp4")])
        env.history.add(missing)
        env.history.saveNow()

        let relaunched = HistoryStore(fileURL: env.history.storageDirectory.appending(path: "history.json"))
        #expect(relaunched.entries.map(\.id) == [missing.id])
        try await waitUntil("file status after loading") { relaunched.hasMissingFiles }
        #expect(relaunched.isFileMissing(missing))
    }

    @Test("Flushing writes only when a save is pending")
    func flushWritesOnlyPendingChanges() async throws {
        let env = try AppTestEnvironment()
        let historyFile = env.history.storageDirectory.appending(path: "history.json")
        env.history.add(makeEntry(for: []))
        env.history.flush()
        #expect(FileManager.default.fileExists(atPath: historyFile.path(percentEncoded: false)))

        // A scheduled save that has already happened leaves nothing to flush.
        env.history.add(makeEntry(for: []))
        try await Task.sleep(for: .milliseconds(800))
        try FileManager.default.removeItem(at: historyFile)
        env.history.flush()
        #expect(!FileManager.default.fileExists(atPath: historyFile.path(percentEncoded: false)))
    }

    @Test("Coming back to the app checks history's files again")
    func refreshOnActivation() async throws {
        let env = try AppTestEnvironment()
        try FileManager.default.createDirectory(at: env.storage.downloadsDirectory, withIntermediateDirectories: true)
        let file = try env.makeDownloadedFile(named: "clip.mp4")
        let entry = makeEntry(for: [file])
        env.history.add(entry)
        try await waitUntil("file status") { env.history.fileStatus[entry.id] != nil }
        let model = env.makeAppModel()

        try FileManager.default.removeItem(at: file)
        model.handleScenePhaseChange(.active)
        try await waitUntil("missing file noticed") { env.history.isFileMissing(entry) }
    }
}
