import QuickLook
import SwiftUI

/// Everything downloading, waiting or finished in this session.
struct QueueView: View {
    @Environment(AppModel.self) private var model

    @State private var previewFiles: [URL] = []
    @State private var logItem: DownloadItem?
    @State private var confirmsRemoveAll = false

    private var queue: DownloadQueue { model.queue }

    var body: some View {
        NavigationStack(path: path) {
            Group {
                if queue.items.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Queue")
            .modifier(QueueSubtitle(queue: queue))
            .toolbar { toolbarContent }
            .navigationDestination(for: DownloadItem.ID.self) { id in
                QueueItemDetailView(itemID: id)
            }
        }
        .quickLookFiles($previewFiles)
        .sheet(item: $logItem) { item in
            QueueLogSheet(item: item)
        }
    }

    /// The navigation path mirrors `focusedQueueItemID`, so setting it anywhere in the app shows
    /// that item, and going back clears it.
    private var path: Binding<[DownloadItem.ID]> {
        Binding {
            model.focusedQueueItemID.map { [$0] } ?? []
        } set: { newPath in
            model.focusedQueueItemID = newPath.last
        }
    }

    // MARK: - List

    private var list: some View {
        List {
            if !queue.activeItems.isEmpty {
                Section {
                    rows(queue.activeItems)
                } header: {
                    HStack {
                        Text("Downloading")
                        Spacer()
                        if let progress = queue.aggregateProgress, let percent = Format.percent(progress) {
                            Text(percent)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .animation(.snappy, value: percent)
                                .accessibilityLabel("Overall progress \(percent)")
                        }
                    }
                }
            }
            if !queue.queuedItems.isEmpty {
                Section("Waiting") {
                    rows(queue.queuedItems)
                }
            }
            if !queue.finishedItems.isEmpty {
                Section("Finished") {
                    rows(queue.finishedItems)
                }
            }
        }
        .readableContentWidth(820)
        .animation(.default, value: queue.items.map(\.state))
    }

    private func rows(_ items: [DownloadItem]) -> some View {
        ForEach(items) { item in
            NavigationLink(value: item.id) {
                QueueRowView(item: item)
            }
            .modifier(QueueItemSwipeActions(item: item))
            .contextMenu {
                QueueItemMenuItems(
                    item: item,
                    onOpen: { previewFiles = $0 },
                    onShowLog: { logItem = item }
                )
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Downloads", systemImage: "tray")
        } description: {
            Text("Paste a link on the Download tab.")
        } actions: {
            Button("Go to Download") {
                model.selectedTab = .download
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    model.retryAllFailed()
                } label: {
                    Label("Retry Failed", systemImage: "arrow.clockwise")
                }
                .disabled(!queue.hasRetryableItems)

                Button {
                    queue.cancelAll()
                } label: {
                    Label("Cancel All", systemImage: "xmark.circle")
                }
                .disabled(!queue.isBusy)

                Button {
                    queue.clearFinished()
                } label: {
                    Label("Clear Finished", systemImage: "checkmark.circle")
                }
                .disabled(!queue.hasFinishedItems)

                Divider()

                Button(role: .destructive) {
                    confirmsRemoveAll = true
                } label: {
                    Label("Remove All…", systemImage: "trash")
                }
                .disabled(queue.items.isEmpty)
            } label: {
                Label("Queue Actions", systemImage: "ellipsis.circle")
            }
            .confirmationDialog(
                "Remove every download from the queue?",
                isPresented: $confirmsRemoveAll,
                titleVisibility: .visible
            ) {
                Button("Remove All", role: .destructive) {
                    queue.removeAll()
                }
            } message: {
                Text("Running and waiting downloads are cancelled. Finished files stay in the Files app.")
            }
        }
    }
}

/// "2 downloading · 3 waiting" under the title, where the system supports navigation subtitles.
private struct QueueSubtitle: ViewModifier {
    let queue: DownloadQueue

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.navigationSubtitle(subtitle)
        } else {
            content
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if queue.activeCount > 0 { parts.append("\(queue.activeCount) downloading") }
        if queue.queuedCount > 0 { parts.append("\(queue.queuedCount) waiting") }
        return parts.joined(separator: " · ")
    }
}

#Preview {
    QueueView()
        .environment(AppModel())
}
