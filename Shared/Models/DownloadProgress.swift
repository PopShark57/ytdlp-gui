import Foundation

/// A structured snapshot of yt-dlp's progress output.
struct DownloadProgressSnapshot: Equatable, Sendable {
    var downloadedBytes: Int64?
    var totalBytes: Int64?
    var speedBytesPerSecond: Double?
    var etaSeconds: Int?
    var elapsedSeconds: Double?
    var fragmentIndex: Int?
    var fragmentCount: Int?
    var filename: String?

    static let empty = DownloadProgressSnapshot()

    /// 0...1, or `nil` when the total size is unknown (live streams, some HLS sources).
    var fractionCompleted: Double? {
        if let downloadedBytes, let totalBytes, totalBytes > 0 {
            return min(max(Double(downloadedBytes) / Double(totalBytes), 0), 1)
        }
        if let fragmentIndex, let fragmentCount, fragmentCount > 0 {
            return min(max(Double(fragmentIndex) / Double(fragmentCount), 0), 1)
        }
        return nil
    }

    var percentLabel: String? { Format.percent(fractionCompleted) }
    var speedLabel: String? { Format.speed(speedBytesPerSecond) }
    var etaLabel: String? { Format.eta(etaSeconds) }
    var sizeLabel: String? { Format.transferred(downloaded: downloadedBytes, total: totalBytes) }

    var fragmentLabel: String? {
        guard let fragmentIndex, let fragmentCount, fragmentCount > 0 else { return nil }
        return "fragment \(fragmentIndex) of \(fragmentCount)"
    }

    /// The last path component of the file currently being written.
    var displayFilename: String? {
        guard let filename, !filename.isEmpty else { return nil }
        return (filename as NSString).lastPathComponent
    }
}

/// What yt-dlp is doing right now.
///
/// A single yt-dlp invocation moves through several stages; showing the stage rather than a
/// stalled progress bar is the difference between "the app froze" and "ffmpeg is merging".
enum DownloadPhase: Equatable, Sendable {
    case waiting
    case resolving
    case downloading
    case merging
    case extractingAudio
    case remuxing
    case embeddingSubtitles
    case embeddingThumbnail
    case writingMetadata
    case removingSegments
    case postProcessing(String)
    case movingFiles
    case completed
    case failed
    case cancelled

    var displayName: String {
        switch self {
        case .waiting: "Waiting"
        case .resolving: "Fetching information"
        case .downloading: "Downloading"
        case .merging: "Merging streams"
        case .extractingAudio: "Extracting audio"
        case .remuxing: "Remuxing"
        case .embeddingSubtitles: "Embedding subtitles"
        case .embeddingThumbnail: "Embedding artwork"
        case .writingMetadata: "Writing metadata"
        case .removingSegments: "Removing segments"
        case .postProcessing(let name): "Processing · \(name)"
        case .movingFiles: "Finishing up"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    var symbolName: String {
        switch self {
        case .waiting: "clock"
        case .resolving: "magnifyingglass"
        case .downloading: "arrow.down.circle"
        case .merging: "arrow.triangle.merge"
        case .extractingAudio: "waveform"
        case .remuxing: "shippingbox"
        case .embeddingSubtitles: "captions.bubble"
        case .embeddingThumbnail: "photo"
        case .writingMetadata: "tag"
        case .removingSegments: "scissors"
        case .postProcessing: "gearshape"
        case .movingFiles: "folder"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle.fill"
        }
    }

    /// Post-processing stages have no byte counts, so the UI shows an indeterminate bar.
    var isIndeterminate: Bool {
        switch self {
        case .waiting, .downloading, .completed, .failed, .cancelled: false
        default: true
        }
    }

    /// Maps a yt-dlp postprocessor class name onto a phase.
    static func forPostProcessor(_ name: String) -> DownloadPhase {
        switch name {
        case "Merger": .merging
        case "ExtractAudio": .extractingAudio
        case "VideoRemuxer", "VideoConvertor": .remuxing
        case "EmbedSubtitle", "FFmpegEmbedSubtitle": .embeddingSubtitles
        case "EmbedThumbnail", "FFmpegThumbnailsConvertor": .embeddingThumbnail
        case "Metadata", "FFmpegMetadata": .writingMetadata
        case "ModifyChapters", "SponsorBlock": .removingSegments
        case "MoveFiles", "MoveFilesAfterDownload": .movingFiles
        default: .postProcessing(name)
        }
    }
}
