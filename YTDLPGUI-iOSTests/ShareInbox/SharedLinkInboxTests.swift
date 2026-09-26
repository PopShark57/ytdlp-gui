import Foundation
import Testing

@testable import YTDLPGUI_iOS

/// The entries here are written as literal JSON, the way the Share extension writes them, so
/// the tests also pin the wire format the two targets share.
@Suite("Share extension inbox")
final class SharedLinkInboxTests {

    private let directory: URL
    /// A fixed "now", so ages don't depend on when the tests run.
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "SharedLinkInboxTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - The shared format

    @Test("What the extension writes is what the app reads")
    func sharedFormatRoundTrip() throws {
        let created = try Date("2026-09-20T10:15:00Z", strategy: .iso8601)
        let entry = ShareInboxFormat.Entry(urls: ["https://example.com/a"], kind: "audio", created: created)
        let data = try ShareInboxFormat.encode(entry)
        #expect(String(decoding: data, as: UTF8.self)
            == #"{"created":"2026-09-20T10:15:00Z","kind":"audio","urls":["https://example.com/a"],"version":1}"#)
        #expect(try SharedLinkInbox.decode(data) == SharedLink(urls: ["https://example.com/a"], kind: .audio, created: created))

        // No kind is written as an explicit null.
        let withoutKind = try ShareInboxFormat.encode(ShareInboxFormat.Entry(urls: ["https://example.com/a"], kind: nil, created: created))
        #expect(String(decoding: withoutKind, as: UTF8.self).contains(#""kind":null"#))
        #expect(try SharedLinkInbox.decode(withoutKind).kind == nil)
    }

    @Test("Entry file names sort by age")
    func fileNames() throws {
        let id = try #require(UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
        #expect(ShareInboxFormat.fileName(for: now, id: id) == "20260921T141320.000Z-6F9619FF-8B86-D011-B42D-00C04FC964FF.json")
        let names = [now.addingTimeInterval(0.5), now, now.addingTimeInterval(10)].map { ShareInboxFormat.fileName(for: $0) }
        #expect(names.sorted() == [names[1], names[0], names[2]])
    }

    // MARK: - Round trip

