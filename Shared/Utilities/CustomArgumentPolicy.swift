import Foundation

/// Denylist for yt-dlp custom-argument tokens that can execute commands or load
/// arbitrary configuration / plugins.
///
/// The App Sandbox is intentionally off so yt-dlp can run, which makes `--exec`
/// and `--config-locations` especially dangerous: they would run with the user's
/// full privileges. Commands are still launched with `Process.arguments` (no
/// shell); this policy only decides which *tokens* may appear in that argv.
///
/// Inside the iOS app (`Context.embedded`) a few more options are denied: ones that would
/// launch programs, read browser profiles or replace yt-dlp itself, none of which can work
/// there and some of which would quietly break the engine.
enum CustomArgumentPolicy {

    /// Where the arguments are going, which decides what is allowed.
    enum Context: Sendable {
        /// A separately installed yt-dlp run as a child process (macOS).
        case externalProcess
        /// yt-dlp running inside the app (iOS), where anything that launches programs, reads
        /// browser profiles or replaces yt-dlp itself cannot work.
        case embedded
    }

    /// A denied flag and how many following argv tokens it consumes as values.
    struct DeniedOption: Sendable {
        /// Canonical long-option spellings (including aliases).
        var names: Set<String>
        /// Number of separate argv values that belong to the flag (0 for bare switches).
        var valueArity: Int
        var reason: String
        /// What to do instead, when the app offers its own way to get the same result.
        var alternative: String?

        init(names: Set<String>, valueArity: Int, reason: String, alternative: String? = nil) {
            self.names = names
            self.valueArity = valueArity
            self.reason = reason
            self.alternative = alternative
        }
    }

    /// Result of scanning a free-form custom-arguments string.
    struct Inspection: Equatable, Sendable {
        /// Tokens safe to append to `Process.arguments`.
        var safeArguments: [String]
        /// Canonical denied flag names that were found (e.g. `--exec`).
        var blockedFlags: [String]
        /// The context the arguments were checked for, which decides how the refusal is worded.
        var context: Context = .externalProcess

        var isBlocked: Bool { !blockedFlags.isEmpty }

        /// User-facing explanation when anything was blocked.
        var errorMessage: String? {
            guard isBlocked else { return nil }
            let listed = blockedFlags.map { "‘\($0)’" }.joined(separator: ", ")
            let plural = blockedFlags.count == 1 ? "" : "s"
            switch context {
            case .externalProcess:
                return "Blocked dangerous yt-dlp option\(plural): \(listed). "
                    + "Options that run commands or load arbitrary config/plugins are not allowed "
                    + "in Custom Arguments (sandbox is disabled)."
            case .embedded:
                // Where the app has its own equivalent, say where it is, so the user isn't left
                // with a refusal and no way forward.
                var alternatives: [String] = []
                for flag in blockedFlags {
                    if let alternative = CustomArgumentPolicy.deniedOption(named: flag, in: .embedded)?.alternative,
                       !alternatives.contains(alternative) {
                        alternatives.append(alternative)
                    }
                }
                return (["Blocked yt-dlp option\(plural): \(listed). "
                    + "Custom Arguments can't include options that run programs, load code or "
                    + "configuration, or can't work inside the iOS app."] + alternatives)
                    .joined(separator: " ")
            }
        }
    }

    /// Flags that must never reach yt-dlp via the GUI escape hatch.
    static let deniedOptions: [DeniedOption] = [
        DeniedOption(
            names: ["--exec"],
            valueArity: 1,
            reason: "runs an arbitrary command after download stages"
        ),
        DeniedOption(
            names: ["--exec-before-download"],
            valueArity: 1,
            reason: "runs an arbitrary command before downloading"
        ),
        DeniedOption(
            names: ["--exec-after-download"],
            valueArity: 1,
            reason: "legacy/alias form for post-download command execution"
        ),
        DeniedOption(
            names: ["--config-locations", "--config-location"],
            valueArity: 1,
            reason: "loads an arbitrary config file that can reintroduce --exec and other options"
        ),
        DeniedOption(
            names: ["--plugin-dirs"],
            valueArity: 1,
            reason: "loads third-party plugin code into yt-dlp"
        ),
        DeniedOption(
            names: ["--alias"],
            valueArity: 2,
            reason: "can redefine options into an --exec or config-loading chain"
        ),
        DeniedOption(
            names: ["--downloader", "--external-downloader"],
            valueArity: 1,
            reason: "can point yt-dlp at an arbitrary executable path"
        ),
        DeniedOption(
            names: ["--netrc-cmd"],
            valueArity: 1,
            reason: "executes a shell command to obtain credentials"
        ),
        DeniedOption(
            names: ["--use-postprocessor"],
            valueArity: 1,
            reason: "can load the built-in Exec postprocessor to run an arbitrary command"
        ),
    ]

