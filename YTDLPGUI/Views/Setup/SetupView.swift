import SwiftUI

/// Shown in place of the download screen when yt-dlp can't be found.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var didCopyCommand = false

    private var toolchain: Toolchain { model.toolchain }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header

                SectionCard(title: "Install with Homebrew", systemImage: "shippingbox") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(toolchain.isHomebrewInstalled
                             ? "Homebrew is installed. Run this in Terminal:"
                             : "The easiest way to install yt-dlp is with Homebrew. Install Homebrew first, then run:")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        commandBox(ExternalTool.installCommand(for: missingTools))

                        if !toolchain.isHomebrewInstalled {
                            Link(destination: URL(string: "https://brew.sh")!) {
                                Label("Get Homebrew at brew.sh", systemImage: "arrow.up.forward.app")
                            }
                            .font(.callout)
                        }

                        Text("YTDLP GUI never installs or bundles yt-dlp itself. It only drives the copy you install, so you stay in control of updates.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                SectionCard(title: "Already installed?", systemImage: "folder.badge.questionmark") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("If yt-dlp lives somewhere unusual — a pipx environment, a custom prefix, or a manually downloaded binary — point the app at it directly.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 10) {
                            Button {
                                chooseExecutable(for: .ytdlp)
                            } label: {
                                Label("Choose yt-dlp…", systemImage: "folder")
                            }

                            Button {
                                Task { await toolchain.refresh() }
                            } label: {
                                Label("Check Again", systemImage: "arrow.clockwise")
                            }
                            .disabled(toolchain.isRefreshing)

                            if toolchain.isRefreshing {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                }

                SectionCard(title: "Where the app looked", systemImage: "magnifyingglass") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(searchedPaths, id: \.self) { path in
                            Text(path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }

                statusGrid
            }
            .padding(24)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.app.dashed")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("yt-dlp isn't installed yet")
                .font(.title2.weight(.semibold))

            Text("YTDLP GUI is a front end for the yt-dlp command-line tool. Install it once and this screen won't come back.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
        .frame(maxWidth: 480)
    }

    private func commandBox(_ command: String) -> some View {
        HStack(spacing: 10) {
            Text(command)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                Pasteboard.copy(command)
                withAnimation { didCopyCommand = true }
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation { didCopyCommand = false }
                }
            } label: {
                Label(
                    didCopyCommand ? "Copied" : "Copy",
                    systemImage: didCopyCommand ? "checkmark" : "doc.on.doc"
                )
                .labelStyle(.titleAndIcon)
            }
            .controlSize(.small)
            .help("Copy the command to the clipboard")
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }

    private var statusGrid: some View {
        HStack(spacing: 12) {
            ForEach(ExternalTool.allCases) { tool in
                let status = toolchain.status(for: tool)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: status.isInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(status.isInstalled ? .green : (tool.isRequired ? .red : .orange))
                        Text(tool.displayName)
                            .font(.headline)
                    }
                    Text(status.statusLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(tool.purpose)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: - Data

    private var missingTools: [ExternalTool] {
        let missing = ExternalTool.allCases.filter { !toolchain.status(for: $0).isInstalled }
        return missing.isEmpty ? [.ytdlp] : missing
    }

    /// A representative subset of the search locations, enough to explain the result.
    private var searchedPaths: [String] {
        ToolLocator.searchDirectories
            .prefix(6)
            .map { $0.appending(path: "yt-dlp").path(percentEncoded: false) }
    }

    private func chooseExecutable(for tool: ExternalTool) {
        guard let url = FinderIntegration.chooseExecutable(
            startingAt: toolchain.status(for: tool).executableURL,
            message: "Choose the \(tool.displayName) executable"
        ) else { return }
        Task { await toolchain.setExecutablePath(url.path(percentEncoded: false), for: tool) }
    }
}
