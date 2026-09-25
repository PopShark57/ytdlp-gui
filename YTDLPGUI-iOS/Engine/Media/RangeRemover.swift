import AVFoundation

/// `--sponsorblock-remove` and `--remove-chapters`: cuts spans out of a file without
/// re-encoding it.
///
/// ffmpeg's concat demuxer can only cut on keyframes; an edited composition exported by
/// passthrough cuts exactly, keeping whole GOPs in the file and an edit list that skips the
/// unwanted frames, which every Apple player and ffmpeg honour.
struct RangeRemover {

    func removeRanges(input: URL, output: URL, ranges: [ClosedRange<Double>]) async throws {
        try MediaFiles.requireFile(input)
        guard !ranges.isEmpty else {
            try await MediaFiles.copy(input, to: output)
            return
        }

        let source = try await MediaSource.open(input)
        guard let duration = source.durationSeconds, duration > 0 else {
            throw MediaProcessingError.failed("Couldn't tell how long \(MediaFiles.quotedName(input)) is, so nothing was cut.")
        }
        let cuts = Self.normalized(ranges, duration: duration)
        guard !cuts.isEmpty else {
            try await MediaFiles.copy(input, to: output)
            return
        }
        let removed = cuts.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        guard duration - removed >= 0.001 else {
            throw MediaProcessingError.failed("Those cuts would remove all of \(MediaFiles.quotedName(input)), so nothing was cut.")
        }

        let fileType = MediaFileType.forExtension(output.pathExtension)
            ?? MediaFileType.forExtension(input.pathExtension)
            ?? (source.primaryTrack(ofType: .video) == nil ? .m4a : .mp4)
        // Chapter tracks are left behind: their times no longer fit, and yt-dlp writes the
        // adjusted chapters itself afterwards.
        let tracks = source.tracks.filter(\.isAudiovisual).map { TrackCopy($0) }
        guard !tracks.isEmpty else {
            throw MediaProcessingError.failed("\(MediaFiles.quotedName(input)) has no audio or video to cut.")
        }
        let export = ExportSessionCopy(
            tracks: tracks,
            fileType: fileType,
            endTime: nil,
            removedRanges: cuts.map { Self.timeRange($0) },
            metadata: (try? await source.asset.load(.metadata)) ?? []
        )

        try await MediaFiles.writeAtomically(to: output) { staging in
            guard try await export.write(to: staging) else {
                let codecs = Set(tracks.map(\.source.codecName)).sorted().joined(separator: " and ")
                throw MediaProcessingError.unsupported(
                    "iOS can't cut \(codecs) in an \(MediaFileType.name(of: fileType)) file without re-encoding it, "
                        + "so \(MediaFiles.quotedName(input)) was not cut."
                )
            }
        }
    }

    /// Sorted, clamped to the file, and with overlapping or touching spans merged, so removing
    /// them from last to first never shifts a span that is still to be removed.
    static func normalized(_ ranges: [ClosedRange<Double>], duration: Double) -> [ClosedRange<Double>] {
        let clamped = ranges
            .compactMap { range -> ClosedRange<Double>? in
                guard range.lowerBound.isFinite, range.upperBound.isFinite else { return nil }
                let lower = max(0, range.lowerBound)
                let upper = min(duration, range.upperBound)
                return upper - lower >= 0.001 ? lower...upper : nil
            }
            .sorted { $0.lowerBound < $1.lowerBound }

        var merged: [ClosedRange<Double>] = []
        for range in clamped {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private static func timeRange(_ range: ClosedRange<Double>) -> CMTimeRange {
        let timescale: CMTimeScale = 90_000
        return CMTimeRange(
            start: CMTime(seconds: range.lowerBound, preferredTimescale: timescale),
            end: CMTime(seconds: range.upperBound, preferredTimescale: timescale)
        )
    }
}
