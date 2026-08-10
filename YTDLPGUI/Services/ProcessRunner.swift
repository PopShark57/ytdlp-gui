import Foundation
import os

// MARK: - Configuration

/// Everything needed to launch a child process.
///
/// There is deliberately no "command string" here. Commands are always described as an
/// executable URL plus a fully-formed argument vector, which is handed straight to
/// `Process.arguments`. No shell is ever involved, so URLs, paths and user-supplied text can
/// never be reinterpreted as shell syntax.
struct ProcessConfiguration: Sendable {
    var executableURL: URL
    var arguments: [String]
    var currentDirectoryURL: URL?
    /// Extra variables merged over a minimal inherited environment.
    var additionalEnvironment: [String: String] = [:]

    /// The command line as a user could type it. For display and copying only.
    var displayCommand: String {
        ShellQuoting.commandLine(
            executable: executableURL.path(percentEncoded: false),
            arguments: arguments
        )
    }
}

// MARK: - Events and results

enum ProcessEvent: Sendable {
    case standardOutput(String)
    case standardError(String)
    case finished(ProcessResult)
}

struct ProcessResult: Sendable {
    var exitCode: Int32
    var wasSignalled: Bool
    /// True when the app asked the process to stop, rather than it failing on its own.
    var wasCancelled: Bool

    var isSuccess: Bool { exitCode == 0 && !wasSignalled }
}

enum ProcessLaunchError: LocalizedError, Sendable {
    case fileNotFound(URL)
    case notExecutable(URL)
    case launchFailed(URL, String)
    case timedOut(URL)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            "No file exists at \(url.path(percentEncoded: false))."
        case .notExecutable(let url):
            "\(url.lastPathComponent) is not an executable file."
        case .launchFailed(let url, let reason):
            "Couldn't start \(url.lastPathComponent): \(reason)"
        case .timedOut(let url):
            "\(url.lastPathComponent) did not respond in time."
        }
    }
}

// MARK: - Line splitting

/// Accumulates raw bytes and hands back complete lines.
///
/// Splits on LF *and* CR. yt-dlp is run with `--newline`, but ffmpeg and some yt-dlp
/// downloaders still redraw progress with a carriage return, and treating CR as a terminator
/// keeps those from piling up into one enormous line.
struct LineSplitter {
    private var buffer = Data()

    /// Appends new bytes and returns whatever complete lines that produced.
    mutating func append(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        var lineStart = buffer.startIndex

        for index in buffer.indices {
            let byte = buffer[index]
            guard byte == 0x0A || byte == 0x0D else { continue }
            let slice = buffer[lineStart..<index]
            // Skip the empty string produced by a CRLF pair.
            if !slice.isEmpty {
                lines.append(Self.decode(slice))
            }
            lineStart = buffer.index(after: index)
        }

        buffer = lineStart == buffer.endIndex ? Data() : Data(buffer[lineStart...])
        return lines
    }

    /// Returns any trailing bytes that were never terminated. Call at EOF.
    mutating func flush() -> String? {
        guard !buffer.isEmpty else { return nil }
        let remainder = Self.decode(buffer)
        buffer = Data()
        return remainder.isEmpty ? nil : remainder
    }

