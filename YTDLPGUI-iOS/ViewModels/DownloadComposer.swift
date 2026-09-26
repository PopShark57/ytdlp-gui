import Observation
import Synchronization
import SwiftUI

/// Drives the Download screen: the URL field, the analysis result and the options.
///
/// Mirrors the macOS `DownloadComposer`. The differences come from the embedded engine: the
/// preview shows the embedded argument vector, the advisories speak about what iPhone and iPad
/// can and can't produce, and every path is filled in by the app rather than chosen by the person.
@MainActor
@Observable
final class DownloadComposer {

    enum AnalysisState: Equatable {
        case idle
        case analyzing
        case loaded(MediaInfo)
        case failed(DownloadFailure)

        var info: MediaInfo? {
            if case .loaded(let info) = self { return info }
            return nil
        }

        var isAnalyzing: Bool { self == .analyzing }
    }

    var urlText: String = "" {
        didSet {
            guard urlText != oldValue else { return }
            analyzeWhenReady = false
            // Any previous analysis describes a different link now.
            if analysis != .idle, detectedURLs != analyzedURL.map({ [$0] }) {
                abandonAnalysis()
            }
        }
    }

    var options: DownloadOptions
    private(set) var analysis: AnalysisState = .idle
    /// A transient message, e.g. after queueing several links at once.
    private(set) var statusMessage: String?
    /// Output from the most recent analysis, for "Show Details" on a failure.
    private(set) var analysisLog: [String] = []

    @ObservationIgnored private var analyzedURL: String?
    @ObservationIgnored private var analysisJobID: UUID?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var statusMessageTask: Task<Void, Never>?
    /// Set when a pasted link should be analysed but the engine is still starting.
    @ObservationIgnored private var analyzeWhenReady = false

    private let settings: AppSettings
    private let engine: EngineController
    private let queue: DownloadQueue
    private let cookies: CookieStore
    private let analyzer: any AnalysisEngine
    private let resolver: DownloadOptionsResolver

    init(
        settings: AppSettings,
        engine: EngineController,
        queue: DownloadQueue,
        storage: StorageManager,
        cookies: CookieStore,
        analyzer: any AnalysisEngine
    ) {
        self.settings = settings
        self.engine = engine
        self.queue = queue
        self.cookies = cookies
        self.analyzer = analyzer
        self.resolver = DownloadOptionsResolver(storage: storage, cookies: cookies)
        self.options = Self.editableOptions(from: settings.storedOptions, downloadsDirectory: storage.downloadsDirectory)
    }

    // MARK: - Derived state

    /// The links in the field. More than one means the text was a list or a paragraph.
    var detectedURLs: [String] {
        URLDetection.urlsFromLines(urlText)
    }

    var hasValidURL: Bool { !detectedURLs.isEmpty }

    var isMultipleURLs: Bool { detectedURLs.count > 1 }

    /// Set when Custom Arguments contain something the embedded engine refuses.
    var customArgumentBlockMessage: String? {
        CustomArgumentPolicy.validationMessage(for: options.customArguments, context: .embedded)
    }

    var hasBlockedCustomArguments: Bool { customArgumentBlockMessage != nil }

    var canAnalyze: Bool {
        engine.isReady && detectedURLs.count == 1 && !analysis.isAnalyzing && !hasBlockedCustomArguments
    }

    var canDownload: Bool {
        engine.isReady && hasValidURL && !hasBlockedCustomArguments
    }

    /// The yt-dlp arguments that will be used, shell-quoted, for the preview. Built from the same
    /// resolved options and capabilities the queue uses, so it is the real argument vector, with
    /// passwords and other credentials shown as `PRIVATE`.
    var commandPreview: String {
        let url = detectedURLs.first ?? "URL"
        let arguments = ArgumentBuilder.embeddedDownloadArguments(
            url: url,
            options: resolver.resolve(options),
            capabilities: engine.capabilities
        )
        return ShellQuoting.commandLine(executable: "yt-dlp", arguments: ShellQuoting.redactingSecrets(arguments))
    }

