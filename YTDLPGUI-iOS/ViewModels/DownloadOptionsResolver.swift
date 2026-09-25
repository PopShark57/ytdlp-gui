import Foundation

/// Fills in the parts of `DownloadOptions` that this install manages, and removes what the
/// embedded engine can't use.
///
/// Options reach the queue from the Download screen, the Share extension, Shortcuts, history and
/// the saved queue, and some of those were written by an earlier install whose container path no
/// longer exists. So paths are never taken from the options themselves: every one is replaced
/// with this launch's location, every time a download is queued or its arguments are built.
/// The input is never modified, so the text a person is typing into Advanced Options stays theirs.
@MainActor
struct DownloadOptionsResolver {

    let storage: StorageManager
    let cookies: CookieStore

    func resolve(_ options: DownloadOptions) -> DownloadOptions {
        var resolved = options
        resolved.outputDirectory = storage.downloadsDirectory
        resolved.downloadArchivePath = options.useDownloadArchive
            ? storage.downloadArchiveURL.path(percentEncoded: false)
            : ""
        resolved.cookieFilePath = cookies.cookieFileURL?.path(percentEncoded: false) ?? ""
        // Browsers' cookie stores aren't reachable from an iOS app; imported cookies replace them.
        resolved.cookieBrowser = .none
        // yt-dlp also reads a `yt-dlp.conf` from the output folder, which on iOS is the
        // user-writable Documents folder. It must not be able to change what the preview shows.
        resolved.ignoreUserConfig = true
        // MP3 and Opus can't be encoded on iOS; the argument builder makes them M4A, and saying
        // so here keeps the queue row and history entry truthful.
        if !resolved.audioFormat.isAvailableInEmbeddedEngine {
            resolved.audioFormat = .m4a
        }
        resolved.customArguments = Self.sanitizedCustomArguments(options.customArguments).arguments
        return resolved
    }

    /// Custom arguments with everything the embedded engine refuses taken out, plus the names
    /// of the options that were removed so the person can be told.
    nonisolated static func sanitizedCustomArguments(_ input: String) -> (arguments: String, removed: [String]) {
        let inspection = CustomArgumentPolicy.inspect(input, context: .embedded)
        guard inspection.isBlocked else { return (input, []) }
        let arguments = inspection.safeArguments.map(ShellQuoting.quote).joined(separator: " ")
        return (arguments, inspection.blockedFlags)
    }
}
