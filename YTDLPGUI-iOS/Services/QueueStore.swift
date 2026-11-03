import Foundation
import os

/// A download that hadn't finished, as saved between launches.
struct PersistedDownload: Codable, Equatable, Sendable {
    var id: UUID
    var sourceURL: String
    var options: DownloadOptions
    var title: String?
    var uploader: String?
    var thumbnailURL: URL?
    var durationSeconds: Double?
    var isPlaylist: Bool
    var playlistCount: Int?
    var createdAt: Date
}

/// Saves the unfinished part of the queue to `Application Support/YTDLPGUI/queue.json`.
///
/// iOS terminates suspended apps whenever it needs the memory, with no callback. Without this
/// file, anything waiting or half-downloaded at that moment would simply vanish from the queue,
/// though its partial file would still be sitting in the cache ready to resume.
struct QueueStore: Sendable {

    let fileURL: URL

    private static let logger = AppLog.queue

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    /// Beside `history.json`.
    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return base
            .appending(path: "YTDLPGUI", directoryHint: .isDirectory)
            .appending(path: "queue.json")
    }

    private struct Snapshot: Codable {
        var receipts: Set<String>
        var downloads: [PersistedDownload]
    }

    func receipts() -> Set<String> {
        guard let data = try? Data(contentsOf: fileURL),
              let receipt = try? JSONDecoder().decode(ReceiptHeader.self, from: data) else { return [] }
        return receipt.receipts
    }

    private struct ReceiptHeader: Decodable { var receipts: Set<String> }
    private struct RestoredSnapshot: Decodable { var downloads: [Lossy<PersistedDownload>] }

    /// Reads whatever can be read. An entry that no longer decodes is skipped rather than
    /// discarding the others with it.
    func load() -> [PersistedDownload] {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let snapshot = try? decoder.decode(RestoredSnapshot.self, from: data) {
                return snapshot.downloads.compactMap(\.value)
            }
            return try decoder.decode([Lossy<PersistedDownload>].self, from: data).compactMap(\.value)
        } catch {
            Self.logger.error("Couldn't read the saved queue: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Writes the list, or removes the file when there is nothing left to remember.
    @discardableResult
    func save(_ downloads: [PersistedDownload], receipts: Set<String> = []) -> Bool {
        do {
            if downloads.isEmpty && receipts.isEmpty {
                if FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
                    try FileManager.default.removeItem(at: fileURL)
                }
                return true
            }
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = receipts.isEmpty ? try encoder.encode(downloads) : try encoder.encode(Snapshot(receipts: receipts, downloads: downloads))
            try data.write(to: fileURL, options: .atomic)
            // The saved options can hold passwords, which interrupted downloads need to resume.
            // The file only matters until they finish, so it stays out of device backups. An
            // atomic write replaces the file, which clears the flag, so it is set every time.
            var savedURL = fileURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? savedURL.setResourceValues(values)
            return true
        } catch {
            Self.logger.error("Couldn't save the queue: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

/// Decodes a value if it can, and nothing otherwise, without failing the enclosing array.
private struct Lossy<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
