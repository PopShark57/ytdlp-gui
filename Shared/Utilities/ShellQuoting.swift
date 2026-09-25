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
