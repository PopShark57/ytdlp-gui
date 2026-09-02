import Foundation
import Testing

@testable import YTDLPGUI

@Suite("Custom argument policy")
struct CustomArgumentPolicyTests {

    @Test("Benign custom arguments pass through unchanged")
    func allowsSafeArguments() {
        let input = #"--extractor-args "youtube:player_client=web" --retries 5"#
        let inspection = CustomArgumentPolicy.inspect(input)
        #expect(!inspection.isBlocked)
        #expect(inspection.safeArguments == ["--extractor-args", "youtube:player_client=web", "--retries", "5"])
        #expect(inspection.errorMessage == nil)
    }

    @Test("--exec and its value are hard-denied")
    func deniesExec() {
        let inspection = CustomArgumentPolicy.inspect(#"--retries 3 --exec "rm -rf /" --no-part"#)
        #expect(inspection.blockedFlags == ["--exec"])
        #expect(inspection.safeArguments == ["--retries", "3", "--no-part"])
        #expect(inspection.errorMessage?.contains("--exec") == true)
    }

    @Test("--exec=value inline form is denied")
    func deniesInlineExec() {
        let inspection = CustomArgumentPolicy.inspect("--exec=echo pwned --retries 1")
        #expect(inspection.blockedFlags == ["--exec"])
        #expect(inspection.safeArguments == ["--retries", "1"])
    }

    @Test("--exec-before-download and --exec-after-download are denied")
    func deniesExecVariants() {
        let before = CustomArgumentPolicy.inspect("--exec-before-download id")
        #expect(before.blockedFlags == ["--exec-before-download"])
        #expect(before.safeArguments.isEmpty)

        let after = CustomArgumentPolicy.inspect("--exec-after-download id")
        #expect(after.blockedFlags == ["--exec-after-download"])
    }

    @Test("--config-locations and --config-location are denied")
    func deniesConfigLocations() {
        let plural = CustomArgumentPolicy.inspect("--config-locations /tmp/evil.conf --retries 1")
        #expect(plural.blockedFlags == ["--config-locations"])
        #expect(plural.safeArguments == ["--retries", "1"])

        let singular = CustomArgumentPolicy.inspect("--config-location /tmp/evil.conf")
        #expect(singular.blockedFlags == ["--config-location"])
    }

    @Test("--plugin-dirs, --alias, --downloader and --netrc-cmd are denied")
    func deniesRelatedEscapeHatches() {
        #expect(CustomArgumentPolicy.inspect("--plugin-dirs /tmp/plugins").blockedFlags == ["--plugin-dirs"])
        #expect(CustomArgumentPolicy.inspect("--alias bad '--exec id'").blockedFlags == ["--alias"])
        #expect(CustomArgumentPolicy.inspect("--downloader /tmp/evil").blockedFlags == ["--downloader"])
        #expect(CustomArgumentPolicy.inspect("--external-downloader /tmp/evil").blockedFlags == ["--external-downloader"])
        #expect(CustomArgumentPolicy.inspect("--netrc-cmd 'cat /etc/passwd'").blockedFlags == ["--netrc-cmd"])
    }

    @Test("sanitize rebuilds a quoted string without denied flags")
    func sanitizedString() {
        let input = #"--retries 5 --exec "touch /tmp/x" --no-part"#
        let sanitized = CustomArgumentPolicy.sanitizedArgumentString(input)
        let again = CustomArgumentPolicy.inspect(sanitized)
        #expect(!again.isBlocked)
        #expect(again.safeArguments == ["--retries", "5", "--no-part"])
    }

    @Test("ArgumentBuilder never emits denied custom flags")
    func argumentBuilderStripsDenied() {
        var options = DownloadOptions()
        options.outputDirectory = URL(fileURLWithPath: "/tmp/downloads")
        options.customArguments = #"--exec "id" --extractor-args "youtube:player_client=web""#

        let arguments = ArgumentBuilder.downloadArguments(url: "https://example.com/v", options: options)
        #expect(!arguments.contains("--exec"))
        #expect(!arguments.contains("id"))
        #expect(arguments.contains("--extractor-args"))
        #expect(arguments.contains("youtube:player_client=web"))
    }
}
