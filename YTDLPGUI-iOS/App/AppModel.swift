import Observation
import SwiftUI

/// The app's top-level sections: tabs on iPhone, a sidebar on iPad.
enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case download
    case queue
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .download: "Download"
        case .queue: "Queue"
        case .history: "History"
        case .settings: "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .download: "arrow.down.circle"
        case .queue: "list.bullet.rectangle"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}

/// Composition root, handed to views through the SwiftUI environment.
///
/// Everything the app needs is created once here, which keeps the views free of singletons and
/// makes each piece independently testable. It is also where links arrive from outside the app
/// (the Share extension, `ytdlpgui://` URLs, Shortcuts and the clipboard) and where scene-phase
/// changes are turned into background work, notifications and saving.
@MainActor
@Observable
final class AppModel {

    let settings: AppSettings
    let engine: EngineController
    let history: HistoryStore
    let notifications: NotificationService
    let library: MediaLibrary
    let cookies: CookieStore
    let storage: StorageManager
    let queue: DownloadQueue
    let composer: DownloadComposer
    let background: BackgroundActivity
    /// The passing message shown over every tab.
    let status: StatusCenter

    var selectedTab: AppTab = .download

    /// The queue item whose details are showing, if any. Setting it navigates there.
    var focusedQueueItemID: DownloadItem.ID?

    /// The history entry whose details are showing, if any. Setting it navigates there.
    var focusedHistoryEntryID: HistoryEntry.ID?

