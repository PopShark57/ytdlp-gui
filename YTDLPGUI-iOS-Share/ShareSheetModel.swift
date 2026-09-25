import Foundation
import Observation

/// Drives the share sheet: finds the links, hands them to the app, and says how that went.
@MainActor
@Observable
final class ShareSheetModel {

    enum Phase: Equatable {
        /// Still reading what was shared.
        case loading
        /// Links found; waiting for the user to say what to do with them.
        case choosing
        /// Nothing that was shared contains a web link.
        case noLinks
        /// The links are in the app's inbox. The sheet closes by itself shortly.
        case handedOver
        /// The App Group container is missing, so the links can only be copied by hand.
        case storageUnavailable
        /// Writing to the inbox failed, for a reason the system described.
        case failed(reason: String)
    }

    enum Outcome: Equatable {
        /// The links were handed over.
        case completed
        /// The user backed out, or there was nothing to hand over.
        case cancelled
    }

    /// Everything the model needs from outside the extension's own state, replaceable so that
    /// previews and tests touch neither the App Group nor the pasteboard.
    struct Services {
        var isInboxAvailable: @MainActor () -> Bool
        var writeEntry: @MainActor ([String], ShareDownloadKind?) throws(InboxWriter.Failure) -> Void
        var copyText: @MainActor (String) -> Void
        /// How long the confirmation stays up before the sheet closes on its own.
        var confirmationDuration: @MainActor () -> Duration
    }

    private(set) var phase: Phase = .loading
    private(set) var links: [String] = []
    /// Set once "Copy Link" has put the links on the pasteboard, so the button can say so.
    private(set) var didCopyLinks = false

    /// Called exactly once, when the sheet should go away.
    @ObservationIgnored var onFinish: (@MainActor (Outcome) -> Void)?

    @ObservationIgnored private let services: Services
    @ObservationIgnored private var hasFinished = false
    @ObservationIgnored private var autoCloseTask: Task<Void, Never>?

    init(services: Services) {
        self.services = services
    }

    // MARK: - Loading

    func load(from items: [NSExtensionItem]) async {
        show(await LinkExtractor.webLinks(in: items))
    }

    /// Shows `links`, or explains why they can't be used.
    func show(_ links: [String]) {
        self.links = links
        if links.isEmpty {
            phase = .noLinks
        } else if !services.isInboxAvailable() {
            // Found now rather than after the user picks an action they then can't have.
            phase = .storageUnavailable
        } else {
            phase = .choosing
        }
    }

    // MARK: - Actions

    /// Leaves the links for the app, to download as `kind` or, when `nil`, to fill in the URL field.
    func handOver(as kind: ShareDownloadKind?) {
        guard phase == .choosing else { return }
        do {
            try services.writeEntry(links, kind)
            phase = .handedOver
            scheduleAutoClose()
        } catch {
            switch error {
            case .containerUnavailable:
                phase = .storageUnavailable
            case .writeFailed(let reason):
                phase = .failed(reason: reason)
            }
        }
    }

    /// Puts the links on the pasteboard, one per line, which the app's URL field accepts as is.
    func copyLinks() {
        guard !links.isEmpty else { return }
        services.copyText(links.joined(separator: "\n"))
        didCopyLinks = true
    }

    func done() {
        finish(.completed)
    }

    func cancel() {
        finish(.cancelled)
    }

    // MARK: - Private

    private func scheduleAutoClose() {
        let duration = services.confirmationDuration()
        autoCloseTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.finish(.completed)
        }
    }

    private func finish(_ outcome: Outcome) {
        guard !hasFinished else { return }
        hasFinished = true
        autoCloseTask?.cancel()
        autoCloseTask = nil
        onFinish?(outcome)
    }
}
