import Foundation

/// Why a request from the host couldn't be carried out before it reached the media or
/// JavaScript code. These are mismatches between the app and the bundled host, never something
/// the person using the app did, but they are still worded so a bug report makes sense.
enum EngineRequestError: LocalizedError, Equatable, Sendable {
    case unreadable
    case missingOperation
    case unknownOperation(String)
    case missingField(operation: String, field: String)
    case invalidField(operation: String, field: String)

    var errorDescription: String? {
        switch self {
        case .unreadable:
            "The app couldn't read a request from the download engine."
        case .missingOperation:
            "The download engine sent a request without saying what it wanted."
        case .unknownOperation(let operation):
            "The download engine asked for “\(operation)”, which this version of the app doesn't support."
        case .missingField(let operation, let field):
            "The download engine's \(operation) request is missing its “\(field)” field."
        case .invalidField(let operation, let field):
            "The download engine's \(operation) request has an unusable “\(field)” field."
        }
    }
}

/// Answers the requests the Python host makes of the app ("Requests" in
/// Docs/iOS-Architecture.md): media work that would have gone to ffmpeg, and JavaScript that
/// would have gone to Deno or Node.
///
/// Every request gets an answer whatever goes wrong, because a request without one would leave
/// a yt-dlp post-processor waiting forever.
struct EngineRequestRouter: Sendable {

    var media: any MediaProcessing
    var javaScript: JavaScriptChallengeRunner

    init(
        media: any MediaProcessing = MediaProcessor.shared,
        javaScript: JavaScriptChallengeRunner = JavaScriptChallengeRunner()
    ) {
        self.media = media
        self.javaScript = javaScript
    }

    /// Carries out one request and returns its JSON answer: `{"ok": true, …}` or
    /// `{"ok": false, "error": "…", "unsupported": bool}`.
    func answer(_ request: Data) async -> Data {
        var reply: [String: Any]
        do {
            guard let object = EngineJSON.object(from: request) else { throw EngineRequestError.unreadable }
            reply = try await perform(RequestFields(object))
            reply["ok"] = true
        } catch {
            reply = Self.failure(error)
        }
        return EngineJSON.data(from: reply) ?? Self.encodingFailure
    }

    // MARK: - Operations

    private func perform(_ request: RequestFields) async throws -> [String: Any] {
        switch request.operation {
        case "js.run":
            let seconds = (request.double("timeout") ?? 60).constrained(to: 1...600)
            let output = try await javaScript.run(try request.string("script"), timeout: .seconds(seconds))
            return ["stdout": output.stdout, "stderr": output.standardError.joined(separator: "\n")]

        case "media.merge":
            try await media.merge(
                inputs: try request.paths("inputs"),
                output: try request.path("output"),
                container: try request.value("container", as: MediaContainer.self)
            )
            return [:]

        case "media.extract_audio":
            let written = try await media.extractAudio(
                input: try request.path("input"),
                output: try request.path("output"),
                codec: try request.value("codec", as: AudioCodecRequest.self),
                bitrate: request.int("bitrate")
            )
            return ["output": written.path(percentEncoded: false)]

        case "media.embed":
            try await media.embed(
                into: try request.path("path"),
                metadata: request.metadata("metadata"),
                artwork: try request.optionalPath("artwork"),
                chapters: request.chapters("chapters")
            )
            return [:]

        case "media.convert_image":
            try await media.convertImage(
                input: try request.path("input"),
                output: try request.path("output"),
                format: try request.value("format", as: ImageFormat.self)
            )
            return [:]

        case "media.remove_ranges":
            try await media.removeRanges(
                input: try request.path("input"),
                output: try request.path("output"),
                ranges: try request.ranges("ranges")
            )
            return [:]

        case "media.probe":
            let probe = try await media.probe(try request.path("path"))
            let tracks: [[String: Any]] = probe.tracks.map { track in
                ["kind": track.kind, "codec": track.codec ?? NSNull()]
            }
            return [
                "duration": probe.durationSeconds ?? NSNull(),
                "tracks": tracks,
                "readable": probe.isReadable,
            ]

        case let operation?:
            throw EngineRequestError.unknownOperation(operation)

        case nil:
            throw EngineRequestError.missingOperation
        }
    }

    // MARK: - Answers

    private static func failure(_ error: any Error) -> [String: Any] {
        let message = error is CancellationError ? "Cancelled." : error.localizedDescription
        let unsupported = (error as? MediaProcessingError)?.isUnsupported ?? false
        return ["ok": false, "error": message, "unsupported": unsupported]
    }