    /// Warnings worth showing before the user downloads.
    var advisories: [String] {
        var messages: [String] = []
        if let block = customArgumentBlockMessage {
            messages.append(block)
        }

        switch options.kind {
        case .video:
            if !engine.capabilities.allowsAV1, asksForMoreThan1080p {
                messages.append("YouTube offers above 1080p only in AV1, which this device can't decode, so downloads top out at 1080p.")
            }
            if let info = analysis.info, let maximum = info.maximumHeight,
               let requested = options.videoQuality.maxHeight, requested > maximum {
                messages.append("The highest quality this source offers is \(maximum)p, so \(requested)p isn't available.")
            }
        case .audio:
            if !options.audioFormat.isAvailableInEmbeddedEngine {
                messages.append("iPhone and iPad can't create \(options.audioFormat.displayName) files, so the audio will be saved as M4A (AAC).")
            }
        }

        if options.embedSubtitles, options.subtitleMode.isEnabled {
            messages.append("On iPhone and iPad, subtitles are saved alongside the video as separate files rather than embedded in it.")
        }
        if options.sponsorBlockMode != .off, options.sponsorBlockCategories.isEmpty {
            messages.append("SponsorBlock is on but no categories are selected.")
        }
        if cookies.isStoredFileMissing {
            messages.append("Your imported cookies file is missing, so downloads run without it. Import it again in Settings › Cookies.")
        }
        return messages
    }

    /// Whether the chosen quality needs more than 1080p. For "Best" that is only known once a
    /// YouTube link has been analysed; elsewhere H.264 often goes higher, so "Best" is fine.
    private var asksForMoreThan1080p: Bool {
        if let cap = options.videoQuality.maxHeight {
            return cap > 1080
        }
        guard let info = analysis.info,
              info.extractor?.lowercased().contains("youtube") == true else { return false }
        return (info.maximumHeight ?? 0) > 1080
    }

    /// Audio formats this device can produce, in display order.
    var availableAudioFormats: [AudioFormat] {
        AudioFormat.allCases.filter(\.isAvailableInEmbeddedEngine)
    }

    /// How many advanced options differ from their defaults, for a badge on the row that opens them.
    var customizedAdvancedOptionCount: Int {
        Self.advancedOptions.filter { $0.isCustomized(options) }.count
    }

    /// "Download", or "Download 3 Links" when several were pasted.
    var downloadButtonTitle: String {
        isMultipleURLs ? "Download \(detectedURLs.count) Links" : "Download"
    }

    // MARK: - Input

    /// Accepts text from a paste, a drop, a shared link or a `ytdlpgui://` URL.
    func setURLText(_ text: String, analyzeIfEnabled: Bool) {
        let urls = URLDetection.urlsFromLines(text)
        guard !urls.isEmpty else {
            urlText = text
            showStatus("No web address was found in that text.")
            return
        }
        abandonAnalysis()
        urlText = urls.joined(separator: "\n")
        guard analyzeIfEnabled, settings.autoAnalyzePastedURLs, urls.count == 1 else { return }
        if engine.isReady {
            analyze()
        } else {
            analyzeWhenReady = true
        }
    }

    /// Replaces the options, e.g. with those of a history entry. Paths and anything the embedded
    /// engine refuses are dropped; the app fills in its own when downloading.
    func loadOptions(_ options: DownloadOptions) {
        var editable = Self.editableOptions(from: options, downloadsDirectory: self.options.outputDirectory)
        editable.customArguments = DownloadOptionsResolver.sanitizedCustomArguments(options.customArguments).arguments
        self.options = editable
    }

    /// Called once the engine has started, so a link pasted while it was starting still gets
    /// analysed.
    func engineDidBecomeReady() {
        guard analyzeWhenReady, engine.isReady else { return }
        analyzeWhenReady = false
        if analysis == .idle, detectedURLs.count == 1 {
            analyze()
        }
    }

    func clear() {
        abandonAnalysis()
        urlText = ""
        analysisLog = []
        analyzeWhenReady = false
        dismissStatus()
    }

    // MARK: - Analysis

