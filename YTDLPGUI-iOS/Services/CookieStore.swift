import Foundation
import Observation
import os

/// The imported `cookies.txt`, passed to yt-dlp with `--cookies`.
///
/// On a Mac, yt-dlp reads cookies straight out of a browser profile. An iOS app can't see
/// Safari's cookies, so the person exports a Netscape-format file from a desktop browser and
/// imports it here. The app keeps its own validated copy, because a file picked with
/// `fileImporter` is only readable for as long as the security-scoped access lasts.
@MainActor
@Observable
final class CookieStore {

    struct Summary: Codable, Equatable, Sendable {
        var cookieCount: Int
        /// Distinct domains, sorted, without a leading dot.
        var domains: [String]
        var importedAt: Date
    }

    private(set) var summary: Summary?
    /// Why the last import was rejected, if it was.
    private(set) var lastError: String?

    /// Where the validated copy is kept.
    let storedFileURL: URL

    private let defaults: UserDefaults
    private let logger = AppLog.cookies

    private static let summaryKey = "importedCookiesSummary"
    /// Real cookie exports are a few hundred kilobytes at most; anything far larger was picked
    /// by mistake and isn't worth reading into memory.
    private static let maximumFileSize = 8 * 1024 * 1024

    init(fileURL: URL? = nil, defaults: UserDefaults = .standard) {
        storedFileURL = fileURL ?? Self.defaultFileURL()
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.summaryKey) {
            summary = try? JSONDecoder().decode(Summary.self, from: data)
        }
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return base
            .appending(path: "Cookies", directoryHint: .isDirectory)
            .appending(path: "cookies.txt")
    }

    /// The stored file, or `nil` when none has been imported or it has gone missing.
    var cookieFileURL: URL? {
        guard summary != nil, storedFileExists else { return nil }
        return storedFileURL
    }

    /// Cookies were imported, but the copy is gone (e.g. restored from a backup that excluded it),
    /// so downloads are running without them.
    var isStoredFileMissing: Bool {
        summary != nil && !storedFileExists
    }

    private var storedFileExists: Bool {
        FileManager.default.fileExists(atPath: storedFileURL.path(percentEncoded: false))
    }

    /// Validates a Netscape-format cookies file (e.g. from `fileImporter`) and keeps a copy.
    func importCookies(from url: URL) {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isScoped { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let data = try readFile(at: url)
            let parsed = try CookieFile.parse(data)
            try store(parsed.normalizedText)
            let summary = Summary(
                cookieCount: parsed.cookieCount,
                domains: parsed.domains,
                importedAt: Date()
            )
            self.summary = summary
            if let encoded = try? JSONEncoder().encode(summary) {
                defaults.set(encoded, forKey: Self.summaryKey)
            }
            lastError = nil
        } catch let error as CookieFile.ValidationError {
            lastError = error.message
        } catch {
            logger.error("Cookie import failed: \(error.localizedDescription, privacy: .public)")
            lastError = "The cookies file couldn't be imported: \(error.localizedDescription)"
        }
    }

    func removeCookies() {
        do {
            try FileManager.default.removeItem(at: storedFileURL)
        } catch CocoaError.fileNoSuchFile {
            // Already gone, which is the goal.
        } catch {
            logger.error("Couldn't delete cookies: \(error.localizedDescription, privacy: .public)")
        }
        summary = nil
        lastError = nil
        defaults.removeObject(forKey: Self.summaryKey)
    }

    // MARK: - Files

    private func readFile(at url: URL) throws -> Data {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values?.fileSize, size > Self.maximumFileSize {
            throw CookieFile.ValidationError.tooLarge
        }
        return try Data(contentsOf: url)
    }

    private func store(_ text: String) throws {
        let directory = storedFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: storedFileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        // Session cookies are credentials; they shouldn't travel in device backups.
        var fileURL = storedFileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? fileURL.setResourceValues(values)
    }
}

// MARK: - Netscape cookie file format

