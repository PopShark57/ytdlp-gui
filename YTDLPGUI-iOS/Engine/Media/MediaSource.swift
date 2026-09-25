import AVFoundation
import CoreMedia

/// A media file opened with AVFoundation, with the properties every operation needs loaded up
/// front so the operations themselves stay synchronous where they can.
struct MediaSource {
    let url: URL
    let asset: AVURLAsset
    let duration: CMTime
    let tracks: [SourceTrack]

    /// Opens `url`, throwing `.unsupported` when AVFoundation can't read the container and
    /// `.failed` when the file is missing.
    static func open(_ url: URL) async throws -> MediaSource {
        guard let source = try await inspect(url) else {
            throw MediaProcessingError.unreadable(url)
        }
        return source
    }

    /// Opens `url`, or returns nil when AVFoundation can't read the container (WebM, Ogg,
    /// Matroska, or something that isn't media at all).
    static func inspect(_ url: URL) async throws -> MediaSource? {
        try MediaFiles.requireFile(url)
        // Precise timing costs nothing for MP4, whose sample tables are exact, and the cuts
        // made by `removeRanges` depend on it.
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks: [AVAssetTrack]
        let duration: CMTime
        let isReadable: Bool
        do {
            (tracks, duration, isReadable) = try await asset.load(.tracks, .duration, .isReadable)
        } catch {
            if isUnreadableContainer(error) { return nil }
            throw MediaProcessingError.failed(
                "Couldn't open \(MediaFiles.quotedName(url)): \(MediaErrorText.describe(error))"
            )
        }
        guard isReadable else { return nil }

        var loadedTracks: [SourceTrack] = []
        for track in tracks {
            loadedTracks.append(try await SourceTrack(track, asset: asset))
        }
        return MediaSource(url: url, asset: asset, duration: duration, tracks: loadedTracks)
    }

    /// The tracks of one media type, in file order.
    func tracks(ofType mediaType: AVMediaType) -> [SourceTrack] {
        tracks.filter { $0.mediaType == mediaType }
    }

    /// The track a player would pick: the first enabled one, else the first at all.
    func primaryTrack(ofType mediaType: AVMediaType) -> SourceTrack? {
        let candidates = tracks(ofType: mediaType)
        return candidates.first(where: \.isEnabled) ?? candidates.first
    }

    /// The duration in seconds, or nil when AVFoundation can't tell.
    var durationSeconds: Double? {
        duration.isNumeric && duration.seconds.isFinite ? duration.seconds : nil
    }

    /// "Cannot Open" and "Failed to Parse" mean the container itself is foreign; anything else
    /// (permissions, I/O) is a real failure worth reporting as such.
    private static func isUnreadableContainer(_ error: any Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == AVFoundationErrorDomain else { return false }
        let codes: Set<Int> = [
            AVError.Code.fileFormatNotRecognized.rawValue,
            AVError.Code.fileFailedToParse.rawValue,
            AVError.Code.operationNotSupportedForAsset.rawValue,
        ]
        return codes.contains(nsError.code)
    }
}

/// One track of a `MediaSource`, with the properties that must survive a rewrite.
struct SourceTrack {
    let track: AVAssetTrack
    /// The asset the track belongs to; readers are created per asset.
    let asset: AVURLAsset
    let mediaType: AVMediaType
    let formatDescription: CMFormatDescription?
    let timeRange: CMTimeRange
    let preferredTransform: CGAffineTransform
    let languageCode: String?
    let extendedLanguageTag: String?
    let naturalTimeScale: CMTimeScale
    let isEnabled: Bool
    let metadata: [AVMetadataItem]

    init(_ track: AVAssetTrack, asset: AVURLAsset) async throws {
        self.track = track
        self.asset = asset
        mediaType = track.mediaType
        let formatDescriptions: [CMFormatDescription]
        (
            formatDescriptions, timeRange, preferredTransform, languageCode, extendedLanguageTag,
            naturalTimeScale, isEnabled, metadata
        ) = try await track.load(
            .formatDescriptions, .timeRange, .preferredTransform, .languageCode, .extendedLanguageTag,
            .naturalTimeScale, .isEnabled, .metadata
        )
        formatDescription = formatDescriptions.first
    }

