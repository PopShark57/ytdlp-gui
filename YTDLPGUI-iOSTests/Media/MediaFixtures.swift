import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Generates the media the media tests work on, so no binary fixtures live in the repository.
///
/// Everything is made with AVAssetWriter and ImageIO: H.264 video drawn frame by frame, AAC
/// audio from a generated sine wave, and small images.
enum MediaFixtures {

    struct GenerationError: Error, CustomStringConvertible {
        let description: String
    }

    static let frameRate = 30
    static let sampleRate = 44_100.0

    /// A fresh scratch folder; the caller removes it.
    static func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "MediaTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes H.264 video of `video` seconds and/or AAC audio of `audio` seconds.
    static func makeMedia(
        at url: URL,
        video: Double?,
        audio: Double?,
        fileType: AVFileType = .mp4,
        width: Int = 160,
        height: Int = 120,
        channels: Int = 2
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)

        var videoInput: AVAssetWriterInput?
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        if video != nil {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            videoInput = input
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        }

        var audioInput: AVAssetWriterInput?
        var audioFormat: CMAudioFormatDescription?
        if audio != nil {
            var settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: 64_000 * channels,
            ]
            if channels > 2 {
                var layout = AudioChannelLayout()
                layout.mChannelLayoutTag = kAudioChannelLayoutTag_AAC_5_1
                settings[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
            }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
            audioFormat = try pcmFormat(channels: channels)
        }

        guard writer.startWriting() else {
            throw GenerationError(description: "Couldn't start writing: \(String(describing: writer.error))")
        }
        writer.startSession(atSourceTime: .zero)

        // One feeder for both inputs: append in timestamp order while both are ready, otherwise
        // whichever is ready, because the writer holds back an input that is too far ahead.
        let videoFrames = Int((video ?? 0) * Double(frameRate))
        let audioFrames = Int((audio ?? 0) * sampleRate)
        var videoIndex = 0
        var audioIndex = 0
        let deadline = ContinuousClock.now + .seconds(180)
        while videoIndex < videoFrames || audioIndex < audioFrames {
            let videoReady = videoIndex < videoFrames && videoInput?.isReadyForMoreMediaData == true
            let audioReady = audioIndex < audioFrames && audioInput?.isReadyForMoreMediaData == true
            let videoFirst = Double(videoIndex) / Double(frameRate) <= Double(audioIndex) / sampleRate
            if videoReady && (videoFirst || !audioReady), let adaptor {
                let buffer = try pixelBuffer(frame: videoIndex, adaptor: adaptor, width: width, height: height)
                let time = CMTime(value: CMTimeValue(videoIndex), timescale: CMTimeScale(frameRate))
                guard adaptor.append(buffer, withPresentationTime: time) else {
                    throw GenerationError(description: "Video append failed: \(String(describing: writer.error))")
                }
                videoIndex += 1
                // Finishing an input as soon as it is complete lets the writer stop waiting
                // for it to catch up.
                if videoIndex == videoFrames { videoInput?.markAsFinished() }
            } else if audioReady, let audioInput, let audioFormat {
                let count = min(1024, audioFrames - audioIndex)
                let sample = try sineSample(start: audioIndex, frames: count, channels: channels, format: audioFormat)
                guard audioInput.append(sample) else {
                    throw GenerationError(description: "Audio append failed: \(String(describing: writer.error))")
                }
                audioIndex += count
                if audioIndex == audioFrames { audioInput.markAsFinished() }
            } else {
                guard writer.status == .writing, ContinuousClock.now < deadline else {
                    throw GenerationError(description: "The writer stopped accepting data: \(String(describing: writer.error))")
                }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw GenerationError(description: "Writing failed: \(String(describing: writer.error))")
        }
    }

    /// An image of the given type, with an EXIF orientation when asked.
    static func makeImage(
        at url: URL,
        type: UTType,
        width: Int,
        height: Int,
        orientation: Int = 1,
        transparent: Bool = false
    ) throws {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { throw GenerationError(description: "Couldn't create a drawing context.") }
        if !transparent {
            context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        }
        context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { throw GenerationError(description: "Couldn't create a \(type.identifier) image.") }
        let properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw GenerationError(description: "Couldn't write a \(type.identifier) image.")
        }
    }

    /// Random bytes, which no media framework can make sense of.
    static func makeGarbage(at url: URL, byteCount: Int = 4096) throws {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        try Data(bytes).write(to: url)
    }

    // MARK: - Private

    /// A frame with a bar that moves, so consecutive frames differ as real video does.
    private static func pixelBuffer(
        frame: Int,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        width: Int,
        height: Int
    ) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        } else {
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        }
        guard let buffer else { throw GenerationError(description: "Couldn't allocate a pixel buffer.") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw GenerationError(description: "Couldn't address a pixel buffer.")
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let barStart = (frame * 8) % width
        for y in 0..<height {
            let row = pixels + y * bytesPerRow
            for x in 0..<width {
                let inBar = x >= barStart && x < barStart + 24
                row[x * 4 + 0] = inBar ? 255 : UInt8(truncatingIfNeeded: x)
                row[x * 4 + 1] = inBar ? 255 : UInt8(truncatingIfNeeded: y)
                row[x * 4 + 2] = inBar ? 255 : UInt8(truncatingIfNeeded: frame * 4)
                row[x * 4 + 3] = 255
            }
        }
        return buffer
    }

    private static func pcmFormat(channels: Int) throws -> CMAudioFormatDescription {
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = switch channels {
        case 1: kAudioChannelLayoutTag_Mono
        case 2: kAudioChannelLayoutTag_Stereo
        default: kAudioChannelLayoutTag_AAC_5_1
        }
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &description,
            layoutSize: MemoryLayout<AudioChannelLayout>.size,
            layout: &layout,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )
        guard status == noErr, let format else {
            throw GenerationError(description: "Couldn't describe PCM audio (\(status)).")
        }
        return format
    }

    /// A 440 Hz tone, the same on every channel.
    private static func sineSample(start: Int, frames: Int, channels: Int, format: CMAudioFormatDescription) throws -> CMSampleBuffer {
        var samples = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            let value = Float(sin(2 * Double.pi * 440 * Double(start + frame) / sampleRate)) * 0.4
            for channel in 0..<channels {
                samples[frame * channels + channel] = value
            }
        }
        let byteCount = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        )
        guard status == kCMBlockBufferNoErr, let block else {
            throw GenerationError(description: "Couldn't allocate audio (\(status)).")
        }
        status = samples.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard status == kCMBlockBufferNoErr else {
            throw GenerationError(description: "Couldn't fill audio (\(status)).")
        }
        var sample: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: frames,
            presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(sampleRate)),
            packetDescriptions: nil,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else {
            throw GenerationError(description: "Couldn't wrap audio (\(status)).")
        }
        return sample
    }
}
