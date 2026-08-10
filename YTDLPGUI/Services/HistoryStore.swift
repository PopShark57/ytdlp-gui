import Foundation
import Observation
import os

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

    private let fileURL: URL
    private let logger = Logger(subsystem: "io.github.ytdlpgui.YTDLPGUI", category: "history")
    private var saveTask: Task<Void, Never>?

    /// Older entries beyond this count are dropped on save.
    static let maximumEntries = 1_000

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
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
    }

    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        scheduleSave()
    }

    func remove(ids: Set<HistoryEntry.ID>) {
        guard !ids.isEmpty else { return }
        entries.removeAll { ids.contains($0.id) }
        scheduleSave()
    }

    func removeAll() {
        entries.removeAll()
        scheduleSave()
    }

    /// Drops entries whose file no longer exists on disk.
    func removeMissingFiles() {
        entries.removeAll { $0.succeeded && !$0.fileExists }
        scheduleSave()
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