    /// The codec as the four-character code of its MP4 sample entry ("avc1", "mp4a", "alac"…).
    var codec: String? {
        formatDescription.map(MediaCodec.sampleEntryCode)
    }

    /// The codec's everyday name, for messages.
    var codecName: String {
        formatDescription.map(MediaCodec.displayName) ?? "unknown"
    }

    /// The stream description of an audio track.
    var audioStreamDescription: AudioStreamBasicDescription? {
        guard let formatDescription, mediaType == .audio else { return nil }
        return CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
    }

    /// The channel layout an audio track declares, as the bytes `AVChannelLayoutKey` expects.
    var audioChannelLayout: Data? {
        guard let formatDescription, mediaType == .audio else { return nil }
        var size = 0
        guard let layout = CMAudioFormatDescriptionGetChannelLayout(formatDescription, sizeOut: &size),
              size >= MemoryLayout<AudioChannelLayout>.size
        else { return nil }
        return Data(bytes: layout, count: size)
    }

    /// Whether the track carries anything a person would call audio or video content, as
    /// opposed to chapter text, timecode or timed metadata.
    var isAudiovisual: Bool {
        mediaType == .video || mediaType == .audio
    }
}

/// Naming for codecs, shared by `probe` and error messages.
enum MediaCodec {

    /// Core Media reports AAC by its Core Audio format ID ('aac ', 'aach'…); the Python host
    /// and yt-dlp know it by its MP4 sample entry, 'mp4a', which is what `probe` reports.
    static func sampleEntryCode(_ description: CMFormatDescription) -> String {
        let subtype = CMFormatDescriptionGetMediaSubType(description)
        if CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio, aacFormats.contains(subtype) {
            return "mp4a"
        }
        return fourCharacterString(subtype)
    }

    /// "H.264", "AAC", "Opus" and so on; the four-character code for anything unfamiliar.
    static func displayName(_ description: CMFormatDescription) -> String {
        let subtype = CMFormatDescriptionGetMediaSubType(description)
        if aacFormats.contains(subtype) { return "AAC" }
        return knownNames[fourCharacterString(subtype)] ?? fourCharacterString(subtype)
    }

    static func fourCharacterString(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
        let printable = bytes.allSatisfy { (0x20...0x7E).contains($0) }
        guard printable else { return String(format: "0x%08X", code) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    private static let aacFormats: Set<FourCharCode> = [
        kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
        kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD, kAudioFormatMPEG4AAC_ELD_SBR,
        kAudioFormatMPEG4AAC_ELD_V2,
    ]

    private static let knownNames: [String: String] = [
        "avc1": "H.264", "avc3": "H.264", "hvc1": "HEVC", "hev1": "HEVC", "dvh1": "Dolby Vision",
        "dvhe": "Dolby Vision", "av01": "AV1", "vp09": "VP9", "vp08": "VP8", "mp4v": "MPEG-4 video",
        "alac": "Apple Lossless", "flac": "FLAC", "opus": "Opus", ".mp3": "MP3", "ac-3": "Dolby Digital",
        "ec-3": "Dolby Digital Plus", "lpcm": "PCM",
    ]
}

/// File types by extension, for the containers AVFoundation can write.
enum MediaFileType {

    static func forExtension(_ pathExtension: String) -> AVFileType? {
        switch pathExtension.lowercased() {
        case "mp4", "m4v": .mp4
        case "m4a", "m4b": .m4a
        case "mov", "qt": .mov
        default: nil
        }
    }

    static func name(of fileType: AVFileType) -> String {
        switch fileType {
        case .m4a: "M4A"
        case .mov: "MOV"
        default: "MP4"
        }
    }
}

extension MediaContainer {
    var fileType: AVFileType {
        switch self {
        case .mp4: .mp4
        case .mov: .mov
        case .m4a: .m4a
        }
    }
}

extension MediaProcessingError {

    /// The error for a file AVFoundation can't open at all.
    static func unreadable(_ url: URL) -> MediaProcessingError {
        .unsupported(
            "iOS can't read \(MediaFiles.quotedName(url)): only MP4, M4A and MOV media can be processed "
                + "on iPhone and iPad, not WebM, Ogg or Matroska."
        )
    }
}
