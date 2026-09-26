import Foundation
import os

/// Links handed over by the Share extension. The JSON schema is duplicated in
/// YTDLPGUI-iOS-Share (the extension can't link the app's code) — keep the two in step.
struct SharedLink: Equatable, Sendable {
    var urls: [String]
    var kind: DownloadKind?
    var created: Date
}

/// Reads the links the Share extension leaves in the App Group container.
///
/// Each share is one file, `Inbox/<ISO-8601 basic timestamp>-<UUID>.json`, holding
/// `{"version": 1, "urls": [String], "kind": "video"|"audio"|null, "created": ISO-8601}`.
/// The extension only ever creates files, atomically, and the app only ever deletes them, so
/// the two processes never need to coordinate.
///
/// Everything read here was written by another process and is treated as untrusted: anything
/// that doesn't decode, isn't version 1 or carries no web link is deleted rather than acted on,
/// so one bad file can never wedge the inbox.
enum SharedLinkInbox {

    static let appGroupIdentifier = "group.io.github.ytdlpgui.YTDLPGUI"

    /// Entries older than this are dropped unread. A link shared a week ago and never opened is
    /// more likely forgotten than wanted, and a download starting out of nowhere would surprise.
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    /// No entry the extension writes (at most ten links) comes near this; anything bigger is
    /// discarded without being read into memory.
    static let maximumEntrySize = 64 * 1024

    /// The only format version there is.
    static let formatVersion = 1

    private static let logger = AppLog.shareInbox

    /// The inbox folder inside the App Group container, or `nil` when the container is unavailable.
    static var inboxDirectory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appending(path: "Inbox", directoryHint: .isDirectory)
    }

    /// Reads and deletes every pending entry, oldest first. Unreadable entries are deleted and skipped.
    static func drain() -> [SharedLink] {
        guard let directory = inboxDirectory else {
            logger.error("The App Group container is unavailable; links from the Share extension can't be read.")
            return []
        }
        return drain(from: directory)
    }

    /// Drains `directory` as if it were the inbox, judging age against `now`.
    static func drain(from directory: URL, now: Date = .now) -> [SharedLink] {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        // Only `.json` files are entries. An atomic write still in flight is a temporary file
        // next to its destination (`<name>.json.sb-<hex>-<random>`), and deleting it would lose
        // the share, so anything else, hidden files included, is left alone.
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: .skipsHiddenFiles
        ) else {
            return []  // No inbox folder yet: nothing has ever been shared.
        }

        var pending: [(fileName: String, link: SharedLink)] = []
        for fileURL in contents where fileURL.pathExtension.lowercased() == "json" {
            guard let values = try? fileURL.resourceValues(forKeys: keys), values.isRegularFile == true else {
                continue
            }
            let fileName = fileURL.lastPathComponent
            let result = Result { () throws(EntryError) in
                try readEntry(at: fileURL, fileSize: values.fileSize ?? 0)
            }

            do {
                try fileManager.removeItem(at: fileURL)
            } catch {
                // Acting on an entry that can't be deleted would act on it again at every
                // launch, so it is left alone; the next drain tries again.
                logger.error("Couldn't delete inbox entry \(fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }

            switch result {
            case .success(let link) where now.timeIntervalSince(link.created) > maximumAge:
                logger.notice("Dropped inbox entry \(fileName, privacy: .public): older than a week.")
            case .success(let link):
                pending.append((fileName, link))
            case .failure(let error):
                logger.error("Dropped inbox entry \(fileName, privacy: .public): \(error.description, privacy: .public)")
            }
        }

        // `created` has whole-second precision; the file name, which has milliseconds, breaks ties.
        return pending
            .sorted { ($0.link.created, $0.fileName) < ($1.link.created, $1.fileName) }
            .map(\.link)
    }

    // MARK: - Decoding

    enum EntryError: Error, Equatable, CustomStringConvertible {
        case tooLarge
        case unreadable(String)
        case malformed
        case unsupportedVersion(Int)
        case invalidDate(String)
        case noWebLinks

        var description: String {
            switch self {
            case .tooLarge: "larger than any entry the Share extension writes"
            case .unreadable(let reason): "couldn't be read (\(reason))"
            case .malformed: "not a valid inbox entry"
            case .unsupportedVersion(let version): "format version \(version) isn't supported"
            case .invalidDate(let text): "\"\(text)\" isn't an ISO-8601 date"
            case .noWebLinks: "contains no http or https link"
            }
        }
    }

    private static func readEntry(at fileURL: URL, fileSize: Int) throws(EntryError) -> SharedLink {
        guard fileSize <= maximumEntrySize else { throw .tooLarge }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw .unreadable(error.localizedDescription)
        }
        return try decode(data)
    }

    /// The link an entry file describes, with anything that isn't a web link removed.
    static func decode(_ data: Data) throws(EntryError) -> SharedLink {
        let entry: Entry
        do {
            entry = try JSONDecoder().decode(Entry.self, from: data)
        } catch {
            throw .malformed
        }
        guard entry.version == formatVersion else { throw .unsupportedVersion(entry.version) }
        guard let created = date(fromISO8601: entry.created) else { throw .invalidDate(entry.created) }

        var seen = Set<String>()
        let urls = entry.urls.compactMap(webLink(from:)).filter { seen.insert($0).inserted }
        guard !urls.isEmpty else { throw .noWebLinks }

        return SharedLink(
            urls: urls,
            kind: entry.kind.flatMap(DownloadKind.init(rawValue:)),
            created: created
        )
    }

    /// `text`, trimmed, if it is an `http` or `https` URL with a host.
    private static func webLink(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return nil }
        return trimmed
    }

    /// Accepts ISO-8601 with or without fractional seconds; the extension writes whole seconds.
    private static func date(fromISO8601 text: String) -> Date? {
        let styles = [
            Date.ISO8601FormatStyle(),
            Date.ISO8601FormatStyle(includingFractionalSeconds: true),
        ]
        return styles.lazy.compactMap { try? $0.parse(text) }.first
    }

    /// The wire format. `kind` stays a string so an unknown value becomes `nil` instead of
    /// making the whole entry unreadable.
    private struct Entry: Decodable {
        var version: Int
        var urls: [String]
        var kind: String?
        var created: String
    }
}
