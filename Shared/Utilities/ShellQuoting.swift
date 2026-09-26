import Foundation

/// Rendering and parsing helpers for command lines.
///
/// Important: nothing in this file is used to *execute* anything. Commands are always
/// launched with `Process.executableURL` + `Process.arguments`, which never involves a
/// shell. These helpers exist purely so the UI can show a copy-pasteable preview of the
/// equivalent command, and so a user's free-form "extra arguments" text can be split into
/// a proper argument vector.
enum ShellQuoting {

    /// Characters that are safe to leave unquoted in a POSIX shell.
    private static let safeCharacters = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-./:=@%+,")

    /// Quotes a single argument for *display* in the command preview.
    static func quote(_ argument: String) -> String {
        if argument.isEmpty { return "''" }
        if argument.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
            return argument
        }
        // Single quotes protect everything except a single quote itself.
        return "'" + argument.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Renders an executable plus arguments as a copy-pasteable command line.
    static func commandLine(executable: String, arguments: [String]) -> String {
        ([executable] + arguments).map(quote).joined(separator: " ")
    }

    // MARK: - Secrets

    /// Shown in place of a secret, the word yt-dlp itself uses.
    static let redactedPlaceholder = "PRIVATE"

    /// The arguments with passwords, one-time codes, proxy credentials and authorisation
    /// headers replaced by `PRIVATE`, for showing or logging a command line. The arguments
    /// actually passed to yt-dlp are never redacted.
    ///
    /// This follows yt-dlp's own `Config.hide_login_info` and goes further: it also masks the
    /// two-factor code, the client certificate's password, the user-info part of proxy URLs and
    /// credential headers. Like yt-dlp's parser it accepts `--option value`, `--option=value`,
    /// unambiguous abbreviations of long options, and short options with an attached value
    /// (`-pSECRET`) or inside a cluster (`-vp SECRET`). Everything after `--` is a URL and is
    /// left alone. Also like yt-dlp, it doesn't know which other options take a value, so a value
    /// that looks like one of these options (`--playlist-items -2`) is taken for it.
    static func redactingSecrets(_ arguments: [String]) -> [String] {
        var result = arguments
        for match in secretMatches(in: arguments) {
            if let inlineValue = match.inlineValue {
                result[match.index] = match.head + match.kind.redact(inlineValue)
            } else if let valueIndex = match.valueIndex {
                result[valueIndex] = match.kind.redact(arguments[valueIndex])
            }
        }
        return result
    }

    /// The arguments without their secrets, for saving: the options `redactingSecrets` masks are
    /// removed along with their values, except proxies, which keep their address and lose only
    /// their user name and password. Also returns the options that lost something, each named
    /// once, as spelled in yt-dlp's documentation (`--password`, `-p`).
    static func removingSecrets(_ arguments: [String]) -> (arguments: [String], removed: [String]) {
        var result = arguments.map { Optional($0) }
        var removed: [String] = []
        for match in secretMatches(in: arguments) {
            let value = match.inlineValue ?? match.valueIndex.map { arguments[$0] }
            switch match.kind {
            case .proxyURL:
                guard let value else { continue }
                let stripped = proxyURLWithoutCredentials(value)
                guard stripped != value else { continue }
                if match.inlineValue != nil {
                    result[match.index] = match.head + stripped
                } else if let valueIndex = match.valueIndex {
                    result[valueIndex] = stripped
                }
            case .header:
                guard let value, isSecretHeader(value) else { continue }
                result[match.index] = nil
                if let valueIndex = match.valueIndex { result[valueIndex] = nil }
            case .value:
                // Other options sharing the token (`-vp secret`) stay.
                if let preceding = match.precedingShortOptions, preceding != "-" {
                    result[match.index] = preceding
                } else {
                    result[match.index] = nil
                }
                if let valueIndex = match.valueIndex { result[valueIndex] = nil }
            }
            if !removed.contains(match.name) { removed.append(match.name) }
        }
        return (result.compactMap { $0 }, removed)
    }