    /// Whether the clipboard appears to hold a web link the user hasn't been offered yet.
    ///
    /// Detected with `UIPasteboard.detectPatterns`, which does not read the clipboard and so
    /// never triggers the paste-permission prompt. The Download screen offers a `PasteButton`
    /// while this is true. It is only ever true while the URL field is empty.
    var clipboardHasSuggestedLink: Bool {
        hasClipboardSuggestion && composer.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasClipboardSuggestion = false

    private let clipboard: any ClipboardLinkDetecting
    private let drainSharedInbox: () -> [SharedLink]
    private let resolver: DownloadOptionsResolver
    /// The clipboard's `changeCount` when it was last looked at, so the same contents are only
    /// ever offered once.
    @ObservationIgnored private var lastCheckedClipboardChangeCount: Int?
    @ObservationIgnored private var hasPerformedLaunchSetup = false

    convenience init() {
        let settings = AppSettings()
        let storage = StorageManager()
        let cookies = CookieStore()
        let history = HistoryStore()
        let notifications = NotificationService()
        let library = MediaLibrary()
        let status = StatusCenter()
        let engine = EngineController(engine: .shared, temporaryDirectory: storage.partialDownloadsDirectory)
        let queue = DownloadQueue(
            settings: settings,
            engine: engine,
            downloader: YTDLPEngine.shared,
            history: history,
            notifications: notifications,
            library: library,
            storage: storage,
            cookies: cookies
        )
        let composer = DownloadComposer(
            settings: settings,
            engine: engine,
            queue: queue,
            storage: storage,
            cookies: cookies,
            analyzer: YTDLPEngine.shared,
            status: status
        )
        self.init(
            settings: settings,
            engine: engine,
            history: history,
            notifications: notifications,
            library: library,
            cookies: cookies,
            storage: storage,
            queue: queue,
            composer: composer,
            background: BackgroundActivity(settings: settings),
            status: status,
            clipboard: SystemClipboardLinkDetector(),
            drainSharedInbox: { SharedLinkInbox.drain() }
        )
    }

    /// Assembles the app from its parts; tests pass fakes for the outside world.
    init(
        settings: AppSettings,
        engine: EngineController,
        history: HistoryStore,
        notifications: NotificationService,
        library: MediaLibrary,
        cookies: CookieStore,
        storage: StorageManager,
        queue: DownloadQueue,
        composer: DownloadComposer,
        background: BackgroundActivity,
        status: StatusCenter,
        clipboard: any ClipboardLinkDetecting,
        drainSharedInbox: @escaping () -> [SharedLink]
    ) {
        self.settings = settings
        self.engine = engine
        self.history = history
        self.notifications = notifications
        self.library = library
        self.cookies = cookies
        self.storage = storage
        self.queue = queue
        self.composer = composer
        self.background = background
        self.status = status
        self.clipboard = clipboard
        self.drainSharedInbox = drainSharedInbox
        self.resolver = DownloadOptionsResolver(storage: storage, cookies: cookies)

        storage.isPartialDownloadInUse = { [weak queue] in
            (queue?.activeCount ?? 0) > 0
        }
        queue.onActivityChange = { [weak background] activity in
            background?.update(activity)
        }
        background.onExpiration = { [weak queue] in
            queue?.interruptActiveDownloads()
        }
        notifications.onOpenDownload = { [weak self] id in
            self?.openDownload(id)
        }
    }

    // MARK: - Lifecycle

    /// Work that happens once, when the first scene appears: starting the engine, restoring the
    /// queue, draining the Share extension inbox, checking the clipboard.
    func performLaunchSetup() async {
        guard !hasPerformedLaunchSetup else { return }
        hasPerformedLaunchSetup = true

        // Starting Python takes a moment; everything else can happen meanwhile, and queued
        // downloads wait for it by themselves.
        let engineStart = Task { [engine] in await engine.start() }
        // Earlier builds kept passwords and other credentials in history.
        history.updateEntries { $0.removeSecrets() }
        queue.restoreUnfinishedItems()
        receiveSharedLinks()
        await checkClipboard()
        await engineStart.value
        composer.engineDidBecomeReady()
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        notifications.isAppActive = phase == .active
        background.scenePhaseChanged(phase)

        switch phase {
        case .active:
            queue.resumeInterruptedDownloads()
            // Files may have been deleted or moved back in the Files app meanwhile.
            history.refreshFileStatus()
            receiveSharedLinks()
            Task { await checkClipboard() }
        case .background:
            // The last moment the app is sure to be running; iOS may terminate it from here on
            // without another word.
            queue.flushPersistence()
            history.flush()
        default:
            break
        }
    }

    // MARK: - Links from elsewhere

    /// Handles `ytdlpgui://download?url=…&kind=…` links.
    ///
    /// Such a link only fills in the Download screen. Any web page can open it, so it never
    /// starts a download by itself.
    func handleOpenURL(_ url: URL) {
        guard let request = DownloadLinkRequest(url: url) else {
            if url.scheme?.lowercased() == DownloadLinkRequest.scheme {
                status.show("That link didn't include a web address to download.")
            }
            return
        }
        if let kind = request.kind {
            composer.options.kind = kind
        }
        hasClipboardSuggestion = false
        composer.setURLText(request.urls.joined(separator: "\n"), analyzeIfEnabled: true)
        selectedTab = .download
    }

    /// Text from a `PasteButton`, a drop or the Share inbox, destined for the URL field.
    func acceptPastedText(_ text: String) {
        hasClipboardSuggestion = false
        composer.setURLText(text, analyzeIfEnabled: true)
        selectedTab = .download
    }

    func dismissClipboardSuggestion() {
        hasClipboardSuggestion = false
    }

    /// Looks for a link on the clipboard to offer, without reading it.
    ///
    /// Only when the setting is on, the URL field is empty, and something new has been copied
    /// since the last look, so dismissing a suggestion keeps it dismissed.
    func checkClipboard() async {
        guard settings.suggestClipboardLinks else {
            hasClipboardSuggestion = false
            return
        }
        guard composer.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let changeCount = clipboard.changeCount
        guard changeCount != lastCheckedClipboardChangeCount else { return }
        lastCheckedClipboardChangeCount = changeCount

        let hasLink = await clipboard.containsProbableWebURL()
        // Something may have been copied, or the setting changed, while detection ran.
        guard clipboard.changeCount == changeCount, settings.suggestClipboardLinks else { return }
        hasClipboardSuggestion = hasLink
    }

    /// Takes the links the Share extension left in the App Group inbox.
    ///
    /// Links shared with an explicit kind ("Download Video" / "Download Audio") are queued
    /// straight away with the last-used options; links without one go into the URL field so the
    /// person can choose.
    private func receiveSharedLinks() {
        let links = drainSharedInbox()
        guard !links.isEmpty else { return }

        var linksForComposer: [String] = []
        var queuedCount = 0
        for link in links {
            if let kind = link.kind {
                var options = settings.storedOptions
                options.kind = kind
                queuedCount += queue.enqueue(urls: link.urls, options: resolver.resolve(options)).count
            } else {
                linksForComposer += link.urls
            }
        }

        if !linksForComposer.isEmpty {
            hasClipboardSuggestion = false
            composer.setURLText(linksForComposer.joined(separator: "\n"), analyzeIfEnabled: true)
            selectedTab = .download
        } else if queuedCount > 0 {
            selectedTab = .queue
        }
        if queuedCount > 0 {
            status.show(queuedCount == 1
                ? "Added a shared link to the queue."
                : "Added \(queuedCount) shared links to the queue.")
        }
    }

    /// Queues a link from the "Download with YTDLP GUI" shortcut, which the person set up and
    /// ran deliberately. Returns whether it was added (it isn't when already waiting).
    @discardableResult
    func enqueueFromShortcut(url: String, kind: DownloadKind?) -> Bool {
        var options = settings.storedOptions
        if let kind { options.kind = kind }
        let added = queue.enqueue(urls: [url], options: resolver.resolve(options))
        selectedTab = .queue
        return !added.isEmpty
    }

    // MARK: - Actions

    /// Queues the composer's links and, when that worked, switches to the Queue tab.
    func startDownload() {
        guard composer.startDownload() else { return }
        askForNotificationPermissionIfNeeded()
        if queue.isBusy {
            selectedTab = .queue
        }
    }

    /// Starting a download is the moment "tell me when it's done" makes sense, and it comes
    /// before the person switches away, which is when notifications are posted.
    private func askForNotificationPermissionIfNeeded() {
        guard settings.notifyWhenComplete else { return }
        Task { await notifications.requestAuthorizationIfNeeded() }
    }

    /// Queues a history entry again with the options it was first downloaded with, after
    /// stripping any custom arguments the engine refuses, so history can't replay them.
    ///
    /// When the link is already waiting or running, that download is shown instead.
    func downloadAgain(_ entry: HistoryEntry) {
        var options = entry.options ?? composer.options
        if entry.options == nil { options.kind = entry.kind }
        let sanitized = DownloadOptionsResolver.sanitizedCustomArguments(options.customArguments)
        options.customArguments = sanitized.arguments

        let item: DownloadItem
        switch queue.enqueue(url: entry.sourceURL, options: resolver.resolve(options)) {
        case .added(let added):
            item = added
        case .alreadyPending(let pending):
            showQueueItem(pending.id)
            status.show("That link is already in the queue.")
            return
        }
        if item.title == nil, entry.title != entry.sourceURL { item.title = entry.title }
        if item.thumbnailURL == nil { item.thumbnailURL = entry.thumbnailURL }
        if item.durationSeconds == nil { item.durationSeconds = entry.durationSeconds }
        selectedTab = .queue

        var notes: [String] = []
        if !sanitized.removed.isEmpty {
            notes.append("Removed \(Self.describe(sanitized.removed)) before downloading again.")
        }
        if let secrets = entry.removedSecretOptions, !secrets.isEmpty {
            notes.append(Self.describeRemovedSecrets(secrets))
        }
        if !notes.isEmpty {
            status.show(notes.joined(separator: " "))
        }
    }

    /// Puts a history entry's link and options into the Download screen, to adjust before
    /// downloading again ("Edit Options and Download").
    ///
    /// Paths from the earlier download and custom arguments the engine refuses are dropped, and
    /// the person is told which arguments went. The link is analysed (when that setting is on),
    /// so the formats are there to look at while editing.
    func loadIntoComposer(_ entry: HistoryEntry) {
        if let options = entry.options {
            composer.loadOptions(options)
            var notes: [String] = []
            let removed = DownloadOptionsResolver.sanitizedCustomArguments(options.customArguments).removed
            if !removed.isEmpty {
                notes.append("Removed \(Self.describe(removed)) from the custom arguments.")
            }
            if let secrets = entry.removedSecretOptions, !secrets.isEmpty {
                notes.append(Self.describeRemovedSecrets(secrets) + " Add them again in Advanced Options if they're needed.")
            }
            if !notes.isEmpty {
                status.show(notes.joined(separator: " "))
            }
        } else {
            composer.options.kind = entry.kind
        }
        hasClipboardSuggestion = false
        composer.setURLText(entry.sourceURL, analyzeIfEnabled: true)
        selectedTab = .download
    }

    /// Runs a failed or cancelled download again, unless its link is already waiting or running
    /// as another item, which is then pointed out instead.
    func retry(_ item: DownloadItem) {
        guard queue.retry(item) != nil else { return }
        status.show("That link is already in the queue.")
    }

    /// Retries every failed download, and says how many were left alone because their link is
    /// already waiting or running.
    func retryAllFailed() {
        let skipped = queue.retryAllFailed()
        guard skipped > 0 else { return }
        status.show(skipped == 1
            ? "One download wasn't retried because its link is already in the queue."
            : "\(skipped) downloads weren't retried because their links are already in the queue.")
    }

    /// Shows a queue item's details.
    func showQueueItem(_ id: DownloadItem.ID) {
        selectedTab = .queue
        focusedQueueItemID = id
    }

    /// Shows a history entry's details.
    func showHistoryEntry(_ id: HistoryEntry.ID) {
        selectedTab = .history
        focusedHistoryEntryID = id
    }

    /// Shows the download a notification was about: in the queue while it is still there,
    /// otherwise its history entry. The queue forgets finished downloads when the app is
    /// relaunched (iOS often ends a backgrounded app after the notification was posted) or when
    /// they are cleared, but history keeps them.
    func openDownload(_ id: DownloadItem.ID) {
        if queue.item(withID: id) != nil {
            showQueueItem(id)
        } else if let entry = history.entries.first(where: { $0.downloadID == id }) {
            // Newest first, so a retried download opens its latest attempt.
            showHistoryEntry(entry.id)
        } else {
            selectedTab = .history
            focusedHistoryEntryID = nil
            status.show("That download is no longer in the queue or the history.")
        }
    }

    private static func describe(_ flags: [String]) -> String {
        let listed = flags.map { "‘\($0)’" }.joined(separator: ", ")
        return "the unsupported option\(flags.count == 1 ? "" : "s") \(listed)"
    }

    /// For history entries saved without their credentials (`HistoryEntry.removedSecretOptions`).
    private static func describeRemovedSecrets(_ flags: [String]) -> String {
        let listed = flags.map { "‘\($0)’" }.joined(separator: ", ")
        return "History doesn't keep passwords or other credentials, so those given with \(listed) were left out."
    }
}
