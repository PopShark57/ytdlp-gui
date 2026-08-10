import Foundation
import Testing

@testable import YTDLPGUI

@Suite("Line splitting")
struct LineSplitterTests {

    @Test("Complete lines are returned and the terminator is dropped")
    func simpleLines() {
        var splitter = LineSplitter()
        let lines = splitter.append(Data("one\ntwo\n".utf8))
        #expect(lines == ["one", "two"])
        #expect(splitter.flush() == nil)
    }

    @Test("A partial line is held back until its terminator arrives")
    func partialLine() {
        var splitter = LineSplitter()
        #expect(splitter.append(Data("par".utf8)).isEmpty)
        #expect(splitter.append(Data("tial\n".utf8)) == ["partial"])
    }

    @Test("Carriage returns terminate a line too, so redrawn progress doesn't pile up")
    func carriageReturns() {
        var splitter = LineSplitter()
        #expect(splitter.append(Data("a\rb\r".utf8)) == ["a", "b"])
    }

    @Test("CRLF produces one line, not one line plus an empty one")
    func windowsLineEndings() {
        var splitter = LineSplitter()
        #expect(splitter.append(Data("a\r\nb\r\n".utf8)) == ["a", "b"])
    }

    @Test("A CRLF split across two reads is still one line")
    func splitCRLF() {
        var splitter = LineSplitter()
        #expect(splitter.append(Data("a\r".utf8)) == ["a"])
        #expect(splitter.append(Data("\nb\n".utf8)) == ["b"])
    }

    @Test("Multi-byte characters split across reads are reassembled intact")
    func multiByteAcrossChunks() {
        var splitter = LineSplitter()
        // "é" is 0xC3 0xA9; the boundary falls between its two bytes.
        let full = Array("café\n".utf8)
        let boundary = full.count - 3
        #expect(splitter.append(Data(full[..<boundary])).isEmpty)
        #expect(splitter.append(Data(full[boundary...])) == ["café"])
    }

    @Test("Unterminated trailing output is surfaced by flush, never silently lost")
    func flushTrailing() {
        var splitter = LineSplitter()
        #expect(splitter.append(Data("done".utf8)).isEmpty)
        #expect(splitter.flush() == "done")
        #expect(splitter.flush() == nil)
    }

    @Test("Invalid UTF-8 degrades to replacement characters rather than dropping the line")
    func invalidUTF8() {
        var splitter = LineSplitter()
        var bytes = Data("ok".utf8)
        bytes.append(0xFF)
        bytes.append(contentsOf: Data("\n".utf8))
        let lines = splitter.append(bytes)
        #expect(lines.count == 1)
        #expect(lines[0].hasPrefix("ok"))
    }
}

@Suite("Argument string splitting")
struct ShellQuotingTests {

    @Test("Plain arguments split on whitespace")
    func plainSplit() {
        #expect(ShellQuoting.split("--retries 5 --no-part") == ["--retries", "5", "--no-part"])
    }

    @Test("Double quotes keep spaces together")
    func doubleQuotes() {
        #expect(
            ShellQuoting.split(#"--user-agent "Mozilla 5.0 (Macintosh)""#)
                == ["--user-agent", "Mozilla 5.0 (Macintosh)"]
        )
    }

    @Test("Single quotes are literal")
    func singleQuotes() {
        #expect(ShellQuoting.split("--x 'a b' c") == ["--x", "a b", "c"])
    }

    @Test("Backslash escapes a space outside quotes")
    func escapedSpace() {
        #expect(ShellQuoting.split(#"a\ b c"#) == ["a b", "c"])
    }

    @Test("An empty quoted string is preserved as an empty argument")
    func emptyQuotedArgument() {
        #expect(ShellQuoting.split(#"--flag "" x"#) == ["--flag", "", "x"])
    }

    @Test("Blank input yields no arguments")
    func blankInput() {
        #expect(ShellQuoting.split("   ").isEmpty)
        #expect(ShellQuoting.split("").isEmpty)
    }

    @Test("Newlines and tabs separate arguments just like spaces")
    func whitespaceVariants() {
        #expect(ShellQuoting.split("a\nb\tc") == ["a", "b", "c"])
    }

    @Test("Shell metacharacters are never interpreted, only carried through verbatim")
    func metacharactersAreInert() {
        // The value must reach Process.arguments unchanged; nothing expands it.
        let parsed = ShellQuoting.split("--output '$(whoami); rm -rf ~'")
        #expect(parsed == ["--output", "$(whoami); rm -rf ~"])
    }

    @Test("Display quoting round-trips back to the original argument")
    func quotingRoundTrip() {
        let originals = [
            "simple",
            "with space",
            "it's",
            "$(dangerous)",
            "semi;colon",
            "",
            "%(title)s.%(ext)s",
        ]
        for original in originals {
            let quoted = ShellQuoting.quote(original)
            #expect(ShellQuoting.split(quoted) == (original.isEmpty ? [""] : [original]))
        }
    }

    @Test("Safe arguments stay unquoted so the preview reads naturally")
    func safeArgumentsAreBare() {
        #expect(ShellQuoting.quote("--no-playlist") == "--no-playlist")
        #expect(ShellQuoting.quote("/opt/homebrew/bin/yt-dlp") == "/opt/homebrew/bin/yt-dlp")
        #expect(ShellQuoting.quote("has space") == "'has space'")
    }
}

@Suite("URL detection")
struct URLDetectionTests {

    @Test("Ordinary web addresses are accepted")
    func acceptsHTTPURLs() {
        #expect(URLDetection.isLikelyMediaURL("https://www.youtube.com/watch?v=abc"))
        #expect(URLDetection.isLikelyMediaURL("http://example.com/video"))
    }

    @Test("Non-web text is rejected")
    func rejectsNonURLs() {
        #expect(!URLDetection.isLikelyMediaURL("not a url"))
        #expect(!URLDetection.isLikelyMediaURL(""))
        #expect(!URLDetection.isLikelyMediaURL("file:///etc/passwd"))
        #expect(!URLDetection.isLikelyMediaURL("ftp://example.com/x"))
        #expect(!URLDetection.isLikelyMediaURL("javascript:alert(1)"))
    }

    @Test("Unfamiliar hosts are allowed, because yt-dlp supports far more sites than we could list")
    func allowsUnknownHosts() {
        #expect(URLDetection.isLikelyMediaURL("https://some-obscure-site.example/v/123"))
    }

    @Test("A URL embedded in a sentence is found")
    func findsURLInProse() {
        let text = "look at this https://example.com/watch?v=xyz it's great"
        #expect(URLDetection.firstURL(in: text) == "https://example.com/watch?v=xyz")
    }

    @Test("One URL per line is the multi-download case")
    func multipleLines() {
        let text = """
        https://example.com/a
        https://example.com/b

        https://example.com/c
        """
        #expect(URLDetection.urlsFromLines(text).count == 3)
    }

    @Test("Duplicates found by the detector are collapsed")
    func deduplicates() {
        let text = "https://example.com/a and again https://example.com/a"
        #expect(URLDetection.allURLs(in: text) == ["https://example.com/a"])
    }
}
