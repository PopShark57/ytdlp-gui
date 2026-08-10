import SwiftUI

/// Settings pane for one external tool.
struct ToolSettingsView: View {
    @Environment(AppModel.self) private var model
    let tool: ExternalTool

    @State private var didCopyInstall = false

    private var toolchain: Toolchain { model.toolchain }
    private var status: ToolStatus { toolchain.status(for: tool) }

    var body: some View {
        Form {
            statusSection
            locationSection
            if tool == .ytdlp { updateSection }
            aboutSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Status

    private var statusSection: some View {
        Section("Status") {
            LabeledContent("Availability") {
                HStack(spacing: 6) {
                    Image(systemName: status.isInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(status.isInstalled ? .green : (tool.isRequired ? .red : .orange))
                    Text(status.isInstalled ? "Installed" : "Not found")
                }
            }

            LabeledContent("Version") {
                if toolchain.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Text(status.version ?? "Unknown")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if status.isInstalled {
                LabeledContent("Installed with") {
                    Text(status.isHomebrew ? "Homebrew" : "Other")
                        .foregroundStyle(.secondary)
                }
            }

            if let problem = status.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            if !status.isInstalled {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Install it with Homebrew:")
                        .font(.callout)
                    HStack {
                        Text(tool.installCommand)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button(didCopyInstall ? "Copied" : "Copy") {
                            Pasteboard.copy(tool.installCommand)
                            didCopyInstall = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                didCopyInstall = false
                            }
                        }
                        .controlSize(.small)
                    }
                    .padding(8)
                    .background(
                        Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                }
            }
        }
    }

    // MARK: - Location

    private var locationSection: some View {
        Section {
            LabeledContent("Path") {
                Text(status.displayPath)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            if let resolved = status.resolvedPath {
                LabeledContent("Resolves to") {
                    Text(resolved)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            LabeledContent("Detection") {
                Text(status.source.displayName)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("Choose Executable…") { chooseExecutable() }

                Button("Reset to Automatic") {
                    Task { await toolchain.resetExecutablePath(for: tool) }
                }
                .disabled(status.source == .automatic)

                Button {
                    Task { await toolchain.refresh() }
                } label: {
                    if toolchain.isRefreshing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Checking…")
                        }
                    } else {
                        Text("Check Again")
                    }
                }
                .disabled(toolchain.isRefreshing)

                Spacer()

                if status.isInstalled, let url = status.executableURL {
                    Button {
                        FinderIntegration.reveal(url)
                    } label: {
                        Label("Reveal", systemImage: "magnifyingglass")
                            .labelStyle(.iconOnly)
                    }
                    .help("Reveal in Finder")
                }
            }
        } header: {
            Text("Location")
        } footer: {
            Text("Standard Homebrew, MacPorts and pip locations are searched automatically. Choose the file yourself if \(tool.displayName) lives somewhere else.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Updating

    @ViewBuilder
    private var updateSection: some View {
        Section {
            if let strategy = toolchain.updateStrategy {
                Text(strategy.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await toolchain.updateYTDLP() }
                } label: {
                    if toolchain.isUpdating {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Updating…")
                        }
                    } else {
                        Text("Update yt-dlp")
                    }
                }
                .disabled(toolchain.isUpdating || !status.isInstalled)

                if toolchain.isUpdating {
                    Button("Stop") { toolchain.cancelUpdate() }
                }

                Spacer()

                if !toolchain.updateLog.isEmpty, !toolchain.isUpdating {
                    Button("Clear Output") { toolchain.clearUpdateLog() }
                        .controlSize(.small)
                }
            }

            if let summary = toolchain.updateSummary {
                Label(summary, systemImage: toolchain.updateDidFail ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(toolchain.updateDidFail ? .orange : .green)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !toolchain.updateLog.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(toolchain.updateLog.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 130)
                .background(
                    Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("Sites change constantly and yt-dlp is updated often. If a download suddenly stops working, updating is usually the fix.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About \(tool.displayName)") {
            Text(tool.purpose)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch tool {
            case .ytdlp:
                Link("yt-dlp on GitHub", destination: URL(string: "https://github.com/yt-dlp/yt-dlp")!)
            case .ffmpeg:
                Link("ffmpeg.org", destination: URL(string: "https://ffmpeg.org")!)
            }
        }
    }

    // MARK: - Actions

    private func chooseExecutable() {
        guard let url = FinderIntegration.chooseExecutable(
            startingAt: status.executableURL,
            message: "Choose the \(tool.displayName) executable"
        ) else { return }
        Task { await toolchain.setExecutablePath(url.path(percentEncoded: false), for: tool) }
    }
}
