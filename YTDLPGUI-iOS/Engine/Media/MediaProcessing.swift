import Foundation

// The media work yt-dlp would normally hand to ffmpeg, expressed as a protocol so the engine's
// request router and the AVFoundation implementation can be written and tested independently.
//
// Each method corresponds to one `media.*` request from the Python host; the JSON shapes are in
// Docs/iOS-Architecture.md. Implementations must be safe to call concurrently for different
// files, and must write outputs atomically enough that a failure never leaves a truncated file
// at the output path.

/// Containers the merger can write.
enum MediaContainer: String, Codable, Sendable {
    case mp4
    case mov
    case m4a
}

/// Audio codecs the extractor can produce.
enum AudioCodecRequest: String, Codable, Sendable {
    /// Keep the source audio as it is, only rewrapping it in an M4A container.
    case copy
    /// AAC in M4A, at `bitrate` when given.
    case aac
    /// Apple Lossless in M4A.
    case alac
    /// FLAC in a .flac file.
    case flac
    /// 16-bit PCM in a .wav file.
    case wav
}

enum ImageFormat: String, Codable, Sendable {
    case jpg
    case png
}

/// Tags written into a finished file. Every field is optional; absent ones are left alone.
struct MediaMetadata: Codable, Equatable, Sendable {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var date: String?
    var comment: String?
    var description: String?
    var genre: String?
    var track: String?
    var webpageURL: String?

    enum CodingKeys: String, CodingKey {
        case title, artist, album, date, comment, description, genre, track
        case albumArtist = "album_artist"
        case webpageURL = "purl"
    }
}

/// A chapter marker, in seconds from the start.
struct MediaChapter: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var title: String
}

/// What a file contains, as far as AVFoundation can tell.
struct MediaProbe: Codable, Equatable, Sendable {
    struct Track: Codable, Equatable, Sendable {
        /// "video", "audio", "text", "subtitle", "timecode" or "other".
        var kind: String
        /// The four-character codec code, e.g. "avc1", "hvc1", "av01", "mp4a", "alac".
        var codec: String?
    }

    var durationSeconds: Double?
    var tracks: [Track]
    /// Whether AVFoundation could open the file at all. WebM, Ogg and MKV cannot be opened.
    var isReadable: Bool

    enum CodingKeys: String, CodingKey {
        case durationSeconds = "duration"
        case tracks
        case isReadable = "readable"
    }
}

/// Why a media operation could not be carried out.
enum MediaProcessingError: LocalizedError, Equatable, Sendable {
    /// The input uses a container or codec AVFoundation cannot read or write. The Python host
    /// turns this into a warning and keeps the original file rather than failing the download.
    case unsupported(String)
    /// The operation was possible but failed.
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let message), .failed(let message): message
        }
    }

    var isUnsupported: Bool {
        if case .unsupported = self { return true }
        return false
    }
}

/// Media operations performed with Apple frameworks in place of ffmpeg.
protocol MediaProcessing: Sendable {
    /// Combines the video track(s) of the first input with the audio track(s) of the others,
    /// without re-encoding.
    func merge(inputs: [URL], output: URL, container: MediaContainer) async throws

    /// Writes the audio of `input` to `output` as `codec`. `bitrate` is in bits per second and
    /// only applies to AAC. Returns the file actually written, whose extension may differ from
    /// `output`'s when the codec demands it.
    func extractAudio(input: URL, output: URL, codec: AudioCodecRequest, bitrate: Int?) async throws -> URL

    /// Rewrites `file` in place with the given tags, cover art and chapters. Any argument left
    /// `nil` is not touched.
    func embed(into file: URL, metadata: MediaMetadata?, artwork: URL?, chapters: [MediaChapter]?) async throws

    /// Converts a thumbnail (often WebP) to JPEG or PNG.
    func convertImage(input: URL, output: URL, format: ImageFormat) async throws

    /// Writes `input` to `output` with the given time ranges (in seconds) cut out, without
    /// re-encoding. Used for SponsorBlock's "remove" mode.
    func removeRanges(input: URL, output: URL, ranges: [ClosedRange<Double>]) async throws

    /// Describes a file's duration and tracks.
    func probe(_ file: URL) async throws -> MediaProbe
}
