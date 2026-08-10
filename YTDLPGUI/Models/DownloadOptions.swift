import Foundation

// MARK: - Download kind

enum DownloadKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case video
    case audio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .video: "Video"
        case .audio: "Audio"
        }
    }

    var symbolName: String {
        switch self {
        case .video: "film"
        case .audio: "music.note"
        }
    }
}

// MARK: - Video

enum VideoQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case best
    case uhd2160
    case qhd1440
    case fhd1080
    case hd720
    case sd480

    var id: String { rawValue }

    /// The height cap applied to the format selector, or `nil` for "no cap".
    var maxHeight: Int? {
        switch self {
        case .best: nil
        case .uhd2160: 2160
        case .qhd1440: 1440
        case .fhd1080: 1080
        case .hd720: 720
        case .sd480: 480
        }
    }

    var displayName: String {
        switch self {
        case .best: "Best Quality"
        case .uhd2160: "4K · 2160p"
        case .qhd1440: "1440p"
        case .fhd1080: "1080p"
        case .hd720: "720p"
        case .sd480: "480p"
        }
    }

    var shortName: String {
        switch self {
        case .best: "Best"
        case .uhd2160: "4K"
        case .qhd1440: "1440p"
        case .fhd1080: "1080p"
        case .hd720: "720p"
        case .sd480: "480p"
        }
    }
}

enum VideoContainer: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case mp4
    case mkv
    case webm

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Automatic"
        case .mp4: "MP4"
        case .mkv: "MKV"
        case .webm: "WebM"
        }
    }

    /// The value passed to `--merge-output-format`, or `nil` to let yt-dlp decide.
    var mergeOutputFormat: String? {
        self == .auto ? nil : rawValue
    }

    var helpText: String {
        switch self {
        case .auto: "Let yt-dlp pick the container that avoids re-encoding."
        case .mp4: "Most compatible with Apple apps such as QuickTime Player and Photos."
        case .mkv: "Accepts virtually any codec and multiple subtitle tracks."
        case .webm: "Open format, best paired with VP9/AV1 and Opus audio."
        }
    }
}

// MARK: - Audio

enum AudioFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case best
    case mp3
    case m4a
    case flac
    case wav
    case opus

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .best: "Best Audio"
        case .mp3: "MP3"
        case .m4a: "M4A · AAC"
        case .flac: "FLAC"
        case .wav: "WAV"
        case .opus: "Opus"
        }
    }

    /// Value passed to `--audio-format`. `best` keeps the source codec where possible.
    var ytdlpValue: String { rawValue }

    /// Whether `--audio-quality` has any effect for this format.
    var supportsQuality: Bool {
        switch self {
        case .mp3, .m4a, .opus: true
        case .best, .flac, .wav: false
        }
    }

    var helpText: String {
        switch self {
        case .best: "Keep the original audio stream without re-encoding. Fastest and lossless."
        case .mp3: "Universally compatible lossy audio."
        case .m4a: "AAC in an MP4 container. Native to Apple Music and iOS."
        case .flac: "Lossless compression. Larger files, no quality loss from the source."
        case .wav: "Uncompressed PCM. Very large files."
        case .opus: "Modern lossy codec with excellent quality at low bitrates."
        }
    }
}

enum AudioQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case best
    case kbps320
    case kbps256
    case kbps192
    case kbps128
    case kbps96

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .best: "Best available"
        case .kbps320: "320 kbps"
        case .kbps256: "256 kbps"
        case .kbps192: "192 kbps"
        case .kbps128: "128 kbps"
        case .kbps96: "96 kbps"
        }
    }

    /// Value passed to `--audio-quality`. yt-dlp accepts either a VBR level (0–10) or a bitrate.
    var ytdlpValue: String {
        switch self {
        case .best: "0"
        case .kbps320: "320K"
        case .kbps256: "256K"
        case .kbps192: "192K"
        case .kbps128: "128K"
        case .kbps96: "96K"
        }
    }
}

// MARK: - Subtitles

enum SubtitleMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case manual
    case automatic
    case both

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: "Don't download"
        case .manual: "Uploaded subtitles"
        case .automatic: "Auto-generated captions"
        case .both: "Both"
        }
    }

    var writesManual: Bool { self == .manual || self == .both }
    var writesAutomatic: Bool { self == .automatic || self == .both }
    var isEnabled: Bool { self != .off }
}

