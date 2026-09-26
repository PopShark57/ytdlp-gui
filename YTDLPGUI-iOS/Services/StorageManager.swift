import Foundation
import Observation
import os

/// Where downloads live on this device, and how much room they take.
///
/// Every location is derived from the app's container at launch. iOS moves the container when it
/// updates or reinstalls the app, so no absolute path from a previous launch is ever reused; the
/// queue and composer ask for these URLs afresh whenever they build a download.
@MainActor
@Observable
final class StorageManager {

    /// `Documents`, shown in the Files app under On My iPhone › YTDLP GUI.
    let downloadsDirectory: URL
    /// Where yt-dlp keeps partial files until they finish (`--paths temp:`), so the Files app
    /// only ever shows finished downloads. Caches aren't backed up, which suits half a video.
    let partialDownloadsDirectory: URL
    /// `Application Support`, which holds the download archive and other app-managed files.
    let applicationSupportDirectory: URL
    /// The archive yt-dlp records finished downloads in when "Download archive" is on. The app
    /// manages it so there is no path for the user to choose or lose.
    let downloadArchiveURL: URL

    private(set) var downloadsSizeBytes: Int64?
    private(set) var partialDownloadsSizeBytes: Int64?
    private(set) var availableCapacityBytes: Int64?
    /// Why the last attempt to clear partial downloads did nothing or failed, if it did.
    private(set) var lastError: String?

    /// Consulted before partial downloads are deleted. A running download appends to its
    /// `.part` file and renames it when it finishes, so deleting it mid-way makes it fail.
    @ObservationIgnored
    var isPartialDownloadInUse: @MainActor () -> Bool = { false }

    private let logger = AppLog.storage

    init(
        documentsDirectory: URL? = nil,
        cachesDirectory: URL? = nil,
        applicationSupportDirectory: URL? = nil
    ) {
        let fileManager = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)

        downloadsDirectory = documentsDirectory
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? home.appending(path: "Documents", directoryHint: .isDirectory)
        let caches = cachesDirectory
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? home.appending(path: "Library/Caches", directoryHint: .isDirectory)
        self.applicationSupportDirectory = applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appending(path: "Library/Application Support", directoryHint: .isDirectory)

        partialDownloadsDirectory = caches.appending(path: "Partial Downloads", directoryHint: .isDirectory)
        downloadArchiveURL = self.applicationSupportDirectory.appending(path: "download-archive.txt")

        for directory in [downloadsDirectory, partialDownloadsDirectory, self.applicationSupportDirectory] {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                // Not fatal here: the queue creates the folders again before each download and
                // turns a failure into a message on that download.
                logger.error("Couldn't create \(directory.path(percentEncoded: false), privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Opens the app's folder in the Files app.
    ///
    /// `shareddocuments://` takes the same path as the folder's `file://` URL, so the scheme is
    /// swapped on the file URL's components, which keeps Foundation's percent-encoding intact.
    var filesAppURL: URL? {
        guard var components = URLComponents(url: downloadsDirectory, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = "shareddocuments"
        return components.url
    }

    /// Recomputes the sizes shown in Settings. The folders are walked off the main actor because
    /// a long playlist can leave thousands of files behind.
    func refreshUsage() async {
        let downloads = downloadsDirectory
        let partial = partialDownloadsDirectory
        let usage = await Task.detached(priority: .utility) {
            (
                downloads: Self.allocatedSize(of: downloads),
                partial: Self.allocatedSize(of: partial),
                available: Self.availableCapacity(at: downloads)
            )
        }.value
        downloadsSizeBytes = usage.downloads
        partialDownloadsSizeBytes = usage.partial
        availableCapacityBytes = usage.available
    }

    /// Deletes partial downloads left behind by cancelled or failed downloads.
    ///
    /// Refuses while a download is running, because its partial file is in the same folder and
    /// can't be told apart from abandoned ones. The deletion itself runs on the main actor so a
    /// download cannot start between the check and the deletion.
    func clearPartialDownloads() async {
        guard !isPartialDownloadInUse() else {
            lastError = "Partial downloads can't be cleared while downloads are running. Try again when they've finished."
            return
        }
        lastError = nil
        let fileManager = FileManager.default
        do {
            let contents = try fileManager.contentsOfDirectory(
                at: partialDownloadsDirectory,
                includingPropertiesForKeys: nil
            )
            var failures = 0
            for url in contents {
                do {
                    try fileManager.removeItem(at: url)
                } catch {
                    failures += 1
                    logger.error("Couldn't delete \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            if failures > 0 {
                lastError = failures == 1
                    ? "One partial download couldn't be deleted."
                    : "\(failures) partial downloads couldn't be deleted."
            }
        } catch CocoaError.fileReadNoSuchFile {
            // Nothing has ever been downloaded; there is nothing to clear.
        } catch {
            lastError = "Partial downloads couldn't be cleared: \(error.localizedDescription)"
        }
        try? fileManager.createDirectory(at: partialDownloadsDirectory, withIntermediateDirectories: true)
        await refreshUsage()
    }

    // MARK: - Measuring

    /// The space a folder's files occupy on disk, or `nil` when the folder can't be read.
    nonisolated static func allocatedSize(of directory: URL) -> Int64? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys
        ) else { return nil }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Free space as iOS reports it for user-initiated work, which counts purgeable space the
    /// system would free on demand.
    nonisolated static func availableCapacity(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
