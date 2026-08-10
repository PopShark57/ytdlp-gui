import SwiftUI
import UniformTypeIdentifiers

/// Extracts text or a link from a drag-and-drop operation.
///
/// Different sources offer different representations: Safari's address bar and link drags
/// provide a `URL`, while text selections and most chat apps provide a plain string. Both are
/// accepted, and the string is parsed for URLs afterwards.
@MainActor
enum DropHandling {

    static let acceptedTypes: [UTType] = [.url, .fileURL, .utf8PlainText, .plainText, .text]

    /// Pulls the first usable text payload out of the providers.
    ///
    /// - Returns: `true` when at least one provider could be read, which tells SwiftUI the drop
    ///   was accepted. The payload itself arrives asynchronously through `completion`.
    static func extractText(
        from providers: [NSItemProvider],
        completion: @escaping @Sendable @MainActor (String) -> Void
    ) -> Bool {
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, !url.isFileURL else { return }
                    let text = url.absoluteString
                    Task { @MainActor in completion(text) }
                }
                return true
            }
        }

        for provider in providers where provider.canLoadObject(ofClass: NSString.self) {
            _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                guard let string = value as? NSString else { return }
                let text = string as String
                Task { @MainActor in completion(text) }
            }
            return true
        }

        return false
    }
}

/// Visual treatment for a view that is a valid drop target.
struct DropTargetHighlight: ViewModifier {
    var isTargeted: Bool
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .opacity(isTargeted ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.15), value: isTargeted)
    }
}

extension View {
    func dropTargetHighlight(_ isTargeted: Bool, cornerRadius: CGFloat = 12) -> some View {
        modifier(DropTargetHighlight(isTargeted: isTargeted, cornerRadius: cornerRadius))
    }
}
