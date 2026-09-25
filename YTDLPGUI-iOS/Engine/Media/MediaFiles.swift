import Foundation

/// File-system plumbing shared by every media operation.
///
/// yt-dlp retries and resumes, so an operation must never leave a half-written file where the
/// finished one belongs. Everything is written to a hidden file beside the destination and
/// renamed over it only once complete: a rename within one directory is atomic, and it replaces
/// whatever the destination held, which is exactly what a retry needs.
enum MediaFiles {

    /// The file's name in curly quotes, for messages.
    static func quotedName(_ url: URL) -> String {
        "“\(url.lastPathComponent)”"
    }

    /// Throws unless `url` names an existing file.
    static func requireFile(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) else {
            throw MediaProcessingError.failed(
                "\(quotedName(url)) doesn't exist. It may have been moved or deleted before processing finished."
            )
        }
        guard !isDirectory.boolValue else {
            throw MediaProcessingError.failed("\(quotedName(url)) is a folder, not a media file.")
        }
    }

    /// `url` with its extension replaced by `pathExtension`.
    static func replacingExtension(of url: URL, with pathExtension: String) -> URL {
        guard url.pathExtension.lowercased() != pathExtension else { return url }
        let base = url.pathExtension.isEmpty ? url : url.deletingPathExtension()
        return base.appendingPathExtension(pathExtension)
    }

    /// Runs `write` with a fresh, not-yet-existing path beside `destination`, then moves what it
    /// wrote into place. If `write` throws, the partial file is deleted and `destination` is left
    /// exactly as it was.
    static func writeAtomically<T>(to destination: URL, _ write: (URL) async throws -> T) async throws -> T {
        let staging = try stagingURL(for: destination)
        do {
            let result = try await write(staging)
            try moveIntoPlace(staging, destination: destination)
            return result
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Copies `source` to `destination` atomically, replacing anything already there.
    static func copy(_ source: URL, to destination: URL) async throws {
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        try await writeAtomically(to: destination) { staging in
            do {
                try FileManager.default.copyItem(at: source, to: staging)
            } catch {
                throw MediaProcessingError.failed(
                    "Couldn't copy \(quotedName(source)): \(MediaErrorText.describe(error))"
                )
            }
        }
    }

    // MARK: - Private

    /// A hidden sibling of `destination` that keeps its extension, because AVAudioFile and
    /// ImageIO choose the file format from it.
    private static func stagingURL(for destination: URL) throws -> URL {
        let directory = destination.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw MediaProcessingError.failed(
                "Couldn't create the folder for \(quotedName(destination)): \(MediaErrorText.describe(error))"
            )
        }
        let stem = destination.deletingPathExtension().lastPathComponent
        let token = UUID().uuidString.prefix(8).lowercased()
        var name = ".\(stem).partial-\(token)"
        if !destination.pathExtension.isEmpty {
            name += ".\(destination.pathExtension)"
        }
        return directory.appending(path: name, directoryHint: .notDirectory)
    }

    private static func moveIntoPlace(_ staging: URL, destination: URL) throws {
        let status = staging.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in
                guard let source, let target else { return EINVAL }
                return rename(source, target) == 0 ? 0 : errno
            }
        }
        guard status == 0 else {
            throw MediaProcessingError.failed(
                "Couldn't save \(quotedName(destination)): \(String(cString: strerror(status)))."
            )
        }
    }
}

/// Turns framework errors into a sentence for the person reading the download log.
enum MediaErrorText {

    /// AVFoundation's descriptions are terse ("Cannot Open"), so the failure reason and the
    /// underlying OSStatus are appended: they are what makes a report diagnosable.
    static func describe(_ error: any Error) -> String {
        if let mediaError = error as? MediaProcessingError {
            return mediaError.errorDescription ?? "\(mediaError)"
        }
        let nsError = error as NSError
        var parts = [sentence(nsError.localizedDescription)]
        if let reason = nsError.localizedFailureReason, !reason.isEmpty, !parts.contains(sentence(reason)) {
            parts.append(sentence(reason))
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("(\(nsError.domain) \(nsError.code), \(underlying.domain) \(underlying.code))")
        } else {
            parts.append("(\(nsError.domain) \(nsError.code))")
        }
        return parts.joined(separator: " ")
    }

    private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, !".!?".contains(last) else { return trimmed }
        return trimmed + "."
    }
}
