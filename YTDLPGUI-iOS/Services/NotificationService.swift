import Foundation
import UserNotifications
import os

/// Local notifications for finished downloads, posted only while the app is in the background.
///
/// While the app is in front, the queue already shows what happened, so a banner would only
/// repeat it. Everything here degrades quietly: notifications are a courtesy, and a person who
/// declined them still gets a perfectly working app.
@MainActor
final class NotificationService {

    /// Kept in step with the scene phase by `AppModel`. Notifications are only posted while false.
    var isAppActive = true

    /// Called when the person taps a notification about a download, with that download's id.
    var onOpenDownload: ((DownloadItem.ID) -> Void)? {
        didSet { installResponderIfNeeded() }
    }

    private let logger = Logger(subsystem: "io.github.ytdlpgui.YTDLPGUI.iOS", category: "notifications")
    private var responder: NotificationResponder?

    nonisolated private static let itemIDKey = "downloadItemID"
    private static let threadIdentifier = "downloads"

    /// The notification centre traps if the process isn't a bundled app, which is the case for
    /// SwiftUI previews and command-line test hosts.
    private var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Asks for permission if the person hasn't been asked yet. Called when they turn
    /// notifications on, and at the first download that finishes while they're watching, so the
    /// system prompt appears in a moment that explains itself.
    func requestAuthorizationIfNeeded() async {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            logger.info("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func notifyDownloadCompleted(itemID: DownloadItem.ID, title: String, fileName: String?) async {
        await deliver(
            title: "Download complete",
            body: fileName.map { "\(title)\n\($0)" } ?? title,
            itemID: itemID
        )
    }

    func notifyDownloadFailed(itemID: DownloadItem.ID, title: String, reason: String) async {
        await deliver(title: "Download failed", body: "\(title)\n\(reason)", itemID: itemID)
    }

    func notifyQueueFinished(completed: Int, failed: Int) async {
        guard completed + failed > 1 else { return }
        var body = "\(completed) completed"
        if failed > 0 { body += ", \(failed) failed" }
        await deliver(title: "Downloads finished", body: body, itemID: nil)
    }

    // MARK: - Delivery

    private func deliver(title: String, body: String, itemID: DownloadItem.ID?) async {
        guard isAvailable else { return }
        // Nothing to post while the person is looking at the app. Permission is asked for when
        // they start a download, not here: a prompt on top of a finished download hides it.
        guard !isAppActive else { return }

        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        case .denied, .notDetermined:
            return
        @unknown default:
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = Self.threadIdentifier
        if let itemID {
            content.userInfo = [Self.itemIDKey: itemID.uuidString]
        }

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            logger.info("Couldn't post notification: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func installResponderIfNeeded() {
        guard responder == nil, isAvailable else { return }
        let responder = NotificationResponder { [weak self] itemID in
            Task { @MainActor in self?.onOpenDownload?(itemID) }
        }
        self.responder = responder
        UNUserNotificationCenter.current().delegate = responder
    }

    nonisolated fileprivate static func itemID(from userInfo: [AnyHashable: Any]) -> DownloadItem.ID? {
        (userInfo[itemIDKey] as? String).flatMap(UUID.init(uuidString:))
    }
}

/// Receives taps on notifications. A separate object because the delegate protocol isn't
/// main-actor isolated, and the notification centre holds its delegate weakly.
private final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate, Sendable {

    private let onOpen: @Sendable (DownloadItem.ID) -> Void

    init(onOpen: @escaping @Sendable (DownloadItem.ID) -> Void) {
        self.onOpen = onOpen
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        if let itemID = NotificationService.itemID(from: response.notification.request.content.userInfo) {
            onOpen(itemID)
        }
    }
}
