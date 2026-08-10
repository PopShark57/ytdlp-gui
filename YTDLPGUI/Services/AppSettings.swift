import AppKit
import Foundation
import Observation

/// User preferences, persisted in `UserDefaults`.
///
/// Values are held as stored properties so SwiftUI's observation sees every change, and each
/// setter writes straight through to `UserDefaults` so nothing is lost if the app is force-quit.
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

        var nsAppearance: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    private enum Key {
        static let downloadDirectory = "downloadDirectoryPath"
        static let autoAnalyze = "autoAnalyzePastedURLs"
        static let readClipboard = "readClipboardOnActivate"
        static let maximumConcurrentDownloads = "maximumConcurrentDownloads"
        static let revealWhenComplete = "revealWhenComplete"
        static let notifyWhenComplete = "notifyWhenComplete"
        static let playSoundWhenComplete = "playSoundWhenComplete"
        static let appearance = "appearanceMode"
        static let ytdlpPath = "ytdlpExecutablePath"
        static let ffmpegPath = "ffmpegExecutablePath"
        static let lastOptions = "lastDownloadOptions"
        static let showCommandPreview = "showCommandPreview"
        static let confirmBeforeClearingHistory = "confirmBeforeClearingHistory"
    }

    private let defaults: UserDefaults

    // MARK: General

    var downloadDirectory: URL {
        didSet { defaults.set(downloadDirectory.path(percentEncoded: false), forKey: Key.downloadDirectory) }
    }

    var autoAnalyzePastedURLs: Bool {
        didSet { defaults.set(autoAnalyzePastedURLs, forKey: Key.autoAnalyze) }
    }

    var readClipboardOnActivate: Bool {
        didSet { defaults.set(readClipboardOnActivate, forKey: Key.readClipboard) }
    }

    /// Clamped to `concurrencyRange` on the way in rather than inside the observer: `@Observable`
    /// turns an observed property into a computed one, so assigning to it from its own `didSet`
    /// re-enters the setter instead of being suppressed, and recurses until the stack runs out.
    var maximumConcurrentDownloads: Int {
        didSet {
            defaults.set(maximumConcurrentDownloads, forKey: Key.maximumConcurrentDownloads)
        }
    }

    static let concurrencyRange = 1...8

    var revealWhenComplete: Bool {
        didSet { defaults.set(revealWhenComplete, forKey: Key.revealWhenComplete) }
    }

    var notifyWhenComplete: Bool {
        didSet { defaults.set(notifyWhenComplete, forKey: Key.notifyWhenComplete) }
    }

    var playSoundWhenComplete: Bool {
        didSet { defaults.set(playSoundWhenComplete, forKey: Key.playSoundWhenComplete) }
    }

    // MARK: Appearance

    var appearance: AppearanceMode {
        didSet {
            defaults.set(appearance.rawValue, forKey: Key.appearance)
            applyAppearance()
        }
    }

    // MARK: Tools

    /// Empty means "detect automatically".
    var ytdlpPathOverride: String {
        didSet { defaults.set(ytdlpPathOverride, forKey: Key.ytdlpPath) }
    }

    var ffmpegPathOverride: String {
        didSet { defaults.set(ffmpegPathOverride, forKey: Key.ffmpegPath) }
    }

    // MARK: Interface

    var showCommandPreview: Bool {
        didSet { defaults.set(showCommandPreview, forKey: Key.showCommandPreview) }
    }

    var confirmBeforeClearingHistory: Bool {
        didSet { defaults.set(confirmBeforeClearingHistory, forKey: Key.confirmBeforeClearingHistory) }
    }

    // MARK: Last used options

    /// The options the user last downloaded with, restored at launch.
    private(set) var storedOptions: DownloadOptions

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedPath = defaults.string(forKey: Key.downloadDirectory)
        let resolvedDirectory = storedPath.map { URL(fileURLWithPath: $0) }
            ?? DownloadOptions.defaultDownloadsDirectory
        downloadDirectory = resolvedDirectory

        autoAnalyzePastedURLs = defaults.object(forKey: Key.autoAnalyze) as? Bool ?? true
        readClipboardOnActivate = defaults.object(forKey: Key.readClipboard) as? Bool ?? false
        let storedConcurrency = defaults.object(forKey: Key.maximumConcurrentDownloads) as? Int ?? 2
        maximumConcurrentDownloads = storedConcurrency.constrained(to: Self.concurrencyRange)
        revealWhenComplete = defaults.object(forKey: Key.revealWhenComplete) as? Bool ?? false
        notifyWhenComplete = defaults.object(forKey: Key.notifyWhenComplete) as? Bool ?? true
        playSoundWhenComplete = defaults.object(forKey: Key.playSoundWhenComplete) as? Bool ?? true
        appearance = AppearanceMode(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        ytdlpPathOverride = defaults.string(forKey: Key.ytdlpPath) ?? ""
        ffmpegPathOverride = defaults.string(forKey: Key.ffmpegPath) ?? ""
        showCommandPreview = defaults.object(forKey: Key.showCommandPreview) as? Bool ?? false
        confirmBeforeClearingHistory = defaults.object(forKey: Key.confirmBeforeClearingHistory) as? Bool ?? true

        var restored = DownloadOptions()
        if let data = defaults.data(forKey: Key.lastOptions),
           let decoded = try? JSONDecoder().decode(DownloadOptions.self, from: data) {
            restored = decoded
        }
        // The saved directory can have been deleted or moved since last launch.
        restored.outputDirectory = resolvedDirectory
        storedOptions = restored
    }

    /// Remembers the options used for the most recent download.
    func rememberOptions(_ options: DownloadOptions) {
        storedOptions = options
        if let data = try? JSONEncoder().encode(options) {
            defaults.set(data, forKey: Key.lastOptions)
        }
    }

    /// Applies the chosen appearance to the whole app.
    func applyAppearance() {
        NSApp?.appearance = appearance.nsAppearance
    }

    /// Restores factory defaults for everything except the tool paths.
    func resetToDefaults() {
        downloadDirectory = DownloadOptions.defaultDownloadsDirectory
        autoAnalyzePastedURLs = true
        readClipboardOnActivate = false
        maximumConcurrentDownloads = 2
        revealWhenComplete = false
        notifyWhenComplete = true
        playSoundWhenComplete = true
        appearance = .system
        showCommandPreview = false
        confirmBeforeClearingHistory = true
        storedOptions = DownloadOptions()
        defaults.removeObject(forKey: Key.lastOptions)
    }
}
