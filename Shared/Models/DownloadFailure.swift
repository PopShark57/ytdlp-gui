import Foundation

/// A human-readable interpretation of a yt-dlp failure.
///
/// yt-dlp reports problems as free-form English on stderr. Showing that text raw is a poor
/// experience, but throwing it away makes real problems undiagnosable, so every failure keeps
/// both a friendly summary *and* the original line, which the log view still shows in full.
struct DownloadFailure: Equatable, Sendable {
    var kind: Kind
    /// The most relevant line yt-dlp printed, kept verbatim.
    var underlyingMessage: String?

    enum Kind: Equatable, Sendable {
        case toolMissing(String)
        case invalidURL
        case unsupportedSite
        case unavailable
        case privateOrMembersOnly
        case geoRestricted
        case ageRestricted
        case authenticationRequired
        case botCheck
        case rateLimited
        case network
        case postProcessing
        case ffmpegMissing
        case fileSystem
        case diskFull
        case cancelled
        case unknown
    }

    var title: String {
        switch kind {
        case .toolMissing(let name): "\(name) was not found"
        case .invalidURL: "That doesn't look like a valid URL"
        case .unsupportedSite: "This site isn't supported"
        case .unavailable: "This video isn't available"
        case .privateOrMembersOnly: "This video is private"
        case .geoRestricted: "Not available in your region"
        case .ageRestricted: "Age-restricted video"
        case .authenticationRequired: "Sign-in required"
        case .botCheck: "The site asked for a sign-in check"
        case .rateLimited: "Too many requests"
        case .network: "Network problem"
        case .postProcessing: "Post-processing failed"
        case .ffmpegMissing: "ffmpeg is required for this download"
        case .fileSystem: "Couldn't write the file"
        case .diskFull: "Not enough disk space"
        case .cancelled: "Download cancelled"
        case .unknown: "Download failed"
        }
    }

    var recoverySuggestion: String? {
        #if os(iOS)
        return embeddedEngineRecoverySuggestion
        #else
        switch kind {
        case .toolMissing(let name):
            "Install it with `brew install \(name)`, or choose the executable manually in Settings."
        case .invalidURL:
            "Check the address and try again. It should start with http:// or https://."
        case .unsupportedSite:
            "yt-dlp has no extractor for this site. Updating yt-dlp sometimes adds support."
        case .unavailable:
            "The video may have been removed, made private, or never existed."
        case .privateOrMembersOnly:
            "Try enabling “Use cookies from browser” in Advanced Options with a browser that is signed in."
        case .geoRestricted:
            "A proxy set in Advanced Options may help."
        case .ageRestricted:
            "Enable “Use cookies from browser” in Advanced Options and sign in to the site in that browser."
        case .authenticationRequired:
            "Enable “Use cookies from browser” in Advanced Options and sign in to the site in that browser."
        case .botCheck:
            "Enable “Use cookies from browser” in Advanced Options. Updating yt-dlp also helps, because these checks change often."
        case .rateLimited:
            "Wait a few minutes before retrying, or set a rate limit in Advanced Options."
        case .network:
            "Check your internet connection and try again."
        case .postProcessing:
            "Check that ffmpeg is installed and that the chosen container supports the selected streams."
        case .ffmpegMissing:
            "Install it with `brew install ffmpeg`. Merging separate video and audio streams needs it."
        case .fileSystem:
            "Pick a different output folder, or check that you have permission to write to it."
        case .diskFull:
            "Free up space or choose an output folder on another volume."
        case .cancelled:
            nil
        case .unknown:
            "Open the log for the full output from yt-dlp."
        }
        #endif
    }

    var symbolName: String {
        switch kind {
        case .cancelled: "xmark.circle.fill"
        case .network, .rateLimited: "wifi.exclamationmark"
        case .authenticationRequired, .botCheck, .privateOrMembersOnly, .ageRestricted: "person.badge.key"
        case .toolMissing, .ffmpegMissing: "shippingbox"
        default: "exclamationmark.triangle.fill"
        }
    }

    /// Whether retrying without changing anything has a realistic chance of succeeding.
    var isWorthRetrying: Bool {
        switch kind {
        case .network, .rateLimited, .postProcessing, .unknown, .fileSystem: true
        default: false
        }
    }

    // MARK: - Classification

