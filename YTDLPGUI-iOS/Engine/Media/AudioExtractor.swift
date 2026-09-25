import AVFoundation
import os

/// `--extract-audio`: writes the audio of a download on its own, copied or re-encoded.
///
/// yt-dlp's FFmpegExtractAudioPP decides the target (it asks for `copy` when the source is
/// already AAC and M4A is wanted); this carries it out. Only the audio track is read, so a
/// video file works as a source too.
struct AudioExtractor {

    /// Returns the file written, whose extension always matches the codec.
    func extract(input: URL, output requestedOutput: URL, codec: AudioCodecRequest, bitrate: Int?) async throws -> URL {
        let output = MediaFiles.replacingExtension(of: requestedOutput, with: Self.fileExtension(for: codec))
        let source = try await MediaSource.open(input)
        guard let audio = source.primaryTrack(ofType: .audio) else {
            throw MediaProcessingError.failed("\(MediaFiles.quotedName(input)) has no audio track to extract.")
        }
        let outputName = MediaFiles.quotedName(output)

        try await MediaFiles.writeAtomically(to: output) { staging in
            switch codec {
            case .copy:
                try await copyAudio(audio, to: staging, outputName: outputName)
            case .aac, .alac:
                try await encode(audio, as: codec, bitRate: bitrate, to: staging, outputName: outputName)
            case .flac, .wav:
                var plan = try AudioFormatPlan(source: audio)
                let settings = try plan.settings(for: codec)
                try await AudioFileEncoder(source: audio, plan: plan, fileSettings: settings)
                    .write(to: staging, outputName: outputName)
            }
        }
        return output
    }

    static func fileExtension(for codec: AudioCodecRequest) -> String {
        switch codec {
        case .copy, .aac, .alac: "m4a"
        case .flac: "flac"
        case .wav: "wav"
        }
    }

    // MARK: - Private

    /// Rewraps the audio as it is. Anything MP4 can carry — AAC, ALAC, and also MP3 or AC-3 —
    /// goes through; what it can't (Opus, FLAC from some sources) is reported as unsupported so
    /// yt-dlp keeps the original.
    private func copyAudio(_ audio: SourceTrack, to staging: URL, outputName: String) async throws {
        let copy = PassthroughCopy(tracks: [TrackCopy(audio)], fileType: .m4a, endTime: nil)
        do {
            try await copy.write(to: staging, outputName: outputName)
        } catch let error as MediaProcessingError where !error.isUnsupported {
            throw MediaProcessingError.unsupported(
                "The \(audio.codecName) audio in \(MediaFiles.quotedName(audio.asset.url)) can't be copied into "
                    + "an M4A file as it is. Choose AAC, ALAC, FLAC or WAV to convert it instead. "
                    + "(\(error.errorDescription ?? "No reason given."))"
            )
        }
    }

    /// Decodes to PCM with AVAssetReader and encodes with AVAssetWriter into an M4A.
    private func encode(
        _ audio: SourceTrack,
        as codec: AudioCodecRequest,
        bitRate: Int?,
        to staging: URL,
        outputName: String
    ) async throws {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: audio.asset)
            writer = try AVAssetWriter(outputURL: staging, fileType: .m4a)
        } catch {
            throw MediaProcessingError.failed("Couldn't start converting the audio: \(MediaErrorText.describe(error))")
        }
        var plan = try AudioFormatPlan(source: audio)
        let settings = try plan.settings(for: codec, bitRate: bitRate) {
            writer.canApply(outputSettings: $0, forMediaType: .audio)
        }

        let output = AVAssetReaderTrackOutput(track: audio.track, outputSettings: plan.decodedSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw MediaProcessingError.unsupported(
                "iOS can't decode the \(audio.codecName) audio in \(MediaFiles.quotedName(audio.asset.url))."
            )
        }
        reader.add(output)

        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        if let languageCode = audio.languageCode {
            input.languageCode = languageCode
        }
        guard writer.canAdd(input) else {
            throw MediaProcessingError.unsupported("iOS can't encode audio with these settings for \(outputName).")
        }
        writer.add(input)

        try await ReaderWriterPipeline.run(
            readers: [(reader, audio.asset.url)],
            writer: writer,
            transfers: [SampleTransfer(from: output, to: input, label: "audio")],
            outputName: outputName
        )
    }
}

