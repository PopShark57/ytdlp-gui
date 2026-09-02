import Foundation

/// Denylist for yt-dlp custom-argument tokens that can execute commands or load
/// arbitrary configuration / plugins.
///
/// The App Sandbox is intentionally off so yt-dlp can run, which makes `--exec`
/// and `--config-locations` especially dangerous: they would run with the user's
/// full privileges. Commands are still launched with `Process.arguments` (no
/// shell); this policy only decides which *tokens* may appear in that argv.
enum CustomArgumentPolicy {

    /// A denied flag and how many following argv tokens it consumes as values.
    struct DeniedOption: Sendable {
        /// Canonical long-option spellings (including aliases).
        var names: Set<String>
        /// Number of separate argv values that belong to the flag (0 for bare switches).
        var valueArity: Int
        var reason: String
    }

    /// Result of scanning a free-form custom-arguments string.
    struct Inspection: Equatable, Sendable {
        /// Tokens safe to append to `Process.arguments`.
        var safeArguments: [String]
        /// Canonical denied flag names that were found (e.g. `--exec`).
        var blockedFlags: [String]

        var isBlocked: Bool { !blockedFlags.isEmpty }

        /// User-facing explanation when anything was blocked.
        var errorMessage: String? {
            guard isBlocked else { return nil }
            let listed = blockedFlags.map { "‘\($0)’" }.joined(separator: ", ")
            return "Blocked dangerous yt-dlp option\(blockedFlags.count == 1 ? "" : "s"): \(listed). "
                + "Options that run commands or load arbitrary config/plugins are not allowed "
                + "in Custom Arguments (sandbox is disabled)."
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
    ]

    private static let deniedByName: [String: DeniedOption] = {
        var map: [String: DeniedOption] = [:]
        for option in deniedOptions {
            for name in option.names {
                map[name] = option
            }
        }
        return map
    }()

    // MARK: - Public API

    /// Inspects a free-form custom-arguments string after `ShellQuoting.split`.
    static func inspect(_ input: String) -> Inspection {
        inspect(arguments: ShellQuoting.split(input))
    }

    /// Inspects an already-split argument vector.
    static func inspect(arguments: [String]) -> Inspection {
        var safe: [String] = []
        var blocked: [String] = []
        var index = 0

        while index < arguments.count {
            let token = arguments[index]
            let (flagName, inlineValue) = splitFlag(token)

            if let option = deniedByName[flagName] {
                if !blocked.contains(flagName) {
                    blocked.append(flagName)
                }
                // Drop the flag token itself.
                index += 1
                // `--flag=value` already consumed its value inline.
                if inlineValue != nil {
                    continue
                }
                // Skip the following arity value tokens when present.
                var remaining = option.valueArity
                while remaining > 0, index < arguments.count, !looksLikeFlag(arguments[index]) {
                    index += 1
                    remaining -= 1
                }
                continue
            }

            safe.append(token)
            index += 1
        }

        return Inspection(safeArguments: safe, blockedFlags: blocked)
    }

    /// Arguments safe to hand to `Process` — blocked flags and their values removed.
    static func safeArguments(from input: String) -> [String] {
        inspect(input).safeArguments
    }

    /// Rewrites a custom-arguments string with denied flags stripped (for history replay).
    static func sanitizedArgumentString(_ input: String) -> String {
        let inspection = inspect(input)
        guard inspection.isBlocked else { return input }
        return inspection.safeArguments.map(ShellQuoting.quote).joined(separator: " ")
    }

    /// Clear error when the input contains denied flags; otherwise `nil`.
    static func validationMessage(for input: String) -> String? {
        inspect(input).errorMessage
    }

    // MARK: - Helpers

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
}
