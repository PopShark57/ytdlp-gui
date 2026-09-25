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
        #expect(CustomArgumentPolicy.sanitizedArgumentString("--exec=echo pwned --retries 1") == "--retries 1")
    }

    // yt-dlp takes bare words after a flag's values as URLs, so leftovers of an unquoted
    // blocked command must not survive as extra downloads.
    @Test("Unquoted words after a denied flag's values are dropped up to the next flag")
    func deniesUnquotedRemainder() {
        let spaced = CustomArgumentPolicy.inspect("--retries 3 --exec echo pwned --no-part")
        #expect(spaced.blockedFlags == ["--exec"])
        #expect(spaced.safeArguments == ["--retries", "3", "--no-part"])

        let trailing = CustomArgumentPolicy.inspect("--netrc-cmd=cat /etc/passwd")
        #expect(trailing.blockedFlags == ["--netrc-cmd"])
        #expect(trailing.safeArguments.isEmpty)

        let multiValue = CustomArgumentPolicy.inspect("--alias=bad id pwned --retries 1")
        #expect(multiValue.blockedFlags == ["--alias"])
        #expect(multiValue.safeArguments == ["--retries", "1"])
    }

    @Test("Dropping leftover words stops at --, so later words stay positionals")
    func keepsEndOfOptionsMarker() {
        let inspection = CustomArgumentPolicy.inspect("--exec echo pwned -- --no-part")
        #expect(inspection.blockedFlags == ["--exec"])
        #expect(inspection.safeArguments == ["--", "--no-part"])
    }

    @Test("Leftover words are dropped in every context", arguments: [
        CustomArgumentPolicy.Context.externalProcess,
        .embedded,
    ])
    func deniesUnquotedRemainderInContext(_ context: CustomArgumentPolicy.Context) {
        let inspection = CustomArgumentPolicy.inspect("--exec=echo pwned --retries 1", context: context)
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

    @Test("yt-dlp long-option abbreviations are denied by their resolved names")
    func deniesLongAbbreviations() {
        let cases: [(arguments: [String], flag: String)] = [
            (["--exec-b", "echo hi"], "--exec-before-download"),
            (["--netrc-c=cat x"], "--netrc-cmd"),
            (["--conf", "/tmp/evil.conf"], "--config-locations"),
            (["--config-location", "/tmp/evil.conf"], "--config-location"),
            (["--plu", "/tmp/plugins"], "--plugin-dirs"),
            (["--ali", "bad", "exec id"], "--alias"),
        ]
        for (arguments, flag) in cases {
            for context in [CustomArgumentPolicy.Context.externalProcess, .embedded] {
                let inspection = CustomArgumentPolicy.inspect(arguments: arguments + ["--retries", "1"], context: context)
                #expect(inspection.blockedFlags == [flag])
                #expect(inspection.safeArguments == ["--retries", "1"])
            }
        }
        #expect(CustomArgumentPolicy.validationMessage(for: "--exec-b 'echo hi'")?
            .hasPrefix("Blocked dangerous yt-dlp option: ‘--exec-before-download’.") == true)
    }

    @Test("--use-postprocessor and its abbreviation cannot invoke Exec")
    func deniesUsePostprocessor() {
        for context in [CustomArgumentPolicy.Context.externalProcess, .embedded] {
            for spelling in ["--use-postprocessor", "--use-p"] {
                for value in [
                    "Exec:exec_cmd=echo pwned;when=after_move",
                    "ExecPP:exec_cmd=echo pwned",
                    "ExecAfterDownload:exec_cmd=echo pwned",
                    "ExecAfterDownloadPP:exec_cmd=echo pwned",
                ] {
                    let inspection = CustomArgumentPolicy.inspect(
                        arguments: [spelling, value, "--retries", "1"], context: context
                    )
                    #expect(inspection.blockedFlags == ["--use-postprocessor"])
                    #expect(inspection.safeArguments == ["--retries", "1"])
                }
            }
            let inline = CustomArgumentPolicy.inspect(
                arguments: ["--use-p=Exec:exec_cmd=echo pwned", "--retries", "2"], context: context
            )
            #expect(inline.blockedFlags == ["--use-postprocessor"])
            #expect(inline.safeArguments == ["--retries", "2"])
        }
        #expect(CustomArgumentPolicy.sanitizedArgumentString(
            "--exec-b 'echo hi' --use-p 'Exec:exec_cmd=echo pwned' --retries 1"
        ) == "--retries 1")
    }

    @Test("Embedded-only long abbreviations stay allowed on macOS")
    func embeddedOnlyAbbreviations() {
        let cases: [(arguments: [String], flag: String)] = [
            (["--cookies-from-b", "safari"], "--cookies-from-browser"),
            (["--ff", "/opt/ffmpeg"], "--ffmpeg-location"),
            (["--update-", "stable"], "--update-to"),
            (["--j", "node"], "--js-runtimes"),
            (["--no-j"], "--no-js-runtimes"),
            (["--remot", "ejs:github"], "--remote-components"),
        ]
        for (arguments, flag) in cases {
            let embedded = CustomArgumentPolicy.inspect(arguments: arguments + ["--retries", "1"], context: .embedded)
            #expect(embedded.blockedFlags == [flag])
            #expect(embedded.safeArguments == ["--retries", "1"])

            let external = CustomArgumentPolicy.inspect(arguments: arguments, context: .externalProcess)
            #expect(!external.isBlocked)
            #expect(external.safeArguments == arguments)
        }
        #expect(CustomArgumentPolicy.validationMessage(for: "--cookies-from-b safari", context: .embedded)?
            .contains("import a cookies.txt file in Settings › Cookies") == true)
    }

    @Test("A denied short flag in a cluster is detected without treating attached values as flags")
    func embeddedShortClusters() {
        for cluster in ["-Uv", "-vU", "-vvU"] {
            let embedded = CustomArgumentPolicy.inspect(arguments: [cluster, "--retries", "1"], context: .embedded)
            #expect(embedded.blockedFlags == ["-U"])
            #expect(embedded.safeArguments == ["--retries", "1"])
            #expect(!CustomArgumentPolicy.inspect(arguments: [cluster], context: .externalProcess).isBlocked)
        }
        for attachedValue in ["-fU", "-oUpload"] {
            let inspection = CustomArgumentPolicy.inspect(arguments: [attachedValue], context: .embedded)
            #expect(!inspection.isBlocked)
            #expect(inspection.safeArguments == [attachedValue])
        }
    }

    @Test("Benign option names and values remain available")
    func preservesBenignOptions() {
        let arguments = ["--netrc-location", "/tmp/netrc", "--downloader-args", "ffmpeg:-nostdin", "--retries", "5"]
        for context in [CustomArgumentPolicy.Context.externalProcess, .embedded] {
            let inspection = CustomArgumentPolicy.inspect(arguments: arguments, context: context)
            #expect(!inspection.isBlocked)
            #expect(inspection.safeArguments == arguments)
        }
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

    @Test("ArgumentBuilder passes no stray URL left over from a denied flag")
    func argumentBuilderDropsDeniedRemainder() {
        var options = DownloadOptions()
        options.outputDirectory = URL(fileURLWithPath: "/tmp/downloads")
        options.customArguments = "--exec=echo pwned --retries 1"

        let arguments = ArgumentBuilder.downloadArguments(url: "https://example.com/v", options: options)
        #expect(!arguments.contains("pwned"))
        #expect(Array(arguments.suffix(4)) == ["--retries", "1", "--", "https://example.com/v"])
    }

    @Test("ArgumentBuilder strips abbreviated command and postprocessor options")
    func argumentBuilderStripsParserAliases() {
        var options = DownloadOptions()
        options.outputDirectory = URL(fileURLWithPath: "/tmp/downloads")
        options.customArguments = "--exec-b 'echo hi' --use-p 'Exec:exec_cmd=echo pwned' --retries 1"

        let arguments = ArgumentBuilder.downloadArguments(url: "https://example.com/v", options: options)
        #expect(!arguments.contains("--exec-b"))
        #expect(!arguments.contains("--use-p"))
        #expect(!arguments.contains("echo hi"))
        #expect(!arguments.contains("Exec:exec_cmd=echo pwned"))
        #expect(Array(arguments.suffix(4)) == ["--retries", "1", "--", "https://example.com/v"])
    }
}
