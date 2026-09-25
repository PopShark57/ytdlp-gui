import AudioToolbox
import AVFoundation

/// Decides the rate, channels and channel layout of converted audio, and the settings for each
/// encoder.
///
/// The source's rate and layout are kept wherever the encoder allows, and adjusted only when it
/// doesn't: AAC stops at 48 kHz, and each codec numbers surround channels its own way. The
/// choices come from asking Core Audio what it will accept rather than from a table, and every
/// candidate is checked before an encoder is created — AVAssetWriterInput raises an Objective-C
/// exception, which no Swift code can catch, for settings it rejects.
struct AudioFormatPlan {
    private(set) var sampleRate: Double
    private(set) var channels: Int
    /// The layout written, as `AVChannelLayoutKey` wants it; nil for mono and stereo. The reader
    /// decodes straight to it, so Core Audio reorders the channels when the encoder's order
    /// differs from the source's.
    private(set) var layout: Data?

    private let sourceLayout: Data?
    private let sourceBitDepth: Int?

    /// AAC's rate when yt-dlp asks for no particular quality: transparent for stereo.
    static let defaultAACBitRate = 256_000

    init(source: SourceTrack) throws {
        guard let description = source.audioStreamDescription,
              description.mSampleRate > 0, description.mChannelsPerFrame > 0
        else {
            throw MediaProcessingError.unsupported("iOS can't tell how the \(source.codecName) audio is encoded.")
        }
        sampleRate = description.mSampleRate
        channels = Int(description.mChannelsPerFrame)
        sourceLayout = source.audioChannelLayout
        sourceBitDepth = Self.bitDepth(of: description)
    }

    /// What the reader decodes to: interleaved 32-bit float, which every encoder takes and
    /// which loses nothing from a 24-bit source.
    var decodedSettings: [String: Any] {
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        settings[AVChannelLayoutKey] = layout
        return settings
    }

    /// Settings for `codec`, adjusting the plan until `accepts` agrees.
    ///
    /// Tries the source as it is, then (for AAC) a rate the encoder supports, then a stereo
    /// downmix — the least destructive change first.
    /// - Parameters:
    ///   - bitRate: Only used for AAC, clamped to what the encoder accepts for the final rate
    ///     and channel count.
    ///   - accepts: Whether the destination takes these settings, e.g. AVAssetWriter's
    ///     `canApply(outputSettings:forMediaType:)`.
    mutating func settings(
        for codec: AudioCodecRequest,
        bitRate: Int? = nil,
        accepts: ([String: Any]) -> Bool = { _ in true }
    ) throws -> [String: Any] {
        let formatID = Self.formatID(for: codec)
        var candidates = [(sampleRate, channels)]
        if formatID == kAudioFormatMPEG4AAC, sampleRate > 48_000 || sampleRate < 8_000 {
            candidates.append((sampleRate > 48_000 ? 48_000 : 44_100, channels))
        }
        if channels > 2 {
            candidates += candidates.map { ($0.0, 2) }
        }

        for (rate, count) in candidates {
            guard let layout = layout(for: formatID, channels: count) else { continue }
            let settings = Self.settings(
                formatID: formatID,
                sampleRate: rate,
                channels: count,
                layout: layout,
                bitRate: bitRate,
                losslessBitDepth: losslessBitDepth
            )
            if accepts(settings) {
                sampleRate = rate
                channels = count
                self.layout = layout.data
                return settings
            }
        }
        let kHz = (sampleRate / 1000).formatted(.number.precision(.fractionLength(0...1)))
        throw MediaProcessingError.unsupported(
            "iOS can't encode \(channels)-channel \(kHz) kHz audio as \(codec.rawValue.uppercased())."
        )
    }

    // MARK: - Private

    /// A chosen layout; `data` is nil for mono and stereo, which need none.
    private struct Layout {
        var data: Data?
    }

    /// Lossy sources decode to more than 16 bits of float, but storing that losslessly only
    /// inflates the file; 24 bits is kept for sources that really had it.
    private var losslessBitDepth: Int {
        (sourceBitDepth ?? 16) > 16 ? 24 : 16
    }

    /// The source's layout if the encoder can write it, else the encoder's own layout for this
    /// many channels, or nil when it has none.
    private func layout(for formatID: AudioFormatID, channels count: Int) -> Layout? {
        guard count > 2 else { return Layout(data: nil) }
        let sourceTag = count == channels ? sourceLayout.flatMap(Self.layoutTag) : nil
        if formatID == kAudioFormatLinearPCM {
            // WAV stores any layout; the channel mask is derived from it.
            if count == channels, let sourceLayout { return Layout(data: sourceLayout) }
            return Layout(data: Self.layoutData(kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(count)))
        }
        let encodable = Self.encodableLayoutTags(formatID: formatID, channels: count)
        if let sourceTag, encodable.contains(sourceTag), let sourceLayout {
            return Layout(data: sourceLayout)
        }
        return encodable.first.map { Layout(data: Self.layoutData($0)) }
    }

