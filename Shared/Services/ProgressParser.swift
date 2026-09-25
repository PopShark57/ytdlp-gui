import Foundation

/// A single meaningful thing yt-dlp told us.
enum YTDLPEvent: Equatable, Sendable {
    /// A progress tick while bytes are moving.
    case progress(DownloadProgressSnapshot)
    /// The download portion of one file finished.
    case downloadFinished(DownloadProgressSnapshot)
    /// A post-processing stage began or ended.
    case postProcessing(name: String, isFinished: Bool)
    /// yt-dlp announced the file it is writing.
    case destination(path: String, stage: String)
    /// ffmpeg merged separate streams into this file.
    case merged(path: String)
    /// The file was already present and was skipped.
    case alreadyDownloaded(path: String)
    /// Playlist position, e.g. item 3 of 12.
    case playlistItem(index: Int, total: Int)
    case warning(String)
    case error(String)
    /// Anything else. Still shown in the raw log.
    case information(String)
}

/// Converts yt-dlp's line-oriented output into structured events.
///
/// The primary source is the custom `--progress-template`, which yields tab-separated fields
/// and is stable across releases. The bracketed human-readable lines are parsed too, because
/// they are the only place yt-dlp reveals the final output path.
enum ProgressParser {

    /// yt-dlp renders any unavailable template field as this literal.
    private static let missingValue = "NA"

    static func parse(_ rawLine: String) -> YTDLPEvent {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return .information(rawLine) }

        if line.hasPrefix(ArgumentBuilder.progressMarker) {
            return parseProgress(line)
        }
        if line.hasPrefix(ArgumentBuilder.postProcessMarker) {
            return parsePostProcess(line)
        }
        if line.hasPrefix("ERROR:") {
            return .error(String(line.dropFirst("ERROR:".count)).trimmingCharacters(in: .whitespaces))
        }
        if line.hasPrefix("WARNING:") {
            return .warning(String(line.dropFirst("WARNING:".count)).trimmingCharacters(in: .whitespaces))
        }
        if let event = parseBracketed(line) {
            return event
        }
        return .information(line)
    }

    // MARK: - Template lines

    private static func parseProgress(_ line: String) -> YTDLPEvent {
        let payload = String(line.dropFirst(ArgumentBuilder.progressMarker.count))
        // The filename is last and may itself contain the separator, so the split is bounded.
        let fields = payload.components(separatedBy: ArgumentBuilder.fieldSeparator)
        guard fields.count >= 10 else { return .information(line) }

        let status = fields[0]
        var snapshot = DownloadProgressSnapshot()
        snapshot.downloadedBytes = int64(fields[1])
        snapshot.totalBytes = int64(fields[2]) ?? int64(fields[3])
        snapshot.speedBytesPerSecond = double(fields[4])
        snapshot.etaSeconds = int(fields[5])
        snapshot.elapsedSeconds = double(fields[6])
        snapshot.fragmentIndex = int(fields[7])
        snapshot.fragmentCount = int(fields[8])
        snapshot.filename = string(fields[9...].joined(separator: ArgumentBuilder.fieldSeparator))

        switch status {
        case "finished":
            // The final tick reports a stale ETA and speed; clearing them avoids a row that
            // says "100% · 2 s remaining" for the whole post-processing stage.
            snapshot.etaSeconds = nil
            snapshot.speedBytesPerSecond = nil
            if let total = snapshot.totalBytes { snapshot.downloadedBytes = total }
            return .downloadFinished(snapshot)
        case "error":
            return .error("The download reported an error")
        default:
            return .progress(snapshot)
        }
    }

    private static func parsePostProcess(_ line: String) -> YTDLPEvent {
        let payload = String(line.dropFirst(ArgumentBuilder.postProcessMarker.count))
        let fields = payload.components(separatedBy: ArgumentBuilder.fieldSeparator)
        guard fields.count >= 2 else { return .information(line) }
        let name = string(fields[1]) ?? "Processing"
        return .postProcessing(name: name, isFinished: fields[0] == "finished")
    }

    // MARK: - Human-readable lines

    /// Handles lines of the form `[Stage] message`.
    private static func parseBracketed(_ line: String) -> YTDLPEvent? {
        guard line.hasPrefix("["), let closing = line.firstIndex(of: "]") else {
            // Not bracketed, but this one still tells us a file was replaced.
            if line.hasPrefix("Deleting original file ") {
                return .information(line)
            }
            return nil
        }

        let stage = String(line[line.index(after: line.startIndex)..<closing])
        let message = String(line[line.index(after: closing)...])
            .trimmingCharacters(in: .whitespaces)

        if let path = message.dropPrefixIfPresent("Destination: ") {
            return .destination(path: path, stage: stage)
        }

        if stage == "Merger", let quoted = firstQuotedSubstring(in: message) {
            return .merged(path: quoted)
        }

        // `[Metadata] Adding metadata to "…"` also names the final file, which is the only
        // place the path appears when audio extraction renamed it.
        if let quoted = firstQuotedSubstring(in: message),
           message.contains("Adding metadata to") || message.contains("Adding thumbnail to") {
            return .destination(path: quoted, stage: stage)
        }

        if message.hasSuffix("has already been downloaded") {
            let path = String(message.dropLast("has already been downloaded".count))
                .trimmingCharacters(in: .whitespaces)
            return .alreadyDownloaded(path: path)
        }

        if let range = message.range(of: "Downloading item "),
           let (index, total) = parseItemCount(String(message[range.upperBound...])) {
            return .playlistItem(index: index, total: total)
        }

        return .information(line)
    }

    /// Parses the `3 of 12` fragment of a playlist progress line.
    private static func parseItemCount(_ text: String) -> (Int, Int)? {
        let parts = text.split(separator: " ")
        guard parts.count >= 3, parts[1] == "of",
              let index = Int(parts[0]), let total = Int(parts[2]) else { return nil }
        return (index, total)
    }

    /// Returns the contents of the first `"…"` pair, which is how yt-dlp quotes paths.
    private static func firstQuotedSubstring(in text: String) -> String? {
        guard let opening = text.firstIndex(of: "\""),
              let closing = text.lastIndex(of: "\""),
              opening < closing else { return nil }
        let inner = text[text.index(after: opening)..<closing]
        return inner.isEmpty ? nil : String(inner)
    }

    // MARK: - Field conversion

    private static func string(_ field: String) -> String? {
        let trimmed = field.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != missingValue, trimmed != "None" else { return nil }
        return trimmed
    }

    private static func int(_ field: String) -> Int? {
        guard let value = string(field) else { return nil }
        if let exact = Int(value) { return exact }
        // Some fields arrive as floats even when conceptually integral.
        if let approximate = Double(value), approximate.isFinite { return Int(approximate) }
        return nil
    }

    private static func int64(_ field: String) -> Int64? {
        guard let value = string(field) else { return nil }
        if let exact = Int64(value) { return exact }
        if let approximate = Double(value), approximate.isFinite { return Int64(approximate) }
        return nil
    }

    private static func double(_ field: String) -> Double? {
        guard let value = string(field), let number = Double(value), number.isFinite else {
            return nil
        }
        return number
    }
}

private extension String {
    /// Returns the remainder after `prefix`, or `nil` when the prefix isn't there.
    func dropPrefixIfPresent(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        let remainder = String(dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return remainder.isEmpty ? nil : remainder
    }
}
