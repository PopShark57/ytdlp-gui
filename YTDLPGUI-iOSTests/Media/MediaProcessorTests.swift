import AVFoundation
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import YTDLPGUI_iOS

/// End-to-end checks of every media operation on generated clips, verified by reading the
/// results back with AVFoundation, AVAudioFile and ImageIO.
///
/// Serialized because every test encodes video, and the hardware encoder slows to a crawl when
/// dozens of sessions compete for it.
@Suite("Media processing", .serialized)
final class MediaProcessorTests {

    let directory: URL
    let media = MediaProcessor.shared

    init() throws {
        directory = try MediaFixtures.makeDirectory()
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Probe

    @Test("Probe reports duration, track kinds and codecs")
    func probeDescribesTracks() async throws {
        let movie = try await makeMedia("movie.mp4", video: 2, audio: 2)
        let probe = try await media.probe(movie)
        #expect(probe.isReadable)
        #expect(abs((probe.durationSeconds ?? 0) - 2) < 0.1)
        #expect(probe.tracks.contains(MediaProbe.Track(kind: "video", codec: "avc1")))
        #expect(probe.tracks.contains(MediaProbe.Track(kind: "audio", codec: "mp4a")))
    }

    @Test("Probe of a file AVFoundation can't read says so instead of throwing")
    func probeOfUnreadableFile() async throws {
        let garbage = file("clip.webm")
        try MediaFixtures.makeGarbage(at: garbage)
        let probe = try await media.probe(garbage)
        #expect(!probe.isReadable)
        #expect(probe.tracks.isEmpty)
        #expect(probe.durationSeconds == nil)
    }

    @Test("Probe of a missing file fails rather than reporting it unsupported")
    func probeOfMissingFile() async throws {
        let error = await mediaError { _ = try await self.media.probe(self.file("missing.mp4")) }
        #expect(error != nil)
        #expect(error?.isUnsupported == false)
        #expect(error?.errorDescription?.contains("missing.mp4") == true)
    }

    // MARK: - Merge

    @Test("Merging video and audio copies both tracks without re-encoding")
    func mergeCombinesTracks() async throws {
        let video = try await makeMedia("video.f137.mp4", video: 2, audio: nil)
        let audio = try await makeMedia("audio.f140.m4a", video: nil, audio: 2, fileType: .m4a)
        let output = file("merged.mp4")

        try await media.merge(inputs: [video, audio], output: output, container: .mp4)

        let probe = try await media.probe(output)
        #expect(probe.tracks.map(\.kind).sorted() == ["audio", "video"])
        #expect(probe.tracks.contains { $0.codec == "avc1" })
        #expect(probe.tracks.contains { $0.codec == "mp4a" })
        #expect(abs((probe.durationSeconds ?? 0) - 2) < 0.1)
        #expect(leftovers().isEmpty)
    }

    @Test("Longer audio is trimmed to the video's length")
    func mergeTrimsAudioToVideo() async throws {
        let video = try await makeMedia("video.mp4", video: 2, audio: nil)
        let audio = try await makeMedia("audio.m4a", video: nil, audio: 3.5, fileType: .m4a)
        let output = file("merged.mp4")

        try await media.merge(inputs: [video, audio], output: output, container: .mp4)

        let asset = AVURLAsset(url: output)
        let audioTrack = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let audioDuration = try await audioTrack.load(.timeRange).duration.seconds
        #expect(audioDuration < 2.1)
        #expect(abs(try await asset.load(.duration).seconds - 2) < 0.1)
    }

    @Test("Merging into MOV and replacing an existing output")
    func mergeIntoMovReplacesOutput() async throws {
        let video = try await makeMedia("video.mp4", video: 1, audio: nil)
        let audio = try await makeMedia("audio.m4a", video: nil, audio: 1, fileType: .m4a)
        let output = file("merged.mov")
        try Data("stale partial output".utf8).write(to: output)

        try await media.merge(inputs: [video, audio], output: output, container: .mov)

        let probe = try await media.probe(output)
        #expect(probe.isReadable)
        #expect(probe.tracks.count == 2)
    }

    @Test("Merging an unreadable input is unsupported and leaves no output")
    func mergeRejectsUnreadableInput() async throws {
        let video = try await makeMedia("video.mp4", video: 1, audio: nil)
        let webm = file("audio.webm")
        try MediaFixtures.makeGarbage(at: webm)
        let output = file("merged.mp4")

        let error = await mediaError { try await self.media.merge(inputs: [video, webm], output: output, container: .mp4) }
        #expect(error?.isUnsupported == true)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(leftovers().isEmpty)
    }

    // MARK: - Extract audio

    @Test("Copying AAC out of a movie rewraps it as M4A")
    func extractCopiesAAC() async throws {
        let movie = try await makeMedia("movie.mp4", video: 2, audio: 2)
        let written = try await media.extractAudio(input: movie, output: file("movie.m4a"), codec: .copy, bitrate: nil)

        #expect(written.pathExtension == "m4a")
        let probe = try await media.probe(written)
        #expect(probe.tracks == [MediaProbe.Track(kind: "audio", codec: "mp4a")])
        #expect(abs((probe.durationSeconds ?? 0) - 2) < 0.1)
    }

    @Test("AAC is re-encoded at the requested bit rate, and the extension follows the codec")
    func extractEncodesAAC() async throws {
        let movie = try await makeMedia("movie.mp4", video: 1, audio: 2)
        let written = try await media.extractAudio(input: movie, output: file("song.mp3"), codec: .aac, bitrate: 96_000)

        #expect(written.lastPathComponent == "song.m4a")
        let track = try #require(try await AVURLAsset(url: written).loadTracks(withMediaType: .audio).first)
        let rate = try await track.load(.estimatedDataRate)
        #expect(rate > 64_000 && rate < 128_000)
        #expect(try await media.probe(written).tracks.first?.codec == "mp4a")
    }

    @Test("An absurd bit rate is clamped to one the encoder accepts")
    func extractClampsBitRate() async throws {
        let audio = try await makeMedia("audio.m4a", video: nil, audio: 1, fileType: .m4a)
        let written = try await media.extractAudio(input: audio, output: file("out.m4a"), codec: .aac, bitrate: 5_000_000)
        #expect(try await media.probe(written).tracks.first?.codec == "mp4a")
    }

    @Test("ALAC output is Apple Lossless in M4A")
    func extractEncodesALAC() async throws {
        let audio = try await makeMedia("audio.m4a", video: nil, audio: 2, fileType: .m4a)
        let written = try await media.extractAudio(input: audio, output: file("lossless.m4a"), codec: .alac, bitrate: nil)
        let probe = try await media.probe(written)
        #expect(probe.tracks == [MediaProbe.Track(kind: "audio", codec: "alac")])
        #expect(abs((probe.durationSeconds ?? 0) - 2) < 0.1)
    }

    @Test("FLAC output plays back through AVAudioFile")
    func extractEncodesFLAC() async throws {
        let audio = try await makeMedia("audio.m4a", video: nil, audio: 2, fileType: .m4a)
        let written = try await media.extractAudio(input: audio, output: file("audio.m4a"), codec: .flac, bitrate: nil)

        #expect(written.pathExtension == "flac")
        let playback = try AVAudioFile(forReading: written)
        let formatID = (playback.fileFormat.settings[AVFormatIDKey] as? NSNumber)?.uint32Value
        #expect(formatID == kAudioFormatFLAC)
        #expect(playback.fileFormat.channelCount == 2)
        #expect(abs(Double(playback.length) / playback.fileFormat.sampleRate - 2) < 0.1)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: playback.processingFormat, frameCapacity: 4096))
        try playback.read(into: buffer)
        #expect(buffer.frameLength > 0)
    }

    @Test("WAV output is 16-bit little-endian PCM")
    func extractWritesWAV() async throws {
        let movie = try await makeMedia("movie.mp4", video: 1, audio: 2)
        let written = try await media.extractAudio(input: movie, output: file("movie.wav"), codec: .wav, bitrate: nil)

        let playback = try AVAudioFile(forReading: written)
        let settings = playback.fileFormat.settings
        #expect((settings[AVFormatIDKey] as? NSNumber)?.uint32Value == kAudioFormatLinearPCM)
        #expect((settings[AVLinearPCMBitDepthKey] as? NSNumber)?.intValue == 16)
        #expect((settings[AVLinearPCMIsBigEndianKey] as? NSNumber)?.boolValue == false)
        #expect((settings[AVLinearPCMIsFloatKey] as? NSNumber)?.boolValue == false)
        #expect(abs(Double(playback.length) / playback.fileFormat.sampleRate - 2) < 0.1)
    }

    @Test("Multichannel audio keeps its channels")
    func extractKeepsSurroundChannels() async throws {
        let audio = try await makeMedia("surround.m4a", video: nil, audio: 1, fileType: .m4a, channels: 6)
        let written = try await media.extractAudio(input: audio, output: file("surround.wav"), codec: .wav, bitrate: nil)
        #expect(try AVAudioFile(forReading: written).fileFormat.channelCount == 6)
    }

    @Test("A file without audio can't have its audio extracted")
    func extractNeedsAudio() async throws {
        let video = try await makeMedia("video.mp4", video: 1, audio: nil)
        let error = await mediaError {
            _ = try await self.media.extractAudio(input: video, output: self.file("x.m4a"), codec: .aac, bitrate: nil)
        }
        #expect(error?.isUnsupported == false)
        #expect(error?.errorDescription?.contains("no audio") == true)
    }

    @Test("Extracting from an unreadable file is unsupported")
    func extractRejectsUnreadableInput() async throws {
        let webm = file("clip.webm")
        try MediaFixtures.makeGarbage(at: webm)
        let error = await mediaError {
            _ = try await self.media.extractAudio(input: webm, output: self.file("clip.m4a"), codec: .copy, bitrate: nil)
        }
        #expect(error?.isUnsupported == true)
    }

    // MARK: - Embed

    @Test("Tags, cover art and chapters are written and read back")
    func embedWritesEverything() async throws {
        let movie = try await makeMedia("movie.mp4", video: 3, audio: 3)
        let cover = file("cover.png")
        try MediaFixtures.makeImage(at: cover, type: .png, width: 64, height: 36)
        let chapters = [
            MediaChapter(start: 0, end: 1, title: "Intro"),
            MediaChapter(start: 1, end: 2.5, title: "Main «part» ✓"),
            MediaChapter(start: 2.5, end: 3, title: "Outro"),
        ]

        try await media.embed(into: movie, metadata: Self.sampleMetadata, artwork: cover, chapters: chapters)

        let asset = AVURLAsset(url: movie)
        let items = try await asset.load(.metadata)
        #expect(try await tag(.iTunesMetadataSongName, in: items) == "A Title")
        #expect(try await tag(.iTunesMetadataArtist, in: items) == "An Artist")
        #expect(try await tag(.iTunesMetadataAlbum, in: items) == "An Album")
        #expect(try await tag(.iTunesMetadataAlbumArtist, in: items) == "An Album Artist")
        #expect(try await tag(.iTunesMetadataReleaseDate, in: items) == "2024-01-31")
        #expect(try await tag(.iTunesMetadataUserComment, in: items) == "A comment")
        #expect(try await tag(.iTunesMetadataUserGenre, in: items) == "Music")
        #expect(try await tag(AVMetadataItem.identifier(forKey: "desc", keySpace: .iTunes), in: items) == "A description")
        #expect(try await tag(AVMetadataItem.identifier(forKey: "purl", keySpace: .iTunes), in: items) == "https://example.com/watch?v=1")
        let trackNumber = try await data(.iTunesMetadataTrackNumber, in: items)
        #expect(trackNumber == Data([0, 0, 0, 3, 0, 12, 0, 0]))
        let artwork = try await data(.iTunesMetadataCoverArt, in: items)
        #expect(artwork == (try Data(contentsOf: cover)))

        let readBack = try await chapterList(of: movie)
        #expect(readBack.map(\.title) == chapters.map(\.title))
        #expect(zip(readBack, chapters).allSatisfy { abs($0.start - $1.start) < 0.01 && abs($0.end - $1.end) < 0.01 })

        let probe = try await media.probe(movie)
        #expect(probe.tracks.filter { $0.kind != "text" }.map(\.kind).sorted() == ["audio", "video"])
        #expect(abs((probe.durationSeconds ?? 0) - 3) < 0.1)
        #expect(leftovers().isEmpty)
    }

    @Test("A later cover-art embed keeps the tags and chapters written before it")
    func embedPreservesEarlierWork() async throws {
        let audio = try await makeMedia("song.m4a", video: nil, audio: 2, fileType: .m4a)
        let chapters = [MediaChapter(start: 0, end: 1, title: "One"), MediaChapter(start: 1, end: 2, title: "Two")]
        try await media.embed(into: audio, metadata: Self.sampleMetadata, artwork: nil, chapters: chapters)

        let cover = file("cover.jpg")
        try MediaFixtures.makeImage(at: cover, type: .jpeg, width: 32, height: 32)
        try await media.embed(into: audio, metadata: nil, artwork: cover, chapters: nil)

        let items = try await AVURLAsset(url: audio).load(.metadata)
        #expect(try await tag(.iTunesMetadataSongName, in: items) == "A Title")
        #expect(try await data(.iTunesMetadataCoverArt, in: items) == (try Data(contentsOf: cover)))
        #expect(try await chapterList(of: audio).map(\.title) == ["One", "Two"])
    }

    @Test("Cover art that isn't JPEG or PNG is converted to PNG")
    func embedConvertsArtwork() async throws {
        let movie = try await makeMedia("movie.mp4", video: 1, audio: 1)
        let cover = file("cover.tiff")
        try MediaFixtures.makeImage(at: cover, type: .tiff, width: 40, height: 30)

        try await media.embed(into: movie, metadata: nil, artwork: cover, chapters: nil)

        let items = try await AVURLAsset(url: movie).load(.metadata)
        let artwork = try #require(try await data(.iTunesMetadataCoverArt, in: items))
        #expect(ImageConverter.coverArtFormat(of: artwork) == .png)
    }

    @Test("MOV files get QuickTime metadata as well as iTunes tags")
    func embedIntoMov() async throws {
        let movie = try await makeMedia("movie.mov", video: 1, audio: 1, fileType: .mov)
        try await media.embed(into: movie, metadata: Self.sampleMetadata, artwork: nil, chapters: nil)

        let items = try await AVURLAsset(url: movie).load(.metadata)
        #expect(try await tag(.quickTimeMetadataTitle, in: items) == "A Title")
        #expect(try await tag(.iTunesMetadataSongName, in: items) == "A Title")
    }

    @Test("Embedding into a container other than MP4, M4A or MOV is unsupported")
    func embedRejectsOtherContainers() async throws {
        let webm = file("clip.webm")
        try MediaFixtures.makeGarbage(at: webm)
        let error = await mediaError {
            try await self.media.embed(into: webm, metadata: Self.sampleMetadata, artwork: nil, chapters: nil)
        }
        #expect(error?.isUnsupported == true)
    }

    // MARK: - Images

    @Test("PNG converts to JPEG and back, keeping its size")
    func convertImageRoundTrip() async throws {
        let png = file("thumb.png")
        try MediaFixtures.makeImage(at: png, type: .png, width: 64, height: 36, transparent: true)
        let jpeg = file("thumb.jpg")
        try await media.convertImage(input: png, output: jpeg, format: .jpg)
        #expect(ImageConverter.coverArtFormat(of: try Data(contentsOf: jpeg)) == .jpg)
        #expect(pixelSize(of: jpeg) == CGSize(width: 64, height: 36))

        let back = file("back.png")
        try await media.convertImage(input: jpeg, output: back, format: .png)
        #expect(ImageConverter.coverArtFormat(of: try Data(contentsOf: back)) == .png)
        #expect(pixelSize(of: back) == CGSize(width: 64, height: 36))
    }

    @Test("The EXIF orientation is applied to the pixels")
    func convertImageAppliesOrientation() async throws {
        let rotated = file("rotated.jpg")
        try MediaFixtures.makeImage(at: rotated, type: .jpeg, width: 40, height: 20, orientation: 6)
        let output = file("upright.png")
        try await media.convertImage(input: rotated, output: output, format: .png)
        #expect(pixelSize(of: output) == CGSize(width: 20, height: 40))
    }

    @Test("Something that isn't an image can't be converted")
    func convertImageRejectsGarbage() async throws {
        let garbage = file("thumb.webp")
        try MediaFixtures.makeGarbage(at: garbage)
        let error = await mediaError {
            try await self.media.convertImage(input: garbage, output: self.file("thumb.jpg"), format: .jpg)
        }
        #expect(error?.isUnsupported == true)
    }

    // MARK: - Remove ranges

    @Test("Removing ranges shortens the file by exactly their length")
    func removeRangesCuts() async throws {
        let movie = try await makeMedia("movie.mp4", video: 4, audio: 4)
        let output = file("movie.temp.mp4")

        try await media.removeRanges(input: movie, output: output, ranges: [2.5...3, 1...2, 1.5...1.8])

        let probe = try await media.probe(output)
        #expect(abs((probe.durationSeconds ?? 0) - 2.5) < 0.1)
        #expect(probe.tracks.map(\.kind).sorted() == ["audio", "video"])
        #expect(leftovers().isEmpty)
    }

    @Test("No ranges means a straight copy")
    func removeNothingCopies() async throws {
        let movie = try await makeMedia("movie.mp4", video: 1, audio: 1)
        let output = file("copy.mp4")
        try await media.removeRanges(input: movie, output: output, ranges: [])
        #expect(try Data(contentsOf: output) == Data(contentsOf: movie))
    }

    @Test("Removing everything is refused")
    func removeEverythingFails() async throws {
        let movie = try await makeMedia("movie.mp4", video: 1, audio: 1)
        let error = await mediaError {
            try await self.media.removeRanges(input: movie, output: self.file("out.mp4"), ranges: [0...5])
        }
        #expect(error?.isUnsupported == false)
        #expect(error != nil)
    }

    // MARK: - Helpers

    static let sampleMetadata = MediaMetadata(
        title: "A Title",
        artist: "An Artist",
        album: "An Album",
        albumArtist: "An Album Artist",
        date: "20240131",
        comment: "A comment",
        description: "A description",
        genre: "Music",
        track: "3/12",
        webpageURL: "https://example.com/watch?v=1"
    )

    private func file(_ name: String) -> URL {
        directory.appending(path: name, directoryHint: .notDirectory)
    }

    private func makeMedia(
        _ name: String,
        video: Double?,
        audio: Double?,
        fileType: AVFileType = .mp4,
        channels: Int = 2
    ) async throws -> URL {
        let url = file(name)
        try await MediaFixtures.makeMedia(at: url, video: video, audio: audio, fileType: fileType, channels: channels)
        return url
    }

    /// Staging files an operation failed to clean up.
    private func leftovers() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.contains(".partial-") }
    }

    private func mediaError(_ body: () async throws -> Void) async -> MediaProcessingError? {
        do {
            try await body()
            return nil
        } catch let error as MediaProcessingError {
            return error
        } catch {
            Issue.record("Expected a MediaProcessingError, got \(error)")
            return nil
        }
    }

    private func tag(_ identifier: AVMetadataIdentifier?, in items: [AVMetadataItem]) async throws -> String? {
        guard let identifier,
              let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier).first
        else { return nil }
        return try await item.load(.stringValue)
    }

    private func data(_ identifier: AVMetadataIdentifier, in items: [AVMetadataItem]) async throws -> Data? {
        guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier).first else { return nil }
        return try await item.load(.dataValue)
    }

    private func chapterList(of url: URL) async throws -> [MediaChapter] {
        let asset = AVURLAsset(url: url)
        guard let locale = try await asset.load(.availableChapterLocales).first else { return [] }
        var chapters: [MediaChapter] = []
        for group in try await asset.loadChapterMetadataGroups(withTitleLocale: locale) {
            let title = try await group.items.first?.load(.stringValue) ?? ""
            chapters.append(MediaChapter(start: group.timeRange.start.seconds, end: group.timeRange.end.seconds, title: title))
        }
        return chapters
    }

    private func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return CGSize(width: image.width, height: image.height)
    }
}

