import SwiftUI
import UIKit

/// Copies text and confirms it in place for a moment, so there's no doubt the tap worked.
struct CopyButton: View {
    var title: String = "Copy"
    var text: String

    @State private var didCopy = false

    var body: some View {
        Button {
            TextCopier.copy(text)
            didCopy = true
        } label: {
            Label(didCopy ? "Copied" : title, systemImage: didCopy ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .disabled(text.isEmpty)
        .sensoryFeedback(.success, trigger: didCopy) { _, copied in copied }
        .task(id: didCopy) {
            guard didCopy else { return }
            try? await Task.sleep(for: .seconds(2))
            didCopy = false
        }
    }
}

enum TextCopier {
    /// Puts text on the clipboard. Writing never shows the paste prompt; only reading does.
    @MainActor
    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }
}
