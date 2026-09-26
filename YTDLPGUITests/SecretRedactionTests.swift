import Foundation
import Testing

@testable import YTDLPGUI

/// Command lines are shown and logged, and options are kept in history, so passwords and other
/// credentials must be masked or left out of them, while the real values still reach yt-dlp.
@Suite("Secret redaction")
struct SecretRedactionTests {

    private let hidden = ShellQuoting.redactedPlaceholder

    // MARK: - Redaction for display

    @Test("Passwords, user names and codes are masked in every spelling")
    func valuesAreMasked() {
        #expect(ShellQuoting.redactingSecrets(["--password", "x"]) == ["--password", hidden])
        #expect(ShellQuoting.redactingSecrets(["--password=x"]) == ["--password=\(hidden)"])
        #expect(ShellQuoting.redactingSecrets(["-p", "x"]) == ["-p", hidden])
        #expect(ShellQuoting.redactingSecrets(["-2", "123456"]) == ["-2", hidden])
        #expect(ShellQuoting.redactingSecrets(["--twofactor=123456"]) == ["--twofactor=\(hidden)"])
        // Masked as yt-dlp masks them.
        #expect(ShellQuoting.redactingSecrets(["-u", "me", "--username", "me"]) == ["-u", hidden, "--username", hidden])
        #expect(ShellQuoting.redactingSecrets(["--video-password", "v", "--ap-username", "a", "--ap-password", "b"])
            == ["--video-password", hidden, "--ap-username", hidden, "--ap-password", hidden])
        #expect(ShellQuoting.redactingSecrets(["--client-certificate-password", "c"]) == ["--client-certificate-password", hidden])
    }

    @Test("Abbreviations and short-option clusters are read the way yt-dlp reads them")
    func parserSpellings() {
        // yt-dlp accepts any unambiguous prefix of a long option.
        #expect(ShellQuoting.redactingSecrets(["--pass", "x"]) == ["--pass", hidden])
        #expect(ShellQuoting.redactingSecrets(["--pas=x"]) == ["--pas=\(hidden)"])
        // `--pa` is ambiguous (`--paths`), so it isn't a password.
        #expect(ShellQuoting.redactingSecrets(["--pa", "x"]) == ["--pa", "x"])
        // Short options: an attached value, and a value after a cluster of switches.
        #expect(ShellQuoting.redactingSecrets(["-pSECRET"]) == ["-p\(hidden)"])
        #expect(ShellQuoting.redactingSecrets(["-vp", "s"]) == ["-vp", hidden])
        // In `-fp` the `p` is the format's value, not a password.
        #expect(ShellQuoting.redactingSecrets(["-fp", "best"]) == ["-fp", "best"])
    }

    @Test("Proxy credentials are masked and the address kept")
    func proxies() {
        #expect(ShellQuoting.redactingSecrets(["--proxy", "socks5://a:b@h:1"]) == ["--proxy", "socks5://\(hidden)@h:1"])
        #expect(ShellQuoting.redactingSecrets(["--proxy=http://u:p@h:8/x@y"]) == ["--proxy=http://\(hidden)@h:8/x@y"])
        #expect(ShellQuoting.redactingSecrets(["--geo-verification-proxy", "http://u:p@geo:1"])
            == ["--geo-verification-proxy", "http://\(hidden)@geo:1"])
        #expect(ShellQuoting.redactingSecrets(["--proxy", "http://proxy.test:3128"]) == ["--proxy", "http://proxy.test:3128"])
    }

    @Test("Credential headers are masked; other headers are kept")
    func headers() {
        #expect(ShellQuoting.redactingSecrets(["--add-headers", "Authorization:Bearer t"]) == ["--add-headers", "Authorization:\(hidden)"])
        #expect(ShellQuoting.redactingSecrets(["--add-headers=cookie: a=b"]) == ["--add-headers=cookie:\(hidden)"])
        #expect(ShellQuoting.redactingSecrets(["--add-headers", "Proxy-Authorization:Basic x"]) == ["--add-headers", "Proxy-Authorization:\(hidden)"])
        #expect(ShellQuoting.redactingSecrets(["--add-headers", "Referer:x"]) == ["--add-headers", "Referer:x"])
    }

    @Test("A missing value, other options and the URL are left alone")
    func edges() {
        #expect(ShellQuoting.redactingSecrets(["--password"]) == ["--password"])
        #expect(ShellQuoting.redactingSecrets(["--no-mtime", "-p"]) == ["--no-mtime", "-p"])
        #expect(ShellQuoting.redactingSecrets([]) == [])
        let argv = ["--no-mtime", "--format", "b", "--", "https://user:pass@example.com/v"]
        #expect(ShellQuoting.redactingSecrets(argv) == argv)
    }

    @Test("The shell-quoted command line shows the masked form")
    func commandLine() {
        let argv = ["--password", "s3cret", "--proxy", "http://u:p@h:1", "--", "https://example.com/v"]
        let line = ShellQuoting.commandLine(executable: "yt-dlp", arguments: ShellQuoting.redactingSecrets(argv))
        #expect(!line.contains("s3cret"))
        #expect(!line.contains("u:p"))
        #expect(line.contains("--password PRIVATE"))
    }

    // MARK: - Removal for storage

    @Test("Secret options are removed with their values, and named once")
    func removal() {
        let result = ShellQuoting.removingSecrets(["--no-mtime", "--password", "x", "-u", "me", "--password=y", "--retries", "3"])
        #expect(result.arguments == ["--no-mtime", "--retries", "3"])
        #expect(result.removed == ["--password", "-u"])

        // Only the password leaves a cluster.
        #expect(ShellQuoting.removingSecrets(["-vp", "x"]).arguments == ["-v"])
        #expect(ShellQuoting.removingSecrets(["-vpSECRET"]).arguments == ["-v"])
        #expect(ShellQuoting.removingSecrets(["--password"]).arguments.isEmpty)
    }

    @Test("Proxies keep their address; only credential headers are removed")
    func removalKeepsWhatIsNotSecret() {
        let proxy = ShellQuoting.removingSecrets(["--proxy", "socks5://a:b@h:1"])
        #expect(proxy.arguments == ["--proxy", "socks5://h:1"])
        #expect(proxy.removed == ["--proxy"])
        #expect(ShellQuoting.removingSecrets(["--proxy", "http://h:1"]).removed.isEmpty)

        let headers = ShellQuoting.removingSecrets(["--add-headers", "Authorization:Bearer t", "--add-headers", "Referer:x"])
        #expect(headers.arguments == ["--add-headers", "Referer:x"])
        #expect(headers.removed == ["--add-headers"])
    }

    @Test("Options lose their credentials, and nothing else changes")
    func optionsRemovingSecrets() {
        var options = DownloadOptions()
        options.customArguments = "--password 's3 cret' --no-mtime --add-headers 'Referer:x'"
        options.proxy = "http://user:pass@proxy.test:3128"
        let stripped = options.removingSecrets()
        #expect(stripped.options.customArguments == "--no-mtime --add-headers Referer:x")
        #expect(stripped.options.proxy == "http://proxy.test:3128")
        #expect(stripped.removed == ["--password", "--proxy"])

        var plain = DownloadOptions()
        plain.customArguments = "--retries 'a b'"
        #expect(plain.removingSecrets().options == plain)
        #expect(plain.removingSecrets().removed.isEmpty)
    }

    @Test("A history entry records which options lost their credentials")
    func historyEntryRemovesSecrets() throws {
        var options = DownloadOptions()
        options.customArguments = "-2 123456 --no-mtime"
        var entry = HistoryEntry(title: "Clip", sourceURL: "https://example.com/v", formatSummary: "Best", kind: .video, succeeded: true, options: options)
        entry.removeSecrets()
        #expect(entry.options?.customArguments == "--no-mtime")
        #expect(entry.removedSecretOptions == ["-2"])

        // Round-trips, and an entry without credentials is untouched.
        let decoded = try JSONDecoder().decode(HistoryEntry.self, from: JSONEncoder().encode(entry))
        #expect(decoded == entry)
        var clean = HistoryEntry(title: "Clip", sourceURL: "https://example.com/v", formatSummary: "Best", kind: .video, succeeded: true, options: DownloadOptions())
        clean.removeSecrets()
        #expect(clean.removedSecretOptions == nil)
    }
}
