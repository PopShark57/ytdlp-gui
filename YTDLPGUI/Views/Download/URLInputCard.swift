import SwiftUI

/// URL entry with paste, clear and drag-and-drop.
struct URLInputCard: View {
    @Environment(AppModel.self) private var model
    @Binding var isDropTargeted: Bool
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        @Bindable var composer = model.composer

        SectionCard(
            title: "Source",
            systemImage: "link",
            footnote: "Paste one address, or several at once — one per line. You can also drop a link straight onto this window."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField(
                        "https://…",
                        text: $composer.urlText,
                        axis: .vertical
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1...5)
                    .focused($isFieldFocused)
                    .onSubmit { model.startDownload() }
                    .accessibilityLabel("Media URL")
                    .accessibilityHint("Enter the web address of the video or audio to download")

                    Button {
                        composer.pasteFromClipboard()
                        isFieldFocused = true
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                            .labelStyle(.iconOnly)
                    }
                    .help("Paste from clipboard (⇧⌘V)")
                    .accessibilityLabel("Paste from clipboard")

                    Button {
                        composer.clear()
                        isFieldFocused = true
                    } label: {
                        Label("Clear", systemImage: "xmark.circle")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(composer.urlText.isEmpty)
                    .help("Clear the field (⌘K)")
                    .accessibilityLabel("Clear URL field")
                }

                if !composer.urlText.isEmpty, !composer.hasValidURL {
                    Label(
                        "That doesn't look like a web address. It should start with http:// or https://.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                if composer.isMultipleURLs {
                    Label(
                        "\(composer.detectedURLs.count) addresses found. Each becomes its own queue item, and analysis is skipped.",
                        systemImage: "list.number"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .dropTargetHighlight(isDropTargeted)
    }
}
