import SwiftUI

/// Preferences, storage, the engine, cookies and information about the app.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmsReset = false

    var body: some View {
        let settings = model.settings

        NavigationStack {
            Form {
                downloadsSection(settings)
                StorageSettingsSection()
                EngineSettingsSection()
                CookieSettingsSection()
                appearanceSection(settings)
                historySection(settings)
                AboutSection()
                resetSection
            }
            .readableContentWidth()
            .navigationTitle("Settings")
            .task {
                await model.storage.refreshUsage()
            }
        }
    }

    // MARK: - Downloads

    @ViewBuilder
    private func downloadsSection(_ settings: AppSettings) -> some View {
        @Bindable var settings = settings

        Section {
            Stepper(value: $settings.maximumConcurrentDownloads, in: AppSettings.concurrencyRange) {
                LabeledContent("Simultaneous Downloads", value: settings.maximumConcurrentDownloads.formatted())
            }
            .accessibilityHint("How many downloads run at the same time")

            Toggle("Analyze pasted links automatically", isOn: $settings.autoAnalyzePastedURLs)
            Toggle("Suggest links from the clipboard", isOn: $settings.suggestClipboardLinks)
            Toggle("Save videos to Photos automatically", isOn: $settings.saveVideosToPhotos)
            Toggle("Notify when downloads finish", isOn: $settings.notifyWhenComplete)
                .onChange(of: settings.notifyWhenComplete) { _, isOn in
                    guard isOn else { return }
                    Task { await model.notifications.requestAuthorizationIfNeeded() }
                }
            Toggle("Keep the screen awake while downloading", isOn: $settings.keepScreenAwake)
            Toggle("Show command preview", isOn: $settings.showCommandPreview)
        } header: {
            Text("Downloads")
        } footer: {
            Text("More simultaneous downloads isn't always faster, and some sites slow down or block busy connections. Clipboard suggestions only notice that a link is there; nothing is read until you tap Paste.")
        }
    }

    // MARK: - Appearance

    @ViewBuilder
    private func appearanceSection(_ settings: AppSettings) -> some View {
        @Bindable var settings = settings

        Section("Appearance") {
            Picker("Appearance", selection: $settings.appearance) {
                ForEach(AppSettings.AppearanceMode.allCases) { mode in
                    Label(mode.displayName, systemImage: mode.symbolName)
                        .tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    // MARK: - History

    @ViewBuilder
    private func historySection(_ settings: AppSettings) -> some View {
        @Bindable var settings = settings

        Section {
            Toggle("Ask before clearing history", isOn: $settings.confirmBeforeClearingHistory)
            LabeledContent("Entries", value: model.history.entries.count.formatted())
        } header: {
            Text("History")
        } footer: {
            Text("Clearing history never deletes downloaded files.")
        }
    }

    // MARK: - Reset

    private var resetSection: some View {
        Section {
            Button("Reset All Settings", role: .destructive) {
                confirmsReset = true
            }
            .confirmationDialog(
                "Reset all settings?",
                isPresented: $confirmsReset,
                titleVisibility: .visible
            ) {
                Button("Reset All Settings", role: .destructive) {
                    model.settings.resetToDefaults()
                }
            } message: {
                Text("Your downloads, history and imported cookies are kept.")
            }
        }
    }
}

/// The app's version, the disclaimer and the acknowledgements.
private struct AboutSection: View {
    var body: some View {
        Section {
            LabeledContent("Version", value: appVersion)

            Text("An independent front end. Not affiliated with, endorsed by or connected to YouTube, Google or the yt-dlp project.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Only download what you have the right to. Respect each site's terms of service and the rights of the people who made the work.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            NavigationLink {
                AcknowledgementsView()
            } label: {
                Label("Acknowledgements", systemImage: "heart.text.square")
            }
        } header: {
            Text("About")
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        guard let build = info?["CFBundleVersion"] as? String, build != version else { return version }
        return "\(version) (\(build))"
    }
}

#Preview {
    SettingsView()
        .environment(AppModel())
}
