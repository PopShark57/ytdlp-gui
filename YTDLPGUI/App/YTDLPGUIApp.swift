import AppKit
import SwiftUI

@main
struct YTDLPGUIApp: App {

    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("YTDLP GUI", id: WindowID.main) {
            RootView()
                .environment(model)
                .task {
                    appDelegate.model = model
                    await model.performLaunchSetup()
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                ) { _ in
                    model.handleAppDidBecomeActive()
                }
        }
        .defaultSize(width: 1_040, height: 720)
        .windowToolbarStyle(.unified)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsRootView()
                .environment(model)
        }
    }
}

enum WindowID {
    static let main = "main"
}

/// Minimal delegate for the few behaviours SwiftUI doesn't expose.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Assigned once the first window exists. Only used to guard termination.
    var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Confirms before abandoning downloads that are still running.
    ///
    /// Closing the window quits the app, which would otherwise kill an in-progress download
    /// with no warning and leave a partial `.part` file behind.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.hasWorkInProgress else {
            model?.prepareForTermination()
            return .terminateNow
        }

        let count = model.queue.activeCount
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = count == 1
            ? "A download is still in progress."
            : "\(count) downloads are still in progress."
        // yt-dlp keeps its .part files so an interrupted download can resume, so this
        // deliberately does not promise any cleanup.
        alert.informativeText = "Quitting now will stop them. Any partly downloaded files are left in place."
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return .terminateCancel
        }
        model.prepareForTermination()
        return .terminateNow
    }
}
