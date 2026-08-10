import AppKit
import Foundation

/// Finder and pasteboard helpers.
@MainActor
enum FinderIntegration {

    /// Selects a file in Finder, falling back to opening the enclosing folder if the file has
    /// since been moved or deleted.
    static func reveal(_ url: URL) {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        let parent = url.deletingLastPathComponent()
        if fileManager.fileExists(atPath: parent.path(percentEncoded: false)) {
            NSWorkspace.shared.open(parent)
        }
    }

    /// Opens a file with the user's default application.
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Presents the standard folder chooser.
    static func chooseDirectory(startingAt current: URL?, prompt: String = "Choose") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = "Choose where downloads should be saved"
        if let current, FileManager.default.fileExists(atPath: current.path(percentEncoded: false)) {
            panel.directoryURL = current
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Presents a file chooser for picking a command-line executable.
    ///
    /// Executables usually live in hidden directories such as `/opt/homebrew/bin`, so the panel
    /// shows hidden files and accepts a typed path.
    static func chooseExecutable(startingAt current: URL?, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.message = message
        panel.prompt = "Choose"
        if let current {
            panel.directoryURL = current.deletingLastPathComponent()
        } else {
            panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Presents a save-style chooser for the download archive file.
    static func chooseArchiveFile(startingAt current: URL?) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.message = "Choose where to keep the list of already-downloaded videos"
        panel.prompt = "Choose"
        panel.nameFieldStringValue = current?.lastPathComponent ?? "downloaded.txt"
        if let current {
            panel.directoryURL = current.deletingLastPathComponent()
        }
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Reading and writing the general pasteboard.
@MainActor
enum Pasteboard {

    static func string() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// The first plausible media URL on the pasteboard, if any.
    static func firstURL() -> String? {
        guard let text = string() else { return nil }
        return URLDetection.firstURL(in: text)
    }
}
