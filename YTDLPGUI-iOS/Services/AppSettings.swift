import Observation
import SwiftUI

/// User preferences, persisted in `UserDefaults`. The iOS counterpart of the macOS `AppSettings`.
///
/// Values are held as stored properties so SwiftUI's observation sees every change, and each
/// setter writes straight through to `UserDefaults`: iOS terminates suspended apps without
/// warning, so there is no later moment at which a batch save could be relied upon.
@MainActor
@Observable
final class AppSettings {

    enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
        case system
        case light
        case dark

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }

        var symbolName: String {
            switch self {
            case .system: "circle.lefthalf.filled"
            case .light: "sun.max"
            case .dark: "moon"
            }
        }

        /// The value for `.preferredColorScheme`; `nil` follows the system.
        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    private enum Key {
        static let autoAnalyze = "autoAnalyzePastedURLs"
        static let suggestClipboardLinks = "suggestClipboardLinks"
        static let maximumConcurrentDownloads = "maximumConcurrentDownloads"
        static let saveVideosToPhotos = "saveVideosToPhotos"
        static let notifyWhenComplete = "notifyWhenComplete"
        static let keepScreenAwake = "keepScreenAwake"
        static let showCommandPreview = "showCommandPreview"
        static let confirmBeforeClearingHistory = "confirmBeforeClearingHistory"
        static let appearance = "appearanceMode"
        static let lastOptions = "lastDownloadOptions"
    }

    /// A phone has far less bandwidth, memory and battery to share than a Mac, and every running
    /// download is a Python thread in this process, so the ceiling is lower than on macOS.
    static let concurrencyRange = 1...4

    private enum Default {
        static let autoAnalyzePastedURLs = true
        static let suggestClipboardLinks = true
        static let maximumConcurrentDownloads = 2
        static let saveVideosToPhotos = false
        static let notifyWhenComplete = true
        static let keepScreenAwake = true
        static let showCommandPreview = false
        static let confirmBeforeClearingHistory = true
        static let appearance = AppearanceMode.system
    }

    private let defaults: UserDefaults

    // MARK: Downloads

    var autoAnalyzePastedURLs: Bool {
        didSet { defaults.set(autoAnalyzePastedURLs, forKey: Key.autoAnalyze) }
    }

    /// Offer a link found on the clipboard when the app comes to the front.
    var suggestClipboardLinks: Bool {
        didSet { defaults.set(suggestClipboardLinks, forKey: Key.suggestClipboardLinks) }
    }

    /// Clamped in the setter of this computed wrapper rather than in a `didSet`: `@Observable`
    /// turns an observed property into a computed one, so assigning to it from its own observer
    /// re-enters the setter instead of being suppressed, and recurses until the stack runs out.
    var maximumConcurrentDownloads: Int {
        get { concurrencyLimit }
        set {
            concurrencyLimit = newValue.constrained(to: Self.concurrencyRange)
            defaults.set(concurrencyLimit, forKey: Key.maximumConcurrentDownloads)
        }
    }

    private var concurrencyLimit: Int

    /// Save finished videos to the photo library automatically.
    var saveVideosToPhotos: Bool {
        didSet { defaults.set(saveVideosToPhotos, forKey: Key.saveVideosToPhotos) }
    }

    var notifyWhenComplete: Bool {
        didSet { defaults.set(notifyWhenComplete, forKey: Key.notifyWhenComplete) }
    }

    /// Keep the screen from locking while downloads run in the foreground.
    var keepScreenAwake: Bool {
        didSet { defaults.set(keepScreenAwake, forKey: Key.keepScreenAwake) }
    }

    // MARK: Interface

    var showCommandPreview: Bool {
        didSet { defaults.set(showCommandPreview, forKey: Key.showCommandPreview) }
    }

    var confirmBeforeClearingHistory: Bool {
        didSet { defaults.set(confirmBeforeClearingHistory, forKey: Key.confirmBeforeClearingHistory) }
    }

    var appearance: AppearanceMode {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    // MARK: Last used options

    /// The options the user last downloaded with, restored at launch.
    private(set) var storedOptions: DownloadOptions

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        autoAnalyzePastedURLs = defaults.object(forKey: Key.autoAnalyze) as? Bool
            ?? Default.autoAnalyzePastedURLs
        suggestClipboardLinks = defaults.object(forKey: Key.suggestClipboardLinks) as? Bool
            ?? Default.suggestClipboardLinks
        let storedConcurrency = defaults.object(forKey: Key.maximumConcurrentDownloads) as? Int
            ?? Default.maximumConcurrentDownloads
        concurrencyLimit = storedConcurrency.constrained(to: Self.concurrencyRange)
        saveVideosToPhotos = defaults.object(forKey: Key.saveVideosToPhotos) as? Bool
            ?? Default.saveVideosToPhotos
        notifyWhenComplete = defaults.object(forKey: Key.notifyWhenComplete) as? Bool
            ?? Default.notifyWhenComplete
        keepScreenAwake = defaults.object(forKey: Key.keepScreenAwake) as? Bool
            ?? Default.keepScreenAwake
        showCommandPreview = defaults.object(forKey: Key.showCommandPreview) as? Bool
            ?? Default.showCommandPreview
        confirmBeforeClearingHistory = defaults.object(forKey: Key.confirmBeforeClearingHistory) as? Bool
            ?? Default.confirmBeforeClearingHistory
        appearance = AppearanceMode(rawValue: defaults.string(forKey: Key.appearance) ?? "")
            ?? Default.appearance

        var restored = DownloadOptions()
        if let data = defaults.data(forKey: Key.lastOptions),
           let decoded = try? JSONDecoder().decode(DownloadOptions.self, from: data) {
            restored = decoded
            // Earlier builds kept credentials here.
            let stripped = decoded.removingSecrets()
            if !stripped.removed.isEmpty {
                restored = stripped.options
                if let data = try? JSONEncoder().encode(restored) {
                    defaults.set(data, forKey: Key.lastOptions)
                }
            }
        }
        // The container, and with it every absolute path, moves when iOS updates or reinstalls
        // the app, so a stored folder is never trusted.
        restored.outputDirectory = DownloadOptions.defaultDownloadsDirectory
        storedOptions = restored
    }

    /// Remembers the options used for the most recent download, without passwords or other
    /// credentials: `UserDefaults` is included in device backups. The Download screen keeps them
    /// for as long as the app runs.
    func rememberOptions(_ options: DownloadOptions) {
        let options = options.removingSecrets().options
        storedOptions = options
        if let data = try? JSONEncoder().encode(options) {
            defaults.set(data, forKey: Key.lastOptions)
        }
    }

    /// Restores factory defaults.
    func resetToDefaults() {
        autoAnalyzePastedURLs = Default.autoAnalyzePastedURLs
        suggestClipboardLinks = Default.suggestClipboardLinks
        maximumConcurrentDownloads = Default.maximumConcurrentDownloads
        saveVideosToPhotos = Default.saveVideosToPhotos
        notifyWhenComplete = Default.notifyWhenComplete
        keepScreenAwake = Default.keepScreenAwake
        showCommandPreview = Default.showCommandPreview
        confirmBeforeClearingHistory = Default.confirmBeforeClearingHistory
        appearance = Default.appearance
        storedOptions = DownloadOptions()
        defaults.removeObject(forKey: Key.lastOptions)
    }
}
