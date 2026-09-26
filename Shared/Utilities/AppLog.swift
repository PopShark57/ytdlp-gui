import Foundation
import os

/// The app's loggers, all under one subsystem: the bundle identifier of the app that is
/// running. `log stream --predicate 'subsystem == "io.github.ytdlpgui.YTDLPGUI.iOS"'` then shows
/// everything the iOS app says, one category per area.
///
/// Links and file names are logged with `privacy: .private`; identifiers, states and counts are
/// public, so a report from a device still shows what happened to which download.
enum AppLog {

    static let subsystem = Bundle.main.bundleIdentifier ?? "io.github.ytdlpgui.YTDLPGUI"

    /// Starting the embedded engine, its jobs and updates.
    static let engine = Logger(subsystem: subsystem, category: "engine")
    /// The JavaScript challenge solver.
    static let javaScript = Logger(subsystem: subsystem, category: "javascript")
    /// AVFoundation work the engine asks for.
    static let media = Logger(subsystem: subsystem, category: "media")
    /// Downloads moving through the queue, and the saved queue.
    static let queue = Logger(subsystem: subsystem, category: "queue")
    static let history = Logger(subsystem: subsystem, category: "history")
    static let notifications = Logger(subsystem: subsystem, category: "notifications")
    /// Background execution and the idle timer.
    static let background = Logger(subsystem: subsystem, category: "background")
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let cookies = Logger(subsystem: subsystem, category: "cookies")
    /// Links handed over by the Share extension.
    static let shareInbox = Logger(subsystem: subsystem, category: "share-inbox")
}
