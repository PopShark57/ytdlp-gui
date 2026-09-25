import SwiftUI

/// Where downloads go on this device, and how much room they take.
///
/// The sizes are refreshed by the screen that shows this section, when it appears.
struct StorageSettingsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    @State private var confirmsClearing = false
    @State private var isClearing = false

    private var storage: StorageManager { model.storage }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 3) {
                Text("Downloads are saved to")
                Text("Files › On My \(DeviceName.current) › YTDLP GUI")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            LabeledContent("Downloads", value: sizeText(storage.downloadsSizeBytes))
            LabeledContent("Partial Downloads", value: sizeText(storage.partialDownloadsSizeBytes))
            LabeledContent("Available", value: sizeText(storage.availableCapacityBytes))

            Button {
                if let url = storage.filesAppURL {
                    openURL(url)
                }
            } label: {
                Label("Open in Files", systemImage: "folder")
            }
            .disabled(storage.filesAppURL == nil)

            Button(role: .destructive) {
                confirmsClearing = true
            } label: {
                if isClearing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Clearing…")
                    }
                } else {
                    Label("Clear Partial Downloads", systemImage: "trash")
                }
            }
            .disabled(isClearing || storage.partialDownloadsSizeBytes == 0)
            .confirmationDialog(
                "Clear partial downloads?",
                isPresented: $confirmsClearing,
                titleVisibility: .visible
            ) {
                Button("Clear Partial Downloads", role: .destructive, action: clearPartialDownloads)
            } message: {
                Text("Cancelled and failed downloads will start from the beginning if you retry them. Finished downloads aren't affected.")
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("Partial downloads are what's left of cancelled or failed downloads, kept so a retry can pick up where it stopped.")
        }
    }

    private func sizeText(_ bytes: Int64?) -> String {
        Format.bytes(bytes) ?? "Calculating…"
    }

    private func clearPartialDownloads() {
        isClearing = true
        Task {
            await storage.clearPartialDownloads()
            await storage.refreshUsage()
            isClearing = false
        }
    }
}