    /// Fetches metadata for the single link in the field.
    func analyze() {
        let urls = detectedURLs
        guard urls.count == 1, let url = urls.first, engine.isReady else { return }
        if let block = customArgumentBlockMessage {
            showStatus(block)
            return
        }

        abandonAnalysis()
        let jobID = UUID()
        analysis = .analyzing
        analyzedURL = url
        analysisJobID = jobID
        analysisLog = []

        let argv = ArgumentBuilder.embeddedMetadataArguments(url: url, options: resolver.resolve(options))
        let analyzer = analyzer
        let collector = AnalysisLogCollector()

        analysisTask = Task { [weak self] in
            do {
                let data = try await analyzer.analyze(argv: argv, jobID: jobID) { _, line in
                    collector.append(line)
                }
                self?.analysisSucceeded(data, url: url, jobID: jobID, log: collector.lines)
            } catch {
                self?.analysisFailed(error, jobID: jobID, log: collector.lines)
            }
        }
    }

    func cancelAnalysis() {
        abandonAnalysis()
    }

    /// Stops any analysis in flight and forgets it; its result, if it still arrives, is ignored.
    private func abandonAnalysis() {
        if let analysisJobID {
            analyzer.cancel(jobID: analysisJobID)
        }
        analysisTask?.cancel()
        analysisTask = nil
        analysisJobID = nil
        analyzedURL = nil
        if analysis != .idle { analysis = .idle }
    }

    private func analysisSucceeded(_ data: Data, url: String, jobID: UUID, log: [String]) {
        guard analysisJobID == jobID else { return }
        analysisJobID = nil
        analysisTask = nil
        analysisLog = log
        do {
            let info = try MediaInfoDecoder.decode(data, originalURL: url)
            analysis = .loaded(info)
            adoptDefaults(from: info)
        } catch {
            analysis = .failed(DownloadFailure(
                kind: .unknown,
                underlyingMessage: "yt-dlp's description of this link couldn't be read: \(error.localizedDescription)"
            ))
        }
    }

    private func analysisFailed(_ error: any Error, jobID: UUID, log: [String]) {
        guard analysisJobID == jobID else { return }
        analysisJobID = nil
        analysisTask = nil
        analysisLog = log

        switch error as? EngineError {
        case .analysisFailed(let message, let logLines)?:
            if !logLines.isEmpty { analysisLog = logLines }
            var lines = analysisLog
            // The message is usually one of the log lines already; if not, it is the best
            // evidence there is.
            if !message.isEmpty, !lines.contains(where: { $0.contains(message) }) {
                lines.append(message)
            }
            analysis = .failed(DownloadFailure.classify(logLines: lines, exitCode: 1))
        case .cancelled?:
            analyzedURL = nil
            analysis = .idle
        default:
            analysis = .failed(DownloadFailure(kind: .unknown, underlyingMessage: error.localizedDescription))
        }
    }

    /// Turns on playlist mode when the analysed URL turns out to be nothing but a playlist.
    ///
    /// This does not override a deliberate choice. Analysis runs with `--no-playlist` whenever
    /// the toggle is off, so a *video inside* a playlist comes back as a single video and this
    /// never fires. Only a URL that is a playlist and nothing else — where `--no-playlist` has
    /// nothing to fall back to — still reports itself as one, and downloading a single item
    /// from it isn't a meaningful option.
    private func adoptDefaults(from info: MediaInfo) {
        guard info.isPlaylist, !options.downloadPlaylist else { return }
        options.downloadPlaylist = true
        // Numbering into a per-playlist folder is almost always what's wanted here, but an
        // edited template is the user's and stays untouched.
        if options.outputTemplate == DownloadOptions.defaultOutputTemplate {
            options.outputTemplate = "%(playlist_title|Downloads)s/%(playlist_index|0)02d - %(title)s.%(ext)s"
        }
    }

    // MARK: - Queueing

