import Foundation
import Testing
@testable import YTDLPGUI_iOS

@MainActor
@Suite("Download queue")
struct DownloadQueueTests {

    private let url = "https://www.youtube.com/watch?v=abc123"

    // MARK: - Running

    @Test("A download moves through its phases and records the finished file")
    func progressPhasesAndCompletion() async throws {
        let env = try AppTestEnvironment()
        let item = env.queue.enqueue(url: url, options: DownloadOptions()).item
        let job = try #require(try await waitForJobs(1, on: env.downloader).first)
        #expect(item.state == .active)
        #expect(item.phase == .resolving)

        job.send(.item(EngineItemInfo(
            id: "abc123",
            title: "Sample Clip",
            uploader: "Uploader",
            thumbnailURL: URL(string: "https://i.ytimg.com/vi/abc123/hq.jpg"),
            durationSeconds: 42
        )))
        try await waitUntil("title from the item event") { item.title == "Sample Clip" }
        #expect(item.uploader == "Uploader")
        #expect(item.durationSeconds == 42)

        var snapshot = DownloadProgressSnapshot()
        snapshot.downloadedBytes = 500
        snapshot.totalBytes = 1_000
        snapshot.speedBytesPerSecond = 250
        snapshot.etaSeconds = 2
        job.send(.progress(snapshot, status: .downloading))
        try await waitUntil("progress") { item.progress.downloadedBytes == 500 }
        #expect(item.phase == .downloading)
        #expect(item.progress.fractionCompleted == 0.5)

        snapshot.downloadedBytes = 990
        job.send(.progress(snapshot, status: .finished))
        try await waitUntil("finished tick") { item.progress.downloadedBytes == 1_000 }
        #expect(item.progress.etaSeconds == nil)
        #expect(item.progress.speedBytesPerSecond == nil)

        job.send(.postProcessing(name: "Merger", status: .started, filePath: nil))
        try await waitUntil("merging phase") { item.phase == .merging }
        job.send(.postProcessing(name: "Merger", status: .finished, filePath: nil))

        let file = try env.makeDownloadedFile(named: "Sample Clip.mp4", bytes: 2_048)
        job.send(.log(.info, "[download] Destination: \(env.storage.partialDownloadsDirectory.path(percentEncoded: false))/Sample Clip.f137.mp4"))
        job.send(.file(path: file.path(percentEncoded: false)))
        job.succeed(files: [file.path(percentEncoded: false)])

        try await waitUntil("completion") { item.state == .completed }
        #expect(item.phase == .completed)
        #expect(item.outputURL?.standardizedFileURL == file.standardizedFileURL)
        #expect(item.completedFileSize == 2_048)
        #expect(item.completedItemCount == 1)
        #expect(item.log.lines.contains { $0.hasPrefix("[download] Destination:") })

        let entry = try #require(env.history.entries.first)
        #expect(entry.succeeded)
        #expect(entry.title == "Sample Clip")
        #expect(entry.outputPath == file.path(percentEncoded: false))
    }

    @Test("The argument vector uses this install's paths, whatever the options say")
    func argumentsUseFreshPaths() async throws {
        let env = try AppTestEnvironment()
        var options = DownloadOptions()
        options.outputDirectory = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/OLD/Documents")
        options.useDownloadArchive = true
        options.downloadArchivePath = "/var/mobile/Containers/Data/Application/OLD/archive.txt"
        options.cookieFilePath = "/var/mobile/Containers/Data/Application/OLD/cookies.txt"
        options.customArguments = "--embed-subs --update"

        let item = env.queue.enqueue(url: url, options: options).item
        let job = try #require(try await waitForJobs(1, on: env.downloader).first)

        let documents = env.storage.downloadsDirectory.path(percentEncoded: false)
        let partial = env.storage.partialDownloadsDirectory.path(percentEncoded: false)
        #expect(!job.argv.joined(separator: " ").contains("OLD"))
        #expect(pairs(in: job.argv, flag: "--paths").contains(documents))
        #expect(pairs(in: job.argv, flag: "--paths").contains("temp:" + partial))
        #expect(pairs(in: job.argv, flag: "--download-archive") == [env.storage.downloadArchiveURL.path(percentEncoded: false)])
        // No cookies were imported, so the stale cookie path must not survive.
        #expect(!job.argv.contains("--cookies"))
        #expect(!job.argv.contains("--update"))
        #expect(Array(job.argv.suffix(2)) == ["--", url])
        #expect(item.log.lines.first?.hasPrefix("$ yt-dlp ") == true)
        #expect(item.options.outputDirectory == env.storage.downloadsDirectory)
    }

