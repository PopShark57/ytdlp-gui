import AVFoundation
import CoreMedia

/// Chapters as a QuickTime text track, the form Apple's players, ffmpeg, VLC and mpv all read.
///
/// Each chapter is one text sample whose timing is the chapter's; the audio and video tracks
/// point at the text track through a `chap` track reference (`.chapterList`). The track is
/// disabled so no player renders it as subtitles. This is the same layout ffmpeg writes, so
/// files look the same whichever app produced them.
struct ChapterTrack {

    /// Whole milliseconds, like ffmpeg's chapter time base.
    static let timescale: CMTimeScale = 1000

    let formatDescription: CMFormatDescription
    let samples: [CMSampleBuffer]
    /// The chapters as written, after clean-up.
    let chapters: [MediaChapter]

    /// Builds the samples for `chapters`, or returns nil when none survive clean-up.
    ///
    /// Chapters are sorted, clamped to `duration` and made contiguous — each runs until the next
    /// begins — because a text track with gaps or overlaps reads back as nonsense.
    init?(chapters requested: [MediaChapter], duration: CMTime) throws {
        let chapters = Self.normalized(requested, duration: duration)
        guard !chapters.isEmpty else { return nil }
        let formatDescription = try Self.makeFormatDescription()
        self.formatDescription = formatDescription
        self.chapters = chapters
        samples = try chapters.map { try Self.makeSample($0, formatDescription: formatDescription) }
    }

    /// Makes a writer input for the track. Its language decides whether AVKit offers the
    /// chapters at all — it only shows chapters whose language matches the viewer's — so the
    /// caller passes the language of the media itself, or of the device when that is unknown.
    func makeInput(languageCode: String?, extendedLanguageTag: String?) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: formatDescription)
        input.marksOutputTrackAsEnabled = false
        input.expectsMediaDataInRealTime = false
        if let languageCode {
            input.languageCode = languageCode
        }
        if let extendedLanguageTag {
            input.extendedLanguageTag = extendedLanguageTag
        }
        return input
    }

    // MARK: - Reading

    /// The chapters already in `asset`, in whichever language they were written.
    static func existingChapters(in asset: AVAsset, duration: CMTime) async -> [MediaChapter] {
        do {
            guard let locale = try await asset.load(.availableChapterLocales).first else { return [] }
            let groups = try await asset.loadChapterMetadataGroups(withTitleLocale: locale)
            var chapters: [MediaChapter] = []
            for group in groups {
                let titleItem = group.items.first { $0.commonKey == .commonKeyTitle } ?? group.items.first
                let title = try await titleItem?.load(.stringValue) ?? ""
                let range = group.timeRange
                guard range.start.isNumeric, range.duration.isNumeric else { continue }
                chapters.append(MediaChapter(start: range.start.seconds, end: range.end.seconds, title: title))
            }
            return chapters
        } catch {
            return []
        }
    }

    // MARK: - Private

    static func normalized(_ chapters: [MediaChapter], duration: CMTime) -> [MediaChapter] {
        let total = duration.isNumeric && duration.seconds > 0 ? duration.seconds : nil
        let limit = total ?? .greatestFiniteMagnitude
        let sorted = chapters
            .filter { $0.start.isFinite && $0.end.isFinite }
            .map { MediaChapter(start: max(0, $0.start), end: $0.end, title: $0.title) }
            .filter { $0.start < limit }
            .sorted { $0.start < $1.start }

        var result: [MediaChapter] = []
        for (index, chapter) in sorted.enumerated() {
            let end: Double
            if index + 1 < sorted.count {
                end = sorted[index + 1].start
            } else if chapter.end > chapter.start {
                end = min(chapter.end, limit)
            } else {
                end = total ?? chapter.start
            }
            // Millisecond resolution: anything shorter would round to an empty sample.
            guard end - chapter.start >= 0.001 else { continue }
            let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(MediaChapter(
                start: chapter.start,
                end: end,
                title: title.isEmpty ? "Chapter \(result.count + 1)" : title
            ))
        }
        return result
    }

    /// A QuickTime `text` sample description with default styling, built byte for byte because
    /// Core Media has no higher-level constructor for text formats.
    private static func makeFormatDescription() throws -> CMFormatDescription {
        var body = Data()
        body.appendBigEndian(UInt32(0))            // display flags
        body.appendBigEndian(UInt32(1))            // justification: centred
        body.append(Data(count: 6))                // background colour (RGB, 16 bits each)
        body.append(Data(count: 8))                // default text box
        body.append(Data(count: 8))                // reserved
        body.appendBigEndian(UInt16(0))            // font number
        body.appendBigEndian(UInt16(0))            // font face
        body.append(Data(count: 3))                // reserved
        body.append(Data(count: 6))                // foreground colour
        body.append(0)                             // font name: empty Pascal string

        var description = Data()
        description.appendBigEndian(UInt32(16 + body.count))
        description.append(contentsOf: Array("text".utf8))
        description.append(Data(count: 6))         // reserved
        description.appendBigEndian(UInt16(1))     // data reference index
        description.append(body)

        var formatDescription: CMFormatDescription?
        let status = description.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return kCMFormatDescriptionError_InvalidParameter }
            return CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData(
                allocator: kCFAllocatorDefault,
                bigEndianTextDescriptionData: base,
                size: bytes.count,
                flavor: nil,
                mediaType: kCMMediaType_Text,
                formatDescriptionOut: &formatDescription
            )
        }
        guard status == noErr, let formatDescription else {
            throw MediaProcessingError.failed("Couldn't prepare the chapter track (Core Media error \(status)).")
        }
        return formatDescription
    }

    /// One text sample: a 16-bit length, the UTF-8 title, and an `encd` atom declaring UTF-8,
    /// as ffmpeg writes it.
    private static func makeSample(_ chapter: MediaChapter, formatDescription: CMFormatDescription) throws -> CMSampleBuffer {
        var title = Array(chapter.title.utf8)
        if title.count > Int(UInt16.max) {
            title = Array(title.prefix(Int(UInt16.max)))
        }
        var payload = Data()
        payload.appendBigEndian(UInt16(title.count))
        payload.append(contentsOf: title)
        payload.appendBigEndian(UInt32(12))
        payload.append(contentsOf: Array("encd".utf8))
        payload.appendBigEndian(UInt32(0x0000_0100))

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw MediaProcessingError.failed("Couldn't prepare the chapter track (Core Media error \(status)).")
        }
        status = payload.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
            return CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: bytes.count
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw MediaProcessingError.failed("Couldn't prepare the chapter track (Core Media error \(status)).")
        }

        let start = CMTime(seconds: chapter.start, preferredTimescale: timescale)
        let end = CMTime(seconds: chapter.end, preferredTimescale: timescale)
        var timing = CMSampleTimingInfo(duration: end - start, presentationTimeStamp: start, decodeTimeStamp: .invalid)
        var sampleSize = payload.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else {
            throw MediaProcessingError.failed("Couldn't prepare the chapter track (Core Media error \(status)).")
        }
        return sample
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
