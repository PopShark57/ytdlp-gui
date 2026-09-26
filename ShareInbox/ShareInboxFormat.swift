import Foundation

/// How the Share extension hands links to the app: one small JSON file per share, left in the
/// App Group container's `Inbox` folder.
///
/// - `Inbox/<ISO-8601 basic timestamp>-<UUID>.json`, so names sort chronologically;
/// - `{"version": 1, "urls": [String], "kind": "video"|"audio"|null, "created": ISO-8601}`.
///
/// The `ShareInbox` folder is compiled into both the app and the extension (an extension can't
/// link the app's code, but it can compile the same source file), so the writer
/// (`InboxWriter`) and the reader (`SharedLinkInbox`) can't drift apart.
enum ShareInboxFormat {

    static let appGroupIdentifier = "group.io.github.ytdlpgui.YTDLPGUI"

    /// The only format version there is.
    static let formatVersion = 1

    /// The inbox folder inside the App Group container, or `nil` when the container is
    /// unavailable: the process was signed without the App Group entitlement.
    static var inboxDirectory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appending(path: "Inbox", directoryHint: .isDirectory)
    }

    /// `20260924T195412.123Z-<UUID>.json`.
    ///
    /// Milliseconds keep two shares in the same second in order; the UUID keeps them distinct.
    /// Every timestamp has the same width, so sorting names sorts entries by age.
    static func fileName(for date: Date, id: UUID = UUID()) -> String {
        date.formatted(basicTimestamp) + "-" + id.uuidString + ".json"
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

    /// One entry, as stored.
    ///
    /// `kind` and `created` stay strings: the reader treats an unknown kind as none rather than
    /// rejecting the entry, and parses the date itself, accepting fractional seconds too.
    struct Entry: Codable, Equatable, Sendable {
        var version: Int
        var urls: [String]
        var kind: String?
        var created: String

        /// A new entry in the current format. `kind` is a `DownloadKind` raw value.
        init(urls: [String], kind: String?, created: Date) {
            version = ShareInboxFormat.formatVersion
            self.urls = urls
            self.kind = kind
            self.created = created.formatted(.iso8601)
        }

        private enum CodingKeys: String, CodingKey {
            case version, urls, kind, created
        }

        /// Written by hand so that a missing kind is an explicit `null`, as documented, rather
        /// than an absent key.
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(urls, forKey: .urls)
            try container.encode(kind, forKey: .kind)
            try container.encode(created, forKey: .created)
        }
    }

    /// The file contents for `entry`.
    static func encode(_ entry: Entry) throws -> Data {
        let encoder = JSONEncoder()
        // Slashes left unescaped keep the file readable when someone inspects the container.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(entry)
    }

    static func decode(_ data: Data) throws -> Entry {
        try JSONDecoder().decode(Entry.self, from: data)
    }
}
