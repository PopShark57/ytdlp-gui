import QuickLook
import SwiftUI

/// Everything about one download: progress in full, the file, what went wrong, and the log.
///
/// With room to spare (a full-screen iPad) the details and the log sit side by side, so the log
/// can be watched while the download runs. Otherwise a segmented control switches between them.
struct QueueItemDetailView: View {
    let itemID: DownloadItem.ID

    @Environment(AppModel.self) private var model

    @State private var pane: Pane = .details
    @State private var containerWidth: CGFloat = 0
    @State private var quickLookURL: URL?
    /// Keeps the item on screen while the view animates away after it was removed.
    @State private var retainedItem: DownloadItem?

    private enum Pane: String, CaseIterable, Identifiable {
        case details
        case log

        var id: String { rawValue }

        var title: String {
            switch self {
            case .details: "Details"
            case .log: "Log"
            }
        }
    }

    private var item: DownloadItem? {
        model.queue.item(withID: itemID) ?? retainedItem
    }

    private var isInQueue: Bool {
        model.queue.item(withID: itemID) != nil
    }

    private var showsSideBySide: Bool { containerWidth >= 860 }

    var body: some View {
        Group {
            if let item {
                content(for: item)
                    .navigationTitle(item.displayTitle)
            } else {
                ContentUnavailableView(
                    "Download Removed",
                    systemImage: "tray",
                    description: Text("This download is no longer in the queue.")
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if item != nil, !showsSideBySide {
                ToolbarItem(placement: .principal) {
                    Picker("Show", selection: $pane) {
                        ForEach(Pane.allCases) { pane in
                            Text(pane.title).tag(pane)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            containerWidth = width
        }
        .onAppear {
            retainedItem = model.queue.item(withID: itemID)
        }
        .onChange(of: isInQueue) { _, isInQueue in
            if !isInQueue, model.focusedQueueItemID == itemID {
                model.focusedQueueItemID = nil
            }
        }
        .quickLookPreview($quickLookURL)
    }

    @ViewBuilder
    private func content(for item: DownloadItem) -> some View {
        if showsSideBySide {
            HStack(spacing: 0) {
                QueueItemInfoList(item: item, onOpen: { quickLookURL = $0 })
                    .frame(width: min(440, containerWidth * 0.45))
                Divider()
                QueueItemLog(item: item)
            }
        } else {
            switch pane {
            case .details:
                QueueItemInfoList(item: item, onOpen: { quickLookURL = $0 })
            case .log:
                QueueItemLog(item: item)
            }
        }
    }
}

/// The details half of the detail screen.
private struct QueueItemInfoList: View {
    let item: DownloadItem
    var onOpen: (URL) -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                header
            }

            if item.state == .active {
                progressSection
            }
            if item.state == .completed {
                fileSection
            }
            if let failure = item.failure, item.state == .failed || item.state == .cancelled {
                failureSection(failure)
            }
            if item.existingOutputURL != nil, model.queue.canSaveToPhotos(item) {
                photosSection
            }
            actionsSection
            sourceSection
        }
        .readableContentWidth()
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            ThumbnailView(url: item.thumbnailURL, placeholderSymbol: item.options.kind.symbolName, cornerRadius: 12)
                .frame(maxWidth: 480)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                Text(item.displaySubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            PhaseLabel(phase: item.phase, state: item.state)
                .font(.subheadline.weight(.medium))
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Progress

    private var progressSection: some View {
        Section("Progress") {
            DownloadProgressBar(item: item)
                .padding(.vertical, 4)
                .accessibilityLabel("Progress")
                .accessibilityValue(item.progress.percentLabel ?? item.phase.displayName)

            let progress = item.progress
            if !item.phase.isIndeterminate, let percent = progress.percentLabel {
                statRow("Completed", percent)
            }
            if let size = progress.sizeLabel {
                statRow("Downloaded", size)
            }
            if let speed = progress.speedLabel {
                statRow("Speed", speed)
            }
            if let eta = progress.etaLabel {
                statRow("Time Left", eta)
            }
            if let elapsed = Format.elapsed(progress.elapsedSeconds) {
                statRow("Elapsed", elapsed)
            }
            if let fragments = progress.fragmentLabel {
                statRow("Fragments", fragments)
            }
            if let playlist = item.playlistProgressLabel {
                statRow("Playlist", playlist)
            }
            if let file = progress.displayFilename {
                LabeledContent("Current File") {
                    Text(file)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    private func statRow(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy, value: value)
        }
    }

    // MARK: - File

    private var fileSection: some View {
        Section {
            if let name = item.outputURL?.lastPathComponent {
                LabeledContent("Name") {
                    Text(name)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
            if let size = Format.bytes(item.completedFileSize) {
                LabeledContent("Size", value: size)
            }
            if let finished = item.finishedAt {
                LabeledContent("Finished", value: Format.absoluteDate(finished))
            }
            if let playlist = item.playlistProgressLabel {
                LabeledContent("Playlist", value: playlist)
            }
            if item.outputURL != nil, item.existingOutputURL == nil {
                WarningRow(message: "The file has been moved or deleted.")
            }
        } header: {
            Text("File")
        } footer: {
            Text("Finished downloads are in the Files app, in On My \(DeviceName.current) › YTDLP GUI.")
        }
    }

    // MARK: - Failure

    private func failureSection(_ failure: DownloadFailure) -> some View {
        Section("Problem") {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(failure.title)
                        .font(.headline)
                    if let message = failure.underlyingMessage {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            } icon: {
                Image(systemName: failure.symbolName)
                    .foregroundStyle(item.state.tint)
            }
            if let suggestion = failure.recoverySuggestion {
                Text(suggestion)
                    .font(.subheadline)
            }
        }
    }

    // MARK: - Photos

    @ViewBuilder
    private var photosSection: some View {
        Section {
            switch model.queue.photoSaveState(for: item) {
            case .notSaved:
                Button {
                    model.queue.saveToPhotos(item)
                } label: {
                    Label("Save to Photos", systemImage: "photo.badge.plus")
                }
            case .saving:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Saving to Photos…")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            case .saved:
                Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let message):
                WarningRow(message: message, tint: .red)
                Button {
                    model.queue.saveToPhotos(item)
                } label: {
                    Label("Try Saving Again", systemImage: "arrow.clockwise")
                }
            }
        } header: {
            Text("Photos")
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        Section {
            if let url = item.existingOutputURL {
                Button {
                    onOpen(url)
                } label: {
                    Label("Open", systemImage: "eye")
                }
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            Button {
                TextCopier.copy(item.sourceURL)
                model.composer.showStatus("Link copied.")
            } label: {
                Label("Copy Link", systemImage: "link")
            }
            if item.canRetry {
                Button {
                    model.queue.retry(item)
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }
            if item.canCancel {
                Button(role: .destructive) {
                    model.queue.cancel(item)
                } label: {
                    Label("Cancel Download", systemImage: "xmark.circle")
                }
            }
            if item.state != .active {
                Button(role: .destructive) {
                    model.queue.remove(item)
                } label: {
                    Label("Remove from Queue", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Source

    private var sourceSection: some View {
        Section("Source") {
            LabeledContent("Link") {
                Text(URLDetection.displayString(for: item.sourceURL))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            LabeledContent("Format", value: item.options.formatSummary)
            LabeledContent("Added", value: Format.relativeDate(item.createdAt))
        }
    }
}
