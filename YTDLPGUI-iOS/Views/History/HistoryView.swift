import QuickLook
import SwiftUI

/// Finished and failed downloads, kept between launches.
struct HistoryView: View {
    @Environment(AppModel.self) private var model

    @State private var searchText = ""
    @State private var filter: Filter = .all
    @State private var previewFiles: [URL] = []
    @State private var photoError: String?
    @State private var confirmsClearing = false

    private var history: HistoryStore { model.history }

    var body: some View {
        NavigationStack(path: path) {
            Group {
                if history.entries.isEmpty {
                    emptyState
                } else if filteredEntries.isEmpty {
                    if searchText.isEmpty {
                        ContentUnavailableView(
                            "No \(filter.title) Downloads",
                            systemImage: filter.symbolName,
                            description: Text("Choose All to see every download.")
                        )
                    } else {
                        ContentUnavailableView.search(text: searchText)
                    }
                } else {
                    list
                }
            }
            .navigationTitle("History")
            .searchable(text: $searchText, prompt: "Titles, links and file names")
            .toolbar { toolbarContent }
            .navigationDestination(for: HistoryEntry.ID.self) { id in
                HistoryDetailView(entryID: id)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let error = history.storageError {
                    WarningRow(message: error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(.bar)
                }
            }
        }
        .quickLookFiles($previewFiles)
        .modifier(PhotoSaveErrorAlert(errorMessage: $photoError))
    }

    /// The navigation path mirrors `focusedHistoryEntryID`, so setting it anywhere in the app
    /// (a notification about a finished download) shows that entry, and going back clears it.
    private var path: Binding<[HistoryEntry.ID]> {
        Binding {
            model.focusedHistoryEntryID.map { [$0] } ?? []
        } set: { newPath in
            model.focusedHistoryEntryID = newPath.last
        }
    }

    // MARK: - List

    private var list: some View {
        List {
            ForEach(filteredEntries) { entry in
                NavigationLink(value: entry.id) {
                    HistoryRowView(entry: entry)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        history.remove(entry)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .contextMenu {
                    HistoryEntryActionItems(
                        entry: entry,
                        onOpen: { previewFiles = $0 },
                        onSaveToPhotos: saveToPhotos,
                        onDelete: { history.remove(entry) }
                    )
                }
            }
        }
        .readableContentWidth(820)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No History", systemImage: "clock.arrow.circlepath")
        } description: {
            Text("Everything you download is listed here, so you can find the file again or download it a second time.")
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
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { filter in
                        Label(filter.title, systemImage: filter.symbolName)
                            .tag(filter)
                    }
                }
            } label: {
                Label("Filter", systemImage: filter == .all
                      ? "line.3.horizontal.decrease.circle"
                      : "line.3.horizontal.decrease.circle.fill")
            }
            .accessibilityValue(filter.title)
            .disabled(history.entries.isEmpty)
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    history.removeMissingFiles()
                } label: {
                    Label("Remove Missing Files", systemImage: "questionmark.folder")
                }
                .disabled(!history.entries.contains(where: \.isFileMissing))

                Button(role: .destructive) {
                    if model.settings.confirmBeforeClearingHistory {
                        confirmsClearing = true
                    } else {
                        history.removeAll()
                    }
                } label: {
                    Label(model.settings.confirmBeforeClearingHistory ? "Clear History…" : "Clear History", systemImage: "trash")
                }
            } label: {
                Label("History Actions", systemImage: "ellipsis.circle")
            }
            .disabled(history.entries.isEmpty)
            .confirmationDialog(
                "Clear all history?",
                isPresented: $confirmsClearing,
                titleVisibility: .visible
            ) {
                Button("Clear History", role: .destructive) {
                    history.removeAll()
                }
            } message: {
                Text("This removes \(history.entries.count.formatted()) entries from the list. The downloaded files stay in the Files app.")
            }
        }
    }

    // MARK: - Actions

    private func saveToPhotos(_ files: [URL]) {
        saveHistoryFilesToPhotos(files, model: model, errorMessage: $photoError)
    }

    // MARK: - Filtering

    private enum Filter: String, CaseIterable, Identifiable {
        case all
        case completed
        case failed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All"
            case .completed: "Completed"
            case .failed: "Failed"
            }
        }

        var symbolName: String {
            switch self {
            case .all: "tray.full"
            case .completed: "checkmark.circle"
            case .failed: "exclamationmark.triangle"
            }
        }
    }

    private var filteredEntries: [HistoryEntry] {
        history.entries.filter { entry in
            let passesFilter = switch filter {
            case .all: true
            case .completed: entry.succeeded
            case .failed: !entry.succeeded
            }
            return passesFilter && entry.matches(searchText: searchText)
        }
    }
}

#Preview {
    HistoryView()
        .environment(AppModel())
}
