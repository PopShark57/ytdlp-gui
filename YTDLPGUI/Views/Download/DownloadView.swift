import SwiftUI

/// The primary screen: paste a URL, pick a preset, download.
struct DownloadView: View {
    @Environment(AppModel.self) private var model

    @State private var isDropTargeted = false
    @State private var showAdvanced = false
    @State private var showCommandPreview = false

    private var composer: DownloadComposer { model.composer }

    var body: some View {
        @Bindable var composer = model.composer

        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    if let message = composer.statusMessage {
                        AdvisoryBanner(kind: .success, title: message, actionTitle: "Dismiss") {
                            composer.dismissStatus()
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if !model.toolchain.canMergeStreams, model.toolchain.hasCompletedFirstCheck {
                        AdvisoryBanner(
                            kind: .warning,
                            title: "ffmpeg isn't installed",
                            message: "Without it, separate video and audio streams can't be merged and audio can't be converted. Install it with `brew install ffmpeg`.",
                            actionTitle: "Copy Command"
                        ) {
                            Pasteboard.copy("brew install ffmpeg")
                        }
                    }

                    URLInputCard(isDropTargeted: $isDropTargeted)

                    AnalysisSection()

                    FormatCard()

                    OutputCard()

                    AdvancedOptionsCard(isExpanded: $showAdvanced)

                    CommandPreviewCard(isExpanded: $showCommandPreview)

                    ForEach(composer.advisories, id: \.self) { advisory in
                        AdvisoryBanner(kind: .warning, title: advisory)
                    }
                }
                .padding(20)
                .frame(maxWidth: 780)
                .frame(maxWidth: .infinity)
                .animation(.easeInOut(duration: 0.2), value: composer.statusMessage)
                .animation(.easeInOut(duration: 0.2), value: composer.analysis)
            }
            .scrollBounceBehavior(.basedOnSize)

            Divider()

            actionBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: DropHandling.acceptedTypes, isTargeted: $isDropTargeted) { providers in
            DropHandling.extractText(from: providers) { text in
                composer.setURLText(text, analyzeIfEnabled: true)
            }
        }
        .onAppear {
            showCommandPreview = model.settings.showCommandPreview
            composer.syncOutputDirectoryFromSettings()
        }
        .onChange(of: showCommandPreview) { _, newValue in
            model.settings.showCommandPreview = newValue
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            if composer.isMultipleURLs {
                Label("\(composer.detectedURLs.count) URLs detected", systemImage: "list.bullet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let info = composer.analysis.info {
                Label(info.title, systemImage: info.isPlaylist ? "list.and.film" : "film")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Button("Clear") {
                composer.clear()
            }
            .disabled(composer.urlText.isEmpty)
            .help("Clear the URL field (⌘K)")

            Button {
                composer.analyze()
            } label: {
                if composer.analysis.isAnalyzing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Analyzing…")
                    }
                } else {
                    Label("Analyze", systemImage: "sparkle.magnifyingglass")
                }
            }
            .disabled(!composer.canAnalyze)
            .help("Fetch title, thumbnail and available formats (⌘I)")

            Button {
                model.startDownload()
            } label: {
                Label(
                    composer.isMultipleURLs ? "Download \(composer.detectedURLs.count)" : "Download",
                    systemImage: "arrow.down.circle.fill"
                )
                .frame(minWidth: 90)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(!composer.canDownload)
            .help("Add to the download queue and start (⌘↩)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}
