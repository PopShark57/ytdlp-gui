import SwiftUI

/// One file of a download, by name, marked when it is no longer there.
struct FileNameRow: View {
    let url: URL
    var isMissing = false

    var body: some View {
        Label {
            Text(url.lastPathComponent)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .foregroundStyle(isMissing ? .secondary : .primary)
        } icon: {
            Image(systemName: isMissing ? "questionmark.folder" : "doc")
                .foregroundStyle(isMissing ? Color.orange : Color.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isMissing ? "Moved or deleted" : "")
    }
}

/// How to say that some or all of a download's files have gone.
enum MissingFiles {

    /// `nil` when nothing is missing.
    static func warning(missing: Int, of total: Int) -> String? {
        guard missing > 0, total > 0 else { return nil }
        if total == 1 { return "The file has been moved or deleted." }
        if missing >= total { return "The files have been moved or deleted." }
        return "\(missing) of \(total) files have been moved or deleted."
    }
}
