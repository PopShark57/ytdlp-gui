import Foundation
import Observation

enum DownloadState: String, Equatable, Sendable {
    case queued
    case active
    case completed
    case failed
    case cancelled

    var isFinished: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        case .queued, .active: false
        }
    }
}

/// A capped, append-only log of the raw output from one yt-dlp invocation.
///
/// Long playlist downloads can emit tens of thousands of lines, so the buffer keeps only the
/// most recent ones. `totalLineCount` still reflects everything that was produced.
struct LogBuffer: Equatable, Sendable {
    private(set) var lines: [String] = []
    private(set) var totalLineCount = 0

    static let limit = 2_000

    mutating func append(_ line: String) {
        totalLineCount += 1
        lines.append(line)
        if lines.count > Self.limit {
            lines.removeFirst(lines.count - Self.limit)
        }
    }

    mutating func removeAll() {
        lines.removeAll()
        totalLineCount = 0
    }

    var isTruncated: Bool { totalLineCount > lines.count }

    var joined: String { lines.joined(separator: "\n") }
}

/// One row in the download queue.
///
/// This is a reference type so that a running download can push frequent progress updates
/// without SwiftUI re-diffing the whole queue array on every tick.
@MainActor
@Observable
final class DownloadItem: Identifiable {
    let id: UUID
    let sourceURL: String
    /// Captured when the item was queued; later UI changes never affect it.
    let options: DownloadOptions
    let createdAt: Date

    var title: String?
    var uploader: String?
    var thumbnailURL: URL?
    var durationSeconds: Double?
    var isPlaylist: Bool = false
    var playlistCount: Int?

    var state: DownloadState = .queued
    var phase: DownloadPhase = .waiting
    var progress: DownloadProgressSnapshot = .empty
    var failure: DownloadFailure?
    var outputURL: URL?
    var completedFileSize: Int64?
    var finishedAt: Date?

    /// Number of files finished so far, for playlist downloads.
    var completedItemCount = 0

    var log = LogBuffer()

    init(
        id: UUID = UUID(),
        sourceURL: String,
        options: DownloadOptions,
        title: String? = nil,
        uploader: String? = nil,
        thumbnailURL: URL? = nil,
        durationSeconds: Double? = nil,
        isPlaylist: Bool = false,
        playlistCount: Int? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.options = options
        self.title = title
        self.uploader = uploader
        self.thumbnailURL = thumbnailURL
        self.durationSeconds = durationSeconds
        self.isPlaylist = isPlaylist
        self.playlistCount = playlistCount
        self.createdAt = createdAt
    }

    /// Title if we know one, otherwise the URL, so a row is never blank.
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return sourceURL
    }

    var displaySubtitle: String {
        var parts: [String] = []
        if let uploader, !uploader.isEmpty { parts.append(uploader) }
        parts.append(options.formatSummary)
        if isPlaylist, let playlistCount {
            parts.append("\(playlistCount) items")
        }
        return parts.joined(separator: " · ")
    }

    var canCancel: Bool { state == .active || state == .queued }
    var canRetry: Bool { state == .failed || state == .cancelled }
    var canRevealInFinder: Bool { state == .completed && outputURL != nil }

    /// Resets everything except identity, so the item can be run again.
    func prepareForRetry() {
        state = .queued
        phase = .waiting
        progress = .empty
        failure = nil
        outputURL = nil
        completedFileSize = nil
        finishedAt = nil
        completedItemCount = 0
        log.removeAll()
    }

    func makeHistoryEntry() -> HistoryEntry {
        HistoryEntry(
            title: displayTitle,
            sourceURL: sourceURL,
            outputPath: outputURL?.path(percentEncoded: false),
            date: finishedAt ?? Date(),
            formatSummary: options.formatSummary,
            kind: options.kind,
            succeeded: state == .completed,
            failureTitle: failure?.title,
            failureDetail: failure?.underlyingMessage,
            thumbnailURL: thumbnailURL,
            fileSizeBytes: completedFileSize,
            durationSeconds: durationSeconds,
            options: options
        )
    }
}