    /// Flags denied only inside the iOS app, on top of `deniedOptions`.
    static let embeddedDeniedOptions: [DeniedOption] = [
        DeniedOption(
            names: ["--cookies-from-browser"],
            valueArity: 1,
            reason: "reads browser profiles, which the iOS app can't access",
            alternative: "To sign in, import a cookies.txt file in Settings › Cookies."
        ),
        DeniedOption(
            names: ["--ffmpeg-location"],
            valueArity: 1,
            reason: "points at an ffmpeg program, which can't run on iOS"
        ),
        DeniedOption(
            names: ["-U", "--update"],
            valueArity: 0,
            reason: "replaces yt-dlp itself with an unverified download",
            alternative: updateAlternative
        ),
        DeniedOption(
            names: ["--update-to"],
            valueArity: 1,
            reason: "replaces yt-dlp itself with an unverified download",
            alternative: updateAlternative
        ),
        DeniedOption(
            names: ["--js-runtimes"],
            valueArity: 1,
            reason: "selects an external JavaScript runtime, which can't run on iOS"
        ),
        DeniedOption(
            names: ["--no-js-runtimes"],
            valueArity: 0,
            reason: "turns off the built-in JavaScript runtime that YouTube downloads need"
        ),
        DeniedOption(
            names: ["--remote-components"],
            valueArity: 1,
            reason: "downloads JavaScript code to run at download time"
        ),
    ]

    private static let updateAlternative = "To update yt-dlp, use Settings › Engine › Check for Updates."

    /// Every option denied in `context`.
    static func deniedOptions(for context: Context) -> [DeniedOption] {
        switch context {
        case .externalProcess: deniedOptions
        case .embedded: deniedOptions + embeddedDeniedOptions
        }
    }

    /// The denied option spelled `name` in `context`, if any.
    static func deniedOption(named name: String, in context: Context) -> DeniedOption? {
        switch context {
        case .externalProcess: deniedByName[name]
        case .embedded: embeddedDeniedByName[name]
        }
    }

    private static let deniedByName = lookupTable(deniedOptions(for: .externalProcess))
    private static let embeddedDeniedByName = lookupTable(deniedOptions(for: .embedded))

    /// Shortest prefixes that yt-dlp 2026.8.19 resolves to these options. Exact spellings
    /// are checked first, so existing aliases keep their existing names in error messages.
    /// A shorter prefix is ambiguous with another yt-dlp option and cannot invoke the denial.
    private static let deniedLongAbbreviations: [(name: String, shortest: String)] = [
        ("--exec-before-download", "--exec-"),
        ("--exec-after-download", "--exec-a"), // Legacy spelling, absent from the vendored parser.
        ("--config-locations", "--conf"),
        ("--plugin-dirs", "--plu"),
        ("--alias", "--ali"),
        ("--netrc-cmd", "--netrc-c"),
        ("--use-postprocessor", "--use-p"),
        ("--cookies-from-browser", "--cookies-"),
        ("--ffmpeg-location", "--ff"),
        ("--update-to", "--update-"),
        ("--js-runtimes", "--j"),
        ("--no-js-runtimes", "--no-j"),
        ("--remote-components", "--remot"),
    ]

    /// In a short-option cluster, optparse treats all remaining characters as the value of
    /// the first value-taking flag. For example, `-fU` is a format value, not `-U`.
    private static let shortOptionsTakingAttachedValues: Set<Character> = [
        "2", "I", "N", "O", "P", "R", "S", "a", "f", "o", "p", "r", "t", "u",
    ]

