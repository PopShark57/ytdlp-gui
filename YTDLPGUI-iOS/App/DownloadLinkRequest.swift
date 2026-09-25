import Foundation

/// A `ytdlpgui://download?url=…&kind=video|audio` link from a web page, another app or a
/// Shortcut.
///
/// Such a link only ever fills in the Download screen. Any web page can open it, so it must never
/// be able to start a download, or touch anything else, by itself.
struct DownloadLinkRequest: Equatable, Sendable {

    static let scheme = "ytdlpgui"
    static let action = "download"

    /// The web links to download, in order, without duplicates. Never empty.
    var urls: [String]
    var kind: DownloadKind?

    /// Parses a `ytdlpgui://` link, or returns `nil` when it isn't one this app understands or
    /// carries no `http`/`https` link.
    ///
    /// Both `ytdlpgui://download?…` and `ytdlpgui:///download?…` are accepted. Each `url` item is
    /// one link; the value must be percent-encoded, as any URL inside a query must be.
    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == Self.scheme else { return nil }

        let host = components.host?.lowercased() ?? ""
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard host == Self.action || (host.isEmpty && path == Self.action) else { return nil }

        let items = components.queryItems ?? []
        var seen = Set<String>()
        let links = items
            .filter { $0.name.lowercased() == "url" }
            .compactMap { $0.value?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { URLDetection.isLikelyMediaURL($0) && seen.insert($0).inserted }
        guard !links.isEmpty else { return nil }

        urls = links
        kind = items
            .first { $0.name.lowercased() == "kind" }
            .flatMap { $0.value?.lowercased() }
            .flatMap(DownloadKind.init(rawValue:))
    }
}