    /// Titles and filenames are frequently non-ASCII, and a stray invalid byte must not
    /// silently drop a whole line, so decoding always falls back to a lossy conversion.
    private static func decode(_ data: some DataProtocol) -> String {
        let bytes = Data(data)
        if let string = String(data: bytes, encoding: .utf8) { return string }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - Session

/// A single running child process, surfaced as a stream of line-oriented events.
///
/// The class is `@unchecked Sendable`: `Process`'s callbacks fire on arbitrary queues, so all
/// mutable state is guarded by one lock.
final class ProcessSession: @unchecked Sendable {

    let events: AsyncStream<ProcessEvent>
    let configuration: ProcessConfiguration

    private let continuation: AsyncStream<ProcessEvent>.Continuation
    private let process = Process()
    private let standardOutputPipe = Pipe()
    private let standardErrorPipe = Pipe()

    private let lock = NSLock()
    private var standardOutputSplitter = LineSplitter()
    private var standardErrorSplitter = LineSplitter()
    private var standardOutputAtEnd = false
    private var standardErrorAtEnd = false
    private var processDidTerminate = false
    private var didEmitResult = false
    private var cancelRequested = false
    private var hasStarted = false

    private static let logger = Logger(subsystem: "io.github.ytdlpgui.YTDLPGUI", category: "process")

    init(configuration: ProcessConfiguration) {
        self.configuration = configuration
        var capturedContinuation: AsyncStream<ProcessEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { capturedContinuation = $0 }
        continuation = capturedContinuation
    }

    // MARK: Launching

    /// Validates the executable and starts the process.
    ///
    /// Throwing here rather than reporting through the stream lets callers distinguish
    /// "couldn't even start" from "ran and failed", which need very different messages.
    func start() throws {
        lock.lock()
        guard !hasStarted else { lock.unlock(); return }
        hasStarted = true
        lock.unlock()

        let executable = configuration.executableURL
        try Self.validateExecutable(executable)

        process.executableURL = executable
        process.arguments = configuration.arguments
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe
        // Nothing is ever written to the child; give it an empty stdin so a tool that asks
        // for input gets EOF immediately instead of blocking forever.
        process.standardInput = FileHandle.nullDevice
        process.currentDirectoryURL = configuration.currentDirectoryURL
        process.environment = Self.makeEnvironment(additions: configuration.additionalEnvironment)

        standardOutputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.handleReadable(handle, isStandardError: false)
        }
        standardErrorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.handleReadable(handle, isStandardError: true)
        }
        process.terminationHandler = { [weak self] _ in
            self?.handleTermination()
        }

        do {
            try process.run()
        } catch {
            clearHandlers()
            continuation.finish()
            throw ProcessLaunchError.launchFailed(executable, error.localizedDescription)
        }
    }

    private static func validateExecutable(_ url: URL) throws {
        let path = url.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw ProcessLaunchError.fileNotFound(url)
        }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw ProcessLaunchError.notExecutable(url)
        }
    }

    /// Builds a deliberately small environment.
    ///
    /// A GUI app launched from Finder inherits almost nothing useful, so rather than depend on
    /// whatever happens to be inherited, the child gets an explicit, predictable environment.
    private static func makeEnvironment(additions: [String: String]) -> [String: String] {
        var environment: [String: String] = [:]
        let inherited = ProcessInfo.processInfo.environment
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "SHELL", "LANG", "SSL_CERT_FILE"] {
            if let value = inherited[key] { environment[key] = value }
        }

        // yt-dlp shells out to ffmpeg/ffprobe by name, so the usual package-manager
        // directories are added even though a `--ffmpeg-location` is normally supplied too.
        var searchPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "/opt/local/bin",
        ]
        if let inheritedPath = inherited["PATH"] {
            searchPaths.append(contentsOf: inheritedPath.split(separator: ":").map(String.init))
        }
        var seen = Set<String>()
        environment["PATH"] = searchPaths.filter { seen.insert($0).inserted }.joined(separator: ":")

        // yt-dlp is a Python program: without these, non-ASCII titles can raise encoding
        // errors and progress output arrives in large delayed chunks instead of line by line.
        environment["PYTHONIOENCODING"] = "utf-8"
        environment["PYTHONUNBUFFERED"] = "1"

        environment.merge(additions) { _, new in new }
        return environment
    }

    // MARK: Reading

    private func handleReadable(_ handle: FileHandle, isStandardError: Bool) {
        let data = handle.availableData

        if data.isEmpty {
            handle.readabilityHandler = nil
            var trailing: String?
            lock.lock()
            if isStandardError {
                standardErrorAtEnd = true
                trailing = standardErrorSplitter.flush()
            } else {
                standardOutputAtEnd = true
                trailing = standardOutputSplitter.flush()
            }
            lock.unlock()

            if let trailing {
                continuation.yield(isStandardError ? .standardError(trailing) : .standardOutput(trailing))
            }
            finishIfReady()
            return
        }

        lock.lock()
        let lines = isStandardError
            ? standardErrorSplitter.append(data)
            : standardOutputSplitter.append(data)
        lock.unlock()

        for line in lines {
            continuation.yield(isStandardError ? .standardError(line) : .standardOutput(line))
        }
    }

    private func handleTermination() {
        lock.lock()
        processDidTerminate = true
        lock.unlock()
        finishIfReady()
    }

    /// Emits the final result once the process has exited *and* both pipes have hit EOF.
    ///
    /// Waiting for both matters: `terminationHandler` routinely fires while the last few
    /// kilobytes of output are still buffered, and reporting completion early would drop the
    /// error message that explains the failure.
    private func finishIfReady() {
        lock.lock()
        guard processDidTerminate, standardOutputAtEnd, standardErrorAtEnd, !didEmitResult else {
            lock.unlock()
            return
        }
        didEmitResult = true
        let cancelled = cancelRequested
        lock.unlock()

        let result = ProcessResult(
            exitCode: process.terminationStatus,
            wasSignalled: process.terminationReason == .uncaughtSignal,
            wasCancelled: cancelled
        )
        continuation.yield(.finished(result))
        continuation.finish()
        clearHandlers()
    }

    private func clearHandlers() {
        standardOutputPipe.fileHandleForReading.readabilityHandler = nil
        standardErrorPipe.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
    }

    // MARK: Control

    var isRunning: Bool { process.isRunning }

    /// Asks the process to stop, escalating to `SIGKILL` if it ignores `SIGTERM`.
    ///
    /// yt-dlp handles `SIGTERM` by cleaning up its partial `.part` files, so the polite signal
    /// is always tried first.
    func cancel(killAfter graceInterval: TimeInterval = 5) {
        lock.lock()
        let alreadyCancelled = cancelRequested
        cancelRequested = true
        lock.unlock()
        guard !alreadyCancelled, process.isRunning else { return }

        process.terminate()

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(graceInterval))
            guard let self, self.process.isRunning else { return }
            Self.logger.warning("Process did not exit after SIGTERM; sending SIGKILL")
            kill(self.process.processIdentifier, SIGKILL)
        }
    }
}

