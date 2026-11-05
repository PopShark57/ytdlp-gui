import AppKit
import Foundation
import Observation

/// The sections shown in the sidebar.
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case download
    case queue
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .download: "New Download"
        case .queue: "Queue"
        case .history: "History"
        }
    }

    var symbolName: String {
        switch self {
        case .download: "arrow.down.circle"
        case .queue: "list.bullet.rectangle"
        case .history: "clock.arrow.circlepath"
        }
    }
}

/// Composition root.
///
/// Everything the app needs is created once here and handed to views through the SwiftUI
/// environment, which keeps the views free of singletons and makes each piece independently
/// testable.
@MainActor
@Observable
final class AppModel {

    let settings: AppSettings
    let toolchain: Toolchain
    let history: HistoryStore
    let notifications: NotificationService
    let queue: DownloadQueue
    let composer: DownloadComposer
    let activityMonitor: QueueActivityMonitor

    var selectedSection: AppSection = .download
    /// Set when the user asks to see a specific queue item's log.
    var focusedLogItemID: DownloadItem.ID?

    private var didSetUp = false
    private var lastSeenClipboardText: String?

    init(
        settings: AppSettings = AppSettings(),
        history: HistoryStore = HistoryStore()
    ) {
        self.settings = settings
        self.history = history
        let toolchain = Toolchain(settings: settings)
        let notifications = NotificationService()
        let queue = DownloadQueue(
            settings: settings,
            toolchain: toolchain,
            history: history,
            notifications: notifications
        )
        self.toolchain = toolchain
        self.notifications = notifications
        self.queue = queue
        self.composer = DownloadComposer(settings: settings, toolchain: toolchain, queue: queue)
        self.activityMonitor = QueueActivityMonitor(queue: queue, settings: settings)
        notifications.onResponse = { [weak self] response in
            self?.handle(response)
        }
    }

    /// Brings the main window back, for actions that come from outside it (notifications, the
    /// menu bar). Supplied by the window's root view, since only views can open windows.
    var openMainWindow: (() -> Void)?

    /// Work that must happen once, after the first window exists.
    func performLaunchSetup() async {
        guard !didSetUp else { return }
        didSetUp = true
        if !queue.interrupted.isEmpty { selectedSection = .queue }
        history.updateEntries { $0.removeSecrets() }
        settings.applyAppearance()
        activityMonitor.start()
        await toolchain.refresh()
    }

    // MARK: - Notifications

    private func handle(_ response: NotificationService.Response) {
        switch response {
        case .reveal(let files):
            FinderIntegration.reveal(files)
        case .retry(let id):
            if let item = queue.item(withID: id), item.canRetry {
                queue.retry(item)
            }
            show(.queue)
        case .showQueue:
            show(.queue)
        case .showHistory:
            show(.history)
        }
    }

    func show(_ section: AppSection) {
        selectedSection = section
        openMainWindow?()
        NSApp.activate()
    }

    // MARK: - Clipboard watching

    /// Offers a URL sitting on the clipboard when the app comes to the front.
    ///
    /// The same clipboard contents are only ever offered once, so returning to the app after
    /// dismissing a suggestion doesn't keep re-filling the field.
    func handleAppDidBecomeActive() {
        history.refreshFileStatus()
        for item in queue.finishedItems { item.refreshFileAvailability() }
        guard settings.readClipboardOnActivate else { return }
        guard composer.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let text = Pasteboard.string(), text != lastSeenClipboardText else { return }
        lastSeenClipboardText = text
        guard let url = URLDetection.firstURL(in: text) else { return }
        composer.setURLText(url, analyzeIfEnabled: true)
        selectedSection = .download
    }

    // MARK: - Menu actions

    func pasteURL() {
        selectedSection = .download
        composer.pasteFromClipboard()
    }

    func startDownload() {
        selectedSection = .download
        composer.startDownload()
    }

    func analyzeCurrentURL() {
        selectedSection = .download
        composer.analyze()
    }

    /// Whether a saved download can go straight back into the queue: its folder is still
    /// there and writable, and it had no credentials that were left out when it was saved.
    private func isOutputFolderUsable(for saved: DownloadQueue.Interrupted) -> Bool {
        var directory: ObjCBool = false
        let path = saved.options.outputDirectory.path(percentEncoded: false)
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
            && directory.boolValue && FileManager.default.isWritableFile(atPath: path)
    }

    private func canResumeDirectly(_ saved: DownloadQueue.Interrupted) -> Bool {
        saved.removedSecrets.isEmpty && isOutputFolderUsable(for: saved)
    }

    func resume(_ saved: DownloadQueue.Interrupted) {
        let usable = isOutputFolderUsable(for: saved)
        if usable && saved.removedSecrets.isEmpty {
            guard toolchain.isReady(for: saved.options.backend) else {
                queue.notice = "Set up \(saved.options.backend.displayName) in Settings before resuming this download."
                return
            }
            queue.enqueue(url: saved.url, options: saved.options, resuming: saved.id)
        } else {
            composer.editingInterrupted = saved
            composer.options = saved.options
            composer.setURLText(saved.url, analyzeIfEnabled: false)
            selectedSection = .download
            var instructions: [String] = []
            if !usable { instructions.append("Choose an available output folder.") }
            if !saved.removedSecrets.isEmpty {
                instructions.append("Re-enter \(saved.removedSecrets.joined(separator: ", ")).")
            }
            composer.showStatus(instructions.joined(separator: " "))
        }
    }

    /// Resumes, in their saved order, every unfinished download that needs nothing from the
    /// user. The rest stay listed, each with its own Resume button.
    func resumeAllInterrupted() {
        let ready = queue.interrupted.filter { canResumeDirectly($0) && toolchain.isReady(for: $0.options.backend) }
        for saved in ready {
            queue.enqueue(url: saved.url, options: saved.options, resuming: saved.id)
        }
        let remaining = queue.interrupted.count
        if remaining > 0 {
            queue.notice = remaining == 1
                ? "One download needs a folder, a credential or a tool before it can resume."
                : "\(remaining) downloads need a folder, a credential or a tool before they can resume."
        }
    }

    func chooseOutputDirectory() {
        composer.chooseOutputDirectory()
    }

    func clearComposer() {
        composer.clear()
    }

    func showLog(for item: DownloadItem) {
        focusedLogItemID = item.id
        selectedSection = .queue
    }

    /// Called from `applicationWillTerminate` so nothing pending is lost.
    func prepareForTermination() {
        activityMonitor.stop()
        queue.prepareForTermination()
        history.flush()
    }

    /// Whether quitting would abandon work in progress.
    var hasWorkInProgress: Bool { queue.activeCount > 0 }
}
