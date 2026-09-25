import CoreTransferable
import Foundation

/// A link or some text dropped onto the app.
///
/// Different sources offer different representations: Safari's address bar and link drags
/// provide a URL, while text selections and most chat apps provide plain text that may contain
/// several links. Both end up as text that the composer searches for links.
struct DroppedLink: Transferable {
    var text: String

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(importing: { (url: URL) in
            // A dragged file is not something yt-dlp can download.
            guard !url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
            return DroppedLink(text: url.absoluteString)
        })
        ProxyRepresentation(importing: { (text: String) in
            DroppedLink(text: text)
        })
    }
}
