import Foundation
import Observation
import SwiftUI
import os

/// Whether a finished download has been copied to the photo library.
enum PhotoSaveState: Equatable, Sendable {
    case notSaved
    case saving
    case saved
    case failed(String)
}

/// What happened when a link was offered to the queue.
@MainActor
enum EnqueueOutcome {
    /// A new item was added for the link.
    case added(DownloadItem)
    /// The link was already waiting or running as this item, so nothing was added.
    case alreadyPending(DownloadItem)

    /// The item now responsible for the link: the new one, or the one that was already there.
    var item: DownloadItem {
        switch self {
        case .added(let item), .alreadyPending(let item): item
        }
    }

    /// The new item, or `nil` when the link was already pending.
    var addedItem: DownloadItem? {
        if case .added(let item) = self { return item }
        return nil
    }
}

/// Owns the download queue and runs downloads through the embedded engine.
///
/// The iOS counterpart of the macOS queue, with the same API and behaviour: at most
/// `settings.maximumConcurrentDownloads` items run at once, and everything here is
/// `@MainActor`. Where the macOS queue launches a `yt-dlp` process per item, this one runs a job in
/// the embedded engine, whose structured events arrive through an `AsyncStream`.
///
/// Two things are specific to iOS. The unfinished part of the queue is saved, because iOS
/// terminates suspended apps without notice. And the system may end background time while
/// downloads run; they are then stopped cleanly and resume when the app comes back.
@MainActor
@Observable
final class DownloadQueue {

    private(set) var items: [DownloadItem] = []
    private var photoSaveStates: [DownloadItem.ID: PhotoSaveState] = [:]

    var activeItems: [DownloadItem] { items.filter { $0.state == .active } }
    var queuedItems: [DownloadItem] { items.filter { $0.state == .queued } }
    var finishedItems: [DownloadItem] { items.filter { $0.state.isFinished } }

    var activeCount: Int { activeItems.count }
    var queuedCount: Int { queuedItems.count }
    var isBusy: Bool { activeCount > 0 || queuedCount > 0 }
    var hasFinishedItems: Bool { items.contains { $0.state.isFinished } }
    var hasRetryableItems: Bool { items.contains(where: \.canRetry) }

    /// Combined progress of everything running, for a toolbar indicator and the background task.
    var aggregateProgress: Double? {
        let running = activeItems.compactMap(\.progress.fractionCompleted)
        guard !running.isEmpty else { return nil }
        return running.reduce(0, +) / Double(running.count)
    }

    /// Told about every change of state or progress, for background execution and the idle timer.
    @ObservationIgnored var onActivityChange: ((QueueActivity) -> Void)?

    private let settings: AppSettings
    private let engine: EngineController
    private let downloader: any DownloadEngine
    private let history: HistoryStore
    private let notifications: NotificationService
    private let library: MediaLibrary
    private let resolver: DownloadOptionsResolver
    private let store: QueueStore
    private let logger = Logger(subsystem: "io.github.ytdlpgui.YTDLPGUI.iOS", category: "queue")