/// Validation and normalisation of Netscape-format (`cookies.txt`) files.
///
/// The rules follow what yt-dlp's loader (`YoutubeDLCookieJar.load` on top of Python's
/// `MozillaCookieJar`) accepts, so a file that passes here also loads there, and a file that
/// wouldn't is rejected now with a reason instead of failing every download later.
enum CookieFile {

    struct Parsed: Equatable, Sendable {
        /// The file as it is stored: the header, then one line per cookie.
        var normalizedText: String
        var cookieCount: Int
        /// Distinct domains, sorted, lowercased, without a leading dot.
        var domains: [String]
    }

    enum ValidationError: Error, Equatable, Sendable {
        case notText
        case tooLarge
        case empty
        case json
        case noCookies
        case wrongFieldCount(line: Int, found: Int)
        case missingDomain(line: Int)
        case invalidExpiry(line: Int)

        var message: String {
            switch self {
            case .notText:
                "That isn't a text file. Choose the cookies.txt file your browser extension exported."
            case .tooLarge:
                "That file is far too large to be a cookies file. Choose the cookies.txt file your browser extension exported."
            case .empty:
                "The file is empty. Export your cookies again and import the new file."
            case .json:
                "This is a JSON cookie export. Export again and choose the Netscape (cookies.txt) format."
            case .noCookies:
                "The file doesn't contain any cookies. Sign in to the site in your browser, then export again."
            case .wrongFieldCount(let line, let found):
                "Line \(line) isn't in cookies.txt format: it has \(found) tab-separated field\(found == 1 ? "" : "s") instead of 7. Export the file again without editing it."
            case .missingDomain(let line):
                "Line \(line) has no domain. Export the file again without editing it."
            case .invalidExpiry(let line):
                "Line \(line) has an expiry date that isn't a number. Export the file again without editing it."
            }
        }
    }

    /// The first line Python's `MozillaCookieJar` insists on. Many exporters include it; it is
    /// added when missing so the stored copy always loads.
    static let header = "# Netscape HTTP Cookie File"
    /// Marks a cookie that JavaScript can't read. Not a comment, despite the `#`.
    static let httpOnlyPrefix = "#HttpOnly_"
    static let fieldCount = 7

    static func parse(_ data: Data) throws(ValidationError) -> Parsed {
        guard var text = String(data: data, encoding: .utf8) else { throw .notText }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return try parse(text)
    }

    static func parse(_ text: String) throws(ValidationError) -> Parsed {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") { throw .json }

        var cookieLines: [String] = []
        var domains = Set<String>()

        // Split on any newline: Swift treats "\r\n" as a single Character, so splitting on "\n"
        // alone would leave a file exported on Windows as one enormous line.
        for (offset, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let lineNumber = offset + 1
            var line = String(rawLine)

            var prefix = ""
            if line.hasPrefix(httpOnlyPrefix) {
                prefix = httpOnlyPrefix
                line.removeFirst(httpOnlyPrefix.count)
            }
            let content = line.trimmingCharacters(in: .whitespaces)
            if content.isEmpty || content.hasPrefix("#") { continue }

            var fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == fieldCount else {
                throw .wrongFieldCount(line: lineNumber, found: fields.count)
            }
            let domain = fields[0].trimmingCharacters(in: .whitespaces)
            guard !domain.isEmpty, domain != "." else { throw .missingDomain(line: lineNumber) }
            let expiry = fields[4]
            guard expiry.isEmpty || isNumber(expiry) else { throw .invalidExpiry(line: lineNumber) }

            // Python asserts that this flag matches the domain's leading dot and rejects the
            // whole file otherwise. Exporters disagree on the flag; the dot is what matters.
            fields[1] = domain.hasPrefix(".") ? "TRUE" : "FALSE"

            cookieLines.append(prefix + fields.joined(separator: "\t"))
            let bareDomain = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            domains.insert(bareDomain.lowercased())
        }

        guard !cookieLines.isEmpty else { throw .noCookies }

        let normalized = ([header, ""] + cookieLines).joined(separator: "\n") + "\n"
        return Parsed(normalizedText: normalized, cookieCount: cookieLines.count, domains: domains.sorted())
    }

    /// yt-dlp accepts an integer or decimal number of seconds.
    private static func isNumber(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }
}
