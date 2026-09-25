import Foundation

/// What the user asked the app to do with the shared links.
///
/// The raw values are the app's `DownloadKind` raw values, which is what the inbox stores.
enum ShareDownloadKind: String, Sendable {
    case video
    case audio
}

/// Hands shared links to the app by leaving a small JSON file in the App Group inbox.
///
/// One file per share, rather than one list both sides edit, means the extension only ever
/// creates files and the app only ever deletes them: neither can clobber the other's changes,
/// and `.atomic` makes each file appear complete or not at all.
///
/// The format is duplicated in the app's `SharedLinkInbox` (an extension can't link the app's
/// code) — keep the two in step:
///
/// - `Inbox/<ISO-8601 basic timestamp>-<UUID>.json`, so names sort chronologically;
/// - `{"version": 1, "urls": [String], "kind": "video"|"audio"|null, "created": ISO-8601}`.
enum InboxWriter {

    static let appGroupIdentifier = "group.io.github.ytdlpgui.YTDLPGUI"
    static let formatVersion = 1

    enum Failure: Error, Equatable {
        /// The App Group container isn't there, which means the extension was signed without
        /// the App Group entitlement. Nothing the user does will fix it on this install.
        case containerUnavailable
        /// The entry couldn't be written. The reason is the system's own, user-readable one.
        case writeFailed(String)
    }

    /// The inbox folder inside the App Group container, or `nil` when the container is unavailable.
    static var inboxDirectory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appending(path: "Inbox", directoryHint: .isDirectory)
    }

    /// Leaves `urls` in the shared inbox for the app to pick up.
    @discardableResult
    static func write(
        urls: [String],
        kind: ShareDownloadKind?,
        created: Date = .now
    ) throws(Failure) -> URL {
        guard let directory = inboxDirectory else { throw Failure.containerUnavailable }
        return try write(urls: urls, kind: kind, created: created, to: directory)
    }

    /// Writes one entry into `directory`, creating the folder on first use.
    @discardableResult
    static func write(
        urls: [String],
        kind: ShareDownloadKind?,
        created: Date,
        to directory: URL
    ) throws(Failure) -> URL {
        let fileURL = directory.appending(path: fileName(for: created))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encode(urls: urls, kind: kind, created: created).write(to: fileURL, options: .atomic)
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
        return fileURL
    }

    // MARK: - Format

    /// `20260924T195412.123Z-<UUID>.json`.
    ///
    /// Milliseconds keep two shares in the same second in order; the UUID keeps them distinct.
    /// Every timestamp has the same width, so sorting names sorts entries by age.
    static func fileName(for date: Date, id: UUID = UUID()) -> String {
        date.formatted(basicTimestamp) + "-" + id.uuidString + ".json"
    }

    static func encode(urls: [String], kind: ShareDownloadKind?, created: Date) throws -> Data {
        let encoder = JSONEncoder()
        // Slashes left unescaped keep the file readable when someone inspects the container.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Entry(urls: urls, kind: kind, created: created))
    }

    /// ISO 8601 "basic" format (no separators), in UTC, with milliseconds.
    private static let basicTimestamp = Date.ISO8601FormatStyle(
        dateSeparator: .omitted,
        dateTimeSeparator: .standard,
        timeSeparator: .omitted,
        timeZoneSeparator: .omitted,
        includingFractionalSeconds: true,
        timeZone: .gmt
    )

    private struct Entry: Encodable {
        var urls: [String]
        var kind: ShareDownloadKind?
        var created: Date

        private enum CodingKeys: String, CodingKey {
            case version, urls, kind, created
        }

        /// Written by hand so that a missing kind is an explicit `null`, as documented, rather
        /// than an absent key, and so `created` is a plain ISO-8601 string whatever the encoder's
        /// date strategy.
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(InboxWriter.formatVersion, forKey: .version)
            try container.encode(urls, forKey: .urls)
            if let kind {
                try container.encode(kind.rawValue, forKey: .kind)
            } else {
                try container.encodeNil(forKey: .kind)
            }
            try container.encode(created.formatted(.iso8601), forKey: .created)
        }
    }
}
