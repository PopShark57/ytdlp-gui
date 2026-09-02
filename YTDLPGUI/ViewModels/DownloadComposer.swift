import Foundation
import Observation

/// Drives the main "new download" screen: the URL field, the analysis result and the options.
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
            // Any previous analysis describes a different URL now.
            if analysis != .idle, urlText != analyzedURL {
                analysis = .idle
            }
        }
    }

    var options: DownloadOptions
    private(set) var analysis: AnalysisState = .idle
    /// Shown as a transient banner, e.g. after adding several URLs at once.
    private(set) var statusMessage: String?

    private var analyzedURL: String?
    private var analysisTask: Task<Void, Never>?
    private var statusMessageTask: Task<Void, Never>?

    private let settings: AppSettings
    private let toolchain: Toolchain
    private let queue: DownloadQueue

    init(settings: AppSettings, toolchain: Toolchain, queue: DownloadQueue) {
        self.settings = settings
        self.toolchain = toolchain
        self.queue = queue
        self.options = settings.storedOptions
        self.options.outputDirectory = settings.downloadDirectory
    }

    // MARK: - Derived state

    /// The URLs currently in the field. More than one means the text was a list or a paragraph.
    var detectedURLs: [String] {
        URLDetection.urlsFromLines(urlText)
    }

    var hasValidURL: Bool { !detectedURLs.isEmpty }

    var isMultipleURLs: Bool { detectedURLs.count > 1 }

    /// Error when Custom Arguments contain denied flags such as `--exec`.
    var customArgumentBlockMessage: String? {
        CustomArgumentPolicy.validationMessage(for: options.customArguments)
    }

    var hasBlockedCustomArguments: Bool { customArgumentBlockMessage != nil }

    var canAnalyze: Bool {
        toolchain.isReady && detectedURLs.count == 1 && !analysis.isAnalyzing && !hasBlockedCustomArguments
    }

    var canDownload: Bool {
        toolchain.isReady && hasValidURL && !hasBlockedCustomArguments
    }

    /// The exact command that will run, for the preview panel.
    var commandPreview: String {
        guard let service = toolchain.service else {
            return "yt-dlp is not installed yet."
        }
        let url = detectedURLs.first ?? "URL"
        return service.previewCommand(url: url, options: options)
    }

    /// Warnings worth surfacing before the user presses Download.
    var advisories: [String] {
        var messages: [String] = []
        if let block = customArgumentBlockMessage {
            messages.append(block)
        }
        if !toolchain.canMergeStreams {
            switch options.kind {
            case .video:
                messages.append("ffmpeg isn't installed. Video and audio streams can't be merged, so quality will be limited to pre-combined formats.")
            case .audio:
                if options.audioFormat != .best {
                    messages.append("ffmpeg isn't installed, so audio can't be converted to \(options.audioFormat.displayName).")
                }
            }
        }
        if options.kind == .video, options.embedSubtitles, options.container == .webm {
            messages.append("WebM can't carry embedded subtitles. Choose MP4 or MKV, or save subtitles as a separate file.")
        }
        if options.embedThumbnail, options.kind == .video, options.container == .webm {
            messages.append("WebM doesn't support embedded cover art.")
        }
        if let info = analysis.info, let maximum = info.maximumHeight,
           let requested = options.videoQuality.maxHeight, requested > maximum, options.kind == .video {
            messages.append("The highest quality this source offers is \(maximum)p, so \(requested)p isn't available.")
        }
        if options.sponsorBlockMode != .off, options.sponsorBlockCategories.isEmpty {
            messages.append("SponsorBlock is on but no categories are selected.")
        }
        if options.useDownloadArchive, options.downloadArchivePath.trimmingCharacters(in: .whitespaces).isEmpty {
            messages.append("Choose an archive file, or turn the download archive off.")
        }
        return messages
    }

    // MARK: - Actions

    func pasteFromClipboard() {
        guard let text = Pasteboard.string()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            showStatus("The clipboard doesn't contain any text.")
            return
        }
        setURLText(text, analyzeIfEnabled: true)
    }

    /// Accepts text from a paste, a drop or the clipboard watcher.
    func setURLText(_ text: String, analyzeIfEnabled: Bool) {
        let urls = URLDetection.urlsFromLines(text)
        guard !urls.isEmpty else {
            urlText = text
            showStatus("No web address was found in that text.")
            return
        }
        urlText = urls.joined(separator: "\n")
        analysis = .idle
        if analyzeIfEnabled, settings.autoAnalyzePastedURLs, urls.count == 1 {
            analyze()
        }
    }

    func clear() {
        analysisTask?.cancel()
        analysisTask = nil
        urlText = ""
        analysis = .idle
        analyzedURL = nil
        statusMessage = nil
    }

    /// Fetches metadata for the current URL.
    func analyze() {
        guard let url = detectedURLs.first, toolchain.isReady else { return }
        if let block = customArgumentBlockMessage {
            showStatus(block)
            return
        }
        analysisTask?.cancel()
        analysis = .analyzing
        analyzedURL = url

        analysisTask = Task { [weak self] in
            guard let self, let service = self.toolchain.service else { return }
            do {
                let info = try await service.fetchMediaInfo(url: url, options: self.options)
                guard !Task.isCancelled, self.analyzedURL == url else { return }
                self.analysis = .loaded(info)
                self.adoptDefaults(from: info)
            } catch let failure as YTDLPService.AnalysisFailure {
                guard !Task.isCancelled, self.analyzedURL == url else { return }
                self.analysis = .failed(failure.failure)
            } catch {
                guard !Task.isCancelled, self.analyzedURL == url else { return }
                self.analysis = .failed(
                    DownloadFailure(kind: .unknown, underlyingMessage: error.localizedDescription)
                )
            }
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

    /// Queues the current URL (or all of them, when several were pasted).
    @discardableResult
    func startDownload() -> Bool {
        guard canDownload else {
            if let block = customArgumentBlockMessage {
                showStatus(block)
            }
            return false
        }
        let urls = detectedURLs
        options.outputDirectory = options.outputDirectory.standardizedFileURL

        if urls.count == 1, let info = analysis.info, info.originalURL == urls[0] {
            queue.enqueue(url: urls[0], options: options, info: info)
            showStatus("Added “\(info.title)” to the queue.")
        } else {
            let added = queue.enqueue(urls: urls, options: options)
            switch added.count {
            case 0: showStatus("Those downloads are already in the queue.")
            case 1: showStatus("Added 1 download to the queue.")
            default: showStatus("Added \(added.count) downloads to the queue.")
            }
        }

        settings.rememberOptions(options)
        clearURLAfterQueueing()
        return true
    }

    private func clearURLAfterQueueing() {
        urlText = ""
        analysis = .idle
        analyzedURL = nil
    }

    // MARK: - Output folder

    func chooseOutputDirectory() {
        guard let url = FinderIntegration.chooseDirectory(startingAt: options.outputDirectory) else {
            return
        }
        options.outputDirectory = url
        settings.downloadDirectory = url
    }

    func revealOutputDirectory() {
        FinderIntegration.open(options.outputDirectory)
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

    /// Keeps the composer's folder in step with a change made in Settings.
    func syncOutputDirectoryFromSettings() {
        if options.outputDirectory != settings.downloadDirectory {
            options.outputDirectory = settings.downloadDirectory
        }
    }
}