    /// Running work, keyed by item id. Kept out of `DownloadItem` so the model stays a plain
    /// value-ish object that SwiftUI can diff cheaply.
    @ObservationIgnored private var runners: [DownloadItem.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var jobIDs: [DownloadItem.ID: UUID] = [:]
    @ObservationIgnored private var cancelRequested: Set<DownloadItem.ID> = []
    /// Final files each finished item produced, for saving to Photos. A playlist makes several.
    @ObservationIgnored private var producedFiles: [DownloadItem.ID: [URL]] = [:]

    /// Items the system stopped (background time ran out) rather than the person.
    @ObservationIgnored private var interruptedIDs: Set<DownloadItem.ID> = []
    /// Cancelled items that are still unfinished work: interrupted, or restored after a relaunch.
    /// They are saved with the queue so a second termination doesn't lose them.
    @ObservationIgnored private var resumableIDs: Set<DownloadItem.ID> = []
    /// While true nothing new starts: background time has run out and the app is suspended.
    @ObservationIgnored private var isSuspended = false

    /// Counts since the queue was last idle, for the summary notification and batch progress.
    @ObservationIgnored private var completedSinceIdle = 0
    @ObservationIgnored private var failedSinceIdle = 0
    @ObservationIgnored private var finishedSinceIdle = 0

    @ObservationIgnored private var persistTask: Task<Void, Never>?

    static let closedBeforeFinishingMessage =
        "YTDLP GUI was closed before this download finished. Retry to continue from where it stopped."
    static let interruptedMessage =
        "iOS paused this download in the background. It continues when you return to YTDLP GUI."

    init(
        settings: AppSettings,
        engine: EngineController,
        downloader: any DownloadEngine,
        history: HistoryStore,
        notifications: NotificationService,
        library: MediaLibrary,
        storage: StorageManager,
        cookies: CookieStore,
        store: QueueStore = QueueStore()
    ) {
        self.settings = settings
        self.engine = engine
        self.downloader = downloader
        self.history = history
        self.notifications = notifications
        self.library = library
        self.resolver = DownloadOptionsResolver(storage: storage, cookies: cookies)
        self.store = store
        observeConcurrencyLimit()
    }

    func item(withID id: DownloadItem.ID) -> DownloadItem? {
        items.first { $0.id == id }
    }

    // MARK: - Adding

    /// The waiting or running item for this link, if there is one.
    ///
    /// A link is only ever queued once at a time. yt-dlp names its temporary files after the
    /// video and doesn't lock them, so two jobs for one link would write the same `.part` files.
    /// Different quality choices still share the audio stream's file, so the rule is by link,
    /// not by options.
    func pendingItem(forURL url: String) -> DownloadItem? {
        let key = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.first { !$0.state.isFinished && $0.sourceURL == key }
    }

    /// Adds one link to the queue, unless it is already waiting or running. Paths in `options`
    /// are replaced with this install's own.
    @discardableResult
    func enqueue(url: String, options: DownloadOptions, info: MediaInfo? = nil) -> EnqueueOutcome {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pending = pendingItem(forURL: url) {
            return .alreadyPending(pending)
        }
        let options = resolver.resolve(options)
        let item = DownloadItem(
            sourceURL: url,
            options: options,
            title: info?.title,
            uploader: info?.displayUploader,
            thumbnailURL: info?.thumbnailURL,
            durationSeconds: info?.duration,
            isPlaylist: info?.isPlaylist ?? false,
            playlistCount: info?.playlistCount
        )
        items.append(item)
        settings.rememberOptions(options)
        queueDidChange()
        return .added(item)
    }

    /// Queues several links, skipping blanks, repeats and ones already waiting or running.
    /// Returns the items that were added.
    @discardableResult
    func enqueue(urls: [String], options: DownloadOptions) -> [DownloadItem] {
        urls
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { enqueue(url: $0, options: options).addedItem }
    }

    // MARK: - Queue control

    func cancel(_ item: DownloadItem) {
        switch item.state {
        case .active:
            // The job's own ending finishes the item; marking it here would race with the
            // final events still in flight.
            cancelRequested.insert(item.id)
            interruptedIDs.remove(item.id)
            if let jobID = jobIDs[item.id] {
                downloader.cancel(jobID: jobID)
            }
        case .queued:
            finishCancelled(item)
            queueDidChange()
        default:
            break
        }
    }

    func cancelAll() {
        for item in items where item.canCancel { cancel(item) }
    }

    /// Runs a failed or cancelled item again, unless another item for the same link is waiting
    /// or running. Returns that other item when it is why nothing happened.
    @discardableResult
    func retry(_ item: DownloadItem) -> DownloadItem? {
        guard item.canRetry else { return nil }
        if let pending = pendingItem(forURL: item.sourceURL), pending.id != item.id {
            return pending
        }
        prepareForRetry(item)
        queueDidChange()
        return nil
    }

    /// Retries every failed item whose link isn't already waiting or running, including by an
    /// item retried just before it. Returns how many were skipped for that reason.
    @discardableResult
    func retryAllFailed() -> Int {
        var skipped = 0
        for item in items where item.state == .failed {
            if let pending = pendingItem(forURL: item.sourceURL), pending.id != item.id {
                skipped += 1
            } else {
                prepareForRetry(item)
            }
        }
        queueDidChange()
        return skipped
    }

    func remove(_ item: DownloadItem) {
        if item.state == .active {
            cancelRequested.insert(item.id)
            if let jobID = jobIDs[item.id] {
                downloader.cancel(jobID: jobID)
            }
        }
        runners[item.id]?.cancel()
        runners[item.id] = nil
        jobIDs[item.id] = nil
        forget(item.id)
        items.removeAll { $0.id == item.id }
        queueDidChange()
    }

    func remove(ids: Set<DownloadItem.ID>) {
        for item in items where ids.contains(item.id) { remove(item) }
    }

    func clearFinished() {
        for item in finishedItems { remove(item) }
    }

    func removeAll() {
        for item in items { remove(item) }
    }

    private func prepareForRetry(_ item: DownloadItem) {
        interruptedIDs.remove(item.id)
        resumableIDs.remove(item.id)
        photoSaveStates[item.id] = nil
        producedFiles[item.id] = nil
        item.prepareForRetry()
    }

    private func forget(_ id: DownloadItem.ID) {
        cancelRequested.remove(id)
        interruptedIDs.remove(id)
        resumableIDs.remove(id)
        producedFiles[id] = nil
        photoSaveStates[id] = nil
    }

    // MARK: - Background interruptions

    /// Stops running downloads because the system is ending the app's background time.
    ///
    /// yt-dlp keeps partial files, so nothing downloaded so far is lost. Waiting items stay
    /// waiting, and nothing new starts until `resumeInterruptedDownloads()`.
    func interruptActiveDownloads() {
        isSuspended = true
        for item in activeItems {
            interruptedIDs.insert(item.id)
            cancelRequested.insert(item.id)
            if let jobID = jobIDs[item.id] {
                downloader.cancel(jobID: jobID)
            }
        }
        flushPersistence()
    }

    /// Restarts whatever `interruptActiveDownloads()` stopped. Called when the app returns to the
    /// foreground; does nothing if nothing was interrupted.
    func resumeInterruptedDownloads() {
        guard isSuspended || !interruptedIDs.isEmpty else { return }
        isSuspended = false
        for item in items where item.state == .cancelled && interruptedIDs.contains(item.id) {
            prepareForRetry(item)
        }
        queueDidChange()
    }

    // MARK: - Scheduling

    /// Starts what can start, notices the queue going idle, saves and reports. Called after
    /// every change to the queue's membership or to an item's state.
    private func queueDidChange() {
        startEligibleItems()
        reportActivity()
        if !isBusy { reportQueueFinishedIfNeeded() }
        schedulePersist()
    }

    /// Starts queued items until the concurrency limit is reached.
    ///
    /// An item whose link is already running waits for that one to finish. Adding and retrying
    /// already refuse a second item for a pending link; this also covers the paths that bypass
    /// them, such as downloads resuming after a background interruption.
    private func startEligibleItems() {
        guard !isSuspended else { return }
        let limit = settings.maximumConcurrentDownloads.constrained(to: AppSettings.concurrencyRange)
        for item in items where item.state == .queued {
            guard activeCount < limit else { break }
            let linkIsRunning = items.contains { $0.state == .active && $0.sourceURL == item.sourceURL }
            guard !linkIsRunning else { continue }
            start(item)
        }
    }

    private func start(_ item: DownloadItem) {
        guard item.state == .queued, runners[item.id] == nil else { return }
        item.state = .active
        item.phase = .resolving
        cancelRequested.remove(item.id)

        runners[item.id] = Task { [weak self] in
            await self?.run(item)
        }
    }

    /// Raising the limit in Settings starts waiting items straight away.
    private func observeConcurrencyLimit() {
        withObservationTracking {
            _ = settings.maximumConcurrentDownloads
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.startEligibleItems()
                self.reportActivity()
                self.observeConcurrencyLimit()
            }
        }
    }

