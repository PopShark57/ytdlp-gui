import Foundation
import Testing

@testable import YTDLPGUI

/// Exercises the decoder against the shapes real extractors produce, including the loose typing
/// that makes a strict `Codable` model unworkable here.
@Suite("Media info decoding")
struct MediaInfoDecodingTests {

    // A trimmed but faithful copy of `yt-dlp --dump-single-json` output for a single video.
    private let singleVideoJSON = """
    {
      "_type": "video",
      "id": "jNQXAC9IVRw",
      "title": "Me at the zoo",
      "description": "The first video.",
      "uploader": "jawed",
      "channel": "jawed",
      "duration": 19,
      "thumbnail": "https://i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg",
      "webpage_url": "https://www.youtube.com/watch?v=jNQXAC9IVRw",
      "extractor_key": "Youtube",
      "extractor": "youtube",
      "width": 320,
      "height": 240,
      "upload_date": "20050424",
      "view_count": 403947630,
      "like_count": 19332854,
      "is_live": false,
      "live_status": "not_live",
      "availability": "public",
      "age_limit": 0,
      "chapters": [
        {"start_time": 0, "title": "Intro", "end_time": 5},
        {"start_time": 5, "title": "The cool thing", "end_time": 17}
      ],
      "subtitles": {"en": [], "de": []},
      "automatic_captions": {"en": [], "fr": [], "es": []},
      "formats": [
        {
          "format_id": "18", "ext": "mp4", "vcodec": "avc1.42001E", "acodec": "mp4a.40.2",
          "width": 320, "height": 240, "fps": 15, "tbr": 266.531, "asr": 44100,
          "filesize_approx": 635110, "format_note": "240p", "dynamic_range": "SDR"
        },
        {
          "format_id": "251", "ext": "webm", "vcodec": "none", "acodec": "opus",
          "abr": 128.5, "asr": 48000, "filesize": 320000
        },
        {
          "format_id": "137", "ext": "mp4", "vcodec": "avc1.640028", "acodec": "none",
          "width": 1920, "height": 1080, "fps": 60, "filesize": 9000000
        }
      ]
    }
    """

    private let playlistJSON = """
    {
      "_type": "playlist",
      "id": "PL123",
      "title": "My Playlist",
      "playlist_count": 3,
      "webpage_url": "https://example.com/playlist?list=PL123",
      "extractor_key": "Generic",
      "entries": [
        {"id": "a", "title": "First", "duration": 100, "url": "https://example.com/a",
         "thumbnail": "https://example.com/a.jpg"},
        {"id": "b", "title": "Second", "duration": 200.5, "webpage_url": "https://example.com/b"},
        {"id": "c", "title": "Third", "duration": null}
      ]
    }
    """

    // MARK: - Single video

    @Test("A single video decodes with all its headline fields")
    func decodesSingleVideo() throws {
        let info = try MediaInfoDecoder.decode(
            Data(singleVideoJSON.utf8),
            originalURL: "https://www.youtube.com/watch?v=jNQXAC9IVRw"
        )

        #expect(info.id == "jNQXAC9IVRw")
        #expect(info.title == "Me at the zoo")
        #expect(info.displayUploader == "jawed")
        #expect(info.duration == 19)
        #expect(info.width == 320)
        #expect(info.height == 240)
        #expect(info.extractor == "Youtube")
        #expect(info.viewCount == 403_947_630)
        #expect(info.isLive == false)
        #expect(info.chapterCount == 2)
        #expect(info.subtitleLanguages == ["de", "en"])
        #expect(info.automaticCaptionLanguages.count == 3)
        #expect(info.isPlaylist == false)
        #expect(info.thumbnailURL?.absoluteString.hasPrefix("https://i.ytimg.com") == true)
    }

    @Test("The upload date is parsed from yt-dlp's bare YYYYMMDD field")
    func parsesUploadDate() throws {
        let info = try MediaInfoDecoder.decode(Data(singleVideoJSON.utf8), originalURL: "u")
        let date = try #require(info.uploadDate)
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        #expect(components.year == 2005)
        #expect(components.month == 4)
        #expect(components.day == 24)
    }

