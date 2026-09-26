import SwiftUI

/// Raw yt-dlp output, for when the friendly summary isn't enough.
///
/// The structured UI is the primary way to follow a download, but when something goes wrong the
/// exact output is what actually explains it, so it is always kept and always reachable. While
/// output is still arriving the console follows the newest line, unless the reader has scrolled
/// up to study something, in which case it stays put and offers a way back down.
struct LogConsoleView: View {
    let lines: [String]
    /// Every line produced, including those the capped buffer has already dropped.
    var totalLineCount: Int
    /// Whether more output may still arrive.
    var isLive: Bool = false
    /// Names the log when it's shared, e.g. the download's title.
    var title: String

    @State private var filterText = ""
    @State private var isAtBottom = true
    @State private var position = ScrollPosition(edge: .bottom)

    var body: some View {
        VStack(spacing: 0) {
            filterField
            Divider()
            if visibleLines.isEmpty {
                emptyState
                    .frame(maxHeight: .infinity)
            } else {
                scroller
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer
        }
    }

    // MARK: - Pieces

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Filter lines", text: $filterText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityLabel("Filter log lines")
            if !filterText.isEmpty {
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.fill.tertiary, in: .rect(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var emptyState: some View {
        if filterText.isEmpty {
            ContentUnavailableView(
                "No Output Yet",
                systemImage: "text.alignleft",
                description: Text("Output from yt-dlp appears here as it runs.")
            )
        } else {
            ContentUnavailableView.search(text: filterText)
        }
    }

    private var scroller: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                if isTruncated {
                    Text("Earlier lines were dropped to save memory. Showing the last \(lines.count.formatted()) of \(totalLineCount.formatted()).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 6)
                }
                ForEach(visibleLines) { line in
                    Text(line.text)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(color(for: line.text))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.visibleRect.maxY >= geometry.contentSize.height - 24
        } action: { _, atBottom in
            isAtBottom = atBottom
        }
        .onChange(of: totalLineCount) {
            guard isLive, isAtBottom, filterText.isEmpty else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                position.scrollTo(edge: .bottom)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !isAtBottom {
                Button {
                    withAnimation {
                        position.scrollTo(edge: .bottom)
                    }
                } label: {
                    Label("Scroll to Latest", systemImage: "arrow.down")
                        .labelStyle(.iconOnly)
                        .font(.body.weight(.semibold))
                        .padding(10)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .padding(12)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy, value: isAtBottom)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(countLabel)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)

            Spacer(minLength: 8)

            CopyButton(title: "Copy All", text: allText)

            ShareLink(
                item: allText,
                subject: Text("yt-dlp log"),
                preview: SharePreview("yt-dlp log · \(title)")
            ) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .labelStyle(.iconOnly)
            }
            .disabled(lines.isEmpty)
            .accessibilityLabel("Share log")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Data

    /// A line, identified by its number among every line produced. That number stays with the
    /// line when older ones are dropped from the front of the capped buffer, unlike its position,
    /// so rows keep their identity (and any text selected in them) while output arrives.
    private struct NumberedLine: Identifiable {
        let id: Int
        let text: String
    }

    private var visibleLines: [NumberedLine] {
        let firstNumber = totalLineCount - lines.count
        let numbered = lines.enumerated().map { NumberedLine(id: firstNumber + $0.offset, text: $0.element) }
        let query = filterText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return numbered }
        return numbered.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    private var isTruncated: Bool { totalLineCount > lines.count }

    private var allText: String { lines.joined(separator: "\n") }

    private var countLabel: String {
        if !filterText.isEmpty {
            return "\(visibleLines.count.formatted()) of \(lines.count.formatted()) lines"
        }
        return lines.count == 1 ? "1 line" : "\(lines.count.formatted()) lines"
    }

    /// yt-dlp prefixes problems the same way on every platform, and the embedded engine keeps
    /// that format, so the prefix is a reliable signal.
    private func color(for line: String) -> Color {
        if line.hasPrefix("ERROR") { return .red }
        if line.hasPrefix("WARNING") { return .orange }
        if line.hasPrefix("[debug]") { return .secondary }
        return .primary
    }
}

#Preview {
    NavigationStack {
        LogConsoleView(
            lines: [
                "[youtube] Extracting URL: https://www.youtube.com/watch?v=jNQXAC9IVRw",
                "[youtube] jNQXAC9IVRw: Downloading webpage",
                "WARNING: [youtube] Falling back to generic n function search",
                "[info] jNQXAC9IVRw: Downloading 1 format(s): 18",
                "ERROR: unable to download video data: HTTP Error 403: Forbidden",
            ],
            totalLineCount: 5,
            title: "Me at the zoo"
        )
        .navigationTitle("Log")
        .navigationBarTitleDisplayMode(.inline)
    }
}
