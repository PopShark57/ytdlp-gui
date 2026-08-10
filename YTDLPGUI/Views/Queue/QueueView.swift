import SwiftUI

/// The download queue.
struct QueueView: View {
    @Environment(AppModel.self) private var model

    @State private var selection: DownloadItem.ID?
    @State private var showInspector = false

    private var queue: DownloadQueue { model.queue }

    var body: some View {
        Group {
            if queue.items.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Queue")
        .toolbar { toolbarContent }
        .inspector(isPresented: $showInspector) {
            inspectorContent
                .inspectorColumnWidth(min: 320, ideal: 420, max: 700)
        }
        .onChange(of: model.focusedLogItemID) { _, newValue in
            guard let newValue else { return }
            selection = newValue
            showInspector = true
            model.focusedLogItemID = nil
        }
        .onChange(of: selection) { _, newValue in
            if newValue == nil { showInspector = false }
        }
    }

    // MARK: - List

    private var list: some View {
        List(selection: $selection) {
            ForEach(queue.items) { item in
                QueueRowView(item: item)
                    .tag(item.id)
                    .contextMenu { contextMenu(for: item) }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
        .contextMenu {
            Button("Clear Finished Items") { queue.clearFinished() }
                .disabled(!queue.hasFinishedItems)
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

    // MARK: - Inspector

    @ViewBuilder
    private var inspectorContent: some View {
        if let selection, let item = queue.items.first(where: { $0.id == selection }) {
            LogConsoleView(item: item)
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
    private func contextMenu(for item: DownloadItem) -> some View {
        if item.canRevealInFinder, let url = item.outputURL {
            Button("Reveal in Finder") { FinderIntegration.reveal(url) }
            Button("Open") { FinderIntegration.open(url) }
            Divider()
        }

        Button("Show Log") {
            selection = item.id
            showInspector = true
        }

        Button("Copy Source URL") { Pasteboard.copy(item.sourceURL) }

        if item.state.isFinished {
            Button("Copy Log") { Pasteboard.copy(item.log.joined) }
        }

        Divider()

        if item.canCancel {
            Button("Cancel", role: .destructive) { queue.cancel(item) }
        }
        if item.canRetry {
            Button("Retry") { queue.retry(item) }
        }
        Button("Remove from Queue", role: .destructive) { queue.remove(item) }
            .disabled(item.state == .active)
    }
}
