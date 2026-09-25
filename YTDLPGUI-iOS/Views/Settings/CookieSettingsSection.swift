import SwiftUI
import UniformTypeIdentifiers

/// The imported cookies.txt: what's in it, and how to import, replace or remove it.
///
/// iOS apps can't read another browser's cookies, which is how the Mac app signs in, so the
/// iPhone and iPad version takes a cookies.txt exported from a desktop browser instead.
struct CookieSettingsSection: View {
    @Environment(AppModel.self) private var model

    @State private var isImporting = false
    @State private var confirmsRemoval = false
    @State private var pickerError: String?

    private var cookies: CookieStore { model.cookies }

    var body: some View {
        Section {
            status

            Button {
                pickerError = nil
                isImporting = true
            } label: {
                Label(
                    cookies.summary == nil ? "Import cookies.txt…" : "Replace cookies.txt…",
                    systemImage: "square.and.arrow.down"
                )
            }
            .accessibilityHint("Chooses a cookies.txt file from Files")
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.plainText, .data]) { result in
                switch result {
                case .success(let url):
                    model.cookies.importCookies(from: url)
                case .failure(let error):
                    pickerError = "The file couldn't be opened: \(error.localizedDescription)"
                }
            }

            if cookies.summary != nil {
                Button(role: .destructive) {
                    confirmsRemoval = true
                } label: {
                    Label("Remove Cookies", systemImage: "trash")
                }
                .confirmationDialog(
                    "Remove the imported cookies?",
                    isPresented: $confirmsRemoval,
                    titleVisibility: .visible
                ) {
                    Button("Remove Cookies", role: .destructive) {
                        model.cookies.removeCookies()
                    }
                } message: {
                    Text("Downloads that need you to be signed in will stop working until you import cookies again.")
                }
            }

            if let error = pickerError ?? cookies.lastError {
                WarningRow(message: error, tint: .red)
            }
        } header: {
            Text("Cookies")
        } footer: {
            Text("Cookies let yt-dlp download private, members-only and age-restricted media from sites where you're signed in. To get a cookies.txt file, sign in on a computer, export the site's cookies with a “cookies.txt” browser extension, then AirDrop the file to this device or save it to Files. Keep it private: it works like a password.")
        }
    }

    @ViewBuilder
    private var status: some View {
        if let summary = cookies.summary {
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(summary.cookieCount == 1 ? "1 cookie" : "\(summary.cookieCount.formatted()) cookies")
                } icon: {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
                .font(.body.weight(.medium))

                if !summary.domains.isEmpty {
                    Text(domainList(summary.domains))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text("Imported \(Format.relativeDate(summary.importedAt))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
        } else {
            Label {
                Text("No cookies imported")
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "key.slash")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func domainList(_ domains: [String]) -> String {
        let shown = domains.prefix(4).joined(separator: ", ")
        let remaining = domains.count - 4
        return remaining > 0 ? "\(shown) and \(remaining.formatted()) more" : shown
    }
}

/// The cookie settings on their own screen, reached from Advanced Options.
struct CookiesView: View {
    var body: some View {
        Form {
            CookieSettingsSection()
        }
        .readableContentWidth()
        .navigationTitle("Cookies")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        CookiesView()
    }
    .environment(AppModel())
}
