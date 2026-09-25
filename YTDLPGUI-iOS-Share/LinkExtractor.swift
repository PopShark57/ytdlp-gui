import Foundation
import UniformTypeIdentifiers

/// Pulls web links out of what the user shared.
///
/// Apps share a link in one of two ways: as a URL attachment (Safari and most browsers) or as
/// text that contains one (the YouTube app, messaging apps, notes). Both are accepted, and text
/// is scanned with `NSDataDetector` so a link inside a sentence is found too.
///
/// Only `http` and `https` links survive: yt-dlp downloads from the web, and a file or `mailto:`
/// link handed to it could only fail.
@MainActor
enum LinkExtractor {

    /// The most links handed over at once, matching the activation rule's
    /// `NSExtensionActivationSupportsWebURLWithMaxCount`.
    nonisolated static let maximumLinkCount = 10

    /// Every distinct web link in `items`, in the order they were shared, up to `maximumLinkCount`.
    static func webLinks(in items: [NSExtensionItem]) async -> [String] {
        var links: [String] = []
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            links = merged(links, await webLinks(in: provider))
            if links.count >= maximumLinkCount { return links }
        }
        if links.isEmpty {
            // A few apps put the shared text on the item itself rather than in an attachment.
            let bodies = items.compactMap { $0.attributedContentText?.string }
            links = merged(links, bodies.flatMap(webLinks(inText:)))
        }
        return links
    }

    private static func webLinks(in provider: NSItemProvider) async -> [String] {
        // Text first: an app sharing a string that happens to parse as a URL registers it as a
        // URL too, and only the text keeps several links, one per line, apart.
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = await loadText(from: provider) {
            let links = webLinks(inText: text)
            if !links.isEmpty { return links }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = await loadURL(from: provider),
           let link = webLink(from: url) {
            return [link]
        }
        return []
    }

    // The completion handlers are `@Sendable` and called on a background queue; they only
    // resume the continuation with a value type, so nothing non-Sendable leaves the provider.

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        let url = await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
        if let url { return url }
        return await loadRegisteredItem(conformingTo: .url, from: provider).flatMap { URL(string: $0) }
    }

    private static func loadText(from provider: NSItemProvider) async -> String? {
        let text = await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                continuation.resume(returning: text)
            }
        }
        if let text { return text }
        return await loadRegisteredItem(conformingTo: .plainText, from: provider)
    }

    /// The fallback for items registered the pre-iOS 11 way (`registerItem(forTypeIdentifier:)`
    /// or `init(item:typeIdentifier:)`), which is still how many apps hand text over.
    /// `loadObject` can't coerce those, even when `canLoadObject` says it can; `loadItem` returns
    /// whatever object the sharing app registered.
    private static func loadRegisteredItem(conformingTo type: UTType, from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                continuation.resume(returning: string(fromRegisteredItem: item))
            }
        }
    }

    private nonisolated static func string(fromRegisteredItem item: (any NSSecureCoding)?) -> String? {
        switch item {
        case let url as URL: url.absoluteString
        case let string as String: string
        case let attributed as NSAttributedString: attributed.string
        case let data as Data: String(data: data, encoding: .utf8)
        default: nil
        }
    }

    // MARK: - Filtering

    /// `url` as a string, if it is a web link yt-dlp could download from.
    nonisolated static func webLink(from url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty else { return nil }
        return url.absoluteString
    }

    /// Every web link in `text`, in order of appearance.
    nonisolated static func webLinks(inText text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, range: range).compactMap { match in
            match.url.flatMap(webLink(from:))
        }
    }

    /// `existing` followed by whatever in `new` it doesn't already contain, capped at
    /// `maximumLinkCount`.
    nonisolated static func merged(_ existing: [String], _ new: [String]) -> [String] {
        var result = existing
        var seen = Set(existing)
        for link in new where result.count < maximumLinkCount && seen.insert(link).inserted {
            result.append(link)
        }
        return result
    }

    /// A short rendering for the sheet: the host without `www.`, then the path.
    ///
    /// The same rule as the app's `URLDetection.displayString`, which the extension can't link.
    nonisolated static func displayString(for link: String) -> String {
        guard let components = URLComponents(string: link), let host = components.host else {
            return link
        }
        let shortHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = components.path
        return path.isEmpty || path == "/" ? shortHost : shortHost + path
    }
}
