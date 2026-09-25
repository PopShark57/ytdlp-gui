import Foundation

/// Lenient reading, and crash-proof writing, of the untyped JSON that crosses the Python bridge.
///
/// The host serialises with Python's `json` module, which writes `NaN` and `Infinity` for
/// non-finite floats, and yt-dlp's fields hold whatever type an extractor happened to produce:
/// an id may be a number, a duration a string. Every reader here accepts what it reasonably can
/// and returns `nil` for the rest, so one odd field never costs a whole event.
enum EngineJSON {

    // MARK: - Reading

    /// Parses a JSON object, or returns `nil` for anything else.
    ///
    /// JSON5 parsing is enabled only because it accepts Python's `NaN` and `Infinity` literals,
    /// which strict JSON parsing rejects along with the rest of the document.
    static func object(from data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed])) as? [String: Any]
    }

    /// A string, or a number written as one (ids are sometimes numeric).
    static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber where !isBoolean(number):
            return number.stringValue
        default:
            return nil
        }
    }

    /// Like `string(_:)`, but treats an empty string as absent.
    static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = string(value), !text.isEmpty else { return nil }
        return text
    }

    /// A finite number, from a JSON number or a numeric string. `NaN`, infinities and booleans
    /// are `nil`.
    static func double(_ value: Any?) -> Double? {
        let number: Double?
        switch value {
        case let value as NSNumber where !isBoolean(value):
            number = value.doubleValue
        case let text as String:
            number = Double(text.trimmingCharacters(in: .whitespaces))
        default:
            number = nil
        }
        guard let number, number.isFinite else { return nil }
        return number
    }

    /// A whole number. Fractions are truncated, the way yt-dlp's own templates print them;
    /// anything out of range is `nil` rather than a trap.
    static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber, !isBoolean(number), !CFNumberIsFloatType(number as CFNumber) {
            return number.int64Value
        }
        guard let number = double(value) else { return nil }
        return Int64(exactly: number.rounded(.towardZero))
    }

    static func int(_ value: Any?) -> Int? {
        int64(value).flatMap { Int(exactly: $0) }
    }

    static func bool(_ value: Any?) -> Bool? {
        (value as? NSNumber)?.boolValue
    }

    /// The strings in an array, skipping anything that isn't one: a number in a list of paths or
    /// log lines is a bug to ignore, not something to guess the meaning of.
    static func strings(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    /// A URL with a scheme, from a string.
    static func url(_ value: Any?) -> URL? {
        guard let text = nonEmptyString(value), let url = URL(string: text), url.scheme != nil else {
            return nil
        }
        return url
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    // MARK: - Writing

    /// Serialises a dictionary or array, replacing non-finite numbers with `null`.
    ///
    /// `JSONSerialization` raises an Objective-C exception, which Swift cannot catch, when it
    /// meets `NaN`; yt-dlp's info dictionaries occasionally contain one. Values that still can't
    /// be represented produce `nil`.
    static func data(from object: Any) -> Data? {
        let candidate = JSONSerialization.isValidJSONObject(object) ? object : replacingNonFiniteNumbers(in: object)
        guard JSONSerialization.isValidJSONObject(candidate) else { return nil }
        return try? JSONSerialization.data(withJSONObject: candidate, options: [.withoutEscapingSlashes])
    }

    private static func replacingNonFiniteNumbers(in value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.mapValues(replacingNonFiniteNumbers(in:))
        case let array as [Any]:
            return array.map(replacingNonFiniteNumbers(in:))
        case let number as NSNumber where !isBoolean(number) && !number.doubleValue.isFinite:
            return NSNull()
        default:
            return value
        }
    }
}
