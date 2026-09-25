import AVFoundation
import os

/// Performs media work with AVFoundation, ImageIO and Core Audio in place of ffmpeg.
///
/// Each operation lives in its own small type; this facade is what the engine's request router
/// calls, and the one place where unexpected errors become sentences. Nothing here holds state,
/// so concurrent calls for different files are independent.
final class MediaProcessor: MediaProcessing {

    static let shared = MediaProcessor()

    func merge(inputs: [URL], output: URL, container: MediaContainer) async throws {
        try await perform("Merging into \(MediaFiles.quotedName(output))") {
            try await MediaMerger().merge(inputs: inputs, output: output, container: container)
        }
    }

    func extractAudio(input: URL, output: URL, codec: AudioCodecRequest, bitrate: Int?) async throws -> URL {
        try await perform("Extracting the audio of \(MediaFiles.quotedName(input))") {
            try await AudioExtractor().extract(input: input, output: output, codec: codec, bitrate: bitrate)
        }
    }

    func embed(into file: URL, metadata: MediaMetadata?, artwork: URL?, chapters: [MediaChapter]?) async throws {
        try await perform("Embedding into \(MediaFiles.quotedName(file))") {
            try await MetadataEmbedder().embed(into: file, metadata: metadata, artwork: artwork, chapters: chapters)
        }
    }

    func convertImage(input: URL, output: URL, format: ImageFormat) async throws {
        try await perform("Converting \(MediaFiles.quotedName(input))") {
            try await ImageConverter.convert(input: input, output: output, format: format)
        }
    }

    func removeRanges(input: URL, output: URL, ranges: [ClosedRange<Double>]) async throws {
        try await perform("Cutting \(MediaFiles.quotedName(input))") {
            try await RangeRemover().removeRanges(input: input, output: output, ranges: ranges)
        }
    }

    func probe(_ file: URL) async throws -> MediaProbe {
        try await perform("Inspecting \(MediaFiles.quotedName(file))") {
            guard let source = try await MediaSource.inspect(file) else {
                return MediaProbe(durationSeconds: nil, tracks: [], isReadable: false)
            }
            return MediaProbe(
                durationSeconds: source.durationSeconds,
                tracks: source.tracks.map { MediaProbe.Track(kind: Self.kind(of: $0.mediaType), codec: $0.codec) },
                isReadable: true
            )
        }
    }

    // MARK: - Private

    /// Lets the operations' own errors through untouched and turns anything unexpected into a
    /// `.failed` that names the step, so the log says what was being attempted.
    private func perform<Result>(_ operation: String, _ body: () async throws -> Result) async throws -> Result {
        do {
            return try await body()
        } catch let error as MediaProcessingError {
            MediaLog.logger.error("\(operation, privacy: .public): \(error.errorDescription ?? "", privacy: .public)")
            throw error
        } catch let error as CancellationError {
            throw error
        } catch {
            let message = "\(operation) failed: \(MediaErrorText.describe(error))"
            MediaLog.logger.error("\(message, privacy: .public)")
            throw MediaProcessingError.failed(message)
        }
    }

    private static func kind(of mediaType: AVMediaType) -> String {
        switch mediaType {
        case .video: "video"
        case .audio: "audio"
        case .text: "text"
        case .subtitle, .closedCaption: "subtitle"
        case .timecode: "timecode"
        default: "other"
        }
    }
}

enum MediaLog {
    static let logger = Logger(subsystem: "io.github.ytdlpgui.YTDLPGUI", category: "media")
}