    private func contains(_ item: DownloadItem) -> Bool {
        items.contains { $0.id == item.id }
    }

    // MARK: - Running a download

    private func run(_ item: DownloadItem) async {
        defer {
            runners[item.id] = nil
            jobIDs[item.id] = nil
            cancelRequested.remove(item.id)
            if contains(item) { queueDidChange() }
        }

        // Links can arrive (from the Share sheet or Shortcuts) while the engine is still
        // starting; they wait for it here rather than failing.
        guard await engine.startIfNeeded() else {
            guard contains(item) else { return }
            finish(item, failure: DownloadFailure(
                kind: .unknown,
                underlyingMessage: engine.failureMessage ?? "The download engine couldn't start."
            ))
            return
        }
        guard contains(item) else { return }
        if cancelRequested.contains(item.id) {
            finishCancelled(item)
            return
        }

        // Resolved afresh: the item may have been saved by an earlier launch whose container
        // path no longer exists.
        let options = resolver.resolve(item.options)
        let capabilities = engine.capabilities

        // Creating the folders up front turns a confusing yt-dlp error into a clear one.
        for directory in [options.outputDirectory, capabilities.temporaryDirectory].compactMap({ $0 }) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                finish(item, failure: DownloadFailure(
                    kind: .fileSystem,
                    underlyingMessage: "Couldn't use \(directory.lastPathComponent): \(error.localizedDescription)"
                ))
                return
            }
        }

        let argv = ArgumentBuilder.embeddedDownloadArguments(
            url: item.sourceURL,
            options: options,
            capabilities: capabilities
        )
        // Logs get shared in bug reports, so secrets are masked here; the engine gets the real argv.
        item.log.append("$ " + ShellQuoting.commandLine(executable: "yt-dlp", arguments: ShellQuoting.redactingSecrets(argv)))

        let jobID = UUID()
        jobIDs[item.id] = jobID
        var tracker = OutputTracker(outputDirectory: options.outputDirectory)
        var result: EngineJobResult?

        for await update in downloader.download(argv: argv, jobID: jobID) {
            switch update {
            case .event(let event):
                apply(event, to: item, tracker: &tracker)
            case .finished(let jobResult):
                result = jobResult
            }
            reportActivity()
        }

        // Removed while running: there is nothing left to update or record.
        guard contains(item) else { return }

        guard let result else {
            finish(item, failure: DownloadFailure(
                kind: .unknown,
                underlyingMessage: "The download engine stopped without reporting a result."
            ))
            return
        }

        let files = tracker.finalFiles(including: result.files)
        producedFiles[item.id] = files

        if result.wasCancelled {
            finishCancelled(item)
        } else if result.isSuccess {
            item.outputURL = files.last ?? tracker.fallbackURL
            item.completedFileSize = Self.totalSize(of: files.isEmpty ? item.outputURL.map { [$0] } ?? [] : files)
            finish(item, failure: nil)
        } else if let hostError = result.hostError {
            finish(item, failure: DownloadFailure(kind: .unknown, underlyingMessage: hostError))
        } else {
            finish(item, failure: DownloadFailure.classify(logLines: item.log.lines, exitCode: result.exitCode))
        }
    }

    // MARK: - Event application

    /// Accumulates the file paths the engine mentions so the finished file can be opened.
    private struct OutputTracker {
        let outputDirectory: URL
        /// Set by `[download] Destination:` — the raw media file, possibly a `.fXXX` part in the
        /// partial-downloads folder.
        var downloadDestination: URL?
        /// Set by merging, audio extraction or metadata stages.
        var processedDestination: URL?
        /// Final locations reported by `file` events, one per finished video. Authoritative.
        var reportedFiles: [URL] = []

        /// The best guess when the engine reported no final file at all.
        var fallbackURL: URL? { processedDestination ?? downloadDestination }

        mutating func record(path: String, stage: String) {
            if stage == "download" {
                downloadDestination = resolve(path)
            } else {
                processedDestination = resolve(path)
            }
        }

        mutating func recordProcessed(path: String) {
            processedDestination = resolve(path)
        }

        mutating func recordFinal(path: String) {
            let url = resolve(path)
            if !reportedFiles.contains(url) { reportedFiles.append(url) }
        }

        func finalFiles(including resultPaths: [String]) -> [URL] {
            var files = reportedFiles
            for url in resultPaths.map(resolve) where !files.contains(url) {
                files.append(url)
            }
            return files
        }

        /// yt-dlp may report a path relative to its output folder.
        private func resolve(_ path: String) -> URL {
            if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
            return outputDirectory.appending(path: path)
        }
    }

    private func apply(_ event: EngineEvent, to item: DownloadItem, tracker: inout OutputTracker) {
        switch event {
        case .log(_, let line):
            item.log.append(line)
            applyLogLine(line, to: item, tracker: &tracker)

        case .progress(let snapshot, let status):
            switch status {
            case .downloading:
                item.progress = snapshot
                if item.phase != .downloading { item.phase = .downloading }
            case .finished:
                // The final tick reports a stale ETA and speed; clearing them avoids a row that
                // says "100% · 2 s remaining" for the whole post-processing stage.
                var final = snapshot
                final.etaSeconds = nil
                final.speedBytesPerSecond = nil
                if let total = final.totalBytes { final.downloadedBytes = total }
                item.progress = final
            case .error:
                // Explained by the log; the job's result decides the outcome.
                break
            }

        case .postProcessing(let name, let status, _):
            // Only the start of a stage is interesting; its end is followed by the next stage.
            if status == .started {
                item.phase = DownloadPhase.forPostProcessor(name)
            }

        case .item(let info):
            applyItemInfo(info, to: item)

        case .file(let path):
            tracker.recordFinal(path: path)
            // Counted per finished file rather than per finished transfer: a merged video is
            // two transfers (picture and sound) but one item of a playlist.
            item.completedItemCount += 1
        }
    }

    /// The human-readable lines still carry what the structured events don't: where yt-dlp is
    /// writing, and the position within a playlist.
    private func applyLogLine(_ line: String, to item: DownloadItem, tracker: inout OutputTracker) {
        switch ProgressParser.parse(line) {
        case .destination(let path, let stage):
            tracker.record(path: path, stage: stage)
        case .merged(let path):
            tracker.recordProcessed(path: path)
            item.phase = .merging
        case .alreadyDownloaded(let path):
            tracker.recordProcessed(path: path)
        case .playlistItem(let index, let total):
            markPlaylistPosition(of: item, index: index, total: total)
        default:
            break
        }
    }

    private func applyItemInfo(_ info: EngineItemInfo, to item: DownloadItem) {
        if let index = info.playlistIndex {
            markPlaylistPosition(of: item, index: index, total: info.playlistCount)
            // The row describes the whole playlist, which the first video's title and length
            // would misrepresent; its artwork and channel are fair stand-ins.
            if item.thumbnailURL == nil { item.thumbnailURL = info.thumbnailURL }
            if item.uploader == nil { item.uploader = info.uploader }
        } else {
            if item.title == nil { item.title = info.title }
            if item.uploader == nil { item.uploader = info.uploader }
            if item.thumbnailURL == nil { item.thumbnailURL = info.thumbnailURL }
            if item.durationSeconds == nil { item.durationSeconds = info.durationSeconds }
        }
        schedulePersist()
    }

    private func markPlaylistPosition(of item: DownloadItem, index: Int, total: Int?) {
        item.isPlaylist = true
        if let total { item.playlistCount = total }
        item.completedItemCount = max(item.completedItemCount, index - 1)
    }

    private static func totalSize(of files: [URL]) -> Int64? {
        let sizes = files.compactMap { url in
            (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
        }
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }

    // MARK: - Completion

    private func finish(_ item: DownloadItem, failure: DownloadFailure?) {
        item.finishedAt = Date()
        item.failure = failure
        interruptedIDs.remove(item.id)
        resumableIDs.remove(item.id)
        finishedSinceIdle += 1

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

        var entry = item.makeHistoryEntry()
        // History outlives the download and is included in device backups, so passwords and
        // other credentials stay out of it. The item keeps them, so a retry still works.
        entry.removeSecrets()
        history.add(entry)

        if settings.notifyWhenComplete {
            let notifications = notifications
            let itemID = item.id
            let title = item.displayTitle
            if let failure {
                let reason = failure.title
                Task { await notifications.notifyDownloadFailed(itemID: itemID, title: title, reason: reason) }
            } else {
                let fileName = item.outputURL?.lastPathComponent
                Task { await notifications.notifyDownloadCompleted(itemID: itemID, title: title, fileName: fileName) }
            }
        }

        if failure == nil, settings.saveVideosToPhotos, item.options.kind == .video, canSaveToPhotos(item) {
            saveToPhotos(item)
        }
    }

    private func finishCancelled(_ item: DownloadItem) {
        if interruptedIDs.contains(item.id), !isSuspended {
            // The app came back to the foreground before the engine finished stopping this
            // download, so it simply carries on.
            prepareForRetry(item)
            return
        }

        item.state = .cancelled
        item.phase = .cancelled
        item.finishedAt = Date()
        finishedSinceIdle += 1

        if interruptedIDs.contains(item.id) {
            resumableIDs.insert(item.id)
            item.failure = DownloadFailure(kind: .cancelled, underlyingMessage: Self.interruptedMessage)
        } else {
            resumableIDs.remove(item.id)
            item.failure = DownloadFailure(kind: .cancelled, underlyingMessage: nil)
        }
    }

    private func reportQueueFinishedIfNeeded() {
        let completed = completedSinceIdle
        let failed = failedSinceIdle
        completedSinceIdle = 0
        failedSinceIdle = 0
        finishedSinceIdle = 0
        guard settings.notifyWhenComplete, completed + failed > 1 else { return }
        let notifications = notifications
        Task { await notifications.notifyQueueFinished(completed: completed, failed: failed) }
    }

    // MARK: - Activity

    /// What the queue is doing, for background execution and the idle timer.
    var currentActivity: QueueActivity {
        let active = activeItems
        let queued = queuedCount
        let finished = finishedSinceIdle
        let total = active.count + queued + finished
        let running = active.reduce(0.0) { $0 + ($1.progress.fractionCompleted ?? 0) }
        let fraction = total > 0 ? (Double(finished) + running) / Double(total) : 0
        return QueueActivity(
            activeCount: active.count,
            queuedCount: queued,
            finishedCount: finished,
            fractionCompleted: fraction.constrained(to: 0...1),
            currentTitle: active.first?.displayTitle
        )
    }

    private func reportActivity() {
        onActivityChange?(currentActivity)
    }

    // MARK: - Photos

    func canSaveToPhotos(_ item: DownloadItem) -> Bool {
        item.state == .completed && !photoFiles(for: item).isEmpty
    }

    func photoSaveState(for item: DownloadItem) -> PhotoSaveState {
        photoSaveStates[item.id] ?? .notSaved
    }

    /// Copies the item's videos (or pictures) to the photo library. Progress and the outcome
    /// are reported through `photoSaveState(for:)`.
    func saveToPhotos(_ item: DownloadItem) {
        switch photoSaveState(for: item) {
        case .saving, .saved: return
        case .notSaved, .failed: break
        }
        let files = photoFiles(for: item)
        guard item.state == .completed, !files.isEmpty else { return }

        let id = item.id
        photoSaveStates[id] = .saving
        Task { [weak self, library] in
            var outcome = PhotoSaveState.saved
            do {
                for file in files {
                    try await library.saveToPhotos(file)
                }
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            guard let self, self.items.contains(where: { $0.id == id }) else { return }
            self.photoSaveStates[id] = outcome
        }
    }

    private func photoFiles(for item: DownloadItem) -> [URL] {
        let files = producedFiles[item.id] ?? item.outputURL.map { [$0] } ?? []
        return files.filter(library.canSaveToPhotos)
    }

    // MARK: - Persistence

    /// Puts back what was unfinished when the app last stopped, as cancelled items that say
    /// why. They aren't restarted automatically: the person may have left for a reason, and
    /// retrying resumes from the partial file anyway.
    func restoreUnfinishedItems() {
        let known = Set(items.map(\.id))
        let restored = store.load()
            .filter { !known.contains($0.id) }
            .map { saved -> DownloadItem in
                let item = DownloadItem(
                    id: saved.id,
                    sourceURL: saved.sourceURL,
                    options: saved.options,
                    title: saved.title,
                    uploader: saved.uploader,
                    thumbnailURL: saved.thumbnailURL,
                    durationSeconds: saved.durationSeconds,
                    isPlaylist: saved.isPlaylist,
                    playlistCount: saved.playlistCount,
                    createdAt: saved.createdAt
                )
                item.state = .cancelled
                item.phase = .cancelled
                item.finishedAt = Date()
                item.failure = DownloadFailure(kind: .cancelled, underlyingMessage: Self.closedBeforeFinishingMessage)
                return item
            }
        guard !restored.isEmpty else { return }
        resumableIDs.formUnion(restored.map(\.id))
        items.insert(contentsOf: restored, at: 0)
    }

    /// Writes any pending change now. Called when the app moves to the background, the last
    /// moment it is sure to be running.
    func flushPersistence() {
        persistTask?.cancel()
        persistTask = nil
        persistNow()
    }

    /// Coalesces bursts of changes (a playlist of links, a cancel-all) into one write.
    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    private func persistNow() {
        let unfinished = items
            .filter { !$0.state.isFinished || resumableIDs.contains($0.id) }
            .map { item in
                PersistedDownload(
                    id: item.id,
                    sourceURL: item.sourceURL,
                    options: item.options,
                    title: item.title,
                    uploader: item.uploader,
                    thumbnailURL: item.thumbnailURL,
                    durationSeconds: item.durationSeconds,
                    isPlaylist: item.isPlaylist,
                    playlistCount: item.playlistCount,
                    createdAt: item.createdAt
                )
            }
        store.save(unfinished)
    }
}
