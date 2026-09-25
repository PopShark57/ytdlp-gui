import Foundation
import Testing

@testable import YTDLPGUI

/// iOS moves an app's container on every update or reinstall, so history has to find files by
/// where they sit inside Documents rather than by the absolute path recorded at the time.
@Suite("History entry file location")
struct HistoryEntryLocationTests {

    /// A throwaway "current container" with a Documents folder, removed after each test.
    private final class Container {
        let root: URL
        let documents: URL

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "ytdlpgui-history-\(UUID().uuidString)", directoryHint: .isDirectory)
            documents = root.appending(path: "Documents", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        @discardableResult
        func makeFile(_ relativePath: String) throws -> URL {
            let url = documents.appending(path: relativePath, directoryHint: .notDirectory)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("clip".utf8).write(to: url)
            return url
        }
    }

    private let staleContainer = "/private/var/mobile/Containers/Data/Application/0B4C9D3E-OLD-INSTALL"

    @Test("A path that still exists is used as is")
    func existingPathIsKept() throws {
        let container = try Container()
        let file = try container.makeFile("Clip.mp4")
        let resolved = HistoryEntry.resolve(
            storedPath: file.path(percentEncoded: false),
            documentsDirectory: URL(fileURLWithPath: "/nonexistent/Documents")
        )
        #expect(resolved.path(percentEncoded: false) == file.path(percentEncoded: false))
    }

    @Test("A file from an earlier container is found under the current Documents folder")
    func staleContainerIsReRooted() throws {
        let container = try Container()
        let file = try container.makeFile("Uploader/My Clip #1.mp4")
        let resolved = HistoryEntry.resolve(
            storedPath: staleContainer + "/Documents/Uploader/My Clip #1.mp4",
            documentsDirectory: container.documents
        )
        #expect(resolved.path(percentEncoded: false) == file.path(percentEncoded: false))
    }

    @Test("A subfolder named Documents doesn't hide the container's own")
    func nestedDocumentsFolder() throws {
        let container = try Container()
        let file = try container.makeFile("Documents/Clip.mp4")
        let resolved = HistoryEntry.resolve(
            storedPath: staleContainer + "/Documents/Documents/Clip.mp4",
            documentsDirectory: container.documents
        )
        #expect(resolved.path(percentEncoded: false) == file.path(percentEncoded: false))
    }

    @Test(
        "A file that is really gone keeps its recorded path, so it can be reported as missing",
        arguments: [
            "/private/var/mobile/Containers/Data/Application/0B4C9D3E-OLD-INSTALL/Documents/Gone.mp4",
            "/private/var/mobile/Containers/Data/Application/0B4C9D3E-OLD-INSTALL/Documents",
            "/Users/me/Movies/Clip.mp4",
        ]
    )
    func missingFileKeepsStoredPath(storedPath: String) throws {
        let container = try Container()
        try container.makeFile("Clip.mp4")
        let resolved = HistoryEntry.resolve(storedPath: storedPath, documentsDirectory: container.documents)
        #expect(resolved.path(percentEncoded: false) == storedPath)
    }

    @Test("On the Mac the recorded path is used exactly as stored")
    func macUsesStoredPath() {
        let stored = staleContainer + "/Documents/Clip.mp4"
        let entry = HistoryEntry(
            title: "Clip",
            sourceURL: "https://example.com/v",
            outputPath: stored,
            formatSummary: "Best",
            kind: .video,
            succeeded: true
        )
        #if os(macOS)
        #expect(entry.outputURL == URL(fileURLWithPath: stored))
        #expect(!entry.fileExists)
        #expect(entry.fileName == "Clip.mp4")
        #endif

        let noPath = HistoryEntry(title: "x", sourceURL: "u", outputPath: "", formatSummary: "", kind: .audio, succeeded: false)
        #expect(noPath.outputURL == nil)
        #expect(!noPath.fileExists)
    }
}
