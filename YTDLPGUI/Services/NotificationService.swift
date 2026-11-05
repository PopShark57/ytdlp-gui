import AppKit
import Foundation
import UserNotifications
import os

/// Posts a local notification when a download finishes, and routes what the user does with it.
///
/// A completed download's notification offers Show in Finder; a failed one offers Retry.
/// Clicking either opens the matching section of the window. `onResponse` is how the app
/// hears about it.
///
/// Everything here degrades quietly: notifications are a courtesy, and a user who declined the
/// permission (or is running an unsigned build where the notification centre is unavailable)
/// should still get a perfectly working app.
@MainActor
final class NotificationService: NSObject {

    /// What the user asked for from a notification.
    enum Response: Equatable {
        case reveal([URL])
        case retry(UUID)
        case showQueue
        case showHistory
    }

    /// Set by the app model. Called on the main actor.
    var onResponse: ((Response) -> Void)?

    private enum Category {
        static let completed = "download.completed"
        static let failed = "download.failed"
        static let queue = "queue.finished"
    }

    private enum Action {
        static let reveal = "reveal"
        static let retry = "retry"
    }

    private enum UserInfoKey {
        static let paths = "paths"
        static let itemID = "itemID"
    }

    private let logger = Logger(subsystem: "io.github.ytdlpgui.YTDLPGUI", category: "notifications")
    private var authorizationState: AuthorizationState = .notRequested

    private enum AuthorizationState {
        case notRequested
        case granted
        case denied
        case unavailable
    }

    /// The notification centre traps if the process isn't a properly bundled app, which is the
    /// case for SwiftUI previews and command-line test hosts.
    private var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    override init() {
        super.init()
        guard isAvailable else { return }
        // The delegate must be in place before launch finishes, so a click on a notification that
        // relaunched the app is still delivered.
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Category.completed,
                actions: [UNNotificationAction(identifier: Action.reveal, title: "Show in Finder")],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Category.failed,
                actions: [UNNotificationAction(identifier: Action.retry, title: "Retry")],
                intentIdentifiers: []
            ),
            UNNotificationCategory(identifier: Category.queue, actions: [], intentIdentifiers: []),
        ])
    }

    /// Asks for permission the first time it is actually needed rather than at launch, so the
    /// system prompt appears in a context the user understands.
    private func ensureAuthorized() async -> Bool {
        switch authorizationState {
        case .granted: return true
        case .denied, .unavailable: return false
        case .notRequested: break
        }

        guard isAvailable else {
            authorizationState = .unavailable
            return false
        }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            authorizationState = .granted
            return true
        case .denied:
            authorizationState = .denied
            return false
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                authorizationState = granted ? .granted : .denied
                return granted
            } catch {
                logger.info("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
                authorizationState = .unavailable
                return false
            }
        @unknown default:
            authorizationState = .denied
            return false
        }
    }

    func notifyDownloadCompleted(title: String, fileName: String?, files: [URL], playSound: Bool) async {
        await post(
            title: "Download complete",
            body: fileName.map { "\(title)\n\($0)" } ?? title,
            category: Category.completed,
            userInfo: [UserInfoKey.paths: files.map { $0.path(percentEncoded: false) }],
            playSound: playSound
        )
    }

    func notifyDownloadFailed(title: String, reason: String, itemID: UUID, playSound: Bool) async {
        await post(
            title: "Download failed",
            body: "\(title)\n\(reason)",
            category: Category.failed,
            userInfo: [UserInfoKey.itemID: itemID.uuidString],
            playSound: playSound
        )
    }

    func notifyQueueFinished(completed: Int, failed: Int, playSound: Bool) async {
        guard completed + failed > 1 else { return }
        var body = "\(completed) completed"
        if failed > 0 { body += ", \(failed) failed" }
        await post(title: "Queue finished", body: body, category: Category.queue, userInfo: [:], playSound: playSound)
    }

    private func post(
        title: String,
        body: String,
        category: String,
        userInfo: [String: any Sendable],
        playSound: Bool
    ) async {
        guard await ensureAuthorized() else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.userInfo = userInfo
        // One group per kind, so a long batch stacks in Notification Center instead of
        // flooding it.
        content.threadIdentifier = category
        if playSound { content.sound = .default }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            logger.info("Couldn't post notification: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handle(category: String, action: String, paths: [String], itemID: UUID?) {
        let response: Response
        switch (category, action) {
        case (Category.completed, Action.reveal):
            response = .reveal(paths.map { URL(fileURLWithPath: $0) })
        case (Category.failed, Action.retry):
            guard let itemID else { return }
            response = .retry(itemID)
        case (Category.failed, _):
            response = .showQueue
        case (_, UNNotificationDismissActionIdentifier):
            return
        default:
            response = .showHistory
        }
        onResponse?(response)
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content
        let category = content.categoryIdentifier
        let action = response.actionIdentifier
        let paths = content.userInfo[UserInfoKey.paths] as? [String] ?? []
        let itemID = (content.userInfo[UserInfoKey.itemID] as? String).flatMap(UUID.init(uuidString:))
        await handle(category: category, action: action, paths: paths, itemID: itemID)
    }

    /// Shown as a banner even while the app is in front: with the window closed and the app
    /// living in the menu bar, it can be frontmost with nothing on screen.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await MainActor.run {
            NSApp.windows.contains { $0.isVisible && $0.isKeyWindow } ? [.list] : [.banner, .list, .sound]
        }
    }
}
