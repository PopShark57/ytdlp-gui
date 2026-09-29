import SwiftUI

/// The link field, with paste, clear and analyze.
struct LinkSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var isFieldFocused: FocusState<Bool>.Binding

    private var composer: DownloadComposer { model.composer }

    var body: some View {
        @Bindable var composer = model.composer

        Section {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label("Add a link", systemImage: "link")
                        .font(.headline)
                    Spacer()
                    Text("01")
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                if model.clipboardHasSuggestedLink {
                    ClipboardSuggestionRow()
                }

                if !model.engine.isReady {
                    Label {
                        Text("Preparing the download engine…")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } icon: {
                        ProgressView()
                    }
                    .accessibilityElement(children: .combine)
                }

                TextField("Paste or type a link", text: $composer.urlText, axis: .vertical)
                    .font(.body)
                    .lineLimit(2...4)
                    .padding(16)
                    .background(MobileTheme.canvas, in: .rect(cornerRadius: 16))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(MobileTheme.accent.opacity(isFieldFocused.wrappedValue ? 0.8 : 0.18))
                    }
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused(isFieldFocused)
                    .onSubmit(submit)
                    .onChange(of: composer.urlText) { oldValue, newValue in
                        handleReturnKey(from: oldValue, to: newValue)
                    }
                    .accessibilityLabel("Link")
                    .accessibilityHint("The web address of the video or audio to download. Several links, one per line, are downloaded one after another.")

                actionRow

                if composer.isMultipleURLs {
                    Label(
                        "\(composer.detectedURLs.count) links — each uses the options below",
                        systemImage: "list.bullet"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                } else if showsInvalidLinkHint {
                    WarningRow(message: "That doesn't look like a web address. It should start with http:// or https://.")
                }
            }
            .padding(.vertical, 8)
        } footer: {
            Text("One link or a whole playlist. Paste several links to queue them together.")
        }
        .mobileCardRow()
    }

    // MARK: - Actions

    private var actionRow: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))

        return layout {
            PasteButton(payloadType: String.self) { strings in
                model.acceptPastedText(strings.joined(separator: "\n"))
            }
            .buttonBorderShape(.capsule)
            .labelStyle(.titleAndIcon)

            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 0)
            }

            Button {
                composer.clear()
            } label: {
                Image(systemName: "xmark")
                    .frame(minWidth: 24, minHeight: 24)
            }
            .mobileGlassButton()
            .buttonBorderShape(.capsule)
            .disabled(composer.urlText.isEmpty)
            .accessibilityLabel("Clear link")

            analyzeButton
        }
        .controlSize(.regular)
        .padding(.vertical, 2)
        .mobileGlassGroup()
    }

    @ViewBuilder
    private var analyzeButton: some View {
        if composer.analysis.isAnalyzing {
            Button(role: .cancel) {
                composer.cancelAnalysis()
            } label: {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Cancel")
                }
            }
            .mobileGlassButton()
            .buttonBorderShape(.capsule)
            .accessibilityLabel("Analyzing. Cancel")
        } else {
            Button(action: submit) {
                Label("Analyze", systemImage: "sparkle.magnifyingglass")
            }
            .mobileGlassButton()
            .buttonBorderShape(.capsule)
            .disabled(!canAnalyze)
            .accessibilityHint("Fetches the title, artwork and available formats")
        }
    }

    // MARK: - Behaviour

    private var canAnalyze: Bool {
        composer.canAnalyze && model.engine.isReady && !composer.analysis.isAnalyzing
    }

    private var showsInvalidLinkHint: Bool {
        !composer.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !composer.hasValidURL
    }

    /// The Go key: analyze when possible, and put the keyboard away so the result is visible.
    private func submit() {
        if canAnalyze {
            composer.analyze()
        }
        isFieldFocused.wrappedValue = false
    }

    /// A multi-line field inserts a newline for Return instead of submitting. A single typed
    /// newline is therefore taken back out and treated as Go. Pasted text, which may hold one
    /// link per line on purpose, arrives many characters at once and is left alone.
    private func handleReturnKey(from oldValue: String, to newValue: String) {
        guard isFieldFocused.wrappedValue, newValue.count == oldValue.count + 1 else { return }
        let newlines = { (text: String) in text.reduce(0) { $0 + ($1.isNewline ? 1 : 0) } }
        guard newlines(newValue) == newlines(oldValue) + 1 else { return }
        model.composer.urlText = oldValue
        submit()
    }
}

/// Offers a link that iOS says is on the clipboard.
///
/// The app only knows that the clipboard *looks like* it holds a web link; reading it would show
/// the paste prompt. The `PasteButton` here reads it with the user's tap, which needs no prompt.
private struct ClipboardSuggestionRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard")
                .font(.title3)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("There's a link on the clipboard")
                    .font(.subheadline.weight(.semibold))
                Text("Paste it to get started.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            PasteButton(payloadType: String.self) { strings in
                model.acceptPastedText(strings.joined(separator: "\n"))
            }
            .buttonBorderShape(.capsule)
            .labelStyle(.iconOnly)

            Button {
                model.dismissClipboardSuggestion()
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 28, minHeight: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss suggestion")
        }
        .padding(.vertical, 2)
    }
}