    private static func lookupTable(_ options: [DeniedOption]) -> [String: DeniedOption] {
        var map: [String: DeniedOption] = [:]
        for option in options {
            for name in option.names {
                map[name] = option
            }
        }
        return map
    }

    // MARK: - Public API

    /// Inspects a free-form custom-arguments string after `ShellQuoting.split`.
    static func inspect(_ input: String, context: Context = .externalProcess) -> Inspection {
        inspect(arguments: ShellQuoting.split(input), context: context)
    }

    /// Inspects an already-split argument vector.
    static func inspect(arguments: [String], context: Context = .externalProcess) -> Inspection {
        var safe: [String] = []
        var blocked: [String] = []
        var index = 0

        while index < arguments.count {
            let token = arguments[index]
            let (flagName, inlineValue) = splitFlag(token)

            if let (deniedName, option) = deniedMatch(for: flagName, in: context) {
                if !blocked.contains(deniedName) {
                    blocked.append(deniedName)
                }
                // Drop the flag token itself.
                index += 1
                // Skip its separate value tokens; `--flag=value` already supplied the first inline.
                var remaining = option.valueArity - (inlineValue == nil ? 0 : 1)
                while remaining > 0, index < arguments.count, !looksLikeFlag(arguments[index]) {
                    index += 1
                    remaining -= 1
                }
                // Bare words left after the values would reach yt-dlp as extra URLs. They are
                // almost always the unquoted rest of the blocked value (`--exec=echo pwned`), so
                // drop them too, up to the next flag or a `--` that ends option parsing.
                while index < arguments.count, isBareWord(arguments[index]) {
                    index += 1
                }
                continue
            }

            safe.append(token)
            index += 1
        }

        return Inspection(safeArguments: safe, blockedFlags: blocked, context: context)
    }

    /// Arguments safe to hand to yt-dlp — blocked flags and their values removed.
    static func safeArguments(from input: String, context: Context = .externalProcess) -> [String] {
        inspect(input, context: context).safeArguments
    }

    /// Rewrites a custom-arguments string with denied flags stripped (for history replay).
    static func sanitizedArgumentString(_ input: String, context: Context = .externalProcess) -> String {
        let inspection = inspect(input, context: context)
        guard inspection.isBlocked else { return input }
        return inspection.safeArguments.map(ShellQuoting.quote).joined(separator: " ")
    }

    /// Clear error when the input contains denied flags; otherwise `nil`.
    static func validationMessage(for input: String, context: Context = .externalProcess) -> String? {
        inspect(input, context: context).errorMessage
    }

    // MARK: - Helpers

    private static func deniedMatch(for name: String, in context: Context) -> (String, DeniedOption)? {
        if let option = deniedOption(named: name, in: context) {
            return (name, option)
        }

        if name.hasPrefix("--") {
            for (canonical, shortest) in deniedLongAbbreviations
            where name.hasPrefix(shortest) && canonical.hasPrefix(name) {
                if let option = deniedOption(named: canonical, in: context) {
                    return (canonical, option)
                }
            }
        } else if name.hasPrefix("-") {
            for character in name.dropFirst() {
                let shortName = "-\(character)"
                if let option = deniedOption(named: shortName, in: context) {
                    return (shortName, option)
                }
                if shortOptionsTakingAttachedValues.contains(character) {
                    break
                }
            }
        }

        return nil
    }

    /// Splits `--flag=value` into (`--flag`, `value`); bare flags yield a nil value.
    private static func splitFlag(_ token: String) -> (name: String, inlineValue: String?) {
        guard looksLikeFlag(token) else { return (token, nil) }
        if let eq = token.firstIndex(of: "=") {
            let name = String(token[..<eq])
            let value = String(token[token.index(after: eq)...])
            return (name, value)
        }
        return (token, nil)
    }

    private static func looksLikeFlag(_ token: String) -> Bool {
        token.hasPrefix("-") && token != "-" && token != "--"
    }

    /// A token yt-dlp would take as a positional (a URL) when no option is expecting a value.
    /// `--` is excluded: dropping it would turn the words after it into options.
    private static func isBareWord(_ token: String) -> Bool {
        !looksLikeFlag(token) && token != "--"
    }
}