@Suite("Media processing rules")
struct MediaProcessingRuleTests {

    @Test("Ranges are clamped, sorted and merged")
    func rangesNormalize() {
        let ranges = RangeRemover.normalized([8...12, 1...2, 1.5...3, -1...0.5, 4...4], duration: 10)
        #expect(ranges == [0...0.5, 1...3, 8...10])
    }

    @Test("Chapters become contiguous, clamped and titled")
    func chaptersNormalize() {
        let chapters = ChapterTrack.normalized([
            MediaChapter(start: 5, end: 12, title: "  "),
            MediaChapter(start: 0, end: 4, title: "Intro"),
            MediaChapter(start: 11, end: 20, title: "Past the end"),
        ], duration: CMTime(seconds: 10, preferredTimescale: 600))
        #expect(chapters == [
            MediaChapter(start: 0, end: 5, title: "Intro"),
            MediaChapter(start: 5, end: 10, title: "Chapter 2"),
        ])
    }

    @Test("yt-dlp dates become ISO 8601, anything else is kept")
    func datesNormalize() {
        #expect(MetadataTags.normalizedDate("20240131") == "2024-01-31")
        #expect(MetadataTags.normalizedDate("2024") == "2024")
        #expect(MetadataTags.normalizedDate("2024-01-31") == "2024-01-31")
    }

    @Test("Track numbers become the binary trkn value")
    func trackNumbers() {
        #expect(MetadataTags.trackNumberData("7") == Data([0, 0, 0, 7, 0, 0, 0, 0]))
        #expect(MetadataTags.trackNumberData("3/12") == Data([0, 0, 0, 3, 0, 12, 0, 0]))
        #expect(MetadataTags.trackNumberData("side A") == nil)
    }

    @Test("AAC is reported by its MP4 sample entry")
    func codecNames() throws {
        var description = AudioStreamBasicDescription(
            mSampleRate: 44_100, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        )
        let aac = try #require(format)
        #expect(MediaCodec.sampleEntryCode(aac) == "mp4a")
        #expect(MediaCodec.displayName(aac) == "AAC")
        #expect(MediaCodec.fourCharacterString(kCMVideoCodecType_HEVC) == "hvc1")
    }
}
