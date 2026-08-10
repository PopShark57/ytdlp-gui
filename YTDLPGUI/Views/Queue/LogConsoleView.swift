import SwiftUI

/// Raw yt-dlp output for one queue item.
///
/// The structured UI is the primary way to follow a download, but when something goes wrong
/// the exact output is what actually explains it, so it is always kept and always reachable.
struct LogConsoleView: View {
    let item: DownloadItem

    @State private var filterText = ""
    @State private var autoScroll = true
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if visibleLines.isEmpty {
                ContentUnavailableView(
                    filterText.isEmpty ? "No output yet" : "No matching lines",
                    systemImage: "text.alignleft",
                    description: Text(
                        filterText.isEmpty
                            ? "Output from yt-dlp appears here as the download runs."
                            : "No log lines contain “\(filterText)”."
                    )
                )
                .frame(maxHeight: .infinity)
            } else {
                logScroller
            }

            Divider()

            footer
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: item.phase.symbolName)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.phase.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            TextField("Filter", text: $filterText, prompt: Text("Filter lines"))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
        }
        .padding(12)
        .background(.bar)
    }

    private var logScroller: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(visibleLines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(color(for: line))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                    // Anchor for auto-scrolling to the newest line.
                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                }
                .padding(10)
            }
            .onChange(of: visibleLines.count) { _, _ in
                guard autoScroll else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
            .onAppear {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle("Follow", isOn: $autoScroll)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help("Keep scrolling to the newest line")

            if item.log.isTruncated {
                Text("showing last \(item.log.lines.count) of \(item.log.totalLineCount)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("\(item.log.lines.count) lines")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                Pasteboard.copy(item.log.joined)
                withAnimation { didCopy = true }
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation { didCopy = false }
                }
            } label: {
                Label(didCopy ? "Copied" : "Copy All", systemImage: didCopy ? "checkmark" : "doc.on.doc")
            }
            .controlSize(.small)
            .disabled(item.log.lines.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Data

    private let bottomAnchor = "log-bottom"

    /// Progress-template lines are noise in a human-readable log: they arrive many times a
    /// second and their content is already shown as a progress bar.
    private var visibleLines: [String] {
        let lines = item.log.lines.filter { !$0.hasPrefix(ArgumentBuilder.progressMarker) }
        let query = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return lines }
        return lines.filter { $0.lowercased().contains(query) }
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("ERROR") { return .red }
        if line.hasPrefix("WARNING") { return .orange }
        if line.hasPrefix("$ ") { return .accentColor }
        if line.hasPrefix(ArgumentBuilder.postProcessMarker) { return .secondary }
        return .primary
    }
}
