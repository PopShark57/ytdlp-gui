import QuickLook
import SwiftUI

/// Completed and failed downloads, persisted between launches.
struct HistoryView: View {
    @Environment(AppModel.self) private var model

    @State private var searchText = ""
    @State private var selection = Set<HistoryEntry.ID>()
    @State private var filter: Filter = .all
    @State private var showClearConfirmation = false
    @State private var previewURL: URL?
    @State private var previewURLs: [URL] = []

    private enum Filter: String, CaseIterable, Identifiable {
        case all, completed, failed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All"
            case .completed: "Completed"
            case .failed: "Failed"
            }
        }
    }

    private var history: HistoryStore { model.history }

    var body: some View {
        Group {
            if history.entries.isEmpty {
                emptyState
            } else if filteredEntries.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                list
            }
        }
        .navigationTitle("History")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search titles, URLs and paths")
        .toolbar { toolbarContent }
        .confirmationDialog(
            "Clear all history?",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                history.removeAll()
                selection.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \(history.entries.count) entries from the list. The downloaded files themselves are not deleted.")
        }
        .quickLookPreview($previewURL, in: previewURLs)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let error = history.storageError {
                AdvisoryBanner(kind: .warning, title: error)
                    .padding(12)
                    .background(.bar)
            }
        }
    }

    // MARK: - List

    private var list: some View {
        List(selection: $selection) {
            ForEach(filteredEntries) { entry in
                let files = history.existingFiles(of: entry)
                HistoryRowView(entry: entry, status: history.fileStatus[entry.id])
                    .tag(entry.id)
                    .modifier(FileDragSource(url: files.last))
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
        .contextMenu(forSelectionType: HistoryEntry.ID.self) { ids in
            contextMenu(for: entries(for: ids))
        } primaryAction: { ids in
            // Double-click or Return: open what was downloaded, or retry what failed.
            for entry in entries(for: ids) {
                if let file = history.existingFiles(of: entry).last {
                    FinderIntegration.open(file)
                } else if !entry.succeeded {
                    downloadAgain(entry)
                }
            }
        }
        .onDeleteCommand {
            guard !selection.isEmpty else { return }
            history.remove(ids: selection)
            selection.removeAll()
        }
        .onKeyPress(.space) {
            let files = entries(for: selection).flatMap { history.existingFiles(of: $0) }
            guard let first = files.first else { return .ignored }
            previewURLs = files
            previewURL = first
            return .handled
        }
    }

    private func entries(for ids: Set<HistoryEntry.ID>) -> [HistoryEntry] {
        filteredEntries.filter { ids.contains($0.id) }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No downloads yet", systemImage: "clock.arrow.circlepath")
        } description: {
            Text("Everything you download is recorded here, so you can find the file again or download it a second time.")
        } actions: {
            Button("Go to New Download") {
                model.selectedSection = .download
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Picker("Filter", selection: $filter) {
                ForEach(Filter.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Show all downloads, or only those that succeeded or failed")
        }

        ToolbarItemGroup {
            Button {
                history.removeMissingFiles()
            } label: {
                Label("Remove Missing", systemImage: "questionmark.folder")
            }
            .help("Remove entries whose file is no longer on disk")
            .disabled(!history.hasMissingFiles)

            Button {
                if model.settings.confirmBeforeClearingHistory {
                    showClearConfirmation = true
                } else {
                    history.removeAll()
                }
            } label: {
                Label("Clear History", systemImage: "trash")
            }
            .disabled(history.entries.isEmpty)
            .help("Remove every entry. Downloaded files are not deleted.")
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(for chosen: [HistoryEntry]) -> some View {
        if let entry = chosen.first, chosen.count == 1 {
            singleEntryMenu(for: entry)
        } else if !chosen.isEmpty {
            let files = chosen.flatMap { history.existingFiles(of: $0) }
            if !files.isEmpty {
                Button("Reveal \(files.count) Files in Finder") { FinderIntegration.reveal(files) }
                Button("Quick Look") {
                    previewURLs = files
                    previewURL = files.first
                }
                Divider()
            }
            Button("Copy \(chosen.count) Source URLs") {
                Pasteboard.copy(chosen.map(\.sourceURL).joined(separator: "\n"))
            }
            Button("Download \(chosen.count) Again") {
                chosen.forEach(downloadAgain)
            }
            Divider()
            Button("Remove \(chosen.count) from History", role: .destructive) {
                history.remove(ids: Set(chosen.map(\.id)))
                selection.subtract(chosen.map(\.id))
            }
        }
    }

    @ViewBuilder
    private func singleEntryMenu(for entry: HistoryEntry) -> some View {
        let files = history.existingFiles(of: entry)
        if let url = files.last {
            Button("Open") { FinderIntegration.open(url) }
            Button("Reveal in Finder") { FinderIntegration.reveal(files) }
            Button("Quick Look") {
                previewURLs = files
                previewURL = files.first
            }
            ShareLink(items: files) {
                Text("Share…")
            }
            Divider()
        }

        Button("Copy Source URL") { Pasteboard.copy(entry.sourceURL) }

        if let path = entry.outputPath {
            Button("Copy File Path") { Pasteboard.copy(path) }
        }

        Divider()

        Button("Download Again") { downloadAgain(entry) }

        Button("Load Settings into New Download") {
            loadIntoComposer(entry)
        }

        Divider()

        Button("Remove from History", role: .destructive) {
            history.remove(entry)
            selection.remove(entry.id)
        }
    }

    // MARK: - Actions

    /// Re-queues the entry using the exact options it was originally downloaded with,
    /// after stripping any denied custom arguments so history cannot replay `--exec`.
    private func downloadAgain(_ entry: HistoryEntry) {
        if let removed = entry.removedSecretOptions, !removed.isEmpty {
            loadIntoComposer(entry)
            return
        }
        var options = entry.options ?? model.composer.options
        let inspection = CustomArgumentPolicy.inspect(options.customArguments)
        if inspection.isBlocked {
            options.customArguments = CustomArgumentPolicy.sanitizedArgumentString(options.customArguments)
        }
        // The original folder may be gone; fall back to the current default.
        if !FileManager.default.fileExists(atPath: options.outputDirectory.path(percentEncoded: false)) {
            options.outputDirectory = model.settings.downloadDirectory
        }
        model.queue.enqueue(url: entry.sourceURL, options: options)
        model.selectedSection = .queue
        if inspection.isBlocked {
            let listed = inspection.blockedFlags.map { "‘\($0)’" }.joined(separator: ", ")
            model.composer.showStatus(
                "Removed dangerous custom option\(inspection.blockedFlags.count == 1 ? "" : "s") before re-download: \(listed)."
            )
        }
    }

    private func loadIntoComposer(_ entry: HistoryEntry) {
        if var options = entry.options {
            let inspection = CustomArgumentPolicy.inspect(options.customArguments)
            if inspection.isBlocked {
                options.customArguments = CustomArgumentPolicy.sanitizedArgumentString(options.customArguments)
            }
            model.composer.options = options
            model.composer.options.outputDirectory = model.settings.downloadDirectory
            if inspection.isBlocked {
                let listed = inspection.blockedFlags.map { "‘\($0)’" }.joined(separator: ", ")
                model.composer.showStatus(
                    "Stripped dangerous custom option\(inspection.blockedFlags.count == 1 ? "" : "s") from history: \(listed)."
                )
            }
        }
        if let removed = entry.removedSecretOptions, !removed.isEmpty {
            model.composer.showStatus("Re-enter \(removed.joined(separator: ", ")) before downloading again.")
        }
        model.composer.setURLText(entry.sourceURL, analyzeIfEnabled: false)
        model.selectedSection = .download
    }

    // MARK: - Data

    private var filteredEntries: [HistoryEntry] {
        history.entries.filter { entry in
            switch filter {
            case .all: true
            case .completed: entry.succeeded
            case .failed: !entry.succeeded
            }
        }
        .filter { $0.matches(searchText: searchText) }
    }
}

/// Lets a row's downloaded file be dragged out to Finder, Mail or any other app.
struct FileDragSource: ViewModifier {
    let url: URL?

    func body(content: Content) -> some View {
        if let url {
            content.draggable(url) {
                Label(url.lastPathComponent, systemImage: "doc")
                    .padding(6)
            }
        } else {
            content
        }
    }
}
