import SwiftUI

/// The embedded yt-dlp: which versions are running, and keeping yt-dlp up to date.
///
/// Sites change constantly and yt-dlp follows them with frequent releases, so an app that could
/// never update it would stop working within weeks. This is where that happens.
struct EngineSettingsSection: View {
    @Environment(AppModel.self) private var model

    private var engine: EngineController { model.engine }

    var body: some View {
        Section {
            stateRow

            if let info = engine.info {
                LabeledContent("yt-dlp") {
                    HStack(spacing: 8) {
                        Text(info.ytdlpVersion)
                            .monospacedDigit()
                            .textSelection(.enabled)
                        StatusBadge(
                            text: info.ytdlpSource == .updated ? "Updated" : "Bundled",
                            tint: info.ytdlpSource == .updated ? .accentColor : .secondary
                        )
                    }
                }
                .accessibilityElement(children: .combine)
                LabeledContent("Python", value: info.pythonVersion)
                LabeledContent("yt-dlp-ejs", value: info.ejsVersion ?? "Not available")
                LabeledContent("certifi", value: info.certifiVersion ?? "Not available")
            }

            updateRows

            if showsUseBundledVersion {
                Button {
                    engine.revertToBundledVersion()
                } label: {
                    Label("Use Bundled Version", systemImage: "arrow.uturn.backward")
                }
                .accessibilityHint("Removes the downloaded update and goes back to the yt-dlp that came with the app")
            }

            if engine.isRestartRequired {
                WarningRow(
                    message: "Restart the app to finish: swipe it away in the App Switcher, then open it again.",
                    systemImage: "arrow.clockwise.circle.fill",
                    tint: .accentColor
                )
            }
        } header: {
            Text("Engine")
        } footer: {
            Text("If downloads from a site suddenly stop working, updating yt-dlp is usually the fix. Updates come from PyPI and are checked against their published fingerprints before they're installed.")
        }
    }

    // MARK: - State

    @ViewBuilder
    private var stateRow: some View {
        switch engine.state {
        case .notStarted, .starting:
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Starting…")
                }
            }
            .accessibilityElement(children: .combine)
        case .ready:
            LabeledContent("Status") {
                // A Label as the value of LabeledContent lays out vertically in a Form, which
                // left a tall empty row; an explicit HStack keeps it on one line.
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Ready")
                }
                .foregroundStyle(.green)
            }
            .accessibilityElement(children: .combine)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                WarningRow(message: message, systemImage: "xmark.octagon.fill", tint: .red)
                Button("Try Again") {
                    Task { await engine.start() }
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Updates

    @ViewBuilder
    private var updateRows: some View {
        switch engine.updateState {
        case .idle:
            checkButton(title: "Check for Updates")
        case .checking:
            progressRow("Checking for updates…")
        case .upToDate(let version):
            Label("yt-dlp \(version) is the latest version.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            checkButton(title: "Check Again")
        case .available(let update):
            if update.isNewer {
                VStack(alignment: .leading, spacing: 2) {
                    Text("yt-dlp \(update.latestVersion) is available")
                        .font(.body.weight(.medium))
                    Text("You have \(update.currentVersion).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Button {
                    Task { await engine.installUpdate() }
                } label: {
                    Label("Install \(update.latestVersion)", systemImage: "arrow.down.circle")
                }
                .disabled(!engine.isReady)
            } else {
                Label("yt-dlp \(update.currentVersion) is the latest version.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                checkButton(title: "Check Again")
            }
        case .installing:
            progressRow("Installing the update…")
        case .installed(let version):
            Label("yt-dlp \(version) is installed and will be used the next time the app opens.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            WarningRow(message: message)
            checkButton(title: "Try Again")
        }
    }

    private func checkButton(title: String) -> some View {
        Button {
            Task { await engine.checkForUpdates() }
        } label: {
            Label(title, systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(!engine.isReady)
    }

    private func progressRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var showsUseBundledVersion: Bool {
        if engine.info?.ytdlpSource == .updated { return true }
        if case .installed = engine.updateState { return true }
        return false
    }
}
