import QuickLook
import SwiftUI

/// The download queue.
struct QueueView: View {
    @Environment(AppModel.self) private var model

    @State private var selection = Set<DownloadItem.ID>()
    @State private var showInspector = false
    @State private var previewURL: URL?
    @State private var previewURLs: [URL] = []

    private var queue: DownloadQueue { model.queue }

    var body: some View {
        Group {
            if queue.items.isEmpty && queue.interrupted.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Queue")
        .safeAreaInset(edge: .top, spacing: 0) {
            if let notice = queue.notice {
                AdvisoryBanner(kind: .info, title: notice, actionTitle: "Dismiss") {
                    queue.notice = nil
                }
                .padding(12)
                .background(.bar)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: queue.notice)
        .toolbar { toolbarContent }
        .inspector(isPresented: $showInspector) {
            inspectorContent
                .inspectorColumnWidth(min: 320, ideal: 420, max: 700)
        }
        .quickLookPreview($previewURL, in: previewURLs)
        .onChange(of: model.focusedLogItemID, initial: true) { _, newValue in
            guard let newValue else { return }
            selection = [newValue]
            showInspector = true
            model.focusedLogItemID = nil
        }
        .onChange(of: selection) { _, newValue in
            if newValue.isEmpty { showInspector = false }
        }
    }

    // MARK: - List

    private var list: some View {
        List(selection: $selection) {
            if !queue.interrupted.isEmpty {
                interruptedSection
            }
            ForEach(queue.items) { item in
                QueueRowView(item: item)
                    .tag(item.id)
            }
            .onMove { source, destination in
                queue.move(fromOffsets: source, toOffset: destination)
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
        .contextMenu(forSelectionType: DownloadItem.ID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            performPrimaryAction(on: ids)
        }
        .onDeleteCommand {
            removeSelection()
        }
        .onKeyPress(.space) {
            guard previewSelection() else { return .ignored }
            return .handled
        }
    }

    private var interruptedSection: some View {
        Section {
            ForEach(queue.interrupted) { saved in
                HStack(spacing: 10) {
                    Image(systemName: "arrow.uturn.forward.circle")
                        .foregroundStyle(.orange)
                        .imageScale(.large)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(saved.title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(saved.options.formatSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Resume") { model.resume(saved) }
                    Button("Discard") { queue.forgetInterrupted(saved.id) }
                }
                .padding(.vertical, 4)
                .selectionDisabled()
            }
        } header: {
            HStack {
                Text("Unfinished from last session")
                Spacer()
                if queue.interrupted.count > 1 {
                    Button("Resume All") { model.resumeAllInterrupted() }
                        .buttonStyle(.link)
                        .controlSize(.small)
                    Button("Discard All") { queue.forgetAllInterrupted() }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing in the queue", systemImage: "tray")
        } description: {
            Text("Downloads you start appear here with live progress, speed and estimated time.")
        } actions: {
            Button("Go to New Download") {
                model.selectedSection = .download
            }
        }
    }

    // MARK: - Selection actions

    private func items(for ids: Set<DownloadItem.ID>) -> [DownloadItem] {
        queue.items.filter { ids.contains($0.id) }
    }

    /// Double-click or Return: open what was downloaded, or show the log of anything else.
    private func performPrimaryAction(on ids: Set<DownloadItem.ID>) {
        let chosen = items(for: ids)
        let files = chosen.compactMap(\.existingOutputURLs.last)
        if !files.isEmpty {
            files.forEach(FinderIntegration.open)
        } else if let item = chosen.first {
            selection = [item.id]
            showInspector = true
        }
    }

    /// Delete removes waiting and finished items. A running download is only ever stopped by an
    /// explicit Cancel or Remove, never by a stray key press.
    private func removeSelection() {
        let removable = items(for: selection).filter { $0.state != .active }
        guard !removable.isEmpty else { return }
        queue.remove(ids: Set(removable.map(\.id)))
        selection.subtract(removable.map(\.id))
    }

    @discardableResult
    private func previewSelection() -> Bool {
        let files = items(for: selection).flatMap(\.existingOutputURLs)
        guard let first = files.first else { return false }
        previewURLs = files
        previewURL = first
        return true
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspectorContent: some View {
        if selection.count == 1, let id = selection.first, let item = queue.item(withID: id) {
            LogConsoleView(item: item)
        } else if selection.count > 1 {
            ContentUnavailableView(
                "\(selection.count) downloads selected",
                systemImage: "sidebar.right",
                description: Text("Select a single download to see its raw output.")
            )
        } else {
            ContentUnavailableView(
                "No download selected",
                systemImage: "sidebar.right",
                description: Text("Select a download to see its raw yt-dlp output.")
            )
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                queue.retryAllFailed()
            } label: {
                Label("Retry Failed", systemImage: "arrow.clockwise")
            }
            .disabled(!queue.hasRetryableItems)
            .help("Retry every failed download")

            Button {
                queue.cancelAll()
            } label: {
                Label("Cancel All", systemImage: "stop.circle")
            }
            .disabled(!queue.isBusy)
            .help("Stop all running and queued downloads (⌘.)")

            Button {
                queue.clearFinished()
            } label: {
                Label("Clear Finished", systemImage: "trash")
            }
            .disabled(!queue.hasFinishedItems)
            .help("Remove completed, failed and cancelled items from the list")

            Button {
                showInspector.toggle()
            } label: {
                Label("Log", systemImage: "sidebar.trailing")
            }
            .help("Show the raw output log")
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(for ids: Set<DownloadItem.ID>) -> some View {
        let chosen = items(for: ids)
        if chosen.isEmpty {
            Button("Clear Finished Items") { queue.clearFinished() }
                .disabled(!queue.hasFinishedItems)
        } else {
            let files = chosen.flatMap(\.existingOutputURLs)
            if !files.isEmpty {
                Button("Open") { chosen.compactMap(\.existingOutputURLs.last).forEach(FinderIntegration.open) }
                Button("Reveal in Finder") { FinderIntegration.reveal(files) }
                Button("Quick Look") {
                    previewURLs = files
                    previewURL = files.first
                }
                Divider()
            }

            if chosen.count == 1, let item = chosen.first {
                Button("Show Log") {
                    selection = [item.id]
                    showInspector = true
                }
                Button("Copy Source URL") { Pasteboard.copy(item.sourceURL) }
                if item.state.isFinished {
                    Button("Copy Log") { Pasteboard.copy(item.log.joined) }
                }
            } else {
                Button("Copy \(chosen.count) Source URLs") {
                    Pasteboard.copy(chosen.map(\.sourceURL).joined(separator: "\n"))
                }
            }

            if chosen.contains(where: { $0.state == .queued }) {
                Divider()
                Button("Start Next") { queue.startNext(ids) }
                Button("Move to End of Queue") { queue.startLast(ids) }
            }

            Divider()

            let retryable = chosen.filter(\.canRetry)
            if !retryable.isEmpty {
                Button(retryable.count == 1 ? "Retry" : "Retry \(retryable.count) Downloads") {
                    retryable.forEach(queue.retry)
                }
            }
            let cancellable = chosen.filter(\.canCancel)
            if !cancellable.isEmpty {
                Button(cancellable.count == 1 ? "Cancel" : "Cancel \(cancellable.count) Downloads", role: .destructive) {
                    cancellable.forEach(queue.cancel)
                }
            }
            Button(chosen.count == 1 ? "Remove from Queue" : "Remove \(chosen.count) from Queue", role: .destructive) {
                queue.remove(ids: ids)
                selection.subtract(ids)
            }
        }
    }
}
