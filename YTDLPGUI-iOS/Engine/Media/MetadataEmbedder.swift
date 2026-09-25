import AVFoundation
import os

/// `--embed-metadata`, `--embed-chapters` and `--embed-thumbnail`: rewrites a finished file with
/// tags, cover art and chapters.
///
/// The file is copied sample by sample — nothing is re-encoded — into a sibling that then
/// replaces it. Whatever the call doesn't mention is carried over: yt-dlp embeds metadata and
/// chapters in one step and the thumbnail in a later one, and the second must not undo the first.
struct MetadataEmbedder {

    func embed(into file: URL, metadata: MediaMetadata?, artwork: URL?, chapters: [MediaChapter]?) async throws {
        try MediaFiles.requireFile(file)
        guard let fileType = MediaFileType.forExtension(file.pathExtension) else {
            throw MediaProcessingError.unsupported(
                "Tags, cover art and chapters can only be embedded in MP4, M4A and MOV files on iPhone and iPad; "
                    + "\(MediaFiles.quotedName(file)) was left as it is."
            )
        }
        let requestedChapters = chapters.flatMap { $0.isEmpty ? nil : $0 }
        guard metadata != nil || artwork != nil || requestedChapters != nil else { return }

        let source = try await MediaSource.open(file)
        let tags = MetadataTags(fileType: fileType)
        var replacements = metadata.map(tags.items(for:)) ?? []
        if let artwork {
            let (data, format) = try coverArt(from: artwork)
            replacements += tags.artworkItems(data, format: format)
        }
        let existing = (try? await source.asset.load(.metadata)) ?? []
        let fileMetadata = tags.merged(existing: existing, replacements: replacements)

        let chapterTrack: ChapterTrack?
        if let requestedChapters {
            chapterTrack = try ChapterTrack(chapters: requestedChapters, duration: source.duration)
        } else {
            let current = await ChapterTrack.existingChapters(in: source.asset, duration: source.duration)
            chapterTrack = try ChapterTrack(chapters: current, duration: source.duration)
        }

        let copy = SampleCopyWriter(
            tracks: carriedTracks(of: source),
            fileType: fileType,
            endTime: nil,
            metadata: fileMetadata,
            chapters: chapterTrack
        )
        let chaptersAreEverything = requestedChapters != nil && metadata == nil && artwork == nil
        do {
            try await write(copy, over: file)
        } catch {
            // Chapters are the part of this most likely to be refused, and the least important;
            // tags and cover art are still worth writing without them.
            guard chapterTrack != nil, !(error is CancellationError) else { throw error }
            if chaptersAreEverything {
                throw MediaProcessingError.unsupported(
                    "iOS couldn't write chapters into \(MediaFiles.quotedName(file)): "
                        + "\(Self.reason(error))"
                )
            }
            MediaLog.logger.warning(
                "Writing \(MediaFiles.quotedName(file), privacy: .public) without chapters: \(Self.reason(error), privacy: .public)"
            )
            var withoutChapters = copy
            withoutChapters.chapters = nil
            try await write(withoutChapters, over: file)
        }
    }

    // MARK: - Private

    private func write(_ copy: SampleCopyWriter, over file: URL) async throws {
        try await MediaFiles.writeAtomically(to: file) { staging in
            try await copy.write(to: staging, outputName: MediaFiles.quotedName(file))
        }
    }

    /// The audio and video tracks. Existing chapter tracks are rebuilt rather than copied, and
    /// the embedded engine never adds subtitle tracks (subtitles are saved as separate files).
    private func carriedTracks(of source: MediaSource) -> [TrackCopy] {
        source.tracks.filter(\.isAudiovisual).map { TrackCopy($0) }
    }

    /// Cover art as JPEG or PNG bytes, converting anything else (usually WebP) to PNG — lossless,
    /// as yt-dlp prefers.
    private func coverArt(from url: URL) throws -> (Data, ImageFormat) {
        try MediaFiles.requireFile(url)
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw MediaProcessingError.failed(
                "Couldn't read the thumbnail \(MediaFiles.quotedName(url)): \(MediaErrorText.describe(error))"
            )
        }
        if let format = ImageConverter.coverArtFormat(of: data) {
            return (data, format)
        }
        return (try ImageConverter.encodedImage(at: url, as: .png), .png)
    }

    private static func reason(_ error: any Error) -> String {
        if error is SampleCopyWriter.ChapterTrackRejected {
            return "the file type doesn't accept a chapter track."
        }
        return MediaErrorText.describe(error)
    }
}
