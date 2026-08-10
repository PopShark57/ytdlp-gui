import SwiftUI

/// Shows the exact yt-dlp command that will run.
///
/// The text is generated from the same argument array that is handed to `Process`, so what is
/// shown is genuinely what runs — with the caveat, stated in the footer, that the app never
/// passes it through a shell.
struct CommandPreviewCard: View {
    @Environment(AppModel.self) private var model
    @Binding var isExpanded: Bool
    @State private var didCopy = false

    var body: some View {
        SectionCard {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    ScrollView(.horizontal, showsIndicators: true) {
                        Text(model.composer.commandPreview)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                    .background(
                        Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    }

                    HStack {
                        Text("Arguments are passed directly to yt-dlp. No shell is involved, so quoting here is only for readability.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 8)

                        Button {
                            Pasteboard.copy(model.composer.commandPreview)
                            withAnimation { didCopy = true }
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                withAnimation { didCopy = false }
                            }
                        } label: {
                            Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        }
                        .controlSize(.small)
                        .help("Copy the command so you can run it in Terminal")
                    }
                }
                .padding(.top, 12)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .foregroundStyle(.tint)
                    Text("Command Preview")
                        .font(.headline)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
        }
    }
}
