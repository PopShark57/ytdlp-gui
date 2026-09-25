import Foundation
import Testing

@testable import YTDLPGUI

/// The two places custom arguments can go: a separately installed yt-dlp on the Mac, and the
/// engine embedded in the iOS app, which has to refuse more.
@Suite("Custom argument policy contexts")
struct CustomArgumentPolicyContextTests {

    /// Options only the embedded engine refuses, each followed by an argument that must survive.
    static let embeddedOnly: [(input: String, flag: String)] = [
        ("--cookies-from-browser safari --retries 3", "--cookies-from-browser"),
        ("--cookies-from-browser=chrome:Profile --retries 3", "--cookies-from-browser"),
        ("--ffmpeg-location /opt/homebrew/bin --retries 3", "--ffmpeg-location"),
        ("-U --retries 3", "-U"),
        ("--update --retries 3", "--update"),
        ("--update-to nightly --retries 3", "--update-to"),
        ("--update-to=stable@2026.08.19 --retries 3", "--update-to"),
        ("--js-runtimes node --retries 3", "--js-runtimes"),
        ("--js-runtimes=deno:/usr/local/bin/deno --retries 3", "--js-runtimes"),
        ("--no-js-runtimes --retries 3", "--no-js-runtimes"),
        ("--remote-components ejs:github --retries 3", "--remote-components"),
    ]

    @Test("The embedded engine refuses options that can't work inside the app", arguments: embeddedOnly)
    func embeddedDenies(input: String, flag: String) {
        let inspection = CustomArgumentPolicy.inspect(input, context: .embedded)
        #expect(inspection.blockedFlags == [flag])
        #expect(inspection.safeArguments == ["--retries", "3"])
        #expect(inspection.context == .embedded)
        #expect(CustomArgumentPolicy.safeArguments(from: input, context: .embedded) == ["--retries", "3"])
    }

    @Test("The same options still reach yt-dlp on the Mac", arguments: embeddedOnly)
    func externalProcessAllows(input: String, flag: String) {
        let inspection = CustomArgumentPolicy.inspect(input, context: .externalProcess)
        #expect(!inspection.isBlocked)
        #expect(inspection.safeArguments == ShellQuoting.split(input))
        #expect(CustomArgumentPolicy.validationMessage(for: input, context: .externalProcess) == nil)
    }

    @Test("Leaving out the context means the Mac rules, exactly as before contexts existed")
    func defaultContextIsExternalProcess() {
        for input in ["--exec id --retries 1", "--js-runtimes node", "--alias a b --no-part", "--retries 5"] {
            #expect(CustomArgumentPolicy.inspect(input) == CustomArgumentPolicy.inspect(input, context: .externalProcess))
            #expect(CustomArgumentPolicy.safeArguments(from: input)
                == CustomArgumentPolicy.safeArguments(from: input, context: .externalProcess))
            #expect(CustomArgumentPolicy.sanitizedArgumentString(input)
                == CustomArgumentPolicy.sanitizedArgumentString(input, context: .externalProcess))
        }
        #expect(CustomArgumentPolicy.deniedOptions(for: .externalProcess).map(\.names)
            == CustomArgumentPolicy.deniedOptions.map(\.names))
    }

    @Test("Everything denied on the Mac is denied in the app too")
    func embeddedIncludesExternalDenials() {
        let embeddedNames = Set(CustomArgumentPolicy.deniedOptions(for: .embedded).flatMap(\.names))
        for option in CustomArgumentPolicy.deniedOptions {
            #expect(option.names.isSubset(of: embeddedNames))
        }
        let inspection = CustomArgumentPolicy.inspect(#"--exec "id" --plugin-dirs /tmp/p --retries 1"#, context: .embedded)
        #expect(inspection.blockedFlags == ["--exec", "--plugin-dirs"])
        #expect(inspection.safeArguments == ["--retries", "1"])
    }

    @Test("The Mac refusal is worded exactly as before")
    func externalProcessMessage() {
        #expect(CustomArgumentPolicy.validationMessage(for: "--exec id")
            == "Blocked dangerous yt-dlp option: ‘--exec’. Options that run commands or load arbitrary "
            + "config/plugins are not allowed in Custom Arguments (sandbox is disabled).")
        #expect(CustomArgumentPolicy.validationMessage(for: "--exec id --netrc-cmd x", context: .externalProcess)?
            .hasPrefix("Blocked dangerous yt-dlp options: ‘--exec’, ‘--netrc-cmd’.") == true)
    }

    @Test("The app's refusal explains itself without mentioning the Mac sandbox")
    func embeddedMessage() throws {
        let message = try #require(CustomArgumentPolicy.validationMessage(for: "--update --retries 1", context: .embedded))
        #expect(message.hasPrefix("Blocked yt-dlp option: ‘--update’."))
        #expect(message.contains("run programs, load code or configuration, or can't work inside the iOS app"))
        #expect(!message.contains("sandbox"))
        #expect(message.contains("Settings › Engine › Check for Updates"))
    }

    @Test("Alternatives are offered once each, and only where the app has one")
    func embeddedMessageAlternatives() throws {
        let message = try #require(CustomArgumentPolicy.validationMessage(
            for: "-U --update-to nightly --cookies-from-browser safari --js-runtimes node",
            context: .embedded
        ))
        #expect(message.hasPrefix("Blocked yt-dlp options: ‘-U’, ‘--update-to’, ‘--cookies-from-browser’, ‘--js-runtimes’."))
        #expect(message.components(separatedBy: "Check for Updates").count == 2)
        #expect(message.contains("import a cookies.txt file in Settings › Cookies"))

        let plain = try #require(CustomArgumentPolicy.validationMessage(for: "--js-runtimes node", context: .embedded))
        #expect(!plain.contains("Settings"))
    }

    @Test("History replay strips what the destination would refuse")
    func sanitizingPerContext() {
        let input = "--cookies-from-browser safari --retries 3"
        #expect(CustomArgumentPolicy.sanitizedArgumentString(input, context: .embedded) == "--retries 3")
        // Unchanged on the Mac, where the option is allowed.
        #expect(CustomArgumentPolicy.sanitizedArgumentString(input, context: .externalProcess) == input)
    }
}
