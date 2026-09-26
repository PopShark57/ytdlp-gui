import Foundation
import Testing
@testable import YTDLPGUI_iOS

@MainActor
@Suite("App model")
struct AppModelTests {

    private let url = "https://www.youtube.com/watch?v=abc123"

    @Test("A ytdlpgui:// link fills in the Download screen and never starts a download")
    func openURL() async throws {
        let env = try AppTestEnvironment()
        env.settings.autoAnalyzePastedURLs = false
        let model = env.makeAppModel()
        model.selectedTab = .history

        model.handleOpenURL(try #require(URL(string: "ytdlpgui://download?url=https%3A%2F%2Fexample.com%2Fsong&kind=audio")))
        #expect(model.selectedTab == .download)
        #expect(model.composer.urlText == "https://example.com/song")
        #expect(model.composer.options.kind == .audio)
        #expect(model.queue.items.isEmpty)

        model.handleOpenURL(try #require(URL(string: "ytdlpgui://download?url=javascript%3Aalert(1)")))
        #expect(model.composer.urlText == "https://example.com/song")
        #expect(model.status.message == "That link didn't include a web address to download.")
    }

    @Test("Shared links with a kind are queued; links without one go to the URL field")
    func sharedInbox() async throws {
        let env = try AppTestEnvironment()
        env.settings.autoAnalyzePastedURLs = false
        env.settings.maximumConcurrentDownloads = 1
        var remembered = DownloadOptions()
        remembered.embedMetadata = true
        env.settings.rememberOptions(remembered)
        env.sharedLinks = [
            SharedLink(urls: ["https://example.com/a", "https://example.com/b"], kind: .audio, created: Date()),
            SharedLink(urls: ["https://example.com/c"], kind: nil, created: Date()),
        ]
        let model = env.makeAppModel()

        model.handleScenePhaseChange(.active)
        #expect(model.queue.items.map(\.sourceURL) == ["https://example.com/a", "https://example.com/b"])
        #expect(model.queue.items.allSatisfy { $0.options.kind == .audio && $0.options.embedMetadata })
        #expect(model.queue.items.allSatisfy { $0.options.outputDirectory == env.storage.downloadsDirectory })
        #expect(model.composer.urlText == "https://example.com/c")
        #expect(model.selectedTab == .download)
        #expect(model.status.message == "Added 2 shared links to the queue.")

        // Draining again finds nothing new.
        model.handleScenePhaseChange(.inactive)
        model.handleScenePhaseChange(.active)
        #expect(model.queue.items.count == 2)
    }

    @Test("Only-queued shared links switch to the Queue tab")
    func sharedLinksSwitchToQueue() async throws {
        let env = try AppTestEnvironment()
        env.sharedLinks = [SharedLink(urls: [url], kind: .video, created: Date())]
        let model = env.makeAppModel()
        model.handleScenePhaseChange(.active)
        #expect(model.selectedTab == .queue)
        #expect(model.status.message == "Added a shared link to the queue.")
    }

    @Test("A clipboard link is offered once per copy, only into an empty field")
    func clipboardSuggestion() async throws {
        let env = try AppTestEnvironment()
        env.settings.autoAnalyzePastedURLs = false
        let model = env.makeAppModel()
        env.clipboard.holdsLink = true
        env.clipboard.changeCount = 1

        await model.checkClipboard()
        #expect(model.clipboardHasSuggestedLink)

        model.dismissClipboardSuggestion()
        #expect(!model.clipboardHasSuggestedLink)
        await model.checkClipboard()
        #expect(!model.clipboardHasSuggestedLink)
        #expect(env.clipboard.detectionCount == 1)

        env.clipboard.changeCount = 2
        await model.checkClipboard()
        #expect(model.clipboardHasSuggestedLink)

        model.acceptPastedText(url)
        #expect(!model.clipboardHasSuggestedLink)
        #expect(model.composer.urlText == url)

        // With text in the field nothing is looked at.
        env.clipboard.changeCount = 3
        await model.checkClipboard()
        #expect(env.clipboard.detectionCount == 2)
        #expect(!model.clipboardHasSuggestedLink)

        // And the setting turns it off entirely.
        model.composer.clear()
        env.settings.suggestClipboardLinks = false
        await model.checkClipboard()
        #expect(!model.clipboardHasSuggestedLink)
        #expect(env.clipboard.detectionCount == 2)
    }

    @Test("A clipboard without a link offers nothing")
    func clipboardWithoutLink() async throws {
        let env = try AppTestEnvironment()
        let model = env.makeAppModel()
        env.clipboard.changeCount = 5
        env.clipboard.holdsLink = false
        await model.checkClipboard()
        #expect(!model.clipboardHasSuggestedLink)
    }

    @Test("Download Again strips refused custom arguments and uses fresh paths")
    func downloadAgain() async throws {
        let env = try AppTestEnvironment()
        let model = env.makeAppModel()
        var options = DownloadOptions()
        options.kind = .audio
        options.outputDirectory = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/OLD/Documents")
        options.customArguments = "--exec 'rm -rf ~' --no-mtime --cookies-from-browser safari"
        let entry = HistoryEntry(
            title: "Old Song",
            sourceURL: url,
            outputPath: "/var/mobile/Containers/Data/Application/OLD/Documents/Old Song.m4a",
            formatSummary: "Best Audio",
            kind: .audio,
            succeeded: true,
            durationSeconds: 180,
            options: options
        )

        model.downloadAgain(entry)
        let item = try #require(model.queue.items.first)
        #expect(model.selectedTab == .queue)
        #expect(item.sourceURL == url)
        #expect(item.title == "Old Song")
        #expect(item.durationSeconds == 180)
        #expect(item.options.kind == .audio)
        #expect(item.options.outputDirectory == env.storage.downloadsDirectory)
        #expect(item.options.customArguments == "--no-mtime")
        #expect(model.status.message?.contains("‘--exec’") == true)
        #expect(model.status.message?.contains("‘--cookies-from-browser’") == true)
    }

    @Test("Download Again shows the existing item when the link is already queued")
    func downloadAgainWhilePending() async throws {
        let env = try AppTestEnvironment()
        let model = env.makeAppModel()
        let existing = model.queue.enqueue(url: url, options: DownloadOptions()).item
        _ = try await waitForJobs(1, on: env.downloader)
        model.selectedTab = .history
        let entry = HistoryEntry(title: "Clip", sourceURL: url, formatSummary: "Best", kind: .video, succeeded: true, options: DownloadOptions())

        model.downloadAgain(entry)
        #expect(model.queue.items.count == 1)
        #expect(model.selectedTab == .queue)
        #expect(model.focusedQueueItemID == existing.id)
        #expect(model.status.message == "That link is already in the queue.")
        try await Task.sleep(for: .milliseconds(50))
        #expect(env.downloader.jobs.count == 1)
    }

    @Test("Retrying reports a link that is already queued again")
    func retryReportsPendingLink() async throws {
        let env = try AppTestEnvironment()
        let model = env.makeAppModel()
        let failed = model.queue.enqueue(url: url, options: DownloadOptions()).item
        let job = try #require(try await waitForJobs(1, on: env.downloader).first)
        job.fail()
        try await waitUntil("failure") { failed.state == .failed }
        _ = model.queue.enqueue(url: url, options: DownloadOptions())

        model.retry(failed)
        #expect(failed.state == .failed)
        #expect(model.status.message == "That link is already in the queue.")

        model.status.dismiss()
        model.retryAllFailed()
        #expect(failed.state == .failed)
        #expect(model.status.message == "One download wasn't retried because its link is already in the queue.")
    }

    @Test("Download Again and Edit Options say which credentials history left out")
    func removedSecretsAreExplained() async throws {
        let env = try AppTestEnvironment()
        env.settings.autoAnalyzePastedURLs = false
        let model = env.makeAppModel()
        var options = DownloadOptions()
        options.customArguments = "--no-mtime"
        let entry = HistoryEntry(
            title: "Clip", sourceURL: url, formatSummary: "Best", kind: .video, succeeded: true,
            options: options, removedSecretOptions: ["--password"]
        )

        model.loadIntoComposer(entry)
        #expect(model.status.message?.contains("‘--password’") == true)
        #expect(model.status.message?.contains("Advanced Options") == true)

        model.status.dismiss()
        model.downloadAgain(entry)
        #expect(model.queue.items.count == 1)
        #expect(model.status.message?.contains("‘--password’") == true)
    }

    @Test("Launch removes credentials an older build kept in history")
    func launchRemovesSecretsFromHistory() async throws {
        let env = try AppTestEnvironment()
        var options = DownloadOptions()
        options.customArguments = "--password s3cret --no-mtime"
        env.history.add(HistoryEntry(title: "Clip", sourceURL: url, formatSummary: "Best", kind: .video, succeeded: true, options: options))
        let model = env.makeAppModel()

        await model.performLaunchSetup()
        let entry = try #require(env.history.entries.first)
        #expect(entry.options?.customArguments == "--no-mtime")
        #expect(entry.removedSecretOptions == ["--password"])
    }

    @Test("Loading a history entry into the Download screen keeps its options but not its paths")
    func loadIntoComposer() async throws {
        let env = try AppTestEnvironment()
        env.settings.autoAnalyzePastedURLs = false
        let model = env.makeAppModel()
        var options = DownloadOptions()
        options.subtitleMode = .both
        options.outputDirectory = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/OLD/Documents")
        options.cookieFilePath = "/old/cookies.txt"
        options.useDownloadArchive = true
        options.downloadArchivePath = "/old/archive.txt"
        options.customArguments = "--exec 'rm -rf ~' --update --no-mtime"
        let entry = HistoryEntry(title: "Clip", sourceURL: url, formatSummary: "Best", kind: .video, succeeded: false, options: options)

        model.loadIntoComposer(entry)
        #expect(model.selectedTab == .download)
        #expect(model.composer.urlText == url)
        #expect(model.composer.options.subtitleMode == .both)
        #expect(model.composer.options.useDownloadArchive)
        #expect(model.composer.options.outputDirectory == env.storage.downloadsDirectory)
        #expect(model.composer.options.cookieFilePath.isEmpty)
        #expect(model.composer.options.downloadArchivePath.isEmpty)
        #expect(model.composer.options.customArguments == "--no-mtime")
        #expect(model.status.message?.contains("‘--exec’") == true)
        #expect(model.status.message?.contains("‘--update’") == true)
        #expect(model.queue.items.isEmpty)
        // "Edit Options and Download" never becomes the remembered options by itself.
        #expect(env.settings.storedOptions.customArguments.isEmpty)
    }

    @Test("An older history entry without saved options loads with its own kind")
    func loadIntoComposerWithoutOptions() async throws {
        let env = try AppTestEnvironment()
        env.settings.autoAnalyzePastedURLs = false
        let model = env.makeAppModel()
        model.composer.options.kind = .video
        let entry = HistoryEntry(title: "Song", sourceURL: url, formatSummary: "Best Audio", kind: .audio, succeeded: true)

        model.loadIntoComposer(entry)
        #expect(model.composer.options.kind == .audio)
        #expect(model.composer.urlText == url)
        #expect(model.status.message == nil)
    }

    @Test("A loaded history entry is analysed when automatic analysis is on")
    func loadIntoComposerAnalyses() async throws {
        let env = try AppTestEnvironment()
        env.settings.autoAnalyzePastedURLs = true
        env.analyzer.respond(with: .success(SampleInfo.video(url: url)))
        let model = env.makeAppModel()
        await model.performLaunchSetup()
        let entry = HistoryEntry(title: "Clip", sourceURL: url, formatSummary: "Best", kind: .video, succeeded: true, options: DownloadOptions())

        model.loadIntoComposer(entry)
        try await waitUntil("analysis") { model.composer.analysis.info != nil }
        #expect(env.analyzer.calls.count == 1)
    }

    @Test("Starting a download switches to the Queue tab only when something was queued")
    func startDownload() async throws {
        let env = try AppTestEnvironment()
        env.settings.autoAnalyzePastedURLs = false
        let model = env.makeAppModel()
        await model.performLaunchSetup()
        #expect(model.engine.isReady)

        model.startDownload()
        #expect(model.selectedTab == .download)

        model.acceptPastedText(url)
        model.startDownload()
        #expect(model.selectedTab == .queue)
        #expect(model.queue.items.count == 1)
        #expect(model.queue.isBusy)
    }

    @Test("Launch setup restores the saved queue and starts the engine once")
    func launchSetup() async throws {
        let env = try AppTestEnvironment()
        let saved = PersistedDownload(
            id: UUID(),
            sourceURL: url,
            options: DownloadOptions(),
            title: "Saved",
            isPlaylist: false,
            createdAt: Date()
        )
        QueueStore(fileURL: env.queueStoreURL).save([saved])
        let model = env.makeAppModel()

        await model.performLaunchSetup()
        await model.performLaunchSetup()
        #expect(env.runtime.startCount == 1)
        #expect(model.queue.items.map(\.id) == [saved.id])
        #expect(model.queue.items.first?.state == .cancelled)
    }

    @Test("A shortcut queues its link with the chosen kind")
    func shortcut() async throws {
        let env = try AppTestEnvironment()
        let model = env.makeAppModel()
        #expect(model.enqueueFromShortcut(url: url, kind: .audio))
        #expect(model.queue.items.first?.options.kind == .audio)
        #expect(model.selectedTab == .queue)
        #expect(!model.enqueueFromShortcut(url: url, kind: nil))
    }

    @Test("A notification opens its download in the queue while the queue still has it")
    func openDownloadInQueue() async throws {
        let env = try AppTestEnvironment()
        let model = env.makeAppModel()
        let item = model.queue.enqueue(url: url, options: DownloadOptions()).item
        let job = try #require(try await waitForJobs(1, on: env.downloader).first)
        job.succeed()
        try await waitUntil("completion") { item.state == .completed }
        model.selectedTab = .download

        model.openDownload(item.id)
        #expect(model.selectedTab == .queue)
        #expect(model.focusedQueueItemID == item.id)
        #expect(model.focusedHistoryEntryID == nil)
    }

    @Test("A notification opens the history entry once the queue has forgotten the download")
    func openDownloadInHistory() async throws {
        let env = try AppTestEnvironment()
        let model = env.makeAppModel()
        let item = model.queue.enqueue(url: url, options: DownloadOptions()).item
        let firstJob = try #require(try await waitForJobs(1, on: env.downloader).first)
        firstJob.fail()
        try await waitUntil("failure") { item.state == .failed }
        // Retried, so two entries share the download's ID; the newest is the one to show.
        model.retry(item)
        let secondJob = try #require(try await waitForJobs(2, on: env.downloader).last)
        secondJob.succeed()
        try await waitUntil("completion") { item.state == .completed }
        #expect(env.history.entries.filter { $0.downloadID == item.id }.count == 2)
        let latest = try #require(env.history.entries.first)
        #expect(latest.succeeded)

        // As after "Clear Finished", or a relaunch: the queue no longer has it.
        model.queue.clearFinished()
        model.openDownload(item.id)
        #expect(model.selectedTab == .history)
        #expect(model.focusedHistoryEntryID == latest.id)
        #expect(model.focusedQueueItemID == nil)
    }

    @Test("A notification about a download that is gone opens History without a detail screen")
    func openUnknownDownload() throws {
        let env = try AppTestEnvironment()
        let model = env.makeAppModel()
        model.openDownload(UUID())
        #expect(model.selectedTab == .history)
        #expect(model.focusedHistoryEntryID == nil)
        #expect(model.focusedQueueItemID == nil)
        #expect(model.status.message != nil)
    }

    @Test("Only the Download screen changes the remembered options")
    func rememberedOptions() async throws {
        let env = try AppTestEnvironment()
        env.settings.autoAnalyzePastedURLs = false
        let model = env.makeAppModel()
        await model.performLaunchSetup()
        var remembered = DownloadOptions()
        remembered.embedMetadata = true
        env.settings.rememberOptions(remembered)

        // The Share sheet, Shortcuts and Download Again use them without changing them.
        env.sharedLinks = [SharedLink(urls: ["https://example.com/a", "https://example.com/b"], kind: .audio, created: Date())]
        model.handleScenePhaseChange(.active)
        model.enqueueFromShortcut(url: "https://example.com/c", kind: .audio)
        var historyOptions = DownloadOptions()
        historyOptions.kind = .audio
        historyOptions.subtitleMode = .both
        model.downloadAgain(HistoryEntry(title: "D", sourceURL: "https://example.com/d", formatSummary: "Best", kind: .audio, succeeded: true, options: historyOptions))
        #expect(model.queue.items.count == 4)
        #expect(env.settings.storedOptions.kind == .video)
        #expect(env.settings.storedOptions.subtitleMode == .off)
        #expect(env.settings.storedOptions.embedMetadata)

        // Choosing on the Download screen does.
        model.composer.options.kind = .audio
        model.acceptPastedText("https://example.com/e")
        model.startDownload()
        #expect(env.settings.storedOptions.kind == .audio)
        #expect(env.settings.storedOptions.cookieFilePath.isEmpty)
    }

    @Test("Showing a queue item selects it on the Queue tab")
    func showQueueItem() throws {
        let env = try AppTestEnvironment()
        let model = env.makeAppModel()
        let id = UUID()
        model.showQueueItem(id)
        #expect(model.selectedTab == .queue)
        #expect(model.focusedQueueItemID == id)
    }
}
