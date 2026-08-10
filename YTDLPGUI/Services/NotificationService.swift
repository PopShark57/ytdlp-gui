import AppKit
import Foundation
import UserNotifications
import os

/// Posts a local notification when a download finishes.
///
/// Everything here degrades quietly: notifications are a courtesy, and a user who declined the
/// permission (or is running an unsigned build where the notification centre is unavailable)
/// should still get a perfectly working app.
@MainActor
final class NotificationService {

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

    func notifyDownloadCompleted(title: String, fileName: String?, playSound: Bool) async {
        await post(
            title: "Download complete",
            body: fileName.map { "\(title)\n\($0)" } ?? title,
            playSound: playSound
        )
    }

    func notifyDownloadFailed(title: String, reason: String, playSound: Bool) async {
        await post(
            title: "Download failed",
            body: "\(title)\n\(reason)",
            playSound: playSound
        )
    }

    func notifyQueueFinished(completed: Int, failed: Int, playSound: Bool) async {
        guard completed + failed > 1 else { return }
        var body = "\(completed) completed"
        if failed > 0 { body += ", \(failed) failed" }
        await post(title: "Queue finished", body: body, playSound: playSound)
    }

    private func post(title: String, body: String, playSound: Bool) async {
        guard await ensureAuthorized() else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
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
}