// MARK: - SponsorBlock

enum SponsorBlockMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case mark
    case remove

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: "Off"
        case .mark: "Mark as chapters"
        case .remove: "Cut from file"
        }
    }

    var helpText: String {
        switch self {
        case .off: "Leave the video untouched."
        case .mark: "Add chapter markers around the selected segments, keeping the full video."
        case .remove: "Physically remove the selected segments. Requires ffmpeg and re-encodes chapters."
        }
    }
}

/// The SponsorBlock categories yt-dlp understands, limited to the ones people actually use.
enum SponsorBlockCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case sponsor
    case intro
    case outro
    case selfpromo
    case preview
    case filler
    case interaction
    case music_offtopic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sponsor: "Sponsor"
        case .intro: "Intro / intermission"
        case .outro: "Endcards & credits"
        case .selfpromo: "Unpaid self-promotion"
        case .preview: "Preview / recap"
        case .filler: "Filler tangent"
        case .interaction: "Interaction reminder"
        case .music_offtopic: "Non-music section"
        }
    }
}

// MARK: - Cookies

enum CookieBrowser: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case safari
    case chrome
    case firefox
    case brave
    case edge
    case chromium
    case opera
    case vivaldi
    case whale

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: "Don't use cookies"
        case .safari: "Safari"
        case .chrome: "Google Chrome"
        case .firefox: "Firefox"
        case .brave: "Brave"
        case .edge: "Microsoft Edge"
        case .chromium: "Chromium"
        case .opera: "Opera"
        case .vivaldi: "Vivaldi"
        case .whale: "Whale"
        }
    }

    var ytdlpValue: String? { self == .none ? nil : rawValue }
}

// MARK: - Options

/// Everything the user can configure for a single download.
///
/// A snapshot of this struct is captured when an item is added to the queue, so later
/// changes in the UI never affect downloads that are already running or waiting.
struct DownloadOptions: Codable, Equatable, Sendable {

    // Core
    var kind: DownloadKind = .video
    var videoQuality: VideoQuality = .best
    var container: VideoContainer = .auto
    var audioFormat: AudioFormat = .best
    var audioQuality: AudioQuality = .best
    var outputDirectory: URL = DownloadOptions.defaultDownloadsDirectory
    var outputTemplate: String = DownloadOptions.defaultOutputTemplate

    // Subtitles
    var subtitleMode: SubtitleMode = .off
    var subtitleLanguages: String = "en"
    var embedSubtitles: Bool = false

    // Metadata & artwork
    var embedThumbnail: Bool = false
    var embedMetadata: Bool = false
    var embedChapters: Bool = false
    var writeThumbnail: Bool = false
    var writeInfoJSON: Bool = false

    // SponsorBlock
    var sponsorBlockMode: SponsorBlockMode = .off
    var sponsorBlockCategories: Set<SponsorBlockCategory> = [.sponsor]

    // Playlists
    var downloadPlaylist: Bool = false
    var playlistItems: String = ""

    // Archive
    var useDownloadArchive: Bool = false
    var downloadArchivePath: String = ""

    // Network & authentication
    var cookieBrowser: CookieBrowser = .none
    var rateLimit: String = ""
    var concurrentFragments: Int = 1
    var proxy: String = ""
    var userAgent: String = ""

    // Files
    var restrictFilenames: Bool = false
    var overwriteExisting: Bool = false

    // Escape hatch
    var customArguments: String = ""

    /// When true, `--ignore-config` is passed so a user's `yt-dlp.conf` cannot silently
    /// change the behaviour shown in the command preview.
    var ignoreUserConfig: Bool = true

    static let defaultOutputTemplate = "%(title)s.%(ext)s"

    static var defaultDownloadsDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Downloads")
    }

    /// A one-line description of the chosen preset, for queue rows and history.
    var formatSummary: String {
        switch kind {
        case .video:
            let container = container == .auto ? "" : " · \(container.displayName)"
            return "\(videoQuality.shortName)\(container)"
        case .audio:
            let quality = audioFormat.supportsQuality && audioQuality != .best
                ? " · \(audioQuality.displayName)"
                : ""
            return "\(audioFormat.displayName)\(quality)"
        }
    }
}