    /// Derives a failure from the lines yt-dlp printed.
    ///
    /// Matching is done on lowercase substrings because yt-dlp's wording differs per extractor
    /// and changes between releases; the ordering below puts the more specific checks first.
    static func classify(logLines: [String], exitCode: Int32) -> DownloadFailure {
        let errorLines = logLines.filter {
            let lower = $0.lowercased()
            return lower.hasPrefix("error") || lower.contains("error:")
        }
        let relevant = errorLines.last ?? logLines.last
        let haystack = (errorLines.isEmpty ? logLines.suffix(20) : errorLines.suffix(5))
            .joined(separator: "\n")
            .lowercased()

        let kind: Kind

        switch true {
        case haystack.contains("confirm you") && haystack.contains("bot"),
             haystack.contains("sign in to confirm"):
            kind = .botCheck
        case haystack.contains("http error 429"), haystack.contains("too many requests"):
            kind = .rateLimited
        case haystack.contains("members-only"), haystack.contains("private video"),
             haystack.contains("this video is private"):
            kind = .privateOrMembersOnly
        case haystack.contains("age-restricted"), haystack.contains("age restricted"),
             haystack.contains("inappropriate for some users"):
            kind = .ageRestricted
        case haystack.contains("login required"), haystack.contains("requires authentication"),
             haystack.contains("account") && haystack.contains("password"),
             haystack.contains("use --cookies"), haystack.contains("--cookies-from-browser"):
            kind = .authenticationRequired
        // Covers both "not available in your country" and YouTube's actual phrasing,
        // "The uploader has not made this video available in your country".
        case haystack.contains("available in your country"),
             haystack.contains("geo restricted"), haystack.contains("geo-restricted"),
             haystack.contains("blocked it in your country"),
             haystack.contains("not available from your location"):
            kind = .geoRestricted
        case haystack.contains("video unavailable"), haystack.contains("has been removed"),
             haystack.contains("no longer available"), haystack.contains("does not exist"),
             haystack.contains("account associated with this video has been terminated"):
            kind = .unavailable
        case haystack.contains("unsupported url"), haystack.contains("no suitable extractor"):
            kind = .unsupportedSite
        case haystack.contains("is not a valid url"), haystack.contains("invalid url"):
            kind = .invalidURL
        case haystack.contains("ffmpeg not found"), haystack.contains("ffmpeg is not installed"),
             haystack.contains("you have requested merging") && haystack.contains("ffmpeg"),
             haystack.contains("ffprobe and ffmpeg not found"):
            kind = .ffmpegMissing
        case haystack.contains("no space left"), haystack.contains("disk full"):
            kind = .diskFull
        case haystack.contains("permission denied"), haystack.contains("read-only file system"),
             haystack.contains("unable to open for writing"), haystack.contains("unable to create directory"):
            kind = .fileSystem
        case haystack.contains("postprocessing:"), haystack.contains("post-processing"),
             haystack.contains("conversion failed"):
            kind = .postProcessing
        case haystack.contains("urlopen error"), haystack.contains("connection reset"),
             haystack.contains("temporary failure in name resolution"),
             haystack.contains("unable to download webpage"), haystack.contains("timed out"),
             haystack.contains("network is unreachable"), haystack.contains("connection refused"),
             haystack.contains("ssl:"), haystack.contains("certificate verify failed"):
            kind = .network
        default:
            kind = .unknown
        }

        return DownloadFailure(kind: kind, underlyingMessage: cleaned(relevant))
    }

    /// Strips yt-dlp's `ERROR: ` prefix and the trailing hints it appends.
    private static func cleaned(_ line: String?) -> String? {
        guard var line = line?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else {
            return nil
        }
        for prefix in ["ERROR: ", "WARNING: "] where line.hasPrefix(prefix) {
            line.removeFirst(prefix.count)
        }
        if let range = line.range(of: "; please report this issue on") {
            line = String(line[line.startIndex..<range.lowerBound])
        }
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#if os(iOS)
extension DownloadFailure {

    /// Advice for the iOS app, which has no Homebrew, Terminal, Finder or ffmpeg, signs in with
    /// an imported cookies file rather than a browser's, and updates yt-dlp from its own settings.
    fileprivate var embeddedEngineRecoverySuggestion: String? {
        switch kind {
        case .toolMissing(let name) where name.lowercased().hasPrefix("ff"):
            Self.ffmpegUnavailableAdvice
        case .toolMissing:
            "The download engine built into the app couldn't start. Quit and reopen the app. If you "
                + "installed a yt-dlp update, Settings › Engine › Use Bundled Version goes back to the "
                + "version that came with the app."
        case .invalidURL:
            "Check the address and try again. It should start with http:// or https://."
        case .unsupportedSite:
            "yt-dlp has no extractor for this site. Updating yt-dlp in Settings › Engine › Check for "
                + "Updates sometimes adds support."
        case .unavailable:
            "The video may have been removed, made private, or never existed."
        case .privateOrMembersOnly:
            "If your account can watch it, sign in to the site in a browser and import its cookies.txt "
                + "file in Settings › Cookies."
        case .geoRestricted:
            "A proxy set in Advanced Options may help."
        case .ageRestricted, .authenticationRequired:
            "Sign in to the site in a browser, then import a cookies.txt file in Settings › Cookies."
        case .botCheck:
            "Import a cookies.txt file in Settings › Cookies. Updating yt-dlp in Settings › Engine › "
                + "Check for Updates also helps, because these checks change often."
        case .rateLimited:
            "Wait a few minutes before retrying, or set a rate limit in Advanced Options."
        case .network:
            "Check your internet connection and try again."
        case .postProcessing:
            "The downloaded file couldn't be processed on this device. Try again with metadata and "
                + "artwork embedding turned off in Advanced Options, or choose M4A for audio."
        case .ffmpegMissing:
            Self.ffmpegUnavailableAdvice
        case .fileSystem:
            "Check that the filename template in Advanced Options stays inside the app's folder, "
                + "then try again."
        case .diskFull:
            "Free up space on this device, or clear partial downloads in Settings › Storage."
        case .cancelled:
            nil
        case .unknown:
            "Open the log for the full output from yt-dlp."
        }
    }

    private static let ffmpegUnavailableAdvice =
        "The requested processing needs ffmpeg, which iPhone and iPad don't have. Download MP4 video "
            + "or M4A audio instead, which the app can process on its own."
}
#endif
