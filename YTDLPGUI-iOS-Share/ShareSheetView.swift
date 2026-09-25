import SwiftUI

/// The sheet the Share extension shows: the links it found and what to do with them.
struct ShareSheetView: View {
    let model: ShareSheetModel

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("YTDLP GUI")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .background(Color(.systemGroupedBackground))
        }
        .tint(.appAccent)
        .sensoryFeedback(trigger: model.phase) { _, phase in
            switch phase {
            case .handedOver: .success
            case .storageUnavailable, .failed: .error
            case .loading, .choosing, .noLinks: nil
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Looking for links…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .choosing:
            LinkChoiceView(model: model)
        case .handedOver:
            HandedOverView()
        case .noLinks:
            NoLinksView(model: model)
        case .storageUnavailable:
            HandOverFailureView(
                model: model,
                title: "Can't Reach YTDLP GUI",
                message: "The share extension can't open the storage it shares with the app, "
                    + "so it can't pass anything along."
            )
        case .failed(let reason):
            HandOverFailureView(
                model: model,
                title: "Couldn't Add to YTDLP GUI",
                message: reason
            )
        }
    }

    /// Error screens carry their own Close button, where it can't be missed, so they get none here.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if model.phase == .loading || model.phase == .choosing {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: model.cancel)
            }
        }
        if model.phase == .handedOver {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: model.done)
            }
        }
    }
}

// MARK: - Choosing

/// The links, and the three ways to hand them over.
private struct LinkChoiceView: View {
    let model: ShareSheetModel

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        List {
            Section {
                ForEach(model.links, id: \.self) { link in
                    LinkRow(link: link)
                }
            } header: {
                ShareHeader(linkCount: model.links.count)
            }

            if dynamicTypeSize.isAccessibilitySize {
                // At the largest text sizes the buttons alone would fill a pinned footer, so
                // they scroll with everything else instead.
                Section {
                    actions
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            if !dynamicTypeSize.isAccessibilitySize {
                actions
                    .padding(.horizontal)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .background(.bar)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { downloadButtons }
                VStack(spacing: 10) { downloadButtons }
            }
            Button {
                model.handOver(as: nil)
            } label: {
                Label("Add to YTDLP GUI", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityHint("Fills in the app's Download screen, so you can choose options before downloading.")

            Text("Downloads use your last settings, and start when you open YTDLP GUI.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var downloadButtons: some View {
        Button {
            model.handOver(as: .video)
        } label: {
            Label("Download Video", systemImage: "film")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)

        Button {
            model.handOver(as: .audio)
        } label: {
            Label("Download Audio", systemImage: "music.note")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}

/// The app's badge and what was found, above the links.
private struct ShareHeader: View {
    let linkCount: Int

    var body: some View {
        HStack(spacing: 14) {
            AppBadge()
            VStack(alignment: .leading, spacing: 2) {
                Text("Download with YTDLP GUI")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                Text(linkCount == 1 ? "1 link" : "\(linkCount) links")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .textCase(nil)
        .padding(.bottom, 8)
    }
}

private struct LinkRow: View {
    let link: String

    var body: some View {
        Label {
            Text(LinkExtractor.displayString(for: link))
                .lineLimit(2)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: "link")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LinkExtractor.displayString(for: link))
    }
}

/// A stand-in for the app icon, whose artwork isn't in the extension's bundle: the same
/// gradient and download arrow, drawn with an SF Symbol.
private struct AppBadge: View {
    @ScaledMetric(relativeTo: .headline) private var size: CGFloat = 44

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0x7A / 255, green: 0x5A / 255, blue: 0xF8 / 255),
                        Color(red: 0x4C / 255, green: 0x6F / 255, blue: 0xF5 / 255),
                        Color(red: 0x21 / 255, green: 0xC7 / 255, blue: 0xE6 / 255),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "arrow.down")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Outcomes

private struct HandedOverView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounce = 0

    private static let message = "Added to YTDLP GUI. Open the app to start the download."

    var body: some View {
        ContentUnavailableView {
            Label {
                Text("Added to YTDLP GUI")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: bounce)
            }
        } description: {
            Text("Open the app to start the download.")
        }
        .accessibilityElement(children: .combine)
        .onAppear {
            if !reduceMotion { bounce += 1 }
            AccessibilityNotification.Announcement(Self.message).post()
        }
    }
}

private struct NoLinksView: View {
    let model: ShareSheetModel

    var body: some View {
        ContentUnavailableView {
            Label("No Link to Download", systemImage: "link")
        } description: {
            Text("No web link found in what you shared. Try sharing a web page, or a video from an app like YouTube.")
        } actions: {
            Button("Close", action: model.cancel)
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
    }
}

/// Shown when the links couldn't be left for the app: copying them is the way round it.
private struct HandOverFailureView: View {
    let model: ShareSheetModel
    let title: String
    let message: String

    private var isSingleLink: Bool { model.links.count == 1 }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message + (isSingleLink
                ? " Copy the link, then paste it into YTDLP GUI's Download screen."
                : " Copy the links, then paste them into YTDLP GUI's Download screen."))
        } actions: {
            Button(action: model.copyLinks) {
                if model.didCopyLinks {
                    Label("Copied", systemImage: "checkmark")
                } else {
                    Label(isSingleLink ? "Copy Link" : "Copy Links", systemImage: "doc.on.doc")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityHint("Copies to the clipboard, so you can paste it in the app.")

            Button("Close", action: model.cancel)
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
        .sensoryFeedback(.success, trigger: model.didCopyLinks) { _, copied in copied }
    }
}

private extension Color {
    /// The app's accent colour, so the sheet looks like part of it. The app's `AccentColor` asset
    /// (written by `Tools/GenerateAppIcon.swift`) isn't in the extension's bundle, so its light
    /// and dark values are repeated here; keep them in step.
    static let appAccent = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x5B / 255, green: 0x7B / 255, blue: 0xF6 / 255, alpha: 1)
            : UIColor(red: 0x3E / 255, green: 0x64 / 255, blue: 0xF4 / 255, alpha: 1)
    })
}