    @Test("The log masks credentials, while the engine gets the real ones")
    func logRedactsSecrets() async throws {
        let env = try AppTestEnvironment()
        var options = DownloadOptions()
        options.customArguments = "--password s3cret --proxy http://u:p@h:1 --no-mtime"
        let item = env.queue.enqueue(url: url, options: options).item
        let job = try #require(try await waitForJobs(1, on: env.downloader).first)

        #expect(job.argv.contains("s3cret"))
        #expect(job.argv.contains("http://u:p@h:1"))
        let commandLine = try #require(item.log.lines.first)
        #expect(commandLine.hasPrefix("$ yt-dlp "))
        #expect(!commandLine.contains("s3cret"))
        #expect(!commandLine.contains("u:p"))
        #expect(commandLine.contains("--password PRIVATE"))
        #expect(commandLine.contains("http://PRIVATE@h:1"))
    }

    @Test("History and the last-used options don't keep credentials; the saved queue does, out of backups")
    func secretsStayOutOfHistory() async throws {
        let env = try AppTestEnvironment()
        env.settings.maximumConcurrentDownloads = 1
        var options = DownloadOptions()
        options.customArguments = "--password s3cret --no-mtime"
        options.proxy = "http://user:pass@proxy.test:3128"
        let item = env.queue.enqueue(url: url, options: options).item
        let waiting = env.queue.enqueue(url: "https://example.com/b", options: options).item
        let job = try #require(try await waitForJobs(1, on: env.downloader).first)

        #expect(env.settings.storedOptions.customArguments == "--no-mtime")
        #expect(env.settings.storedOptions.proxy == "http://proxy.test:3128")

        // The waiting download needs its password to run after a relaunch.
        env.queue.flushPersistence()
        let saved = try #require(QueueStore(fileURL: env.queueStoreURL).load().first { $0.id == waiting.id })
        #expect(saved.options.customArguments.contains("s3cret"))
        let values = try env.queueStoreURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)

