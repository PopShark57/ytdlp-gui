import Foundation
import Testing
@testable import YTDLPGUI_iOS

@MainActor
@Suite("App settings")
struct AppSettingsTests {

    /// A throwaway defaults suite, removed when the test ends.
    private final class Suite {
        let name = "YTDLPGUITests.Settings.\(UUID().uuidString)"
        let defaults: UserDefaults

        init() throws {
            defaults = try #require(UserDefaults(suiteName: name))
        }

        deinit {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
    }

    @Test("A fresh install starts with the documented defaults")
    func defaults() throws {
        let suite = try Suite()
        let settings = AppSettings(defaults: suite.defaults)
        #expect(settings.autoAnalyzePastedURLs)
        #expect(settings.suggestClipboardLinks)
        #expect(settings.maximumConcurrentDownloads == 2)
        #expect(!settings.saveVideosToPhotos)
        #expect(settings.notifyWhenComplete)
        #expect(settings.keepScreenAwake)
        #expect(!settings.showCommandPreview)
        #expect(settings.confirmBeforeClearingHistory)
        #expect(settings.appearance == .system)
        #expect(settings.storedOptions == DownloadOptions())
    }

    @Test("Every change is written through and read back at the next launch")
    func persistence() throws {
        let suite = try Suite()
        let settings = AppSettings(defaults: suite.defaults)
        settings.autoAnalyzePastedURLs = false
        settings.suggestClipboardLinks = false
        settings.maximumConcurrentDownloads = 3
        settings.saveVideosToPhotos = true
        settings.notifyWhenComplete = false
        settings.keepScreenAwake = false
        settings.showCommandPreview = true
        settings.confirmBeforeClearingHistory = false
        settings.appearance = .dark

        let relaunched = AppSettings(defaults: suite.defaults)
        #expect(!relaunched.autoAnalyzePastedURLs)
        #expect(!relaunched.suggestClipboardLinks)
        #expect(relaunched.maximumConcurrentDownloads == 3)
        #expect(relaunched.saveVideosToPhotos)
        #expect(!relaunched.notifyWhenComplete)
        #expect(!relaunched.keepScreenAwake)
        #expect(relaunched.showCommandPreview)
        #expect(!relaunched.confirmBeforeClearingHistory)
        #expect(relaunched.appearance == .dark)
        #expect(relaunched.appearance.colorScheme == .dark)
    }

    @Test("Simultaneous downloads stay within 1...4, however they are set")
    func concurrencyIsClamped() throws {
        let suite = try Suite()
        let settings = AppSettings(defaults: suite.defaults)
        settings.maximumConcurrentDownloads = 10
        #expect(settings.maximumConcurrentDownloads == 4)
        settings.maximumConcurrentDownloads = 0
        #expect(settings.maximumConcurrentDownloads == 1)

        suite.defaults.set(9, forKey: "maximumConcurrentDownloads")
        #expect(AppSettings(defaults: suite.defaults).maximumConcurrentDownloads == 4)
    }

    @Test("The last options are remembered, but never their folder")
    func storedOptions() throws {
        let suite = try Suite()
        let settings = AppSettings(defaults: suite.defaults)
        var options = DownloadOptions()
        options.kind = .audio
        options.audioFormat = .alac
        options.subtitleMode = .both
        options.outputDirectory = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/OLD/Documents")
        settings.rememberOptions(options)
        #expect(settings.storedOptions == options)

        let restored = AppSettings(defaults: suite.defaults).storedOptions
        #expect(restored.kind == .audio)
        #expect(restored.audioFormat == .alac)
        #expect(restored.subtitleMode == .both)
        #expect(restored.outputDirectory == DownloadOptions.defaultDownloadsDirectory)
    }

    @Test("The last options are remembered without credentials, including ones an older build saved")
    func storedOptionsDropSecrets() throws {
        let suite = try Suite()
        let settings = AppSettings(defaults: suite.defaults)
        var options = DownloadOptions()
        options.customArguments = "--username me --password s3cret --no-mtime"
        options.proxy = "http://user:pass@proxy.test:3128"
        settings.rememberOptions(options)
        #expect(settings.storedOptions.customArguments == "--no-mtime")
        #expect(settings.storedOptions.proxy == "http://proxy.test:3128")

        // As an earlier build would have saved them.
        let saved = try JSONEncoder().encode(options)
        suite.defaults.set(saved, forKey: "lastDownloadOptions")
        let relaunched = AppSettings(defaults: suite.defaults)
        #expect(relaunched.storedOptions.customArguments == "--no-mtime")
        let rewritten = try #require(suite.defaults.data(forKey: "lastDownloadOptions"))
        #expect(!String(decoding: rewritten, as: UTF8.self).contains("s3cret"))
    }

    @Test("Resetting restores every default and forgets the last options")
    func reset() throws {
        let suite = try Suite()
        let settings = AppSettings(defaults: suite.defaults)
        settings.maximumConcurrentDownloads = 4
        settings.appearance = .light
        settings.keepScreenAwake = false
        var options = DownloadOptions()
        options.kind = .audio
        settings.rememberOptions(options)

        settings.resetToDefaults()
        #expect(settings.maximumConcurrentDownloads == 2)
        #expect(settings.appearance == .system)
        #expect(settings.keepScreenAwake)
        #expect(settings.storedOptions == DownloadOptions())

        let relaunched = AppSettings(defaults: suite.defaults)
        #expect(relaunched.maximumConcurrentDownloads == 2)
        #expect(relaunched.storedOptions.kind == .video)
    }
}