    @Test("Formats are classified as video-only, audio-only or combined")
    func classifiesFormats() throws {
        let info = try MediaInfoDecoder.decode(Data(singleVideoJSON.utf8), originalURL: "u")
        #expect(info.formats.count == 3)

        let combined = try #require(info.formats.first { $0.id == "18" })
        #expect(combined.isCombined)
        #expect(!combined.isAudioOnly)
        #expect(combined.fileSize == 635_110)
        #expect(combined.qualityLabel == "240p")

        let audio = try #require(info.formats.first { $0.id == "251" })
        #expect(audio.isAudioOnly)
        #expect(audio.qualityLabel == "129 kbps")

        let video = try #require(info.formats.first { $0.id == "137" })
        #expect(video.isVideoOnly)
        // A frame rate of 50 or more is worth showing; 30 is not.
        #expect(video.qualityLabel == "1080p60")
        #expect(video.codecLabel == "avc1")
    }

    @Test("The maximum available height comes from the formats, not the top-level fields")
    func maximumHeight() throws {
        let info = try MediaInfoDecoder.decode(Data(singleVideoJSON.utf8), originalURL: "u")
        // The top-level height says 240, but a 1080p stream is on offer.
        #expect(info.maximumHeight == 1080)
    }

    @Test("Formats are listed best first with duplicates collapsed")
    func displayFormatsOrdering() throws {
        let info = try MediaInfoDecoder.decode(Data(singleVideoJSON.utf8), originalURL: "u")
        #expect(info.displayFormats.first?.id == "137")
    }

    // MARK: - Playlist

    @Test("A playlist decodes into numbered entries")
    func decodesPlaylist() throws {
        let info = try MediaInfoDecoder.decode(Data(playlistJSON.utf8), originalURL: "https://example.com/playlist")

        #expect(info.isPlaylist)
        #expect(info.title == "My Playlist")
        #expect(info.playlistCount == 3)
        #expect(info.playlistEntries.count == 3)
        #expect(info.playlistEntries[0].index == 1)
        #expect(info.playlistEntries[1].url == "https://example.com/b")
        #expect(info.playlistEntries[2].duration == nil)
    }

    @Test("Playlist duration is the sum of its entries, since a playlist has none of its own")
    func playlistDuration() throws {
        let info = try MediaInfoDecoder.decode(Data(playlistJSON.utf8), originalURL: "u")
        #expect(info.duration == 300.5)
    }

    @Test("A playlist borrows its first entry's artwork so the card isn't empty")
    func playlistThumbnailFallback() throws {
        let info = try MediaInfoDecoder.decode(Data(playlistJSON.utf8), originalURL: "u")
        #expect(info.thumbnailURL?.absoluteString == "https://example.com/a.jpg")
    }

    // MARK: - Robustness

    @Test("Numbers arriving as strings are still read")
    func lenientNumberTypes() throws {
        let json = """
        {"id": "x", "title": "T", "duration": "42.5", "height": "720", "view_count": "1000"}
        """
        let info = try MediaInfoDecoder.decode(Data(json.utf8), originalURL: "u")
        #expect(info.duration == 42.5)
        #expect(info.height == 720)
        #expect(info.viewCount == 1_000)
    }

    @Test("A near-empty payload decodes rather than throwing, falling back to the URL for a title")
    func minimalPayload() throws {
        let info = try MediaInfoDecoder.decode(Data("{}".utf8), originalURL: "https://example.com/v")
        #expect(info.title == "https://example.com/v")
        #expect(info.formats.isEmpty)
        #expect(!info.isPlaylist)
    }

    @Test("Nulls are treated as absent, not as zero")
    func nullFields() throws {
        let json = """
        {"id": "x", "title": "T", "duration": null, "uploader": null, "formats": null,
         "thumbnail": null, "view_count": null}
        """
        let info = try MediaInfoDecoder.decode(Data(json.utf8), originalURL: "u")
        #expect(info.duration == nil)
        #expect(info.displayUploader == nil)
        #expect(info.thumbnailURL == nil)
        #expect(info.viewCount == nil)
        #expect(info.formats.isEmpty)
    }

    @Test("Malformed JSON throws so the UI can report it")
    func malformedJSON() {
        #expect(throws: (any Error).self) {
            try MediaInfoDecoder.decode(Data("{not json".utf8), originalURL: "u")
        }
    }
}
