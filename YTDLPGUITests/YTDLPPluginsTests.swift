import Foundation
import Testing

@testable import YTDLPGUI

@Suite("yt-dlp plugin")
struct YTDLPPluginsTests {

    /// The plugin in the repository, which the app bundle must carry unchanged.
    private static let repositoryPlugin = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "YTDLPGUI/Resources/ytdlpgui_thumbnail_naming.py")

    private func makeOptions() -> DownloadOptions {
        var options = DownloadOptions()
        options.outputDirectory = URL(fileURLWithPath: "/tmp/downloads")
        return options
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "YTDLPPluginsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Versions

    @Test("Only a yt-dlp with --plugin-dirs is given the plugin", arguments: [
        ("2026.08.19", true),
        ("2024.10.22", true),
        ("2025.10.22.232815", true),
        ("2024.10.21", false),
        ("2023.12.30", false),
        ("", false),
        ("unknown", false),
    ])
    func versionGate(version: String, supported: Bool) {
        #expect(YTDLPPlugins.isSupported(version: version) == supported)
    }

    @Test("An unknown version gets no plugin")
    func unknownVersion() {
        #expect(!YTDLPPlugins.isSupported(version: nil))
    }

    // MARK: - Installing

    @Test("The app bundle carries the plugin")
    func bundled() throws {
        let bundled = try #require(Bundle.main.url(forResource: "ytdlpgui_thumbnail_naming", withExtension: "py"))
        #expect(try Data(contentsOf: bundled) == Data(contentsOf: Self.repositoryPlugin))
    }

    @Test("The plugin is laid out where yt-dlp looks, replacing whatever an earlier build left")
    func install() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let postprocessors = directory.appending(path: "ytdlpgui/yt_dlp_plugins/postprocessor")
        try FileManager.default.createDirectory(at: postprocessors, withIntermediateDirectories: true)
        let stale = postprocessors.appending(path: "renamed_plugin.py")
        try Data("stale".utf8).write(to: stale)

        #expect(YTDLPPlugins.install(into: directory, source: Self.repositoryPlugin) == directory)
        let installed = postprocessors.appending(path: "ytdlpgui_thumbnail_naming.py")
        #expect(try Data(contentsOf: installed) == Data(contentsOf: Self.repositoryPlugin))
        #expect(!FileManager.default.fileExists(atPath: stale.path(percentEncoded: false)))

        // Installing again, as the next launch does, works over the existing copy.
        #expect(YTDLPPlugins.install(into: directory, source: Self.repositoryPlugin) == directory)
    }

    @Test("Without the plugin source there is no plugin folder")
    func missingSource() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(YTDLPPlugins.install(into: directory, source: nil) == nil)
    }

    // MARK: - Arguments

    @Test("Downloads load the plugin and run it before files are named")
    func downloadArguments() throws {
        let plugins = URL(fileURLWithPath: "/tmp/plugins dir")
        let arguments = ArgumentBuilder.downloadArguments(
            url: "https://example.com/v", options: makeOptions(), pluginDirectory: plugins
        )
        let dirs = try #require(arguments.firstIndex(of: "--plugin-dirs"))
        #expect(arguments[dirs + 1] == "/tmp/plugins dir")
        let use = try #require(arguments.firstIndex(of: "--use-postprocessor"))
        #expect(arguments[use + 1] == "YTDLPGUIThumbnailNaming:when=video")
        let separator = try #require(arguments.firstIndex(of: "--"))
        #expect(use < separator)
    }

    @Test("No plugin folder, no plugin arguments")
    func withoutPluginDirectory() {
        let arguments = ArgumentBuilder.downloadArguments(url: "https://example.com/v", options: makeOptions())
        #expect(!arguments.contains("--plugin-dirs"))
        #expect(!arguments.contains("--use-postprocessor"))
    }

    @Test("--no-plugin-dirs in the custom arguments leaves the plugin out rather than failing the download")
    func customNoPluginDirs() {
        var options = makeOptions()
        options.customArguments = "--no-plugin-dirs"
        let arguments = ArgumentBuilder.downloadArguments(
            url: "https://example.com/v", options: options, pluginDirectory: URL(fileURLWithPath: "/tmp/plugins")
        )
        #expect(!arguments.contains("--use-postprocessor"))
        #expect(arguments.contains("--no-plugin-dirs"))
    }

    @Test("The service passes its plugin folder to both the download and its preview")
    func service() {
        let service = YTDLPService(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/yt-dlp"),
            ffmpegURL: nil,
            pluginDirectory: URL(fileURLWithPath: "/tmp/plugins")
        )
        #expect(service.previewCommand(url: "https://example.com/v", options: makeOptions())
            .contains("--plugin-dirs /tmp/plugins"))
    }
}
