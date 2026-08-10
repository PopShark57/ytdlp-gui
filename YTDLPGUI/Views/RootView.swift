import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model

        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail
                .frame(minWidth: 560, minHeight: 480)
        }
        .navigationTitle(model.selectedSection.title)
        .toolbar { toolbarContent }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        @Bindable var model = model

        return VStack(spacing: 0) {
            List(selection: $model.selectedSection) {
                ForEach(AppSection.allCases) { section in
                    Label(section.title, systemImage: section.symbolName)
                        .badge(badge(for: section))
                        .tag(section)
                }
            }
            .listStyle(.sidebar)

            Divider()

            DependencyStatusFooter()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
    }

    private func badge(for section: AppSection) -> Int {
        switch section {
        case .download: 0
        case .queue: model.queue.activeCount + model.queue.queuedCount
        case .history: 0
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch model.selectedSection {
        case .download:
            if model.toolchain.hasCompletedFirstCheck, !model.toolchain.isReady {
                SetupView()
            } else {
                DownloadView()
            }
        case .queue:
            QueueView()
        case .history:
            HistoryView()
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if let progress = model.queue.aggregateProgress {
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 120)
                    Text(Format.percent(progress) ?? "")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .help("Overall progress of active downloads")
                .transition(.opacity)
            }
        }

        ToolbarItem {
            Button {
                openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Open Settings (⌘,)")
        }
    }
}

/// Compact yt-dlp / ffmpeg availability shown at the bottom of the sidebar.
struct DependencyStatusFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ExternalTool.allCases) { tool in
                row(for: model.toolchain.status(for: tool))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { openSettings() }
        .help("Open Settings to change where these tools are found")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Installed tools")
    }

    private func row(for status: ToolStatus) -> some View {
        HStack(spacing: 6) {
            Image(systemName: status.isInstalled ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(status.isInstalled ? Color.green : (status.tool.isRequired ? Color.red : Color.orange))
                .imageScale(.small)
                .accessibilityHidden(true)

            Text(status.tool.displayName)
                .font(.caption)

            Spacer(minLength: 4)

            if model.toolchain.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Text(status.version ?? (status.isInstalled ? "installed" : "missing"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(status.tool.displayName) \(status.statusLabel)")
    }
}
