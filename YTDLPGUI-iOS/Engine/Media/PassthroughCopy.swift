import AVFoundation
import os

/// A track to copy into a new file, and the part of it to keep.
struct TrackCopy {
    let source: SourceTrack
    /// In the source's timeline. The copy keeps its position, so tracks taken from different
    /// files stay in sync exactly as they were.
    var timeRange: CMTimeRange

    init(_ source: SourceTrack, timeRange: CMTimeRange? = nil) {
        self.source = source
        self.timeRange = timeRange ?? source.timeRange
    }
}

/// Copies tracks into a new file without re-encoding, the way `ffmpeg -c copy` does.
///
/// `AVAssetExportSession` is tried first: it is Apple's own remuxer and the most forgiving about
/// what it reads. It refuses some codec and container combinations, though, and has no notion
/// of alternate audio tracks — given two, it would play both at once — so those cases go through
/// `SampleCopyWriter` instead, which copies sample by sample.
struct PassthroughCopy {
    var tracks: [TrackCopy]
    var fileType: AVFileType
    /// Where the new timeline ends; nil keeps every sample.
    var endTime: CMTime?

    func write(to url: URL, outputName: String) async throws {
        let audioCount = tracks.count { $0.source.mediaType == .audio }
        if audioCount <= 1 {
            let session = ExportSessionCopy(tracks: tracks, fileType: fileType, endTime: endTime)
            if try await session.write(to: url), await containsExpectedTracks(url) {
                return
            }
            try? FileManager.default.removeItem(at: url)
            MediaLog.logger.info("Export session couldn't copy into \(outputName, privacy: .public); copying sample by sample")
        }
        let writer = SampleCopyWriter(tracks: tracks, fileType: fileType, endTime: endTime)
        try await writer.write(to: url, outputName: outputName)
    }

    /// The export session has been seen to drop a track it can't carry rather than fail, so
    /// its output is checked before it is trusted.
    private func containsExpectedTracks(_ url: URL) async -> Bool {
        guard let written = try? await MediaSource.inspect(url) else { return false }
        for mediaType in [AVMediaType.video, .audio] {
            let expected = tracks.count { $0.source.mediaType == mediaType }
            guard written.tracks(ofType: mediaType).count == expected else { return false }
        }
        return (written.durationSeconds ?? 0) > 0
    }
}

/// Remuxes through `AVMutableComposition` and `AVAssetExportSession`'s passthrough preset.
struct ExportSessionCopy {
    var tracks: [TrackCopy]
    var fileType: AVFileType
    var endTime: CMTime?
    /// Spans of the timeline to cut out, applied last to first.
    var removedRanges: [CMTimeRange] = []
    var metadata: [AVMetadataItem] = []

    /// Returns false, having left nothing at `url`, when the export session won't handle this
    /// combination of tracks and container.
    func write(to url: URL) async throws -> Bool {
        let composition = AVMutableComposition()
        for copy in tracks {
            var range = copy.timeRange
            if let endTime, endTime.isNumeric, range.end > endTime {
                range = CMTimeRange(start: range.start, end: max(range.start, endTime))
            }
            guard range.duration > .zero,
                  let track = composition.addMutableTrack(
                      withMediaType: copy.source.mediaType,
                      preferredTrackID: kCMPersistentTrackID_Invalid
                  )
            else { continue }
            do {
                try track.insertTimeRange(range, of: copy.source.track, at: range.start)
            } catch {
                MediaLog.logger.info("Composition refused a \(copy.source.codecName, privacy: .public) track: \(error, privacy: .public)")
                return false
            }
            track.preferredTransform = copy.source.preferredTransform
            track.languageCode = copy.source.languageCode
            track.extendedLanguageTag = copy.source.extendedLanguageTag
            track.isEnabled = copy.source.isEnabled
        }
        for range in removedRanges.sorted(by: { $0.start > $1.start }) {
            composition.removeTimeRange(range)
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough),
              await session.compatibleFileTypes.contains(fileType)
        else { return false }
        session.metadata = metadata
        do {
            try await session.export(to: url, as: fileType)
            return true
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: url)
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: url)
            MediaLog.logger.info("Passthrough export failed: \(MediaErrorText.describe(error), privacy: .public)")
            return false
        }
    }
}

/// Copies tracks sample by sample from `AVAssetReader` into `AVAssetWriter`, with no encoder
/// involved on either side. It can also write file metadata and a chapter track, which the
/// export session cannot.
struct SampleCopyWriter {
    var tracks: [TrackCopy]
    var fileType: AVFileType
    var endTime: CMTime?
    var metadata: [AVMetadataItem] = []
    var chapters: ChapterTrack?

    /// Raised before anything is written when the writer won't take the chapter track, so the
    /// caller can decide whether to go on without it.
    struct ChapterTrackRejected: Error {}

    func write(to url: URL, outputName: String) async throws {
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        } catch {
            throw MediaProcessingError.failed("Couldn't create \(outputName): \(MediaErrorText.describe(error))")
        }
        writer.metadata = metadata