    /// Queues the link (or all of them). Returns whether anything was queued.
    @discardableResult
    func startDownload() -> Bool {
        guard canDownload else {
            if let block = customArgumentBlockMessage {
                showStatus(block)
            } else if hasValidURL, !engine.isReady {
                showStatus("The download engine is still starting. Try again in a moment.")
            }
            return false
        }

        let urls = detectedURLs
        let queuedOptions = resolver.resolve(options)

        if urls.count == 1, let url = urls.first {
            let info = analysis.info.flatMap { $0.originalURL == url ? $0 : nil }
            guard case .added = queue.enqueue(url: url, options: queuedOptions, info: info) else {
                // The link stays in the field, so nothing typed is lost.
                showStatus("That link is already in the queue.")
                return false
            }
            if let info {
                showStatus("Added “\(info.title)” to the queue.")
            } else {
                showStatus("Added 1 download to the queue.")
            }
        } else {
            let added = queue.enqueue(urls: urls, options: queuedOptions)
            switch added.count {
            case 0: showStatus("Those downloads are already in the queue.")
            case 1: showStatus("Added 1 download to the queue.")
            default: showStatus("Added \(added.count) downloads to the queue.")
            }
        }

        // The person's own choices, not the resolved copy, so no path is remembered.
        settings.rememberOptions(options)
        clearURLAfterQueueing()
        return true
    }

    private func clearURLAfterQueueing() {
        abandonAnalysis()
        urlText = ""
        analysisLog = []
    }

    // MARK: - Advanced options

    /// One advanced option: whether it differs from its default, and how to put it back.
    private struct AdvancedOption {
        let isCustomized: (DownloadOptions) -> Bool
        let reset: (inout DownloadOptions) -> Void

        init<Value: Equatable>(_ keyPath: WritableKeyPath<DownloadOptions, Value>) {
            let defaultValue = DownloadOptions()[keyPath: keyPath]
            isCustomized = { $0[keyPath: keyPath] != defaultValue }
            reset = { $0[keyPath: keyPath] = defaultValue }
        }
    }

    /// Everything on the Advanced Options screen. Left out: the mode and quality choices, which
    /// are on the main screen, and the fields the app fills in itself (output folder, archive
    /// and cookie paths, browser cookies, ignoring config files), which the person never sets.
    private static let advancedOptions: [AdvancedOption] = [
        AdvancedOption(\.outputTemplate),
        AdvancedOption(\.restrictFilenames),
        AdvancedOption(\.overwriteExisting),
        AdvancedOption(\.subtitleMode),
        AdvancedOption(\.subtitleLanguages),
        AdvancedOption(\.embedSubtitles),
        AdvancedOption(\.embedThumbnail),
        AdvancedOption(\.embedMetadata),
        AdvancedOption(\.embedChapters),
        AdvancedOption(\.writeThumbnail),
        AdvancedOption(\.writeInfoJSON),
        AdvancedOption(\.sponsorBlockMode),
        AdvancedOption(\.sponsorBlockCategories),
        AdvancedOption(\.downloadPlaylist),
        AdvancedOption(\.playlistItems),
        AdvancedOption(\.useDownloadArchive),
        AdvancedOption(\.rateLimit),
        AdvancedOption(\.concurrentFragments),
        AdvancedOption(\.proxy),
        AdvancedOption(\.userAgent),
        AdvancedOption(\.customArguments),
    ]

    /// Puts every advanced option back to its default, keeping the mode and quality choices.
    func resetAdvancedOptions() {
        var reset = options
        for option in Self.advancedOptions {
            option.reset(&reset)
        }
        options = reset
    }

    /// Options as the Download screen edits them: the person's choices, with the fields the
    /// app manages cleared so they neither count as customisations nor carry stale paths.
    private static func editableOptions(from options: DownloadOptions, downloadsDirectory: URL) -> DownloadOptions {
        var editable = options
        editable.outputDirectory = downloadsDirectory
        editable.downloadArchivePath = ""
        editable.cookieFilePath = ""
        editable.cookieBrowser = .none
        editable.ignoreUserConfig = true
        return editable
    }

    // MARK: - Status banner

    func showStatus(_ message: String) {
        statusMessage = message
        statusMessageTask?.cancel()
        statusMessageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.statusMessage = nil
        }
    }

    func dismissStatus() {
        statusMessageTask?.cancel()
        statusMessage = nil
    }
}

/// Collects an analysis's output lines, which arrive on the engine's thread.
private final class AnalysisLogCollector: Sendable {
    private let storage = Mutex<[String]>([])

    func append(_ line: String) {
        storage.withLock { lines in
            lines.append(line)
            if lines.count > LogBuffer.limit {
                lines.removeFirst(lines.count - LogBuffer.limit)
            }
        }
    }

    var lines: [String] {
        storage.withLock { $0 }
    }
}