// MARK: - One-shot execution

/// Convenience wrappers for short commands whose output is only needed as a whole.
enum ProcessRunner {

    struct CollectedOutput: Sendable {
        var standardOutput: String
        var standardError: String
        var result: ProcessResult

        var isSuccess: Bool { result.isSuccess }

        /// Trimmed stdout, or trimmed stderr when stdout is empty. Version commands vary.
        var trimmedOutput: String {
            let out = standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !out.isEmpty { return out }
            return standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Runs a command to completion, collecting all output.
    ///
    /// - Parameter timeout: Upper bound on total run time. A wedged network call must not
    ///   leave the settings window spinning forever, so the process is cancelled and the call
    ///   throws once the limit is reached.
    static func run(
        _ configuration: ProcessConfiguration,
        timeout: TimeInterval = 30
    ) async throws -> CollectedOutput {
        let session = ProcessSession(configuration: configuration)
        try session.start()

        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            session.cancel(killAfter: 2)
        }
        defer { timeoutTask.cancel() }

        var standardOutputLines: [String] = []
        var standardErrorLines: [String] = []
        var finalResult: ProcessResult?

        await withTaskCancellationHandler {
            for await event in session.events {
                switch event {
                case .standardOutput(let line): standardOutputLines.append(line)
                case .standardError(let line): standardErrorLines.append(line)
                case .finished(let result): finalResult = result
                }
            }
        } onCancel: {
            session.cancel(killAfter: 2)
        }
        try Task.checkCancellation()

        guard let finalResult else {
            throw ProcessLaunchError.launchFailed(configuration.executableURL, "the process produced no result")
        }
        if finalResult.wasCancelled, timeoutTask.isCancelled == false {
            throw ProcessLaunchError.timedOut(configuration.executableURL)
        }

        return CollectedOutput(
            standardOutput: standardOutputLines.joined(separator: "\n"),
            standardError: standardErrorLines.joined(separator: "\n"),
            result: finalResult
        )
    }
}
