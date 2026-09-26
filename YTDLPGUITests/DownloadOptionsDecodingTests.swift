import Foundation
import Testing

@testable import YTDLPGUI

/// Stored options always come from some other build — an older one, a newer one, or the other
/// platform — and a history entry that fails to decode takes the whole history file with it.
@Suite("Download options decoding")
struct DownloadOptionsDecodingTests {

    private func decode(_ json: String) throws -> DownloadOptions {
        try JSONDecoder().decode(DownloadOptions.self, from: Data(json.utf8))
    }

    /// One change per stored property, each away from its default.
    private static let changes: [(key: String, apply: @Sendable (inout DownloadOptions) -> Void)] = [
        ("kind", { $0.kind = .audio }),
        ("videoQuality", { $0.videoQuality = .hd720 }),
        ("container", { $0.container = .mkv }),
        ("audioFormat", { $0.audioFormat = .alac }),
        ("audioQuality", { $0.audioQuality = .kbps96 }),
        ("outputDirectory", { $0.outputDirectory = URL(fileURLWithPath: "/tmp/elsewhere") }),
        ("outputTemplate", { $0.outputTemplate = "%(id)s.%(ext)s" }),
        ("subtitleMode", { $0.subtitleMode = .automatic }),
        ("subtitleLanguages", { $0.subtitleLanguages = "de,fr" }),
        ("embedSubtitles", { $0.embedSubtitles = true }),
        ("embedThumbnail", { $0.embedThumbnail = true }),
        ("embedMetadata", { $0.embedMetadata = true }),
        ("embedChapters", { $0.embedChapters = true }),
        ("writeThumbnail", { $0.writeThumbnail = true }),
        ("writeInfoJSON", { $0.writeInfoJSON = true }),
        ("sponsorBlockMode", { $0.sponsorBlockMode = .mark }),
        ("sponsorBlockCategories", { $0.sponsorBlockCategories = [.intro, .outro, .music_offtopic] }),
        ("downloadPlaylist", { $0.downloadPlaylist = true }),
        ("playlistItems", { $0.playlistItems = "2-4" }),
        ("useDownloadArchive", { $0.useDownloadArchive = true }),
        ("downloadArchivePath", { $0.downloadArchivePath = "/tmp/archive.txt" }),
        ("cookieBrowser", { $0.cookieBrowser = .vivaldi }),
        ("cookieFilePath", { $0.cookieFilePath = "/tmp/cookies.txt" }),
        ("rateLimit", { $0.rateLimit = "3M" }),
        ("concurrentFragments", { $0.concurrentFragments = 8 }),
        ("proxy", { $0.proxy = "http://proxy.test:3128" }),
        ("userAgent", { $0.userAgent = "Agent/2" }),
        ("restrictFilenames", { $0.restrictFilenames = true }),
        ("overwriteExisting", { $0.overwriteExisting = true }),
        ("customArguments", { $0.customArguments = "--retries 9" }),
        ("ignoreUserConfig", { $0.ignoreUserConfig = false }),
    ]

    @Test("An empty object decodes to the defaults")
    func emptyObject() throws {
        #expect(try decode("{}") == DownloadOptions())
    }

