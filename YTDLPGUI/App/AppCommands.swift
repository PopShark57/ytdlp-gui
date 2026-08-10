import SwiftUI

/// Menu bar commands and their keyboard shortcuts.
struct AppCommands: Commands {

    let model: AppModel

    var body: some Commands {
        // Replaces the unused "New Item" entry with something meaningful for this app.
        CommandGroup(replacing: .newItem) {
            Button("Paste URL") { model.pasteURL() }
                .keyboardShortcut("v", modifiers: [.command, .shift])

            Button("Clear URL Field") { model.clearComposer() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(model.composer.urlText.isEmpty)
        }

        CommandGroup(after: .newItem) {
            Divider()

            Button("Choose Output Folder…") { model.chooseOutputDirectory() }
                .keyboardShortcut("o", modifiers: .command)

            Button("Reveal Output Folder in Finder") { model.composer.revealOutputDirectory() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }

        CommandMenu("Download") {
            Button("Analyze URL") { model.analyzeCurrentURL() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(!model.composer.canAnalyze)

            Button("Start Download") { model.startDownload() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.composer.canDownload)

            Divider()

            Button("Cancel All Downloads") { model.queue.cancelAll() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!model.queue.isBusy)

            Button("Retry Failed Downloads") { model.queue.retryAllFailed() }
                .disabled(!model.queue.hasRetryableItems)

            Button("Clear Finished Items") { model.queue.clearFinished() }
                .disabled(!model.queue.hasFinishedItems)

            Divider()

            Button("Check for yt-dlp Update") {
                Task { await model.toolchain.updateYTDLP() }
            }
            .disabled(model.toolchain.isUpdating || !model.toolchain.isReady)

            Button("Re-check Installed Tools") {
                Task { await model.toolchain.refresh() }
            }
            .disabled(model.toolchain.isRefreshing)
        }

        CommandGroup(after: .sidebar) {
            Divider()
            ForEach(AppSection.allCases) { section in
                Button(section.title) { model.selectedSection = section }
                    .keyboardShortcut(shortcutKey(for: section), modifiers: .command)
            }
        }

        CommandGroup(replacing: .help) {
            Link("yt-dlp Documentation", destination: URL(string: "https://github.com/yt-dlp/yt-dlp#readme")!)
            Link("Supported Sites", destination: URL(string: "https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md")!)
            Divider()
            Link("Output Template Reference", destination: URL(string: "https://github.com/yt-dlp/yt-dlp#output-template")!)
            Link("Format Selection Reference", destination: URL(string: "https://github.com/yt-dlp/yt-dlp#format-selection")!)
        }
    }

    private func shortcutKey(for section: AppSection) -> KeyEquivalent {
        switch section {
        case .download: "1"
        case .queue: "2"
        case .history: "3"
        }
    }
}
