import Foundation

/// Turns the host's event JSON ("Events" in Docs/iOS-Architecture.md) into `EngineEvent`s.
enum EngineEventDecoder {

    /// Decodes one event. Unreadable JSON, and event types this app doesn't know (a newer host
    /// may add some), produce `nil` so they can be skipped without disturbing the job.
    static func decode(_ data: Data) -> EngineEvent? {
        guard let object = EngineJSON.object(from: data) else { return nil }
        return decode(object)
    }

    static func decode(_ object: [String: Any]) -> EngineEvent? {
        switch EngineJSON.string(object["type"]) {
        case "log":
            return log(from: object)
        case "progress":
            return progress(from: object)
        case "postprocess":
            return postProcessing(from: object)
        case "item":
            return .item(item(from: object))
        case "file":
            // Hosts before `main` existed only reported main files.
            let isMain = EngineJSON.bool(object["main"]) ?? true
            return EngineJSON.nonEmptyString(object["path"]).map { .file(path: $0, isMain: isMain) }
        default:
            return nil
        }
    }

    // MARK: - Event types

    private static func log(from object: [String: Any]) -> EngineEvent? {
        guard let message = EngineJSON.string(object["message"]) else { return nil }
        let level = EngineJSON.string(object["level"]).flatMap(EngineLogLevel.init(rawValue:)) ?? .info
        return .log(level, message)
    }

    private static func progress(from object: [String: Any]) -> EngineEvent {
        let status = EngineJSON.string(object["status"]).flatMap(EngineProgressStatus.init(rawValue:)) ?? .downloading
        var snapshot = progressSnapshot(from: object)
        if status == .finished {
            // As in `ProgressParser`: the final tick carries a stale ETA and speed, and clearing
            // them avoids a row reading "100% · 2 s remaining" for the whole post-processing stage.
            snapshot.etaSeconds = nil
            snapshot.speedBytesPerSecond = nil
            if let total = snapshot.totalBytes {
                snapshot.downloadedBytes = total
            }
        }
        return .progress(snapshot, status: status)
    }

    /// Reads the fields of a yt-dlp progress hook dictionary.
    static func progressSnapshot(from object: [String: Any]) -> DownloadProgressSnapshot {
        var snapshot = DownloadProgressSnapshot()
        snapshot.downloadedBytes = EngineJSON.int64(object["downloaded_bytes"])
        // As in `ProgressParser`: fragmented (HLS, DASH) downloads usually know only an estimate.
        snapshot.totalBytes = EngineJSON.int64(object["total_bytes"]) ?? EngineJSON.int64(object["total_bytes_estimate"])
        snapshot.speedBytesPerSecond = EngineJSON.double(object["speed"])
        snapshot.etaSeconds = EngineJSON.int(object["eta"])
        snapshot.elapsedSeconds = EngineJSON.double(object["elapsed"])
        snapshot.fragmentIndex = EngineJSON.int(object["fragment_index"])
        snapshot.fragmentCount = EngineJSON.int(object["fragment_count"])
        snapshot.filename = EngineJSON.nonEmptyString(object["filename"])
        return snapshot
    }

    private static func postProcessing(from object: [String: Any]) -> EngineEvent {
        let status = EngineJSON.string(object["status"]).flatMap(EnginePostProcessStatus.init(rawValue:)) ?? .processing
        return .postProcessing(
            name: EngineJSON.nonEmptyString(object["postprocessor"]) ?? "Processing",
            status: status,
            filePath: EngineJSON.nonEmptyString(object["filepath"])
        )
    }

    private static func item(from object: [String: Any]) -> EngineItemInfo {
        EngineItemInfo(
            id: EngineJSON.nonEmptyString(object["id"]),
            title: EngineJSON.nonEmptyString(object["title"]),
            uploader: EngineJSON.nonEmptyString(object["uploader"]),
            thumbnailURL: EngineJSON.url(object["thumbnail"]),
            durationSeconds: EngineJSON.double(object["duration"]),
            webpageURL: EngineJSON.url(object["webpage_url"]),
            extractor: EngineJSON.nonEmptyString(object["extractor"]),
            playlistIndex: EngineJSON.int(object["playlist_index"]),
            playlistCount: EngineJSON.int(object["playlist_count"])
        )
    }
}
