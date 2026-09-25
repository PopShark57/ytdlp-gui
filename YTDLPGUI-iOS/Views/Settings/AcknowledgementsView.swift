import SwiftUI

/// The open-source components bundled into the app, with their licences.
///
/// The iOS app ships its own Python and yt-dlp, so, unlike the Mac app, it redistributes their
/// code and owes each project credit and its licence terms.
struct AcknowledgementsView: View {
    var body: some View {
        List {
            Section {
                ForEach(Component.all) { component in
                    ComponentRow(component: component)
                }
            } footer: {
                Text("YTDLP GUI is built on these projects. Thank you to everyone who works on them.")
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
        .readableContentWidth()
    }
}

private struct Component: Identifiable {
    var name: String
    var licence: String
    var website: URL?

    var id: String { name }

    static let all: [Component] = [
        Component(name: "Python 3.14", licence: "PSF License", website: URL(string: "https://www.python.org")),
        Component(name: "yt-dlp", licence: "Unlicense", website: URL(string: "https://github.com/yt-dlp/yt-dlp")),
        Component(
            name: "yt-dlp-ejs",
            licence: "Unlicense; its solver bundles meriyah (ISC) and astring (MIT)",
            website: URL(string: "https://github.com/yt-dlp/ejs")
        ),
        Component(name: "certifi", licence: "MPL-2.0", website: URL(string: "https://github.com/certifi/python-certifi")),
        Component(name: "OpenSSL", licence: "Apache-2.0", website: URL(string: "https://www.openssl.org")),
        Component(name: "libFFI", licence: "MIT", website: URL(string: "https://sourceware.org/libffi/")),
        Component(name: "BZip2", licence: "bzip2 licence", website: URL(string: "https://sourceware.org/bzip2/")),
        Component(name: "XZ Utils", licence: "0BSD", website: URL(string: "https://tukaani.org/xz/")),
        Component(name: "mpdecimal", licence: "BSD-2-Clause", website: URL(string: "https://www.bytereef.org/mpdecimal/")),
        Component(name: "Zstandard", licence: "BSD-3-Clause", website: URL(string: "https://facebook.github.io/zstd/")),
        Component(name: "SQLite", licence: "Public domain", website: URL(string: "https://sqlite.org")),
        Component(
            name: "BeeWare Python-Apple-support",
            licence: "BSD-3-Clause",
            website: URL(string: "https://github.com/beeware/Python-Apple-support")
        ),
    ]
}

private struct ComponentRow: View {
    let component: Component

    var body: some View {
        if let website = component.website {
            Link(destination: website) {
                HStack {
                    details
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.up.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the project's website")
        } else {
            details
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(component.name)
                .foregroundStyle(.primary)
            Text(component.licence)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack {
        AcknowledgementsView()
    }
}
