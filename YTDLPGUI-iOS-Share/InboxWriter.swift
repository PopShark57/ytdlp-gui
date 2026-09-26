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
/// The format is `ShareInboxFormat`'s, the same source file the app reads it with.
enum InboxWriter {

    enum Failure: Error, Equatable {
        /// The App Group container isn't there, which means the extension was signed without
        /// the App Group entitlement. Nothing the user does will fix it on this install.
        case containerUnavailable
        /// The entry couldn't be written. The reason is the system's own, user-readable one.
        case writeFailed(String)
    }

    /// The inbox folder inside the App Group container, or `nil` when the container is unavailable.
    static var inboxDirectory: URL? {
        ShareInboxFormat.inboxDirectory
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
        let fileURL = directory.appending(path: ShareInboxFormat.fileName(for: created))
        let entry = ShareInboxFormat.Entry(urls: urls, kind: kind?.rawValue, created: created)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try ShareInboxFormat.encode(entry).write(to: fileURL, options: .atomic)
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
        return fileURL
    }
}
