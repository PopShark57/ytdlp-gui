import Foundation
import Testing
@testable import YTDLPGUI_iOS

@Suite("ytdlpgui:// links")
struct DownloadLinkRequestTests {

    private func request(_ string: String) throws -> DownloadLinkRequest? {
        DownloadLinkRequest(url: try #require(URL(string: string)))
    }

    @Test("A percent-encoded link and kind are read")
    func basic() throws {
        let parsed = try #require(try request(
            "ytdlpgui://download?url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3Dabc%26t%3D10&kind=audio"
        ))
        #expect(parsed.urls == ["https://www.youtube.com/watch?v=abc&t=10"])
        #expect(parsed.kind == .audio)
    }

    @Test("Both URL forms, any letter case, work")
    func forms() throws {
        #expect(try request("ytdlpgui:///download?url=https%3A%2F%2Fexample.com%2Fa")?.urls == ["https://example.com/a"])
        #expect(try request("YTDLPGUI://Download?URL=https%3A%2F%2Fexample.com%2Fa&Kind=VIDEO")?.kind == .video)
    }

    @Test("Several links are kept in order without duplicates")
    func multipleLinks() throws {
        let parsed = try #require(try request(
            "ytdlpgui://download?url=https%3A%2F%2Fexample.com%2Fa&url=https%3A%2F%2Fexample.com%2Fb&url=https%3A%2F%2Fexample.com%2Fa"
        ))
        #expect(parsed.urls == ["https://example.com/a", "https://example.com/b"])
        #expect(parsed.kind == nil)
    }

    @Test("An unknown kind is ignored rather than rejecting the link")
    func unknownKind() throws {
        let parsed = try #require(try request("ytdlpgui://download?url=https%3A%2F%2Fexample.com%2Fa&kind=podcast"))
        #expect(parsed.kind == nil)
    }

    @Test("Anything that isn't a download of a web link is refused", arguments: [
        "https://example.com/download?url=https%3A%2F%2Fexample.com%2Fa",
        "ytdlpgui://settings?url=https%3A%2F%2Fexample.com%2Fa",
        "ytdlpgui://download",
        "ytdlpgui://download?kind=video",
        "ytdlpgui://download?url=",
        "ytdlpgui://download?url=javascript%3Aalert(1)",
        "ytdlpgui://download?url=file%3A%2F%2F%2Fetc%2Fpasswd",
        "ytdlpgui://download?url=not%20a%20link",
    ])
    func refused(_ link: String) throws {
        #expect(try request(link) == nil)
    }
}