    private static func settings(
        formatID: AudioFormatID,
        sampleRate: Double,
        channels: Int,
        layout: Layout,
        bitRate: Int?,
        losslessBitDepth: Int
    ) -> [String: Any] {
        var settings: [String: Any] = [
            AVFormatIDKey: formatID,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        settings[AVChannelLayoutKey] = layout.data
        switch formatID {
        case kAudioFormatMPEG4AAC:
            let requested = bitRate.flatMap { $0 > 0 ? $0 : nil } ?? defaultAACBitRate
            settings[AVEncoderBitRateKey] = clampedAACBitRate(requested, sampleRate: sampleRate, channels: channels)
            // A chosen bit rate should mean what it means to ffmpeg (`-b:a`): the file's rate.
            // Apple's default long-term-average strategy spends far less on simple material.
            settings[AVEncoderBitRateStrategyKey] = AVAudioBitRateStrategy_Constant
        case kAudioFormatAppleLossless, kAudioFormatFLAC:
            settings[AVEncoderBitDepthHintKey] = losslessBitDepth
        default:
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
        }
        return settings
    }

    private static func formatID(for codec: AudioCodecRequest) -> AudioFormatID {
        switch codec {
        case .copy, .aac: kAudioFormatMPEG4AAC
        case .alac: kAudioFormatAppleLossless
        case .flac: kAudioFormatFLAC
        case .wav: kAudioFormatLinearPCM
        }
    }

    /// The bit rate nearest `requested` that the AAC encoder accepts for this rate and channel
    /// count; `requested` itself if Core Audio can't say.
    private static func clampedAACBitRate(_ requested: Int, sampleRate: Double, channels: Int) -> Int {
        let ranges = aacBitRates(sampleRate: sampleRate, channels: channels)
        guard !ranges.isEmpty else { return requested }
        let target = Double(requested)
        let nearest = ranges
            .map { range in min(max(target, range.mMinimum), range.mMaximum) }
            .min { abs($0 - target) < abs($1 - target) }
        return Int(nearest ?? target)
    }

    private static func aacBitRates(sampleRate: Double, channels: Int) -> [AudioValueRange] {
        let channelCount = UInt32(channels)
        var input = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channelCount,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channelCount,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var output = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var converter: AudioConverterRef?
        guard AudioConverterNew(&input, &output, &converter) == noErr, let converter else { return [] }
        defer { AudioConverterDispose(converter) }

        var size: UInt32 = 0
        guard AudioConverterGetPropertyInfo(converter, kAudioConverterApplicableEncodeBitRates, &size, nil) == noErr,
              size >= UInt32(MemoryLayout<AudioValueRange>.stride)
        else { return [] }
        var ranges = [AudioValueRange](
            repeating: AudioValueRange(),
            count: Int(size) / MemoryLayout<AudioValueRange>.stride
        )
        let status = ranges.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return kAudioConverterErr_UnspecifiedError }
            return AudioConverterGetProperty(converter, kAudioConverterApplicableEncodeBitRates, &size, base)
        }
        return status == noErr ? ranges : []
    }

    /// The layouts Core Audio's encoder for `formatID` can write with `channels` channels.
    private static func encodableLayoutTags(formatID: AudioFormatID, channels: Int) -> [AudioChannelLayoutTag] {
        var description = AudioStreamBasicDescription()
        description.mSampleRate = 48_000
        description.mFormatID = formatID
        description.mChannelsPerFrame = UInt32(channels)
        let specifierSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(
            kAudioFormatProperty_AvailableEncodeChannelLayoutTags, specifierSize, &description, &size
        ) == noErr, size > 0 else { return [] }
        var tags = [AudioChannelLayoutTag](repeating: 0, count: Int(size) / MemoryLayout<AudioChannelLayoutTag>.size)
        let status = tags.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return kAudioFormatUnspecifiedError }
            return AudioFormatGetProperty(
                kAudioFormatProperty_AvailableEncodeChannelLayoutTags, specifierSize, &description, &size, base
            )
        }
        guard status == noErr else { return [] }
        return tags.filter { AudioChannelLayoutTag_GetNumberOfChannels($0) == UInt32(channels) }
    }

    private static func layoutTag(_ data: Data) -> AudioChannelLayoutTag? {
        guard data.count >= MemoryLayout<AudioChannelLayout>.size else { return nil }
        return data.withUnsafeBytes { $0.loadUnaligned(as: AudioChannelLayout.self).mChannelLayoutTag }
    }

    private static func layoutData(_ tag: AudioChannelLayoutTag) -> Data {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = tag
        return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
    }

    private static func bitDepth(of description: AudioStreamBasicDescription) -> Int? {
        switch description.mFormatID {
        case kAudioFormatLinearPCM:
            return description.mBitsPerChannel > 0 ? Int(description.mBitsPerChannel) : nil
        case kAudioFormatAppleLossless, kAudioFormatFLAC:
            // Both codecs record the source depth in the format flags.
            switch description.mFormatFlags {
            case kAppleLosslessFormatFlag_16BitSourceData: return 16
            case kAppleLosslessFormatFlag_20BitSourceData: return 20
            case kAppleLosslessFormatFlag_24BitSourceData: return 24
            case kAppleLosslessFormatFlag_32BitSourceData: return 32
            default: return nil
            }
        default:
            return nil
        }
    }
}