/// Writes FLAC and WAV through `AVAudioFile`, Core Audio's file API: AVAssetWriter has no FLAC
/// support, and the two plain audio formats are simplest handled the same way.
struct AudioFileEncoder {
    let source: SourceTrack
    let plan: AudioFormatPlan
    let fileSettings: [String: Any]

    func write(to url: URL, outputName: String) async throws {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: source.asset)
        } catch {
            throw MediaProcessingError.failed("Couldn't start converting the audio: \(MediaErrorText.describe(error))")
        }
        let output = AVAssetReaderTrackOutput(track: source.track, outputSettings: plan.decodedSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw MediaProcessingError.unsupported(
                "iOS can't decode the \(source.codecName) audio in \(MediaFiles.quotedName(source.asset.url))."
            )
        }
        reader.add(output)

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: fileSettings, commonFormat: .pcmFormatFloat32, interleaved: true)
        } catch {
            throw MediaProcessingError.unsupported("iOS couldn't create \(outputName): \(MediaErrorText.describe(error))")
        }
        guard reader.startReading() else {
            let detail = reader.error.map(MediaErrorText.describe) ?? "AVFoundation gave no reason."
            throw MediaProcessingError.failed("Couldn't read \(MediaFiles.quotedName(source.asset.url)): \(detail)")
        }

        let job = AudioFileJob(reader: reader, output: output, file: file)
        try await withTaskCancellationHandler {
            try await job.run()
        } onCancel: {
            job.cancel()
        }
        if reader.status == .failed {
            let detail = reader.error.map(MediaErrorText.describe) ?? "AVFoundation gave no reason."
            throw MediaProcessingError.failed("Couldn't read \(MediaFiles.quotedName(source.asset.url)): \(detail)")
        }
    }
}

/// The blocking read-convert-write loop, run on its own queue so it never ties up a thread of
/// the cooperative pool. The reader, output and file are used only inside `run`'s block.
private final class AudioFileJob: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderOutput
    private let file: AVAudioFile
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    init(reader: AVAssetReader, output: AVAssetReaderOutput, file: AVAudioFile) {
        self.reader = reader
        self.output = output
        self.file = file
    }

    func cancel() {
        cancelled.withLock { $0 = true }
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue(label: "io.github.ytdlpgui.media.audio-file").async { [self] in
                do {
                    try copySamples()
                    file.close()
                    continuation.resume()
                } catch {
                    reader.cancelReading()
                    file.close()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func copySamples() throws {
        let format = file.processingFormat
        var buffer: AVAudioPCMBuffer?
        while let sample = output.copyNextSampleBuffer() {
            if cancelled.withLock({ $0 }) {
                throw CancellationError()
            }
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0 else { continue }
            if buffer.map({ Int($0.frameCapacity) < frames }) ?? true {
                buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
            }
            guard let buffer else {
                throw MediaProcessingError.failed("Couldn't allocate memory for the audio conversion.")
            }
            // Setting the length first sizes the buffer list the copy fills.
            buffer.frameLength = AVAudioFrameCount(frames)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sample,
                at: 0,
                frameCount: Int32(frames),
                into: buffer.mutableAudioBufferList
            )
            guard status == noErr else {
                throw MediaProcessingError.failed("Couldn't convert the audio (Core Media error \(status)).")
            }
            do {
                try file.write(from: buffer)
            } catch {
                throw MediaProcessingError.failed("Couldn't write the audio: \(MediaErrorText.describe(error))")
            }
        }
    }
}