    @Test("An entry in the extension's format comes back intact, and is deleted")
    func roundTrip() throws {
        try write(
            #"{"created":"2026-09-20T10:15:00Z","kind":"audio","urls":["https://www.youtube.com/watch?v=dQw4w9WgXcQ","https://youtu.be/abc"],"version":1}"#,
            named: "20260920T101500.250Z-6F9619FF-8B86-D011-B42D-00C04FC964FF.json"
        )
        let created = try Date("2026-09-20T10:15:00Z", strategy: .iso8601)

        let links = SharedLinkInbox.drain(from: directory, now: created.addingTimeInterval(3_600))

        #expect(links == [
            SharedLink(
                urls: ["https://www.youtube.com/watch?v=dQw4w9WgXcQ", "https://youtu.be/abc"],
                kind: .audio,
                created: created
            ),
        ])
        #expect(try remainingFiles().isEmpty)
    }

    @Test("Escaped slashes, as a default JSONEncoder writes them, decode the same")
    func escapedSlashes() throws {
        try writeEntry(urlsJSON: #"["https:\/\/example.com\/video"]"#, kind: "\"video\"", created: now)
        let links = SharedLinkInbox.drain(from: directory, now: now)
        #expect(links.map(\.urls) == [["https://example.com/video"]])
        #expect(links.first?.kind == .video)
    }

    @Test("A null, missing or unknown kind means no kind", arguments: ["null", "\"gif\"", nil])
    func kindWithoutMeaning(kindJSON: String?) throws {
        try writeEntry(urls: ["https://example.com/v"], kind: kindJSON, created: now)
        let links = SharedLinkInbox.drain(from: directory, now: now)
        #expect(links.count == 1)
        #expect(links.first?.kind == nil)
    }

    @Test("Only http and https links survive, trimmed and without duplicates")
    func onlyWebLinks() throws {
        try writeEntry(
            urls: [
                "ftp://example.com/a",
                "javascript:alert(1)",
                "file:///etc/passwd",
                "  https://example.com/video\n",
                "https://",
                "not a url",
                "HTTP://EXAMPLE.COM/UPPER",
                "https://example.com/video",
            ],
            kind: "\"video\"",
            created: now
        )
        let links = SharedLinkInbox.drain(from: directory, now: now)
        #expect(links.map(\.urls) == [["https://example.com/video", "HTTP://EXAMPLE.COM/UPPER"]])
    }

    @Test("Timestamps with fractional seconds or an offset are accepted")
    func timestampVariants() throws {
        try write(
            #"{"created":"2026-09-20T10:15:00.500Z","kind":null,"urls":["https://example.com/a"],"version":1}"#,
            named: "a.json"
        )
        try write(
            #"{"created":"2026-09-20T12:15:01+02:00","kind":null,"urls":["https://example.com/b"],"version":1}"#,
            named: "b.json"
        )
        let reference = try Date("2026-09-20T10:15:00Z", strategy: .iso8601)

        let links = SharedLinkInbox.drain(from: directory, now: reference)

        #expect(links.map(\.created) == [reference.addingTimeInterval(0.5), reference.addingTimeInterval(1)])
    }

    // MARK: - Garbage

    @Test("Unreadable entries are deleted and skipped, without losing the good one")
    func garbageEntries() throws {
        let garbage: [String] = [
            "",
            "not json at all",
            "[1, 2, 3]",
            #"{"version":1}"#,
            #"{"created":"2026-09-20T10:15:00Z","kind":null,"urls":["https://example.com"],"version":2}"#,
            #"{"created":"yesterday","kind":null,"urls":["https://example.com"],"version":1}"#,
            #"{"created":"2026-09-20T10:15:00Z","kind":null,"urls":[1, 2],"version":1}"#,
            #"{"created":"2026-09-20T10:15:00Z","kind":7,"urls":["https://example.com"],"version":1}"#,
            #"{"created":"2026-09-20T10:15:00Z","kind":null,"urls":["mailto:someone@example.com"],"version":1}"#,
            #"{"created":"2026-09-20T10:15:00Z","kind":null,"urls":[],"version":1}"#,
        ]
        for (index, body) in garbage.enumerated() {
            try write(body, named: "garbage-\(index).json")
        }
        let oversized = #"{"created":"2026-09-20T10:15:00Z","kind":null,"urls":["https://example.com"],"version":1}"#
            + String(repeating: " ", count: SharedLinkInbox.maximumEntrySize)
        try write(oversized, named: "oversized.json")
        try writeEntry(urls: ["https://example.com/good"], kind: "\"video\"", created: now)

        let links = SharedLinkInbox.drain(from: directory, now: now)

        #expect(links.map(\.urls) == [["https://example.com/good"]])
        #expect(try remainingFiles().isEmpty)
    }

    @Test("Files that aren't entries are left alone")
    func nonEntriesUntouched() throws {
        // What an atomic write in progress looks like, a hidden file, a stray file, and a folder.
        let inFlight = "20260920T101500.250Z-6F9619FF-8B86-D011-B42D-00C04FC964FF.json.sb-897aa19c-lhWdaL"
        try write("{", named: inFlight)
        try write("", named: ".DS_Store")
        try write("hello", named: "notes.txt")
        try FileManager.default.createDirectory(
            at: directory.appending(path: "folder.json", directoryHint: .isDirectory),
            withIntermediateDirectories: false
        )

        let links = SharedLinkInbox.drain(from: directory, now: now)

        #expect(links.isEmpty)
        #expect(try remainingFiles() == [".DS_Store", inFlight, "folder.json", "notes.txt"])
    }

    @Test("A missing inbox folder reads as empty")
    func missingDirectory() {
        let missing = directory.appending(path: "does-not-exist", directoryHint: .isDirectory)
        #expect(SharedLinkInbox.drain(from: missing, now: now).isEmpty)
    }

    @Test("Draining twice doesn't hand the same links over again")
    func drainIsDestructive() throws {
        try writeEntry(urls: ["https://example.com/once"], kind: nil, created: now)
        #expect(SharedLinkInbox.drain(from: directory, now: now).count == 1)
        #expect(SharedLinkInbox.drain(from: directory, now: now).isEmpty)
    }

    // MARK: - Ordering

    @Test("Entries come back oldest first, whatever order they were written in")
    func oldestFirst() throws {
        for offset in [20.0, 0, 10, 30] {
            try writeEntry(
                urls: ["https://example.com/\(Int(offset))"],
                kind: nil,
                created: now.addingTimeInterval(offset)
            )
        }

        let links = SharedLinkInbox.drain(from: directory, now: now.addingTimeInterval(60))

        #expect(links.map(\.urls) == [
            ["https://example.com/0"],
            ["https://example.com/10"],
            ["https://example.com/20"],
            ["https://example.com/30"],
        ])
    }

    @Test("Within one second, the file name's milliseconds decide the order")
    func sameSecondOrderedByName() throws {
        let body = { (path: String) in
            #"{"created":"2026-09-20T10:15:00Z","kind":null,"urls":["https://example.com/"# + path + #""],"version":1}"#
        }
        try write(body("second"), named: "20260920T101500.900Z-00000000-0000-0000-0000-000000000001.json")
        try write(body("first"), named: "20260920T101500.100Z-FFFFFFFF-0000-0000-0000-000000000002.json")
        let reference = try Date("2026-09-20T10:15:00Z", strategy: .iso8601)

        let links = SharedLinkInbox.drain(from: directory, now: reference)

        #expect(links.map(\.urls) == [["https://example.com/first"], ["https://example.com/second"]])
    }

    // MARK: - Expiry

    @Test("Entries older than a week are deleted instead of acted on")
    func expiry() throws {
        let day: TimeInterval = 24 * 60 * 60
        try writeEntry(urls: ["https://example.com/stale"], kind: "\"video\"", created: now.addingTimeInterval(-8 * day))
        try writeEntry(urls: ["https://example.com/fresh"], kind: "\"video\"", created: now.addingTimeInterval(-6 * day))

        let links = SharedLinkInbox.drain(from: directory, now: now)

        #expect(links.map(\.urls) == [["https://example.com/fresh"]])
        #expect(try remainingFiles().isEmpty)
    }

    // MARK: - Helpers

    private func write(_ body: String, named name: String) throws {
        try Data(body.utf8).write(to: directory.appending(path: name), options: .atomic)
    }

    /// Writes an entry named the way the extension names them. `kind` is raw JSON (`"\"video\""`,
    /// `"null"`), or `nil` to leave the key out.
    private func writeEntry(urls: [String], kind: String?, created: Date) throws {
        let urlsJSON = String(decoding: try JSONEncoder().encode(urls), as: UTF8.self)
        try writeEntry(urlsJSON: urlsJSON, kind: kind, created: created)
    }

    private func writeEntry(urlsJSON: String, kind: String?, created: Date) throws {
        var fields = [
            #""created":"\#(created.formatted(.iso8601))""#,
            #""urls":\#(urlsJSON)"#,
            #""version":1"#,
        ]
        if let kind { fields.append(#""kind":\#(kind)"#) }
        try write("{" + fields.joined(separator: ",") + "}", named: Self.fileName(for: created))
    }

    private static func fileName(for date: Date) -> String {
        let basic = Date.ISO8601FormatStyle(
            dateSeparator: .omitted,
            dateTimeSeparator: .standard,
            timeSeparator: .omitted,
            timeZoneSeparator: .omitted,
            includingFractionalSeconds: true,
            timeZone: .gmt
        )
        return date.formatted(basic) + "-" + UUID().uuidString + ".json"
    }

    private func remainingFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).sorted()
    }
}