    /// `scheme://user:password@host:port/…` without its `user:password@`.
    static func proxyURLWithoutCredentials(_ url: String) -> String {
        replacingUserInfo(in: url, with: nil)
    }

    /// How a secret-bearing option's value is treated.
    private enum SecretKind {
        /// The whole value is a secret: a password, user name or code.
        case value
        /// A proxy URL, whose user-info part may hold credentials.
        case proxyURL
        /// An HTTP header, secret when it is one of `secretHeaderNames`.
        case header

        func redact(_ value: String) -> String {
            switch self {
            case .value: ShellQuoting.redactedPlaceholder
            case .proxyURL: ShellQuoting.replacingUserInfo(in: value, with: ShellQuoting.redactedPlaceholder)
            case .header: ShellQuoting.redactingHeader(value)
            }
        }
    }

    /// One secret-bearing option found in an argument vector.
    private struct SecretMatch {
        /// The option as yt-dlp's documentation spells it, e.g. `--password` or `-p`.
        var name: String
        var kind: SecretKind
        /// The token holding the option.
        var index: Int
        /// What precedes the value in that token when the value is attached (`--password=`,
        /// `-vp`); the whole token otherwise.
        var head: String
        /// The value, when it is in the same token.
        var inlineValue: String?
        /// The value's own token, when it is separate and present.
        var valueIndex: Int?
        /// For a short option, the options before it in its cluster (`-v` in `-vp`), or `-`
        /// when there are none. `nil` for long options.
        var precedingShortOptions: String?
    }

    /// yt-dlp's `Config.hide_login_info` list, plus the two-factor code, the client
    /// certificate's password, proxies and headers. Each maps to the shortest abbreviation
    /// yt-dlp 2026.8.19 resolves to it; anything shorter is ambiguous with another option.
    private static let secretLongOptions: [(name: String, shortest: String, kind: SecretKind)] = [
        ("--password", "--pas", .value),
        ("--username", "--usern", .value),
        ("--video-password", "--video-p", .value),
        ("--ap-password", "--ap-p", .value),
        ("--ap-username", "--ap-u", .value),
        ("--twofactor", "--tw", .value),
        ("--client-certificate-password", "--client-certificate-p", .value),
        ("--proxy", "--prox", .proxyURL),
        ("--geo-verification-proxy", "--geo-v", .proxyURL),
        ("--add-headers", "--add-h", .header),
    ]

    /// `-p` (password), `-u` (user name) and `-2` (two-factor code).
    private static let secretShortOptions: Set<Character> = ["p", "u", "2"]

    /// Every short option of yt-dlp 2026.8.19 that takes a value. Kept in step with
    /// `CustomArgumentPolicy`'s list of the same.
    private static let shortOptionsTakingValues: Set<Character> = [
        "2", "I", "N", "O", "P", "R", "S", "a", "f", "o", "p", "r", "t", "u",
    ]

    /// Header names whose values are credentials, lowercased.
    private static let secretHeaderNames: Set<String> = ["authorization", "proxy-authorization", "cookie"]