        job.succeed()
        try await waitUntil("completion") { item.state == .completed }
        let entry = try #require(env.history.entries.first)
        #expect(entry.options?.customArguments == "--no-mtime")
        #expect(entry.options?.proxy == "http://proxy.test:3128")
        #expect(entry.removedSecretOptions == ["--password", "--proxy"])
        // The finished item itself still has them, for a retry.
        #expect(item.options.customArguments.contains("s3cret"))
    }

    @Test("Playlist items update the position, and each finished file counts once")
    func playlistEvents() async throws {
        let env = try AppTestEnvironment()
        var options = DownloadOptions()
        options.downloadPlaylist = true
        let item = env.queue.enqueue(url: "https://www.youtube.com/playlist?list=PL1", options: options).item
        let job = try #require(try await waitForJobs(1, on: env.downloader).first)

        job.send(.item(EngineItemInfo(title: "First video", uploader: "Channel", playlistIndex: 1, playlistCount: 3)))
        try await waitUntil("playlist detected") { item.isPlaylist }
        #expect(item.playlistCount == 3)
        // The first video's title would misdescribe the whole playlist.
        #expect(item.title == nil)
        #expect(item.uploader == "Channel")

        // A merged video finishes two transfers but is one item.
        job.send(.progress(DownloadProgressSnapshot(downloadedBytes: 10, totalBytes: 10), status: .finished))
        job.send(.progress(DownloadProgressSnapshot(downloadedBytes: 5, totalBytes: 5), status: .finished))
        job.send(.file(path: env.storage.downloadsDirectory.appending(path: "1.mp4").path(percentEncoded: false)))
        try await waitUntil("first file") { item.completedItemCount == 1 }

        job.send(.log(.info, "[download] Downloading item 3 of 3"))
        try await waitUntil("position from the log line") { item.completedItemCount == 2 }

        job.succeed()
        try await waitUntil("completion") { item.state == .completed }
        #expect(item.displayTitle == "https://www.youtube.com/playlist?list=PL1")
    }

    // MARK: - Failures

    @Test("A failed download is classified from its log")
    func failureClassification() async throws {
        let env = try AppTestEnvironment()
        let item = env.queue.enqueue(url: url, options: DownloadOptions()).item
        let job = try #require(try await waitForJobs(1, on: env.downloader).first)

        job.send(.log(.error, "ERROR: [youtube] abc123: Video unavailable. This video has been removed by the uploader"))
        job.fail(exitCode: 1)

        try await waitUntil("failure") { item.state == .failed }
        #expect(item.failure?.kind == .unavailable)
        #expect(item.phase == .failed)
        let entry = try #require(env.history.entries.first)
        #expect(!entry.succeeded)
        #expect(entry.failureTitle == item.failure?.title)
    }

    @Test("A host error becomes an unknown failure carrying its message")
    func hostError() async throws {
        let env = try AppTestEnvironment()
        let item = env.queue.enqueue(url: url, options: DownloadOptions()).item
        let job = try #require(try await waitForJobs(1, on: env.downloader).first)

        job.fail(exitCode: 1, hostError: "The host couldn't parse the arguments.")
        try await waitUntil("failure") { item.state == .failed }
        #expect(item.failure == DownloadFailure(kind: .unknown, underlyingMessage: "The host couldn't parse the arguments."))
    }

    @Test("A download fails clearly when the engine can't start")
    func engineStartFailure() async throws {
        let env = try AppTestEnvironment()
        env.runtime.failStarts(with: .startupFailed("Python couldn't be found."))
        let item = env.queue.enqueue(url: url, options: DownloadOptions()).item

        try await waitUntil("failure") { item.state == .failed }
        #expect(item.failure?.kind == .unknown)
        #expect(item.failure?.underlyingMessage?.contains("Python couldn't be found.") == true)
        #expect(env.downloader.jobs.isEmpty)
    }

    // MARK: - Control

    @Test("Cancelling a running download stops its job")
    func cancelActive() async throws {
        let env = try AppTestEnvironment()
        let item = env.queue.enqueue(url: url, options: DownloadOptions()).item
        let job = try #require(try await waitForJobs(1, on: env.downloader).first)

        env.queue.cancel(item)
        try await waitUntil("cancellation") { item.state == .cancelled }
        #expect(env.downloader.cancelledJobIDs == [job.id])
        #expect(item.failure?.kind == .cancelled)
        #expect(item.canRetry)
        #expect(env.history.entries.isEmpty)
    }

    @Test("Cancelling a waiting download never starts it")
    func cancelQueued() async throws {
        let env = try AppTestEnvironment()
        env.settings.maximumConcurrentDownloads = 1
        _ = env.queue.enqueue(url: url, options: DownloadOptions()).item
        let waiting = env.queue.enqueue(url: "https://example.com/second", options: DownloadOptions()).item
        _ = try await waitForJobs(1, on: env.downloader)
        #expect(waiting.state == .queued)

        env.queue.cancel(waiting)
        #expect(waiting.state == .cancelled)
        try await Task.sleep(for: .milliseconds(50))
        #expect(env.downloader.jobs.count == 1)
    }

    @Test("Retrying a failed download runs it again from scratch")
    func retry() async throws {
        let env = try AppTestEnvironment()
        let item = env.queue.enqueue(url: url, options: DownloadOptions()).item
        let first = try #require(try await waitForJobs(1, on: env.downloader).first)
        first.send(.log(.error, "ERROR: Unable to download webpage: timed out"))
        first.fail()
        try await waitUntil("failure") { item.state == .failed }
        #expect(item.failure?.kind == .network)

        env.queue.retry(item)
        let jobs = try await waitForJobs(2, on: env.downloader)
        #expect(item.state == .active)
        #expect(item.failure == nil)
        #expect(!item.log.lines.contains { $0.contains("timed out") })

        jobs[1].succeed()
        try await waitUntil("completion") { item.state == .completed }
    }

    @Test("No more than the configured number of downloads run at once")
    func concurrencyLimit() async throws {
        let env = try AppTestEnvironment()
        env.settings.maximumConcurrentDownloads = 2
        let items = ["a", "b", "c"].map {
            env.queue.enqueue(url: "https://example.com/\($0)", options: DownloadOptions()).item
        }
        let jobs = try await waitForJobs(2, on: env.downloader)
        try await Task.sleep(for: .milliseconds(50))
        #expect(env.downloader.jobs.count == 2)
        #expect(env.queue.activeCount == 2)
        #expect(items[2].state == .queued)

        jobs[0].succeed()
        _ = try await waitForJobs(3, on: env.downloader)
        #expect(items[2].state == .active)
    }

    @Test("Raising the limit in Settings starts waiting downloads")
    func raisingTheLimitStartsMore() async throws {
        let env = try AppTestEnvironment()
        env.settings.maximumConcurrentDownloads = 1
        _ = env.queue.enqueue(url: "https://example.com/a", options: DownloadOptions()).item
        let second = env.queue.enqueue(url: "https://example.com/b", options: DownloadOptions()).item
        _ = try await waitForJobs(1, on: env.downloader)
        #expect(second.state == .queued)

        env.settings.maximumConcurrentDownloads = 2
        _ = try await waitForJobs(2, on: env.downloader)
        #expect(second.state == .active)
    }

    @Test("Several links are queued once each")
    func enqueueDeduplicates() throws {
        let env = try AppTestEnvironment()
        env.settings.maximumConcurrentDownloads = 1
        let added = env.queue.enqueue(urls: [url, " \(url) ", "", "https://example.com/b"], options: DownloadOptions())
        #expect(added.map(\.sourceURL) == [url, "https://example.com/b"])
        #expect(env.queue.enqueue(urls: [url], options: DownloadOptions()).isEmpty)
    }

    @Test("A link that is waiting or running can't be queued a second time")
    func duplicateLinkIsRefused() async throws {
        let env = try AppTestEnvironment()
        env.settings.maximumConcurrentDownloads = 2
        let first = env.queue.enqueue(url: url, options: DownloadOptions())
        #expect(first.addedItem != nil)
        let job = try #require(try await waitForJobs(1, on: env.downloader).first)

        // Different options, and stray whitespace, are still the same link.
        var audio = DownloadOptions()
        audio.kind = .audio
        let second = env.queue.enqueue(url: " \(url)\n", options: audio)
        #expect(second.addedItem == nil)
        #expect(second.item.id == first.item.id)
        #expect(env.queue.pendingItem(forURL: url)?.id == first.item.id)
        #expect(env.queue.items.count == 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(env.downloader.jobs.count == 1)

        // Once the first has finished the link can be queued again.
        job.succeed()
        try await waitUntil("completion") { first.item.state == .completed }
        #expect(env.queue.pendingItem(forURL: url) == nil)
        #expect(env.queue.enqueue(url: url, options: DownloadOptions()).addedItem != nil)
        _ = try await waitForJobs(2, on: env.downloader)
    }

    @Test("Retrying is refused while another item for the same link is pending")
    func retryWhileLinkIsPending() async throws {
        let env = try AppTestEnvironment()
        let failed = env.queue.enqueue(url: url, options: DownloadOptions()).item
        let firstJob = try #require(try await waitForJobs(1, on: env.downloader).first)
        firstJob.fail()
        try await waitUntil("failure") { failed.state == .failed }

        let running = try #require(env.queue.enqueue(url: url, options: DownloadOptions()).addedItem)
        _ = try await waitForJobs(2, on: env.downloader)

        #expect(env.queue.retry(failed)?.id == running.id)
        #expect(failed.state == .failed)
        #expect(env.queue.retryAllFailed() == 1)
        #expect(failed.state == .failed)
        try await Task.sleep(for: .milliseconds(50))
        #expect(env.downloader.jobs.count == 2)
    }

    @Test("Retry All retries two failed items for one link only once")
    func retryAllFailedDeduplicates() async throws {
        let env = try AppTestEnvironment()
        let first = env.queue.enqueue(url: url, options: DownloadOptions()).item
        let firstJob = try #require(try await waitForJobs(1, on: env.downloader).first)
        firstJob.fail()
        try await waitUntil("first failure") { first.state == .failed }
        let second = env.queue.enqueue(url: url, options: DownloadOptions()).item
        #expect(second.id != first.id)
        let secondJob = try #require(try await waitForJobs(2, on: env.downloader).last)
        secondJob.fail()
        try await waitUntil("second failure") { second.state == .failed }

        #expect(env.queue.retryAllFailed() == 1)
        #expect(first.state != .failed)
        #expect(second.state == .failed)
        _ = try await waitForJobs(3, on: env.downloader)
        try await Task.sleep(for: .milliseconds(50))
        #expect(env.downloader.jobs.count == 3)
    }

    @Test("A queued item waits while another item for its link is running")
    func sameLinkNeverRunsTwice() async throws {
        let env = try AppTestEnvironment()
        env.settings.maximumConcurrentDownloads = 2
        let running = env.queue.enqueue(url: "https://example.com/a", options: DownloadOptions()).item
        _ = try await waitForJobs(1, on: env.downloader)

        // An interruption leaves the running item cancelled; a new item for the same link can
        // then be queued, and resuming must not run both at once.
        env.queue.interruptActiveDownloads()
        try await waitUntil("interrupted") { running.state == .cancelled }
        let second = try #require(env.queue.enqueue(url: "https://example.com/a", options: DownloadOptions()).addedItem)
        env.queue.resumeInterruptedDownloads()
        _ = try await waitForJobs(2, on: env.downloader)
        try await Task.sleep(for: .milliseconds(50))
        #expect(env.downloader.jobs.count == 2)
        #expect([running.state, second.state].filter { $0 == .active }.count == 1)
        #expect([running.state, second.state].filter { $0 == .queued }.count == 1)
    }

    @Test("Removing a running download stops it without recording it")
    func removeActive() async throws {
        let env = try AppTestEnvironment()
        let item = env.queue.enqueue(url: url, options: DownloadOptions()).item
        let job = try #require(try await waitForJobs(1, on: env.downloader).first)

        env.queue.remove(item)
        #expect(env.queue.items.isEmpty)
        #expect(env.downloader.cancelledJobIDs == [job.id])
        try await Task.sleep(for: .milliseconds(50))
        #expect(env.history.entries.isEmpty)
    }

    @Test("Aggregate progress averages the running downloads")
    func aggregateProgress() async throws {
        let env = try AppTestEnvironment()
        _ = env.queue.enqueue(url: "https://example.com/a", options: DownloadOptions()).item
        _ = env.queue.enqueue(url: "https://example.com/b", options: DownloadOptions()).item
        let jobs = try await waitForJobs(2, on: env.downloader)
        #expect(env.queue.aggregateProgress == nil)

        jobs[0].send(.progress(DownloadProgressSnapshot(downloadedBytes: 1, totalBytes: 4), status: .downloading))
        jobs[1].send(.progress(DownloadProgressSnapshot(downloadedBytes: 3, totalBytes: 4), status: .downloading))
        try await waitUntil("both progressed") { env.queue.aggregateProgress == 0.5 }
        #expect(env.queue.currentActivity.fractionCompleted == 0.5)
        #expect(env.queue.currentActivity.activeCount == 2)
    }

    // MARK: - Background and persistence

    @Test("Downloads the system interrupts resume when the app returns")
    func interruptAndResume() async throws {
        let env = try AppTestEnvironment()
        env.settings.maximumConcurrentDownloads = 1
        let running = env.queue.enqueue(url: "https://example.com/a", options: DownloadOptions()).item
        let waiting = env.queue.enqueue(url: "https://example.com/b", options: DownloadOptions()).item
        _ = try await waitForJobs(1, on: env.downloader)

        env.queue.interruptActiveDownloads()
        try await waitUntil("interrupted") { running.state == .cancelled }
        #expect(running.failure?.underlyingMessage == DownloadQueue.interruptedMessage)
        try await Task.sleep(for: .milliseconds(50))
        #expect(waiting.state == .queued)
        #expect(env.downloader.jobs.count == 1)

        env.queue.resumeInterruptedDownloads()
        _ = try await waitForJobs(2, on: env.downloader)
        #expect(running.state == .active)
        #expect(waiting.state == .queued)
    }

    @Test("Unfinished downloads survive a relaunch as cancelled items that can be retried")
    func persistenceRoundTrip() async throws {
        let env = try AppTestEnvironment()
        env.settings.maximumConcurrentDownloads = 1
        var options = DownloadOptions()
        options.kind = .audio
        options.audioFormat = .flac
        let running = env.queue.enqueue(url: "https://example.com/a", options: options).item
        let waiting = env.queue.enqueue(url: "https://example.com/b", options: DownloadOptions()).item
        let job = try #require(try await waitForJobs(1, on: env.downloader).first)
        job.send(.item(EngineItemInfo(title: "Song", uploader: "Band", durationSeconds: 200)))
        try await waitUntil("title") { running.title == "Song" }

        env.queue.flushPersistence()

        let relaunched = env.makeRelaunchedQueue()
        relaunched.restoreUnfinishedItems()
        #expect(relaunched.items.map(\.id) == [running.id, waiting.id])
        let restored = try #require(relaunched.item(withID: running.id))
        #expect(restored.state == .cancelled)
        #expect(restored.failure?.underlyingMessage == DownloadQueue.closedBeforeFinishingMessage)
        #expect(restored.title == "Song")
        #expect(restored.uploader == "Band")
        #expect(restored.durationSeconds == 200)
        #expect(restored.options.kind == .audio)
        #expect(restored.options.audioFormat == .flac)
        #expect(restored.canRetry)

        // Still remembered if the app is terminated again before anything is retried.
        relaunched.flushPersistence()
        #expect(QueueStore(fileURL: env.queueStoreURL).load().map(\.id) == [running.id, waiting.id])

        // Restoring twice doesn't duplicate anything.
        relaunched.restoreUnfinishedItems()
        #expect(relaunched.items.count == 2)

        relaunched.retry(restored)
        _ = try await waitForJobs(2, on: env.downloader)
        #expect(restored.state == .active)
    }

    @Test("Finished downloads are not remembered as unfinished")
    func finishedItemsAreNotPersisted() async throws {
        let env = try AppTestEnvironment()
        let item = env.queue.enqueue(url: url, options: DownloadOptions()).item
        let job = try #require(try await waitForJobs(1, on: env.downloader).first)
        job.succeed()
        try await waitUntil("completion") { item.state == .completed }

        env.queue.flushPersistence()
        #expect(QueueStore(fileURL: env.queueStoreURL).load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: env.queueStoreURL.path(percentEncoded: false)))
    }

    @Test("A saved entry that no longer decodes doesn't take the others with it")
    func lenientQueueFile() throws {
        let env = try AppTestEnvironment()
        let good = PersistedDownload(
            id: UUID(),
            sourceURL: url,
            options: DownloadOptions(),
            isPlaylist: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let store = QueueStore(fileURL: env.queueStoreURL)
        store.save([good])
        let data = try Data(contentsOf: env.queueStoreURL)
        var array = try #require(try JSONSerialization.jsonObject(with: data) as? [Any])
        array.insert(["sourceURL": 42], at: 0)
        try JSONSerialization.data(withJSONObject: array).write(to: env.queueStoreURL)

        #expect(store.load() == [good])
    }

    // MARK: - Helpers

    /// The values following each occurrence of `flag`.
    private func pairs(in argv: [String], flag: String) -> [String] {
        argv.indices.compactMap { index in
            argv[index] == flag && index + 1 < argv.count ? argv[index + 1] : nil
        }
    }
}

private extension DownloadProgressSnapshot {
    init(downloadedBytes: Int64, totalBytes: Int64) {
        self.init()
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
    }
}