    @Test("Every stored property survives a round trip")
    func everyPropertyRoundTrips() throws {
        // A property the decoder forgot would come back as its default and fail here, and a new
        // property without an entry in `changes` fails the count check.
        let encoded = try JSONEncoder().encode(DownloadOptions())
        let keys = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any]).keys
        #expect(Set(keys) == Set(Self.changes.map(\.key)))

        var everything = DownloadOptions()
        for change in Self.changes {
            var single = DownloadOptions()
            change.apply(&single)
            #expect(single != DownloadOptions(), "\(change.key) must differ from its default")
            let decoded = try JSONDecoder().decode(DownloadOptions.self, from: JSONEncoder().encode(single))
            #expect(decoded == single, "\(change.key) was not decoded")
            change.apply(&everything)
        }
        let decoded = try JSONDecoder().decode(DownloadOptions.self, from: JSONEncoder().encode(everything))
        #expect(decoded == everything)
    }

    @Test("Options saved before the cookies file existed still load")
    func legacyJSONWithoutCookieFile() throws {
        // The shape the Mac app stored before `cookieFilePath` (and ALAC) were added.
        let legacy = """
        {
          "kind": "audio", "videoQuality": "fhd1080", "container": "mp4", "audioFormat": "mp3",
          "audioQuality": "kbps192", "outputDirectory": "file:///Users/me/Downloads/",
          "outputTemplate": "%(title)s.%(ext)s", "subtitleMode": "off", "subtitleLanguages": "en",
          "embedSubtitles": false, "embedThumbnail": true, "embedMetadata": true, "embedChapters": false,
          "writeThumbnail": false, "writeInfoJSON": false, "sponsorBlockMode": "remove",
          "sponsorBlockCategories": ["sponsor", "selfpromo"], "downloadPlaylist": false,
          "playlistItems": "", "useDownloadArchive": false, "downloadArchivePath": "",
          "cookieBrowser": "safari", "rateLimit": "", "concurrentFragments": 1, "proxy": "",
          "userAgent": "", "restrictFilenames": false, "overwriteExisting": false,
          "customArguments": "", "ignoreUserConfig": true
        }
        """
        let options = try decode(legacy)
        #expect(options.cookieFilePath == "")
        #expect(options.kind == .audio)
        #expect(options.audioFormat == .mp3)
        #expect(options.audioQuality == .kbps192)
        #expect(options.cookieBrowser == .safari)
        #expect(options.embedThumbnail)
        #expect(options.sponsorBlockMode == .remove)
        #expect(options.sponsorBlockCategories == [.sponsor, .selfpromo])
        #expect(options.outputDirectory.absoluteString == "file:///Users/me/Downloads/")
    }

    @Test("Unknown enum values fall back to the default instead of failing")
    func unknownEnumValues() throws {
        let options = try decode("""
        {
          "kind": "hologram", "videoQuality": "uhd4320", "container": "avi", "audioFormat": "aiff",
          "audioQuality": "lossless", "subtitleMode": "burned-in", "sponsorBlockMode": "skip",
          "cookieBrowser": "netscape", "proxy": "http://kept.test"
        }
        """)
        let defaults = DownloadOptions()
        #expect(options.kind == defaults.kind)
        #expect(options.videoQuality == defaults.videoQuality)
        #expect(options.container == defaults.container)
        #expect(options.audioFormat == defaults.audioFormat)
        #expect(options.audioQuality == defaults.audioQuality)
        #expect(options.subtitleMode == defaults.subtitleMode)
        #expect(options.sponsorBlockMode == defaults.sponsorBlockMode)
        #expect(options.cookieBrowser == defaults.cookieBrowser)
        // Known fields next to the bad ones are still read.
        #expect(options.proxy == "http://kept.test")
    }

    @Test("An unknown SponsorBlock category is dropped and the others kept")
    func unknownSponsorBlockCategory() throws {
        let options = try decode(#"{"sponsorBlockCategories": ["sponsor", "chapter", "intro", "poi_highlight"]}"#)
        #expect(options.sponsorBlockCategories == [.sponsor, .intro])

        // An explicit empty choice is respected rather than replaced by the default.
        #expect(try decode(#"{"sponsorBlockCategories": []}"#).sponsorBlockCategories.isEmpty)
    }

    @Test("Wrongly typed and null values fall back to the default")
    func wrongTypes() throws {
        let options = try decode("""
        {
          "concurrentFragments": "four", "embedMetadata": "yes", "outputTemplate": 7,
          "sponsorBlockCategories": "sponsor", "outputDirectory": 12, "proxy": null, "userAgent": "UA/1"
        }
        """)
        let defaults = DownloadOptions()
        #expect(options.concurrentFragments == defaults.concurrentFragments)
        #expect(options.embedMetadata == defaults.embedMetadata)
        #expect(options.outputTemplate == defaults.outputTemplate)
        #expect(options.sponsorBlockCategories == defaults.sponsorBlockCategories)
        #expect(options.outputDirectory == defaults.outputDirectory)
        #expect(options.proxy == defaults.proxy)
        #expect(options.userAgent == "UA/1")
    }

    @Test("Something that isn't an object at all is still reported as an error")
    func notAnObject() {
        #expect(throws: DecodingError.self) { try decode(#"["kind", "audio"]"#) }
        #expect(throws: DecodingError.self) { try decode(#""video""#) }
    }

    @Test("A history entry holding options from a newer build still loads")
    func historyEntryWithNewerOptions() throws {
        let json = """
        [{
          "id": "7D8E0A36-3E2B-4C39-9A0F-6C2E3A0D5B11", "title": "Clip", "sourceURL": "https://example.com/v",
          "outputPath": "/tmp/Clip.mp4", "date": "2026-09-01T10:00:00Z", "formatSummary": "Best",
          "kind": "video", "succeeded": true,
          "options": {"kind": "video", "videoQuality": "uhd4320", "futureFlag": true, "cookieFilePath": "/tmp/c.txt"}
        }]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([HistoryEntry].self, from: Data(json.utf8))
        #expect(entries.count == 1)
        #expect(entries.first?.options?.videoQuality == .best)
        #expect(entries.first?.options?.cookieFilePath == "/tmp/c.txt")
    }

    @Test("A history entry saved before downloadID, outputPaths and removedSecretOptions still loads")
    func historyEntryFromBeforeNewFields() throws {
        let json = """
        [{
          "id": "7D8E0A36-3E2B-4C39-9A0F-6C2E3A0D5B11", "title": "Clip", "sourceURL": "https://example.com/v",
          "outputPath": "/tmp/Clip.mp4", "date": "2026-09-01T10:00:00Z", "formatSummary": "Best",
          "kind": "video", "succeeded": true, "fileSizeBytes": 2048
        }]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try #require(try decoder.decode([HistoryEntry].self, from: Data(json.utf8)).first)
        #expect(entry.downloadID == nil)
        #expect(entry.outputPaths == nil)
        #expect(entry.removedSecretOptions == nil)
        #expect(entry.outputPath == "/tmp/Clip.mp4")
        // Only the one file it recorded.
        #expect(entry.outputURLs.map { $0.path(percentEncoded: false) } == ["/tmp/Clip.mp4"])
    }

    @Test("The new history fields survive a round trip, and the file list is capped")
    func historyEntryNewFieldsRoundTrip() throws {
        let downloadID = UUID()
        let paths = (1...600).map { "/tmp/Playlist/\($0).mp4" }
        let entry = HistoryEntry(
            downloadID: downloadID,
            title: "Playlist",
            sourceURL: "https://example.com/list",
            outputPath: paths[0],
            outputPaths: paths,
            formatSummary: "Best",
            kind: .video,
            succeeded: true,
            removedSecretOptions: ["--password"]
        )
        #expect(entry.outputPaths?.count == HistoryEntry.maximumStoredOutputPaths)
        #expect(entry.outputPaths?.first == paths[0])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HistoryEntry.self, from: encoder.encode(entry))
        #expect(decoded.downloadID == downloadID)
        #expect(decoded.outputPaths == entry.outputPaths)
        #expect(decoded.removedSecretOptions == ["--password"])
        #expect(decoded.outputURLs.count == HistoryEntry.maximumStoredOutputPaths)
    }
}
