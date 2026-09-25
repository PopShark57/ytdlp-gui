import Foundation
import Testing
@testable import YTDLPGUI_iOS

@MainActor
@Suite("Cookies file")
struct CookieStoreTests {

    static let sampleFile = """
        # Netscape HTTP Cookie File
        # This is a generated file! Do not edit.

        .youtube.com\tTRUE\t/\tTRUE\t1790000000\tPREF\tf6=40000000
        .youtube.com\tTRUE\t/\tTRUE\t1790000000\tSID\tabc
        #HttpOnly_.youtube.com\tTRUE\t/\tTRUE\t1790000000\t__Secure-3PSID\txyz
        www.example.com\tFALSE\t/\tFALSE\t0\tsession\t
        """

    /// Imports `sampleFile` into the environment's cookie store.
    static func importSampleCookies(into env: AppTestEnvironment) throws {
        let source = env.root.appending(path: "cookies-export.txt")
        try Data(sampleFile.utf8).write(to: source)
        env.cookies.importCookies(from: source)
        #expect(env.cookies.lastError == nil)
    }

    // MARK: - Validation

    @Test("A browser export is counted by cookie and domain")
    func validFile() throws {
        let parsed = try CookieFile.parse(Self.sampleFile)
        #expect(parsed.cookieCount == 4)
        #expect(parsed.domains == ["www.example.com", "youtube.com"])
        #expect(parsed.normalizedText.hasPrefix("# Netscape HTTP Cookie File\n"))
    }

    @Test("#HttpOnly_ lines are cookies, not comments, and keep their prefix")
    func httpOnlyLines() throws {
        let text = "#HttpOnly_.example.org\tTRUE\t/\tTRUE\t1790000000\tsid\tvalue\n# a real comment\n"
        let parsed = try CookieFile.parse(text)
        #expect(parsed.cookieCount == 1)
        #expect(parsed.domains == ["example.org"])
        #expect(parsed.normalizedText.contains("\n#HttpOnly_.example.org\tTRUE\t/"))
        #expect(!parsed.normalizedText.contains("a real comment"))
    }

    @Test("A missing header is added, Windows line endings are accepted, and the subdomain flag follows the dot")
    func normalisation() throws {
        let text = ".example.org\tFALSE\t/\tFALSE\t1790000000.5\ta\t1\r\nexample.net\tTRUE\t/\tFALSE\t\tb\t2\r\n"
        let parsed = try CookieFile.parse(text)
        let lines = parsed.normalizedText.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == "# Netscape HTTP Cookie File")
        #expect(lines.contains(".example.org\tTRUE\t/\tFALSE\t1790000000.5\ta\t1"))
        #expect(lines.contains("example.net\tFALSE\t/\tFALSE\t\tb\t2"))
        #expect(!parsed.normalizedText.contains("\r"))
    }

    @Test("A malformed line is rejected with its line number")
    func invalidLine() {
        let text = "# Netscape HTTP Cookie File\n.example.org\tTRUE\t/\tTRUE\t1790000000\tname\n"
        #expect(throws: CookieFile.ValidationError.wrongFieldCount(line: 2, found: 6)) {
            try CookieFile.parse(text)
        }
        #expect(throws: CookieFile.ValidationError.invalidExpiry(line: 1)) {
            try CookieFile.parse(".example.org\tTRUE\t/\tTRUE\tnever\tname\tvalue")
        }
        #expect(throws: CookieFile.ValidationError.missingDomain(line: 1)) {
            try CookieFile.parse("\tTRUE\t/\tTRUE\t0\tname\tvalue")
        }
    }

    @Test("Empty, comment-only, JSON and binary files are rejected")
    func unusableFiles() {
        #expect(throws: CookieFile.ValidationError.empty) { try CookieFile.parse("  \n\n") }
        #expect(throws: CookieFile.ValidationError.noCookies) { try CookieFile.parse("# Netscape HTTP Cookie File\n# nothing\n") }
        #expect(throws: CookieFile.ValidationError.json) { try CookieFile.parse(#"[{"domain": ".youtube.com"}]"#) }
        #expect(throws: CookieFile.ValidationError.notText) { try CookieFile.parse(Data([0xFF, 0xFE, 0x00, 0xD8])) }
        #expect(CookieFile.ValidationError.json.message.contains("Netscape"))
    }

    // MARK: - Store

    @Test("Importing keeps a validated copy and a summary that survives relaunch")
    func importAndRemove() throws {
        let env = try AppTestEnvironment()
        #expect(env.cookies.summary == nil)
        #expect(env.cookies.cookieFileURL == nil)

        try Self.importSampleCookies(into: env)
        let summary = try #require(env.cookies.summary)
        #expect(summary.cookieCount == 4)
        #expect(summary.domains == ["www.example.com", "youtube.com"])
        #expect(env.cookies.cookieFileURL == env.cookies.storedFileURL)
        let stored = try String(contentsOf: env.cookies.storedFileURL, encoding: .utf8)
        #expect(stored.hasPrefix("# Netscape HTTP Cookie File"))

        let relaunched = CookieStore(fileURL: env.cookies.storedFileURL, defaults: env.defaults)
        #expect(relaunched.summary == summary)

        env.cookies.removeCookies()
        #expect(env.cookies.summary == nil)
        #expect(env.cookies.cookieFileURL == nil)
        #expect(!FileManager.default.fileExists(atPath: env.cookies.storedFileURL.path(percentEncoded: false)))
        #expect(CookieStore(fileURL: env.cookies.storedFileURL, defaults: env.defaults).summary == nil)
    }

    @Test("A rejected import explains why and keeps the cookies already imported")
    func rejectedImport() throws {
        let env = try AppTestEnvironment()
        try Self.importSampleCookies(into: env)
        let before = env.cookies.summary

        let bad = env.root.appending(path: "bad.txt")
        try Data("not a cookie file at all".utf8).write(to: bad)
        env.cookies.importCookies(from: bad)
        #expect(env.cookies.lastError == CookieFile.ValidationError.wrongFieldCount(line: 1, found: 1).message)
        #expect(env.cookies.summary == before)
        #expect(env.cookies.cookieFileURL != nil)
    }

    @Test("A stored file that disappeared is reported, not passed to yt-dlp")
    func missingStoredFile() throws {
        let env = try AppTestEnvironment()
        try Self.importSampleCookies(into: env)
        try FileManager.default.removeItem(at: env.cookies.storedFileURL)
        #expect(env.cookies.isStoredFileMissing)
        #expect(env.cookies.cookieFileURL == nil)
    }
}
