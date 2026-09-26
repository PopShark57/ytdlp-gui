import Foundation

/// A completed (or failed) download, persisted between launches.
struct HistoryEntry: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    /// The queue item that produced this entry, so a notification about that download still
    /// finds it after the queue has forgotten the item. A retried item produces several entries
    /// with the same ID. `nil` for entries saved before it was recorded.
    var downloadID: UUID?
    var title: String
    var sourceURL: String
    /// The main file: the video, or the last video of a playlist.
    var outputPath: String?
    /// Every file the download produced, in the order they were finished: one per video of a
    /// playlist, or a video and its separate audio track when they couldn't be merged. At most
    /// `maximumStoredOutputPaths`. `nil` for entries saved before they were recorded, which
    /// only know `outputPath`.
    var outputPaths: [String]?
    var date: Date
    var formatSummary: String
    var kind: DownloadKind
    var succeeded: Bool
    var failureTitle: String?
    var failureDetail: String?
    var thumbnailURL: URL?
    var fileSizeBytes: Int64?
    var durationSeconds: Double?
    /// The options used, so "Download again" reproduces the original request exactly.
    var options: DownloadOptions?
    /// Options whose passwords or other credentials were left out of `options` when the entry
    /// was saved, e.g. `--password`, so "Download again" can say so. `nil` when nothing was.
    var removedSecretOptions: [String]?

    /// Keeps `history.json` bounded for very long playlists.
    static let maximumStoredOutputPaths = 500

    init(
        id: UUID = UUID(),
        downloadID: UUID? = nil,
        title: String,
        sourceURL: String,
        outputPath: String? = nil,
        outputPaths: [String]? = nil,
        date: Date = Date(),
        formatSummary: String,
        kind: DownloadKind,
        succeeded: Bool,
        failureTitle: String? = nil,
        failureDetail: String? = nil,
        thumbnailURL: URL? = nil,
        fileSizeBytes: Int64? = nil,
        durationSeconds: Double? = nil,
        options: DownloadOptions? = nil,
        removedSecretOptions: [String]? = nil
    ) {
        self.id = id
        self.downloadID = downloadID
        self.title = title
        self.sourceURL = sourceURL
        self.outputPath = outputPath
        self.outputPaths = outputPaths.map { Array($0.prefix(Self.maximumStoredOutputPaths)) }
        self.date = date
        self.formatSummary = formatSummary
        self.kind = kind
        self.succeeded = succeeded
        self.failureTitle = failureTitle
        self.failureDetail = failureDetail
        self.thumbnailURL = thumbnailURL
        self.fileSizeBytes = fileSizeBytes
        self.durationSeconds = durationSeconds
        self.options = options
        self.removedSecretOptions = removedSecretOptions
    }

    /// Leaves passwords and other credentials out of `options`, and records which options had
    /// them. See `DownloadOptions.removingSecrets()`.
    mutating func removeSecrets() {
        guard let options else { return }
        let stripped = options.removingSecrets()
        guard !stripped.removed.isEmpty else { return }
        self.options = stripped.options
        var removed = removedSecretOptions ?? []
        for name in stripped.removed where !removed.contains(name) {
            removed.append(name)
        }
        removedSecretOptions = removed
    }

    var outputURL: URL? {
        guard let outputPath, !outputPath.isEmpty else { return nil }
        return Self.url(forStoredPath: outputPath)
    }

    /// Every file the download produced (see `outputPaths`), each found the way `outputURL` is.
    /// Entries that recorded only one file give just that one.
    var outputURLs: [URL] {
        guard let outputPaths, !outputPaths.isEmpty else {
            return outputURL.map { [$0] } ?? []
        }
        return outputPaths.filter { !$0.isEmpty }.map(Self.url(forStoredPath:))
    }

    private static func url(forStoredPath path: String) -> URL {
        #if os(iOS)
        // iOS moves the app's container whenever the app is updated or reinstalled, so an
        // absolute path stored by an earlier install is stale even though the file is still there.
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            return resolve(storedPath: path, documentsDirectory: documents)
        }
        #endif
        return URL(fileURLWithPath: path)
    }

    /// Finds a file recorded under some earlier container's `Documents` folder.
    ///
    /// The stored path is used whenever it still exists. Otherwise whatever followed a
    /// `Documents` component is re-rooted under `documentsDirectory` and used if it exists there.
    /// When nothing is found the stored path is returned unchanged, so the entry still names the
    /// file and reports it as missing.
    static func resolve(storedPath: String, documentsDirectory: URL) -> URL {
        let stored = URL(fileURLWithPath: storedPath)
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: stored.path(percentEncoded: false)) else { return stored }

        let components = stored.pathComponents
        // Every occurrence is tried, from the first: the container's own `Documents` comes
        // first, but a subfolder the user named "Documents" must not hide it.
        for index in components.indices where components[index] == "Documents" {
            let remainder = components[components.index(after: index)...]
            guard !remainder.isEmpty else { continue }
            let candidate = remainder.reduce(documentsDirectory) { url, component in
                url.appending(path: component, directoryHint: .notDirectory)
            }
            if fileManager.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return candidate
            }
        }
        return stored
    }

    /// Whether any of the downloaded files is still where we left it.
    var fileExists: Bool {
        outputURLs.contains { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    var fileName: String? {
        outputURL?.lastPathComponent
    }

    /// Fields matched by the history search field.
    func matches(searchText: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return true }
        return title.lowercased().contains(query)
            || sourceURL.lowercased().contains(query)
            || (outputPath?.lowercased().contains(query) ?? false)
            || formatSummary.lowercased().contains(query)
    }
}
