import AppIntents

/// Makes "Download with YTDLP GUI" available in Siri, Spotlight and the Shortcuts app without
/// any setup.
struct YTDLPGUIShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DownloadWithYTDLPGUIIntent(),
            phrases: [
                "Download with \(.applicationName)",
                "Download a link with \(.applicationName)",
                "Save a video with \(.applicationName)",
            ],
            shortTitle: "Download a Link",
            systemImageName: "arrow.down.circle"
        )
    }
}
