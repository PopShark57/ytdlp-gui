import AppKit
import Foundation
import Observation
import os

/// Owns the download queue and runs the downloads.
///
/// Concurrency is managed here rather than by yt-dlp: each queue item is one `yt-dlp` process,
/// and at most `settings.maximumConcurrentDownloads` of them run at a time. Everything is
/// `@MainActor`, which keeps the model single-threaded; the only work happening off the main
/// actor is the child process itself, whose output arrives through an `AsyncStream`.
@MainActor
@Observable
final class DownloadQueue {

    private(set) var items: [DownloadItem] = []

    struct Interrupted: Codable, Identifiable {
        let id: UUID
        let url: String
        let title: String
        let options: DownloadOptions
        let removedSecrets: [String]
    }

    private(set) var interrupted: [Interrupted] = []
    private let recoveryURL: URL
    private var terminating = false
    private let settings: AppSettings
    private let toolchain: Toolchain
    private let history: HistoryStore
    private let notifications: NotificationService
    private let logger = Logger(subsystem: "io.github.ytdlpgui.YTDLPGUI", category: "queue")

    /// Live processes, keyed by item id. Kept out of `DownloadItem` so the model stays a plain
    /// value-ish object that SwiftUI can diff cheaply.
    private var sessions: [DownloadItem.ID: ProcessSession] = [:]
    private var retiring: [UUID: DownloadItem] = [:]
    private var cancelRequested = Set<UUID>()
    var notice: String?
    private var runners: [DownloadItem.ID: Task<Void, Never>] = [:]

    /// Counts for the "queue finished" notification, reset whenever the queue drains.
    private var completedSinceIdle = 0
    private var failedSinceIdle = 0

    init(
        settings: AppSettings,
        toolchain: Toolchain,
        history: HistoryStore,
        notifications: NotificationService
    ) {
        recoveryURL = history.storageDirectory.appending(path: "unfinished.json")
        if FileManager.default.fileExists(atPath: recoveryURL.path) {
            do {
                interrupted = try JSONDecoder().decode([Interrupted].self, from: Data(contentsOf: recoveryURL))
            } catch {
                notice = "Could not restore unfinished downloads: \(error.localizedDescription)"
            }
        }
        self.settings = settings
        self.toolchain = toolchain
        self.history = history
        self.notifications = notifications
    }

    // MARK: - Derived state

    var activeItems: [DownloadItem] { items.filter { $0.state == .active } }
    var queuedItems: [DownloadItem] { items.filter { $0.state == .queued } }
    var finishedItems: [DownloadItem] { items.filter { $0.state.isFinished } }

    var activeCount: Int { activeItems.count }
    var queuedCount: Int { queuedItems.count }
    var isBusy: Bool { activeCount > 0 || queuedCount > 0 }

    var hasFinishedItems: Bool { items.contains { $0.state.isFinished } }
    var hasRetryableItems: Bool { items.contains(where: \.canRetry) }

    /// Combined progress across everything currently running, for the toolbar indicator.
    var aggregateProgress: Double? {
        let running = activeItems.compactMap(\.progress.fractionCompleted)
        guard !running.isEmpty else { return nil }
        return running.reduce(0, +) / Double(running.count)
    }

