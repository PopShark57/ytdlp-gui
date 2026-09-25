import UIKit

/// Tells whether the clipboard seems to hold a web link, without reading it.
///
/// Reading the clipboard makes iOS ask the person for permission (or show a "pasted from"
/// banner). Pattern detection doesn't, so the app can offer a `PasteButton` for a link it can't
/// actually see; the text only arrives when the person taps that button.
@MainActor
protocol ClipboardLinkDetecting {
    /// Changes whenever anything is copied, so the same clipboard is only offered once.
    var changeCount: Int { get }
    func containsProbableWebURL() async -> Bool
}

/// The system clipboard.
struct SystemClipboardLinkDetector: ClipboardLinkDetecting {

    var changeCount: Int { UIPasteboard.general.changeCount }

    func containsProbableWebURL() async -> Bool {
        let pasteboard = UIPasteboard.general
        // Both checks look at item types only; neither triggers the paste prompt.
        guard pasteboard.hasURLs || pasteboard.hasStrings else { return false }
        do {
            let detected = try await pasteboard.detectedPatterns(for: [\.probableWebURL])
            return detected.contains(\UIPasteboard.DetectedValues.probableWebURL)
        } catch {
            return false
        }
    }
}
