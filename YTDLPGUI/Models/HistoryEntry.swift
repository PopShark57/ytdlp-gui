import Foundation

/// A completed (or failed) download, persisted between launches.
struct HistoryEntry: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var sourceURL: String
    var outputPath: String?
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

    init(
        id: UUID = UUID(),
        title: String,
        sourceURL: String,
        outputPath: String? = nil,
        date: Date = Date(),
        formatSummary: String,
        kind: DownloadKind,
        succeeded: Bool,
        failureTitle: String? = nil,
        failureDetail: String? = nil,
        thumbnailURL: URL? = nil,
        fileSizeBytes: Int64? = nil,
        durationSeconds: Double? = nil,
        options: DownloadOptions? = nil
    ) {
        self.id = id
        self.title = title
        self.sourceURL = sourceURL
        self.outputPath = outputPath
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
    }

    var outputURL: URL? {
        guard let outputPath, !outputPath.isEmpty else { return nil }
        return URL(fileURLWithPath: outputPath)
    }

    /// Whether the downloaded file is still where we left it.
    var fileExists: Bool {
        guard let outputURL else { return false }
        return FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false))
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
