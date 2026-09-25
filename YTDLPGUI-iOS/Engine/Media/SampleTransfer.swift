import AVFoundation

/// Something that hands out sample buffers one at a time.
///
/// Implementations are only ever called from their transfer's queue.
protocol SampleSource: AnyObject {
    /// The next sample, or nil when there are no more.
    func nextSample() -> CMSampleBuffer?
}

extension AVAssetReaderOutput: SampleSource {
    func nextSample() -> CMSampleBuffer? {
        copyNextSampleBuffer()
    }
}

/// Samples built in memory, such as the titles of a chapter track.
final class PreparedSamples: SampleSource {
    private let samples: [CMSampleBuffer]
    private var nextIndex = 0

    init(_ samples: [CMSampleBuffer]) {
        self.samples = samples
    }

    func nextSample() -> CMSampleBuffer? {
        guard nextIndex < samples.count else { return nil }
        defer { nextIndex += 1 }
        return samples[nextIndex]
    }
}

/// Moves samples from a source into one writer input, as fast as the writer takes them.
///
/// AVAssetWriter interleaves its inputs by holding back whichever is ahead, so every input must
/// be fed concurrently, each from its own queue through `requestMediaDataWhenReady`. The source
/// and the input are touched only on that queue once `run` starts, which is what makes the
/// unchecked `Sendable` conformance sound.
final class SampleTransfer: @unchecked Sendable {

    enum Outcome: Sendable {
        /// Every sample was appended and the input marked finished.
        case finished
        /// The writer refused a sample; its `error` says why.
        case appendFailed
        case cancelled
    }

    private let source: any SampleSource
    private let input: AVAssetWriterInput
    private let queue: DispatchQueue
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var outcome: Outcome?

    init(from source: any SampleSource, to input: AVAssetWriterInput, label: String) {
        self.source = source
        self.input = input
        queue = DispatchQueue(label: "io.github.ytdlpgui.media.\(label)")
    }

    /// Feeds the input until the source runs dry, the writer fails, or `cancel` is called.
    func run() async -> Outcome {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if let outcome {
                    continuation.resume(returning: outcome)
                    return
                }
                self.continuation = continuation
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    pump()
                }
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            guard outcome == nil else { return }
            // Stops AVFoundation from asking for more data; the pipeline then cancels the
            // writer, so the truncated track is never finished into a file.
            if continuation != nil {
                input.markAsFinished()
            }
            complete(.cancelled)
        }
    }

    private func pump() {
        while outcome == nil, input.isReadyForMoreMediaData {
            guard let sample = source.nextSample() else {
                input.markAsFinished()
                complete(.finished)
                return
            }
            guard input.append(sample) else {
                complete(.appendFailed)
                return
            }
        }
    }

    private func complete(_ result: Outcome) {
        guard outcome == nil else { return }
        outcome = result
        continuation?.resume(returning: result)
        continuation = nil
    }
}

/// Runs AVAssetReaders into an AVAssetWriter and finishes the file.
enum ReaderWriterPipeline {

    /// - Parameters:
    ///   - endTime: Where the written timeline ends. Samples running past it are kept but
    ///     trimmed by an edit list, which is how a longer audio track is cut to the video.
    ///   - outputName: The file being produced, for messages.
    static func run(
        readers: [(reader: AVAssetReader, source: URL)],
        writer: AVAssetWriter,
        transfers: [SampleTransfer],
        endTime: CMTime? = nil,
        outputName: String
    ) async throws {
        for (reader, source) in readers where !reader.startReading() {
            throw readFailure(reader, source: source)
        }
        guard writer.startWriting() else {
            throw writeFailure(writer, outputName: outputName)
        }
        writer.startSession(atSourceTime: .zero)

        let outcomes = await withTaskCancellationHandler {
            await withTaskGroup(of: SampleTransfer.Outcome.self) { group in
                for transfer in transfers {
                    group.addTask { await transfer.run() }
                }
                var outcomes: [SampleTransfer.Outcome] = []
                for await outcome in group {
                    outcomes.append(outcome)
                    // A failed writer stops asking the other inputs for data, so they would
                    // wait forever unless released here.
                    if outcome == .appendFailed {
                        transfers.forEach { $0.cancel() }
                    }
                }
                return outcomes
            }
        } onCancel: {
            transfers.forEach { $0.cancel() }
        }

        if outcomes.contains(.appendFailed) || writer.status == .failed {
            let error = writeFailure(writer, outputName: outputName)
            abandon(readers: readers.map(\.reader), writer: writer)
            throw error
        }
        if Task.isCancelled || outcomes.contains(.cancelled) {
            abandon(readers: readers.map(\.reader), writer: writer)
            throw CancellationError()
        }
        if let (reader, source) = readers.first(where: { $0.reader.status == .failed }) {
            let error = readFailure(reader, source: source)
            abandon(readers: [], writer: writer)
            throw error
        }

        if let endTime, endTime.isNumeric, endTime > .zero {
            writer.endSession(atSourceTime: endTime)
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writeFailure(writer, outputName: outputName)
        }
    }

    private static func abandon(readers: [AVAssetReader], writer: AVAssetWriter) {
        for reader in readers where reader.status == .reading {
            reader.cancelReading()
        }
        if writer.status == .writing {
            writer.cancelWriting()
        }
    }

    private static func readFailure(_ reader: AVAssetReader, source: URL) -> MediaProcessingError {
        let detail = reader.error.map(MediaErrorText.describe) ?? "AVFoundation gave no reason."
        return .failed("Couldn't read \(MediaFiles.quotedName(source)): \(detail)")
    }

    private static func writeFailure(_ writer: AVAssetWriter, outputName: String) -> MediaProcessingError {
        let detail = writer.error.map(MediaErrorText.describe) ?? "AVFoundation gave no reason."
        return .failed("Couldn't write \(outputName): \(detail)")
    }
}