    private func saveUnfinished() {
        guard !terminating else { return }
        let pending = items.filter { !$0.state.isFinished }.map { item in
            let clean = item.options.removingSecrets()
            return Interrupted(id: item.id, url: item.sourceURL, title: item.displayTitle,
                               options: clean.options, removedSecrets: clean.removed)
        }
        do {
            try FileManager.default.createDirectory(at: history.storageDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(interrupted + pending).write(to: recoveryURL, options: .atomic)
        } catch {
            notice = "Could not save unfinished downloads: \(error.localizedDescription)"
        }
    }

    func prepareForTermination() {
        saveUnfinished()
        terminating = true
        cancelAll()
    }

    func forgetInterrupted(_ id: UUID) {
        interrupted.removeAll { $0.id == id }
        saveUnfinished()
    }

    // MARK: - Adding

    /// Adds one URL to the queue.
    @discardableResult
    func enqueue(url: String, options: DownloadOptions, info: MediaInfo? = nil, resuming id: UUID? = nil) -> DownloadItem {
        if let existing = pendingItem(for: url) {
            notice = "Already in the queue: \(existing.displayTitle)"
            return existing
        }
        let item = append(url: url.trimmingCharacters(in: .whitespacesAndNewlines), options: options, info: info, resuming: id)
        saveUnfinished()
        startEligibleItems()
        return item
    }

    private func append(url: String, options: DownloadOptions, info: MediaInfo? = nil, resuming id: UUID? = nil) -> DownloadItem {
        let saved = interrupted.first { $0.id == id && $0.url == url }
        let item = DownloadItem(
            id: saved?.id ?? UUID(),
            sourceURL: url,
            options: options,
            title: info?.title ?? saved?.title,
            uploader: info?.displayUploader,
            thumbnailURL: info?.thumbnailURL,
            durationSeconds: info?.duration,
            isPlaylist: info?.isPlaylist ?? false,
            playlistCount: info?.playlistCount
        )
        if let saved { interrupted.removeAll { $0.id == saved.id } }
        items.append(item)
        return item
    }

    /// Adds several URLs at once, skipping blanks and duplicates already waiting to run.
    @discardableResult
    func enqueue(urls: [String], options: DownloadOptions) -> [DownloadItem] {
        var added: [DownloadItem] = []
        var known = Set(items.filter { !$0.state.isFinished }.map(\.sourceURL))
        known.formUnion(retiring.values.map(\.sourceURL))
        for raw in urls {
            let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty, known.insert(url).inserted else { continue }
            added.append(append(url: url, options: options))
        }
        if !added.isEmpty {
            saveUnfinished()
            startEligibleItems()
        }
        return added
    }

    func pendingItem(for url: String) -> DownloadItem? {
        let key = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.first { !$0.state.isFinished && $0.sourceURL == key }
            ?? retiring.values.first { $0.sourceURL == key }
    }

    // MARK: - Queue control

    func cancel(_ item: DownloadItem) {
        switch item.state {
        case .active:
            // The session's own termination path finishes the item; marking it here would
            // race with the final events still in flight.
            cancelRequested.insert(item.id)
            sessions[item.id]?.cancel()
        case .queued:
            item.state = .cancelled
            item.phase = .cancelled
            item.finishedAt = Date()
            saveUnfinished()
        default:
            break
        }
    }

    func cancelAll() {
        for item in items where item.canCancel { cancel(item) }
    }

    func retry(_ item: DownloadItem) {
        guard item.canRetry else { return }
        if let existing = pendingItem(for: item.sourceURL) {
            notice = "Already in the queue: \(existing.displayTitle)"
            return
        }
        item.prepareForRetry()
        saveUnfinished()
        startEligibleItems()
    }

    func retryAllFailed() {
        for item in items where item.state == .failed { retry(item) }
        startEligibleItems()
    }

    func remove(_ item: DownloadItem) {
        if item.state == .active {
            cancelRequested.insert(item.id)
            sessions[item.id]?.cancel()
        }
        if runners[item.id] != nil { retiring[item.id] = item }
        items.removeAll { $0.id == item.id }
        saveUnfinished()
        startEligibleItems()
    }

    func remove(ids: Set<DownloadItem.ID>) {
        for item in items where ids.contains(item.id) { remove(item) }
    }

    func clearFinished() {
        let finished = items.filter { $0.state.isFinished }
        for item in finished { remove(item) }
    }

    func removeAll() {
        for item in items { remove(item) }
    }

    // MARK: - Scheduling

    /// Starts queued items until the concurrency limit is reached.
    private func startEligibleItems() {
        guard !terminating else { return }
        let limit = settings.maximumConcurrentDownloads.constrained(to: AppSettings.concurrencyRange)
        for item in items where item.state == .queued {
            guard runners.count < limit else { break }
            start(item)
        }

        if !isBusy { reportQueueFinishedIfNeeded() }
    }

    private func start(_ item: DownloadItem) {
        guard item.state == .queued, runners[item.id] == nil else { return }
        item.state = .active
        item.phase = .resolving

        runners[item.id] = Task { [weak self] in
            await self?.run(item)
        }
    }

    // MARK: - Running a download

    private func run(_ item: DownloadItem) async {
        defer {
            saveUnfinished()
            retiring[item.id] = nil
            cancelRequested.remove(item.id)
            runners[item.id] = nil
            sessions[item.id] = nil
            startEligibleItems()
        }

        guard retiring[item.id] == nil else { return }
        if cancelRequested.contains(item.id) {
            finishCancelled(item)
            return
        }
        guard let service = toolchain.service(for: item.options.backend) else {
            finish(item, failure: DownloadFailure(
                kind: .toolMissing(item.options.backend.rawValue),
                underlyingMessage: "\(item.options.backend.displayName) could not be found. Set its location in Settings."
            ))
            return
        }

        // Creating the destination up front turns a confusing yt-dlp error into a clear one.
        do {
            try FileManager.default.createDirectory(
                at: item.options.outputDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            finish(item, failure: DownloadFailure(
                kind: .fileSystem,
                underlyingMessage: "Couldn't use \(item.options.outputDirectory.path(percentEncoded: false)): \(error.localizedDescription)"
            ))
            return
        }

        let session = service.makeDownloadSession(url: item.sourceURL, options: item.options)
        sessions[item.id] = session
        item.log.append("$ " + session.configuration.displayCommand)

        do {
            try session.start()
        } catch {
            finish(item, failure: DownloadFailure(
                kind: .toolMissing(item.options.backend.rawValue),
                underlyingMessage: error.localizedDescription
            ))
            return
        }

        item.phase = .downloading
        let secrets = ShellQuoting.logRedactions(in: session.configuration.arguments)
        var tracker = OutputTracker(outputDirectory: item.options.outputDirectory)
        var result: ProcessResult?

        for await event in session.events {
            switch event {
            case .standardOutput(let line), .standardError(let line):
                if item.options.backend == .ytdlp, line.hasPrefix(ArgumentBuilder.finalPathMarker) {
                    let json = Data(line.dropFirst(ArgumentBuilder.finalPathMarker.count).utf8)
                    if let path = try? JSONDecoder().decode(String.self, from: json) {
                        tracker.recordProcessed(path: path)
                        if let url = tracker.finalURL, !item.outputURLs.contains(url) { item.outputURLs.append(url) }
                    }
                    continue
                }
                if !line.hasPrefix(ArgumentBuilder.progressMarker) {
                    item.log.append(ShellQuoting.sanitizedLogLine(line, secrets: secrets))
                }
                if item.options.backend == .galleryDL {
                    if let url = GalleryDLArguments.fileURL(from: line, outputDirectory: item.options.outputDirectory), !item.outputURLs.contains(url) {
                        item.outputURLs.append(url)
                        item.completedItemCount = item.outputURLs.count
                        tracker.recordProcessed(path: url.path(percentEncoded: false))
                    }
                } else {
                    apply(ProgressParser.parse(line), to: item, tracker: &tracker)
                }
            case .finished(let processResult):
                result = processResult
            }
        }

        guard retiring[item.id] == nil else { return }
        guard let result else {
            finish(item, failure: DownloadFailure(kind: .unknown, underlyingMessage: nil))
            return
        }

        if result.wasCancelled || cancelRequested.contains(item.id) {
            finishCancelled(item)
            return
        }

        if result.isSuccess {
            item.outputURL = item.outputURLs.last ?? tracker.finalURL
            item.completedFileSize = !item.outputURLs.isEmpty
                ? item.outputURLs.reduce(Int64(0)) { total, url in
                    total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                } : tracker.fileSize()
            finish(item, failure: nil)
        } else {
            var failure = DownloadFailure.classify(
                logLines: item.log.lines,
                exitCode: result.exitCode
            )
            // A merge failure with no ffmpeg present has an obvious cause worth naming.
            if failure.kind == .postProcessing, !toolchain.canMergeStreams {
                failure.kind = .ffmpegMissing
            }
            finish(item, failure: failure)
        }
    }

    // MARK: - Event application

    /// Accumulates the file paths yt-dlp mentions so the final one can be revealed in Finder.
    private struct OutputTracker {
        let outputDirectory: URL
        /// Set by `[download] Destination:` — the raw media file, possibly a `.fXXX` part.
        var downloadDestination: URL?
        /// Set by merging, audio extraction or metadata stages — the real deliverable.
        var processedDestination: URL?

        var finalURL: URL? { processedDestination ?? downloadDestination }

        mutating func record(path: String, stage: String) {
            let url = resolve(path)
            if stage == "download" {
                downloadDestination = url
            } else {
                processedDestination = url
            }
        }

        mutating func recordProcessed(path: String) {
            processedDestination = resolve(path)
        }

        /// yt-dlp may report a path relative to its working directory.
        private func resolve(_ path: String) -> URL {
            let expanded = (path as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
            return outputDirectory.appending(path: expanded)
        }

        func fileSize() -> Int64? {
            guard let finalURL,
                  let values = try? finalURL.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize else { return nil }
            return Int64(size)
        }
    }

    private func apply(_ event: YTDLPEvent, to item: DownloadItem, tracker: inout OutputTracker) {
        switch event {
        case .progress(let snapshot):
            item.progress = snapshot
            if item.phase != .downloading { item.phase = .downloading }

        case .downloadFinished(let snapshot):
            item.progress = snapshot
            item.completedItemCount += 1

        case .postProcessing(let name, let isFinished):
            // Only the *start* of a stage is interesting; its end is immediately followed by
            // either the next stage or process exit.
            if !isFinished {
                item.phase = DownloadPhase.forPostProcessor(name)
            }

        case .destination(let path, let stage):
            tracker.record(path: path, stage: stage)

        case .merged(let path):
            tracker.recordProcessed(path: path)
            item.phase = .merging

        case .alreadyDownloaded(let path):
            tracker.recordProcessed(path: path)

        case .playlistItem(let index, let total):
            item.isPlaylist = true
            item.playlistCount = total
            item.completedItemCount = max(item.completedItemCount, index - 1)

        case .warning, .error, .information:
            // Already in the raw log. Errors are classified once the process exits, because
            // yt-dlp emits recoverable errors that it then works around.
            break
        }
    }

    // MARK: - Completion

    private func finish(_ item: DownloadItem, failure: DownloadFailure?) {
        item.finishedAt = Date()
        item.failure = failure

        if let failure {
            item.state = .failed
            item.phase = .failed
            failedSinceIdle += 1
            logger.error("Download failed: \(failure.title, privacy: .public)")
        } else {
            item.state = .completed
            item.phase = .completed
            if item.progress.fractionCompleted == nil {
                item.progress.totalBytes = item.completedFileSize
                item.progress.downloadedBytes = item.completedFileSize
            }
            completedSinceIdle += 1
        }

        item.refreshFileAvailability()
        var entry = item.makeHistoryEntry()
        entry.removeSecrets()
        history.add(entry)

        if settings.notifyWhenComplete {
            let playSound = settings.playSoundWhenComplete
            let title = item.displayTitle
            if let failure {
                let reason = failure.title
                Task { await notifications.notifyDownloadFailed(title: title, reason: reason, playSound: playSound) }
            } else {
                let fileName = item.outputURL?.lastPathComponent
                Task { await notifications.notifyDownloadCompleted(title: title, fileName: fileName, playSound: playSound) }
            }
        }

        if failure == nil, settings.revealWhenComplete, let url = item.outputURL {
            FinderIntegration.reveal(url)
        }
    }

    private func finishCancelled(_ item: DownloadItem) {
        item.state = .cancelled
        item.phase = .cancelled
        item.finishedAt = Date()
        item.failure = DownloadFailure(kind: .cancelled, underlyingMessage: nil)
    }

    private func reportQueueFinishedIfNeeded() {
        let completed = completedSinceIdle
        let failed = failedSinceIdle
        completedSinceIdle = 0
        failedSinceIdle = 0
        guard settings.notifyWhenComplete, completed + failed > 1 else { return }
        let playSound = settings.playSoundWhenComplete
        Task {
            await notifications.notifyQueueFinished(completed: completed, failed: failed, playSound: playSound)
        }
    }
}
