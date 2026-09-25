import AVFoundation

/// yt-dlp's merge step (`bestvideo+bestaudio`): combines separately downloaded streams into one
/// file without re-encoding.
struct MediaMerger {

    /// Follows FFmpegMergerPP's stream mapping — the first video and the first audio track of
    /// each input — so an input carrying both contributes both, as with ffmpeg. The audio is
    /// trimmed to the video's length, since DASH audio often runs a few frames longer.
    func merge(inputs: [URL], output: URL, container: MediaContainer) async throws {
        guard !inputs.isEmpty else {
            throw MediaProcessingError.failed("There was nothing to merge into \(MediaFiles.quotedName(output)).")
        }
        var sources: [MediaSource] = []
        for input in inputs {
            sources.append(try await MediaSource.open(input))
        }

        let videos = container == .m4a ? [] : sources.compactMap { $0.primaryTrack(ofType: .video) }
        let audios = sources.compactMap { $0.primaryTrack(ofType: .audio) }
        guard !videos.isEmpty || !audios.isEmpty else {
            let names = inputs.map(MediaFiles.quotedName).joined(separator: ", ")
            throw MediaProcessingError.failed("None of \(names) contains audio or video to merge.")
        }

        let videoEnd = videos.map(\.timeRange.end).max()
        let tracks = videos.map { TrackCopy($0) } + audios.map { audio in
            guard let videoEnd, audio.timeRange.end > videoEnd else { return TrackCopy(audio) }
            return TrackCopy(audio, timeRange: CMTimeRange(start: audio.timeRange.start, end: max(audio.timeRange.start, videoEnd)))
        }

        let copy = PassthroughCopy(tracks: tracks, fileType: container.fileType, endTime: videoEnd)
        try await MediaFiles.writeAtomically(to: output) { staging in
            try await copy.write(to: staging, outputName: MediaFiles.quotedName(output))
        }
    }
}
