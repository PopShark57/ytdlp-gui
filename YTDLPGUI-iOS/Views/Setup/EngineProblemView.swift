import SwiftUI

/// Shown on the Download tab when the embedded engine couldn't start.
///
/// The iOS counterpart of the Mac app's setup screen. There is nothing to install on iPhone or
/// iPad: the engine ships inside the app, so a failure here is either transient or caused by an
/// installed yt-dlp update, and the screen says how to deal with both.
struct EngineProblemView: View {
    let message: String

    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header

                    VStack(alignment: .leading, spacing: 10) {
                        Text("What went wrong")
                            .font(.headline)
                        Text(message)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        CopyButton(title: "Copy Message", text: message)
                            .font(.subheadline)
                    }
                    .padding(16)
                    .background(.fill.quaternary, in: .rect(cornerRadius: 16, style: .continuous))

                    VStack(spacing: 12) {
                        Button {
                            Task { await model.engine.start() }
                        } label: {
                            Label("Try Again", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Button {
                            model.selectedTab = .settings
                        } label: {
                            Text("Open Settings")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .accessibilityHint("Settings › Engine shows the versions in use and can go back to the bundled yt-dlp")
                    }

                    Text("If this keeps happening, close the app in the App Switcher and open it again. If it started after installing a yt-dlp update, choose Use Bundled Version in Settings › Engine. Your queue and history are unaffected.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Download")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(.largeTitle, weight: .light))
                .imageScale(.large)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text("The download engine couldn't start")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text("YTDLP GUI runs yt-dlp inside the app, with its own copy of Python. Until it starts, links can't be analyzed or downloaded.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 12)
    }
}

#Preview {
    EngineProblemView(message: "The download engine couldn't start: No module named 'yt_dlp'")
        .environment(AppModel())
}
