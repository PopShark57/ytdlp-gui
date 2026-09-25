import Foundation
import Network

/// A minimal HTTP/1.1 file server on the loopback interface, so engine tests exercise yt-dlp's
/// real networking code without touching the internet.
///
/// It serves `GET` and `HEAD` for files in one directory, honours single `Range` requests (yt-dlp
/// uses them to resume partial files), and can throttle its output so a download stays in
/// flight long enough to be cancelled.
final class LocalHTTPServer: @unchecked Sendable {

    enum ServerError: Error {
        case couldNotStart(String)
    }

    let root: URL
    /// Bytes per second to send, or `nil` for as fast as possible.
    let bytesPerSecond: Int?

    // All mutable state is confined to `queue`.
    private let queue = DispatchQueue(label: "LocalHTTPServer")
    private let listener: NWListener
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(root: URL, bytesPerSecond: Int? = nil) throws {
        self.root = root
        self.bytesPerSecond = bytesPerSecond
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    /// Starts listening and returns the server's base URL, e.g. `http://127.0.0.1:52011/`.
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    guard resumed.setOnce(), let port = listener.port?.rawValue else { return }
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(port)/")!)
                case .failed(let error):
                    guard resumed.setOnce() else { return }
                    continuation.resume(throwing: ServerError.couldNotStart(error.localizedDescription))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed, .cancelled:
                self.connections[ObjectIdentifier(connection)] = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                self.respond(to: header, on: connection)
            } else if error != nil || isComplete {
                connection.cancel()
            } else {
                self.receiveRequest(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to header: String, on connection: NWConnection) {
        let lines = header.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else {
            send(status: "400 Bad Request", headers: [:], body: Data(), on: connection)
            return
        }
        let method = String(requestLine[0])
        let rawPath = String(requestLine[1]).split(separator: "?").first.map(String.init) ?? "/"
        let name = (rawPath.removingPercentEncoding ?? rawPath).trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // Only plain file names inside the root are served.
        let file = root.appending(path: name)
        guard !name.isEmpty, !name.contains(".."), let contents = try? Data(contentsOf: file) else {
            send(status: "404 Not Found", headers: [:], body: Data(), on: connection)
            return
        }

        var status = "200 OK"
        var body = contents
        var headers = [
            "Content-Type": Self.contentType(for: file.pathExtension),
            "Accept-Ranges": "bytes",
        ]
        if let range = lines.first(where: { $0.lowercased().hasPrefix("range:") }),
           let (start, end) = Self.parseRange(range, length: contents.count) {
            status = "206 Partial Content"
            body = contents.subdata(in: start..<(end + 1))
            headers["Content-Range"] = "bytes \(start)-\(end)/\(contents.count)"
        }
        headers["Content-Length"] = String(body.count)
        send(status: status, headers: headers, body: method == "HEAD" ? Data() : body, on: connection)
    }

    private func send(status: String, headers: [String: String], body: Data, on connection: NWConnection) {
        var head = "HTTP/1.1 \(status)\r\nConnection: close\r\n"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        sendBody(body, offset: 0, on: connection)
    }

    private func sendBody(_ body: Data, offset: Int, on connection: NWConnection) {
        guard offset < body.count else {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }
        let chunkSize = bytesPerSecond.map { max(1, $0 / 10) } ?? body.count
        let end = min(body.count, offset + chunkSize)
        connection.send(content: body.subdata(in: offset..<end), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { return }
            if self.bytesPerSecond != nil {
                self.queue.asyncAfter(deadline: .now() + 0.1) {
                    self.sendBody(body, offset: end, on: connection)
                }
            } else {
                self.sendBody(body, offset: end, on: connection)
            }
        })
    }

    // MARK: - Helpers

    private static func parseRange(_ line: String, length: Int) -> (Int, Int)? {
        guard let value = line.split(separator: "=", maxSplits: 1).last else { return nil }
        let bounds = value.split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return nil }
        let start = Int(bounds[0].trimmingCharacters(in: .whitespaces)) ?? 0
        let end = Int(bounds[1].trimmingCharacters(in: .whitespaces)) ?? (length - 1)
        guard start >= 0, start < length, end >= start else { return nil }
        return (start, min(end, length - 1))
    }

    private static func contentType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "mpd": "application/dash+xml"
        case "mp4": "video/mp4"
        case "m4a": "audio/mp4"
        case "html": "text/html"
        default: "application/octet-stream"
        }
    }
}

/// A flag that can be set exactly once from any thread.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    /// Returns `true` the first time only.
    func setOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isSet else { return false }
        isSet = true
        return true
    }
}
