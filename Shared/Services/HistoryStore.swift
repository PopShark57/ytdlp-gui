import Foundation
import Observation
import os

/// What is on disk of a history entry's files.
struct HistoryFileStatus: Equatable, Sendable {
    /// The entry's files that still exist, found again under the current container where needed
    /// (see `HistoryEntry.outputURLs`), in the order they were downloaded.
    var existingURLs: [URL]
    /// How many files the entry recorded.
    var recordedCount: Int

    /// None of the files is left (or none was recorded).
    var isMissing: Bool { existingURLs.isEmpty }
    var missingCount: Int { max(0, recordedCount - existingURLs.count) }
}

/// Persists completed downloads to a JSON file in Application Support.
///
/// JSON was chosen over SwiftData deliberately: the data is a flat, append-mostly list of a few
/// thousand rows at most, it needs no relationships or migrations, and a plain file is trivial
/// for a user to inspect, back up or delete.
@MainActor
@Observable
final class HistoryStore {

    private(set) var entries: [HistoryEntry] = []
    /// Set when loading or saving failed, so the UI can say so instead of silently losing data.
    private(set) var storageError: String?

    /// Which files of each entry are still on disk, so views never check the file system while
    /// they draw. Worked out off the main actor after loading and after each `add`, and again by
    /// `refreshFileStatus()`, which the app calls when it returns to the front: files can be
    /// deleted in the Files app meanwhile. An entry that isn't here yet hasn't been checked.
    private(set) var fileStatus: [HistoryEntry.ID: HistoryFileStatus] = [:]
    /// Whether a successful download's files are all gone, according to `fileStatus`.
    private(set) var hasMissingFiles = false

    private let fileURL: URL
    private let logger = AppLog.history
    private var saveTask: Task<Void, Never>?

    /// Older entries beyond this count are dropped on save.
    static let maximumEntries = 1_000

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
        refreshFileStatus()
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return base
            .appending(path: "YTDLPGUI", directoryHint: .isDirectory)
            .appending(path: "history.json")
    }

    /// The folder holding the history file, for "Show in Finder".
    var storageDirectory: URL { fileURL.deletingLastPathComponent() }

    // MARK: - Mutation

    func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.maximumEntries {
            entries.removeLast(entries.count - Self.maximumEntries)
        }
        scheduleSave()
        checkFiles(of: [entry])
    }

    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        entriesDidChange()
    }

    func remove(ids: Set<HistoryEntry.ID>) {
        guard !ids.isEmpty else { return }
        entries.removeAll { ids.contains($0.id) }
        entriesDidChange()
    }

    func removeAll() {
        entries.removeAll()
        entriesDidChange()
    }

    /// Rewrites every entry with `transform`, saving only if something changed. Used to remove
    /// what earlier builds stored and this one no longer keeps.
    func updateEntries(_ transform: (inout HistoryEntry) -> Void) {
        var updated = entries
        for index in updated.indices {
            transform(&updated[index])
        }
        guard updated != entries else { return }
        entries = updated
        scheduleSave()
    }

    /// Drops successful entries none of whose files exists any more. Uses `fileStatus`, and
    /// looks on disk for an entry that hasn't been checked yet.
    func removeMissingFiles() {
        entries.removeAll { entry in
            guard entry.succeeded else { return false }
            return fileStatus[entry.id]?.isMissing ?? !entry.fileExists
        }
        entriesDidChange()
    }

    // MARK: - File status

    /// The entry's files that are still on disk, as last checked. Empty until checked.
    func existingFiles(of entry: HistoryEntry) -> [URL] {
        fileStatus[entry.id]?.existingURLs ?? []
    }

    /// A successful download none of whose files is left, as last checked. An entry that hasn't
    /// been checked yet isn't reported as missing.
    func isFileMissing(_ entry: HistoryEntry) -> Bool {
        entry.succeeded && fileStatus[entry.id]?.isMissing == true
    }

    /// Checks every entry's files again, off the main actor.
    func refreshFileStatus() {
        checkFiles(of: entries)
    }

    private func checkFiles(of entriesToCheck: [HistoryEntry]) {
        guard !entriesToCheck.isEmpty else { return }
        Task { [weak self] in
            let statuses = await Task.detached(priority: .utility) {
                HistoryStore.fileStatuses(of: entriesToCheck)
            }.value
            guard let self else { return }
            // Merged, so a check of one new entry and a check of them all can finish in either
            // order; entries removed meanwhile are left out.
            let current = Set(self.entries.map(\.id))
            self.fileStatus.merge(statuses.filter { current.contains($0.key) }) { _, checked in checked }
            self.updateHasMissingFiles()
        }
    }

    /// Looks at every file of every entry. Several `stat` calls per file for paths from an
    /// earlier container, so never on the main actor.
    nonisolated private static func fileStatuses(of entries: [HistoryEntry]) -> [HistoryEntry.ID: HistoryFileStatus] {
        var statuses: [HistoryEntry.ID: HistoryFileStatus] = [:]
        for entry in entries {
            let files = entry.outputURLs
            let existing = files.filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
            statuses[entry.id] = HistoryFileStatus(existingURLs: existing, recordedCount: files.count)
        }
        return statuses
    }

    private func entriesDidChange() {
        let current = Set(entries.map(\.id))
        fileStatus = fileStatus.filter { current.contains($0.key) }
        updateHasMissingFiles()
        scheduleSave()
    }

    private func updateHasMissingFiles() {
        let hasMissing = entries.contains { isFileMissing($0) }
        if hasMissing != hasMissingFiles { hasMissingFiles = hasMissing }
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = try decoder.decode([HistoryEntry].self, from: data)
        } catch {
            // A corrupt file must not take the app down or wipe itself out silently; it is
            // moved aside so the user can still recover it by hand.
            logger.error("Failed to read history: \(error.localizedDescription, privacy: .public)")
            storageError = "Your download history couldn't be read and has been set aside."
            let backup = fileURL.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
        }
    }

    /// Coalesces rapid changes into a single write.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        let snapshot = entries
        do {
            try FileManager.default.createDirectory(
                at: storageDirectory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
            storageError = nil
        } catch {
            logger.error("Failed to write history: \(error.localizedDescription, privacy: .public)")
            storageError = "Your download history couldn't be saved: \(error.localizedDescription)"
        }
    }

    /// Flushes any pending write. Called when the app is about to quit.
    func flush() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        saveNow()
    }
}