        var readers: [(reader: AVAssetReader, source: URL)] = []
        var transfers: [SampleTransfer] = []
        var audioInputs: [AVAssetWriterInput] = []
        var mediaInputs: [AVAssetWriterInput] = []

        for (index, copy) in tracks.enumerated() {
            let reader = try sharedReader(for: copy.source, in: &readers)
            let output = AVAssetReaderTrackOutput(track: copy.source.track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw MediaProcessingError.unsupported(
                    "iOS can't read the \(copy.source.codecName) \(copy.source.mediaType.noun) in "
                        + "\(MediaFiles.quotedName(copy.source.asset.url)) without decoding it."
                )
            }
            reader.add(output)

            let input = makeInput(for: copy.source)
            guard writer.canAdd(input) else {
                throw MediaProcessingError.unsupported(
                    "iOS can't put \(copy.source.codecName) \(copy.source.mediaType.noun) into an "
                        + "\(MediaFileType.name(of: fileType)) file without re-encoding it."
                )
            }
            writer.add(input)
            if copy.source.mediaType == .audio { audioInputs.append(input) }
            if copy.source.isAudiovisual { mediaInputs.append(input) }
            transfers.append(SampleTransfer(from: output, to: input, label: "track\(index)"))
        }

        // Several audio tracks are alternatives (languages, qualities), not layers to mix.
        if audioInputs.count > 1, let first = audioInputs.first {
            let group = AVAssetWriterInputGroup(inputs: audioInputs, defaultInput: first)
            if writer.canAdd(group) {
                writer.add(group)
            }
        }

        if let chapters {
            let language = chapterLanguage()
            let input = chapters.makeInput(languageCode: language.code, extendedLanguageTag: language.tag)
            guard writer.canAdd(input) else { throw ChapterTrackRejected() }
            writer.add(input)
            for mediaInput in mediaInputs
            where mediaInput.canAddTrackAssociation(withTrackOf: input, type: AVAssetTrack.AssociationType.chapterList.rawValue) {
                mediaInput.addTrackAssociation(withTrackOf: input, type: AVAssetTrack.AssociationType.chapterList.rawValue)
            }
            transfers.append(SampleTransfer(from: PreparedSamples(chapters.samples), to: input, label: "chapters"))
        }

        try await ReaderWriterPipeline.run(
            readers: readers,
            writer: writer,
            transfers: transfers,
            endTime: endTime,
            outputName: outputName
        )
    }

    /// One reader per source file. When the timeline is being cut short, the reader stops at
    /// the cut so nothing past it is even read.
    private func sharedReader(
        for source: SourceTrack,
        in readers: inout [(reader: AVAssetReader, source: URL)]
    ) throws -> AVAssetReader {
        if let existing = readers.first(where: { $0.source == source.asset.url }) {
            return existing.reader
        }
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: source.asset)
        } catch {
            throw MediaProcessingError.failed(
                "Couldn't read \(MediaFiles.quotedName(source.asset.url)): \(MediaErrorText.describe(error))"
            )
        }
        if let endTime, endTime.isNumeric, endTime > .zero {
            reader.timeRange = CMTimeRange(start: .zero, end: endTime)
        }
        readers.append((reader, source.asset.url))
        return reader
    }

    private func makeInput(for source: SourceTrack) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(
            mediaType: source.mediaType,
            outputSettings: nil,
            sourceFormatHint: source.formatDescription
        )
        input.expectsMediaDataInRealTime = false
        input.transform = source.preferredTransform
        input.marksOutputTrackAsEnabled = source.isEnabled
        input.metadata = source.metadata
        if let languageCode = source.languageCode {
            input.languageCode = languageCode
        }
        if let extendedLanguageTag = source.extendedLanguageTag {
            input.extendedLanguageTag = extendedLanguageTag
        }
        // Keeps timestamps exact; the writer's default time scale would round 1001-based frame
        // rates. (Setting it on an audio input raises an exception.)
        if source.mediaType == .video, source.naturalTimeScale > 0 {
            input.mediaTimeScale = source.naturalTimeScale
        }
        return input
    }

    /// The language of the media when a track declares one, otherwise the device's.
    private func chapterLanguage() -> (code: String?, tag: String?) {
        let declared = tracks.lazy
            .map(\.source)
            .first { ($0.languageCode ?? "und") != "und" }
        if let declared {
            return (declared.languageCode, declared.extendedLanguageTag)
        }
        let preferred = Locale(identifier: Locale.preferredLanguages.first ?? "en")
        guard let language = preferred.language.languageCode else { return (nil, nil) }
        return (language.identifier(.alpha3), language.identifier)
    }
}

extension AVMediaType {
    /// "video", "audio"… for messages.
    var noun: String {
        switch self {
        case .video: "video"
        case .audio: "audio"
        case .subtitle, .closedCaption: "subtitles"
        case .text: "text"
        default: "data"
        }
    }
}