    /// Finds the secret-bearing options the way yt-dlp's parser reads the arguments: the value of
    /// any other option is skipped, and nothing after `--` is an option.
    private static func secretMatches(in arguments: [String]) -> [SecretMatch] {
        var matches: [SecretMatch] = []
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            if token == "--" { break }
            guard token.hasPrefix("-"), token != "-" else {
                index += 1
                continue
            }

            if token.hasPrefix("--") {
                let name: String
                let inlineValue: String?
                if let equals = token.firstIndex(of: "=") {
                    name = String(token[..<equals])
                    inlineValue = String(token[token.index(after: equals)...])
                } else {
                    name = token
                    inlineValue = nil
                }
                guard let option = secretLongOptions.first(where: { option in
                    name == option.name || (name.hasPrefix(option.shortest) && option.name.hasPrefix(name))
                }) else {
                    index += 1
                    continue
                }
                let hasNextToken = index + 1 < arguments.count
                matches.append(SecretMatch(
                    name: option.name,
                    kind: option.kind,
                    index: index,
                    head: inlineValue == nil ? token : name + "=",
                    inlineValue: inlineValue,
                    valueIndex: inlineValue == nil && hasNextToken ? index + 1 : nil,
                    precedingShortOptions: nil
                ))
                index += inlineValue == nil ? 2 : 1
                continue
            }

            // A cluster of short options. optparse gives the rest of the token, or else the next
            // token, to the first option in it that takes a value.
            let characters = Array(token.dropFirst())
            var valueIsNextToken = false
            for (offset, character) in characters.enumerated() {
                let isLast = offset == characters.count - 1
                if secretShortOptions.contains(character) {
                    matches.append(SecretMatch(
                        name: "-\(character)",
                        kind: .value,
                        index: index,
                        head: "-" + String(characters[...offset]),
                        inlineValue: isLast ? nil : String(characters[(offset + 1)...]),
                        valueIndex: isLast && index + 1 < arguments.count ? index + 1 : nil,
                        precedingShortOptions: "-" + String(characters[..<offset])
                    ))
                    valueIsNextToken = isLast
                    break
                }
                if shortOptionsTakingValues.contains(character) {
                    valueIsNextToken = isLast
                    break
                }
            }
            index += valueIsNextToken ? 2 : 1
        }
        return matches
    }

    /// Replaces the `user:password@` of `scheme://user:password@host…` with `replacement`, or
    /// removes it (and its `@`) when `replacement` is `nil`.
    private static func replacingUserInfo(in url: String, with replacement: String?) -> String {
        let authorityStart = url.range(of: "://")?.upperBound ?? url.startIndex
        let authorityEnd = url[authorityStart...].firstIndex(where: { "/?#".contains($0) }) ?? url.endIndex
        guard let at = url[authorityStart..<authorityEnd].lastIndex(of: "@") else { return url }
        guard let replacement else {
            return String(url[..<authorityStart]) + String(url[url.index(after: at)...])
        }
        return String(url[..<authorityStart]) + replacement + String(url[at...])
    }

    private static func isSecretHeader(_ header: String) -> Bool {
        guard let colon = header.firstIndex(of: ":") else { return false }
        return secretHeaderNames.contains(header[..<colon].trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// `Authorization:Bearer …` becomes `Authorization:PRIVATE`; other headers are kept.
    private static func redactingHeader(_ header: String) -> String {
        guard isSecretHeader(header), let colon = header.firstIndex(of: ":") else { return header }
        return String(header[...colon]) + redactedPlaceholder
    }

    /// Splits a free-form argument string into individual arguments.
    ///
    /// Supports single quotes, double quotes and backslash escapes so that users can write
    /// things like `--extractor-args "youtube:player_client=web"`. Unlike a shell this never
    /// performs expansion of variables, globs, subcommands or tildes: the resulting strings
    /// are passed verbatim to `Process.arguments`.
    static func split(_ input: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var hasCurrent = false
        var quote: Character?
        var iterator = input.makeIterator()

        while let character = iterator.next() {
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else if character == "\\", activeQuote == "\"" {
                    if let escaped = iterator.next() {
                        // Inside double quotes a backslash only escapes these characters.
                        if escaped == "\"" || escaped == "\\" || escaped == "$" || escaped == "`" {
                            current.append(escaped)
                        } else {
                            current.append(character)
                            current.append(escaped)
                        }
                    } else {
                        current.append(character)
                    }
                } else {
                    current.append(character)
                }
                continue
            }

            switch character {
            case "'", "\"":
                quote = character
                hasCurrent = true
            case "\\":
                if let escaped = iterator.next() {
                    current.append(escaped)
                    hasCurrent = true
                }
            case " ", "\t", "\n", "\r":
                if hasCurrent {
                    arguments.append(current)
                    current = ""
                    hasCurrent = false
                }
            default:
                current.append(character)
                hasCurrent = true
            }
        }

        if hasCurrent { arguments.append(current) }
        return arguments
    }
}
