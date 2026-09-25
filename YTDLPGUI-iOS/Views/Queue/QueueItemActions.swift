import SwiftUI

/// Everything that can be done to a queue item, as menu content for its context menu.
///
/// The detail screen offers the same actions as rows, built from the same conditions, so the
/// two never disagree about what's possible.
struct QueueItemMenuItems: View {
    let item: DownloadItem
    var onOpen: (URL) -> Void
    var onShowLog: (() -> Void)?

    @Environment(AppModel.self) private var model

    var body: some View {
        if let url = item.existingOutputURL {
            Button {
                onOpen(url)
            } label: {
                Label("Open", systemImage: "eye")
            }
            ShareLink(item: url) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            if model.queue.canSaveToPhotos(item) {
                photosButton
            }
            Divider()
        }

        if let onShowLog {
            Button(action: onShowLog) {
                Label("Show Log", systemImage: "text.alignleft")
            }
        }
        Button {
            TextCopier.copy(item.sourceURL)
        } label: {
            Label("Copy Link", systemImage: "link")
        }

        Divider()

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

    @ViewBuilder
    private var photosButton: some View {
        switch model.queue.photoSaveState(for: item) {
        case .notSaved:
            Button {
                model.queue.saveToPhotos(item)
            } label: {
                Label("Save to Photos", systemImage: "photo.badge.plus")
            }
        case .saving:
            Button {} label: {
                Label("Saving to Photos…", systemImage: "photo")
            }
            .disabled(true)
        case .saved:
            Button {} label: {
                Label("Saved to Photos", systemImage: "checkmark.circle")
            }
            .disabled(true)
        case .failed(let message):
            Button {
                model.queue.saveToPhotos(item)
            } label: {
                Text("Save to Photos")
                Text(message)
                Image(systemName: "exclamationmark.triangle")
            }
        }
    }
}

/// Swipe actions for a queue row: retry from the leading edge, cancel or remove from the
/// trailing edge.
struct QueueItemSwipeActions: ViewModifier {
    let item: DownloadItem
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .trailing) {
                if item.state != .active {
                    Button(role: .destructive) {
                        model.queue.remove(item)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
                if item.canCancel {
                    Button {
                        model.queue.cancel(item)
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .tint(.orange)
                }
            }
            .swipeActions(edge: .leading) {
                if item.canRetry {
                    Button {
                        model.queue.retry(item)
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .tint(.accentColor)
                }
            }
    }
}

/// A queue item's log in a sheet, for "Show Log" from a context menu.
struct QueueLogSheet: View {
    let item: DownloadItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            QueueItemLog(item: item)
                .navigationTitle("Log")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

/// The log console, fed from a queue item and following it while it runs.
struct QueueItemLog: View {
    let item: DownloadItem

    var body: some View {
        LogConsoleView(
            lines: item.log.lines,
            totalLineCount: item.log.totalLineCount,
            isLive: !item.state.isFinished,
            title: item.displayTitle
        )
    }
}
