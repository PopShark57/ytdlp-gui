import SwiftUI
import UIKit

/// The primary screen: paste a link, choose video or audio, download.
struct DownloadView: View {
    @Environment(AppModel.self) private var model

    @FocusState private var isLinkFieldFocused: Bool
    @State private var isDropTargeted = false
    @State private var queuedCount = 0

    private var composer: DownloadComposer { model.composer }

    var body: some View {
        NavigationStack {
            Form {
                LinkSection(isFieldFocused: $isLinkFieldFocused)
                AnalysisSection()
                ModeSection()
                AdvisoriesSection()
                advancedOptionsSection
                if model.settings.showCommandPreview {
                    CommandPreviewSection()
                }
            }
            .readableContentWidth()
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Download")
            .animation(.default, value: composer.analysis)
            .bottomBar { downloadBar }
            .background { keyboardCommands }
            .dropDestination(for: DroppedLink.self) { links, _ in
                let text = links.map(\.text).joined(separator: "\n")
                guard !text.isEmpty else { return false }
                model.acceptPastedText(text)
                return true
            } isTargeted: { isTargeted in
                isDropTargeted = isTargeted
            }
            .overlay { dropHighlight }
            .sensoryFeedback(.success, trigger: queuedCount)
        }
    }

    // MARK: - Sections

    private var advancedOptionsSection: some View {
        Section {
            NavigationLink {
                AdvancedOptionsView()
            } label: {
                Label("Advanced Options", systemImage: "gearshape.2")
            }
            .badge(composer.customizedAdvancedOptionCount)
            .accessibilityValue(advancedOptionsAccessibilityValue)
        } footer: {
            Text("File names, subtitles, metadata, SponsorBlock, playlists, network and sign-in.")
        }
    }

    private var advancedOptionsAccessibilityValue: String {
        switch composer.customizedAdvancedOptionCount {
        case 0: ""
        case 1: "1 option changed"
        case let count: "\(count) options changed"
        }
    }

    // MARK: - Download bar

    private var downloadBar: some View {
        Button(action: startDownload) {
            Label(composer.downloadButtonTitle, systemImage: "arrow.down.circle.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!canDownload)
        .accessibilityHint("Adds the download to the queue and starts it")
        // The label matches the Download tab's, so UI tests find this button by identifier.
        .accessibilityIdentifier("startDownloadButton")
        .frame(maxWidth: 680)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var canDownload: Bool {
        composer.canDownload && model.engine.isReady
    }

    private func startDownload() {
        guard canDownload else { return }
        isLinkFieldFocused = false
        let countBefore = model.queue.items.count
        model.startDownload()
        if model.queue.items.count > countBefore {
            queuedCount += 1
        }
    }

    // MARK: - Keyboard

    /// Hardware-keyboard commands for iPad.
    ///
    /// They live outside the form because a form only keeps the rows on screen alive, and a
    /// shortcut belongs to its button: scrolled out of view, a row's shortcut would stop working.
    private var keyboardCommands: some View {
        VStack {
            Button("Paste Link", action: pasteFromKeyboard)
                .keyboardShortcut("v", modifiers: .command)
                // With the field focused, ⌘V belongs to the field's own paste.
                .disabled(isLinkFieldFocused)
            Button("Analyze") { composer.analyze() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(!composer.canAnalyze || !model.engine.isReady || composer.analysis.isAnalyzing)
            Button("Clear Link") { composer.clear() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(composer.urlText.isEmpty)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    /// Reads the clipboard only because the user pressed ⌘V, an explicit request to paste.
    /// A `PasteButton` can't take a keyboard shortcut, so iOS may confirm this read with its
    /// paste prompt; the on-screen Paste buttons never trigger one.
    private func pasteFromKeyboard() {
        let pasteboard = UIPasteboard.general
        guard let text = pasteboard.string ?? pasteboard.url?.absoluteString, !text.isEmpty else { return }
        model.acceptPastedText(text)
    }

    // MARK: - Drop

    @ViewBuilder
    private var dropHighlight: some View {
        if isDropTargeted {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                .padding(8)
                .allowsHitTesting(false)
                .transition(.opacity)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Advisories

/// Things worth knowing before downloading, e.g. that a quality isn't reachable on this device.
private struct AdvisoriesSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let advisories = model.composer.advisories
        if !advisories.isEmpty {
            Section {
                ForEach(advisories, id: \.self) { advisory in
                    WarningRow(message: advisory)
                }
            }
        }
    }
}

// MARK: - Command preview

/// The exact yt-dlp arguments, for people who know the command-line tool.
private struct CommandPreviewSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let command = model.composer.commandPreview
        Section {
            Text(command)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Command")
                .accessibilityValue(command)
            CopyButton(title: "Copy Command", text: command)
        } header: {
            Text("Command Preview")
        } footer: {
            Text("yt-dlp runs inside the app rather than in a shell, so the quoting is only for readability. The app also connects its own progress reporting and processing, which isn't shown.")
        }
    }
}

#Preview {
    DownloadView()
        .environment(AppModel())
}
