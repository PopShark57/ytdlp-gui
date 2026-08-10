import SwiftUI

/// The standard macOS Settings window.
struct SettingsRootView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }

            ToolSettingsView(tool: .ytdlp)
                .tabItem { Label("yt-dlp", systemImage: "arrow.down.app") }

            ToolSettingsView(tool: .ffmpeg)
                .tabItem { Label("ffmpeg", systemImage: "film.stack") }

            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
        }
        .frame(width: 560)
        .frame(minHeight: 420)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section {
                LabeledContent("Save downloads to") {
                    HStack(spacing: 8) {
                        Text(displayPath)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.secondary)
                        Button("Change…") {
                            if let url = FinderIntegration.chooseDirectory(startingAt: settings.downloadDirectory) {
                                settings.downloadDirectory = url
                                model.composer.options.outputDirectory = url
                            }
                        }
                    }
                }
            } header: {
                Text("Downloads")
            } footer: {
                Text("New downloads start in this folder. You can still change the destination for an individual download.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Clipboard") {
                Toggle("Analyze pasted URLs automatically", isOn: $settings.autoAnalyzePastedURLs)
                    .help("Fetches the title, thumbnail and formats as soon as a URL is pasted or dropped")

                Toggle("Check the clipboard when the app becomes active", isOn: $settings.readClipboardOnActivate)
                    .help("Fills the URL field with a link found on the clipboard when you switch back to the app")
            }

            Section("Downloading") {
                Picker("Simultaneous downloads", selection: $settings.maximumConcurrentDownloads) {
                    ForEach(AppSettings.concurrencyRange, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 220)
                .help("How many downloads may run at the same time. More is not always faster, and some sites rate-limit.")
            }

            Section("When a download finishes") {
                Toggle("Show a notification", isOn: $settings.notifyWhenComplete)
                Toggle("Play a sound", isOn: $settings.playSoundWhenComplete)
                    .disabled(!settings.notifyWhenComplete)
                Toggle("Reveal the file in Finder", isOn: $settings.revealWhenComplete)
                    .help("Opens a Finder window with the finished file selected")
            }

            Section("History") {
                Toggle("Ask before clearing history", isOn: $settings.confirmBeforeClearingHistory)
                LabeledContent("Stored entries") {
                    HStack(spacing: 8) {
                        Text("\(model.history.entries.count)")
                            .foregroundStyle(.secondary)
                        Button("Show in Finder") {
                            FinderIntegration.reveal(
                                model.history.storageDirectory.appending(path: "history.json")
                            )
                        }
                    }
                }
            }

            Section {
                Button("Reset All Settings…") {
                    model.settings.resetToDefaults()
                    model.composer.options.outputDirectory = model.settings.downloadDirectory
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var displayPath: String {
        let path = model.settings.downloadDirectory.path(percentEncoded: false)
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - Appearance

struct AppearanceSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section {
                Picker("Theme", selection: $settings.appearance) {
                    ForEach(AppSettings.AppearanceMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.symbolName)
                            .tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Appearance")
            } footer: {
                Text("“System” follows the macOS appearance setting, including automatic switching at sunset.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Download screen") {
                Toggle("Show the command preview by default", isOn: $settings.showCommandPreview)
                    .help("Expands the panel that shows the yt-dlp command before it runs")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
