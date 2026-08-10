import Foundation

/// Recognises and extracts media URLs from arbitrary text.
///
/// Deliberately permissive about *which* site a URL points at: yt-dlp supports well over a
/// thousand extractors and gains more with every release, so refusing an unfamiliar host would
/// make the app less capable than the tool it drives. The only real check is that the text
/// looks like an `http(s)` URL.
enum URLDetection {

    /// Whether the string is usable as a download source.
    static func isLikelyMediaURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return false }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              host.contains(".") else { return false }
        return true
    }

    /// The first URL found anywhere in `text`.
    static func firstURL(in text: String) -> String? {
        allURLs(in: text).first
    }

    /// Every distinct URL in `text`, in the order they appear.
    ///
    /// Uses `NSDataDetector` so that URLs embedded in a sentence, an email or a list of lines
    /// are all picked up — dragging a link out of a browser or a chat app is a common way to
    /// get a URL into this app.
    static func allURLs(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // A single bare URL is by far the common case; skip the detector for it.
        if isLikelyMediaURL(trimmed) { return [trimmed] }

        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        var found: [String] = []
        var seen = Set<String>()

        detector.enumerateMatches(in: trimmed, options: [], range: range) { match, _, _ in
            guard let url = match?.url else { return }
            let scheme = url.scheme?.lowercased()
            guard scheme == "http" || scheme == "https" else { return }
            let absolute = url.absoluteString
            if seen.insert(absolute).inserted { found.append(absolute) }
        }
        return found
    }

    /// Splits multi-line pasted text into candidate URLs, one per line.
    static func urlsFromLines(_ text: String) -> [String] {
        let lines = text.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let direct = lines.filter(isLikelyMediaURL)
        return direct.isEmpty ? allURLs(in: text) : direct
    }

    /// A short, human-friendly rendering of a URL for narrow labels.
    static func displayString(for text: String) -> String {
        guard let components = URLComponents(string: text), let host = components.host else {
            return text
        }
        let path = components.path
        let shortHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return path.isEmpty || path == "/" ? shortHost : shortHost + path
    }
}
