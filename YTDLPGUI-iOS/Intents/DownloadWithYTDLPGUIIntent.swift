import AppIntents
import Foundation

/// Video or audio, as offered in Shortcuts.
enum ShortcutDownloadKind: String, AppEnum {
    case video
    case audio

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Download Type"

    static let caseDisplayRepresentations: [ShortcutDownloadKind: DisplayRepresentation] = [
        .video: DisplayRepresentation(title: "Video", image: .init(systemName: "film")),
        .audio: DisplayRepresentation(title: "Audio", image: .init(systemName: "music.note")),
    ]

    var downloadKind: DownloadKind {
        switch self {
        case .video: .video
        case .audio: .audio
        }
    }
}

/// "Download with YTDLP GUI": queues a link and starts downloading it.
///
/// Unlike a `ytdlpgui://` link, which any web page could open and which therefore only fills in
/// the Download screen, a shortcut is something the person built and ran themselves, so it is
/// allowed to start the download.
struct DownloadWithYTDLPGUIIntent: AppIntent {

    static let title: LocalizedStringResource = "Download with YTDLP GUI"

    static let description = IntentDescription(
        "Adds a link to the YTDLP GUI queue and starts downloading it, using the options you downloaded with last.",
        categoryName: "Downloads"
    )

    /// Downloads run inside the app, so it has to be open for them to run.
    static let openAppWhenRun: Bool = true

    @Parameter(
        title: "Link",
        description: "The web address of the video, song or playlist.",
        requestValueDialog: "Which link do you want to download?"
    )
    var url: URL

    @Parameter(
        title: "Download As",
        description: "Video, or only its audio. Leave empty to use the type you downloaded last."
    )
    var kind: ShortcutDownloadKind?

    @Dependency private var model: AppModel

    static var parameterSummary: some ParameterSummary {
        Summary("Download \(\.$url) as \(\.$kind)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let link = url.absoluteString
        guard URLDetection.isLikelyMediaURL(link) else {
            throw DownloadIntentError.notAWebLink
        }
        let added = model.enqueueFromShortcut(url: link, kind: kind?.downloadKind)
        return .result(dialog: added
            ? "Added to the YTDLP GUI queue."
            : "That link is already in the YTDLP GUI queue.")
    }
}

enum DownloadIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notAWebLink

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notAWebLink:
            "That isn't a web link YTDLP GUI can download. Use an address that starts with https://."
        }
    }
}