    /// Returned only if an answer couldn't be serialised, which the sanitising encoder rules out
    /// for everything built above; kept so the host always gets valid JSON.
    private static let encodingFailure = Data(#"{"ok":false,"error":"The app couldn't encode its answer.","unsupported":false}"#.utf8)
}

// MARK: - Request fields

/// Typed access to one request's fields, with errors that name the field.
private struct RequestFields {
    let object: [String: Any]
    let operation: String?

    init(_ object: [String: Any]) {
        self.object = object
        self.operation = EngineJSON.nonEmptyString(object["op"])
    }

    private var name: String { operation ?? "unnamed" }

    /// A text field. Unlike tags, scripts, paths and option names must really be strings: a
    /// number where a path belongs is a bug, not a file name.
    func string(_ field: String) throws -> String {
        guard object[field] != nil, !(object[field] is NSNull) else {
            throw EngineRequestError.missingField(operation: name, field: field)
        }
        guard let value = object[field] as? String else {
            throw EngineRequestError.invalidField(operation: name, field: field)
        }
        return value
    }

    func double(_ field: String) -> Double? { EngineJSON.double(object[field]) }

    func int(_ field: String) -> Int? { EngineJSON.int(object[field]) }

    func path(_ field: String) throws -> URL {
        let path = try string(field)
        guard !path.isEmpty else { throw EngineRequestError.invalidField(operation: name, field: field) }
        return URL(fileURLWithPath: path)
    }

    func optionalPath(_ field: String) throws -> URL? {
        guard object[field] != nil, !(object[field] is NSNull) else { return nil }
        return try path(field)
    }

    func paths(_ field: String) throws -> [URL] {
        guard let values = object[field] as? [Any] else {
            throw EngineRequestError.missingField(operation: name, field: field)
        }
        let paths = values.compactMap { $0 as? String }.filter { !$0.isEmpty }
        guard !paths.isEmpty, paths.count == values.count else {
            throw EngineRequestError.invalidField(operation: name, field: field)
        }
        return paths.map { URL(fileURLWithPath: $0) }
    }

    func value<Value: RawRepresentable<String>>(_ field: String, as type: Value.Type) throws -> Value {
        guard let value = Value(rawValue: try string(field)) else {
            throw EngineRequestError.invalidField(operation: name, field: field)
        }
        return value
    }

    /// Tags to write. yt-dlp's metadata can hold numbers (a track number, a year), which are
    /// written as text rather than rejected.
    func metadata(_ field: String) -> MediaMetadata? {
        guard let tags = object[field] as? [String: Any] else { return nil }
        return MediaMetadata(
            title: EngineJSON.nonEmptyString(tags["title"]),
            artist: EngineJSON.nonEmptyString(tags["artist"]),
            album: EngineJSON.nonEmptyString(tags["album"]),
            albumArtist: EngineJSON.nonEmptyString(tags["album_artist"]),
            date: EngineJSON.nonEmptyString(tags["date"]),
            comment: EngineJSON.nonEmptyString(tags["comment"]),
            description: EngineJSON.nonEmptyString(tags["description"]),
            genre: EngineJSON.nonEmptyString(tags["genre"]),
            track: EngineJSON.nonEmptyString(tags["track"]),
            webpageURL: EngineJSON.nonEmptyString(tags["purl"])
        )
    }

    /// Chapters, skipping any without usable times.
    func chapters(_ field: String) -> [MediaChapter]? {
        guard let entries = object[field] as? [Any] else { return nil }
        return entries.compactMap { entry in
            guard let chapter = entry as? [String: Any],
                  let start = EngineJSON.double(chapter["start"]),
                  let end = EngineJSON.double(chapter["end"]) else { return nil }
            return MediaChapter(start: start, end: end, title: EngineJSON.string(chapter["title"]) ?? "")
        }
    }

    /// `[[start, end], …]` in seconds. A reversed pair would trap as a `ClosedRange`, so it
    /// makes the whole request invalid instead.
    func ranges(_ field: String) throws -> [ClosedRange<Double>] {
        guard let pairs = object[field] as? [Any] else {
            throw EngineRequestError.missingField(operation: name, field: field)
        }
        return try pairs.map { pair in
            guard let bounds = pair as? [Any], bounds.count == 2,
                  let start = EngineJSON.double(bounds[0]),
                  let end = EngineJSON.double(bounds[1]),
                  start <= end else {
                throw EngineRequestError.invalidField(operation: name, field: field)
            }
            return start...end
        }
    }
}
