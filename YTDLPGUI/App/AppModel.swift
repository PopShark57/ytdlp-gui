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

    var selectedSection: AppSection = .download
    /// Set when the user asks to see a specific queue item's log.
    var focusedLogItemID: DownloadItem.ID?

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
    }

    /// Work that must happen once, after the first window exists.
    func performLaunchSetup() async {
        settings.applyAppearance()
        await toolchain.refresh()
    }

    // MARK: - Clipboard watching

    /// Offers a URL sitting on the clipboard when the app comes to the front.
    ///
    /// The same clipboard contents are only ever offered once, so returning to the app after
    /// dismissing a suggestion doesn't keep re-filling the field.
    func handleAppDidBecomeActive() {
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
        if composer.startDownload(), queue.isBusy {
            selectedSection = .queue
        }
    }

    func analyzeCurrentURL() {
        selectedSection = .download
        composer.analyze()
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
        queue.cancelAll()
        history.flush()
    }

    /// Whether quitting would abandon work in progress.
    var hasWorkInProgress: Bool { queue.activeCount > 0 }
}
