import Foundation
import JavaScriptCore

/// What a script wrote to the console.
struct JavaScriptOutput: Equatable, Sendable {
    /// Lines passed to `console.log` and `console.info`: what a command-line runtime prints to
    /// stdout.
    var standardOutput: [String] = []
    /// Lines passed to `console.warn`, `console.error` and `console.debug`.
    var standardError: [String] = []

    /// The script's stdout, as yt-dlp expects to read it from Deno or Node.
    var stdout: String { standardOutput.joined(separator: "\n") }
}

enum JavaScriptRunnerError: LocalizedError, Equatable, Sendable {
    /// The script threw, or failed to parse. `line` is 1-based, when JavaScriptCore knows it.
    case exception(message: String, line: Int?)
    /// The script was still running when the time limit passed.
    case timedOut(seconds: Int)
    /// JavaScriptCore couldn't create a context (it is out of memory).
    case unavailable
    case cancelled

    var errorDescription: String? {
        switch self {
        case .exception(let message, let line?):
            "The YouTube challenge solver failed at line \(line): \(message)"
        case .exception(let message, nil):
            "The YouTube challenge solver failed: \(message)"
        case .timedOut(let seconds):
            "The YouTube challenge solver didn't finish within \(seconds) seconds."
        case .unavailable:
            "JavaScriptCore couldn't start the YouTube challenge solver. Closing other apps may help."
        case .cancelled:
            "Cancelled."
        }
    }
}

/// Runs yt-dlp's JavaScript challenge solver (yt-dlp-ejs) in JavaScriptCore, standing in for the
/// Deno or Node process yt-dlp launches on a desktop.
///
/// yt-dlp sends one self-contained script per YouTube player: the solver library, then
/// `Object.assign(globalThis, lib)`, the solver core, and finally
/// `console.log(JSON.stringify(jsc({...})))`. All the runner provides is a clean global
/// environment and a console whose `log` output becomes the script's stdout.
///
/// Every run gets a fresh virtual machine, so nothing one player's code leaves in the global
/// scope can influence the next. JavaScriptCore has no JIT inside an iOS app (it interprets),
/// which makes solving take seconds on older devices; the runner adds nothing beyond what the
/// script needs.
struct JavaScriptChallengeRunner: Sendable {

    /// What yt-dlp's host asks for; a large player takes several seconds without a JIT.
    static let defaultTimeout: Duration = .seconds(60)

    /// Evaluates `script` and returns what it wrote to the console.
    ///
    /// JavaScriptCore has no public API for interrupting a running script from outside. The
    /// script therefore runs on a thread of its own, and when `timeout` passes, or the calling
    /// task is cancelled, the caller gets an error straight away while that thread is abandoned
    /// to finish by itself, freeing its virtual machine when it does. The solver scripts are
    /// pinned by hash and trusted, so the time limit is a safety net against a pathological
    /// player, not a sandbox.
    func run(_ script: String, timeout: Duration = defaultTimeout) async throws -> JavaScriptOutput {
        let outcome = FirstOutcome<JavaScriptOutput>()
        return try await withTaskCancellationHandler {
            guard !Task.isCancelled else { throw JavaScriptRunnerError.cancelled }
            EngineThread.detach(named: "YTDLP GUI JavaScript") {
                outcome.settle(Self.evaluate(script).mapError { $0 })
            }
            let seconds = max(Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18, 0)
            let deadline = DispatchWorkItem {
                outcome.settle(.failure(JavaScriptRunnerError.timedOut(seconds: Int(seconds.rounded(.up)))))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: deadline)
            defer { deadline.cancel() }
            return try await outcome.value()
        } onCancel: {
            outcome.settle(.failure(JavaScriptRunnerError.cancelled))
        }
    }

    /// Runs `script` to completion in a new virtual machine. Blocks; runs on its own thread.
    private static func evaluate(_ script: String) -> Result<JavaScriptOutput, JavaScriptRunnerError> {
        autoreleasepool {
            guard let machine = JSVirtualMachine(), let context = JSContext(virtualMachine: machine) else {
                return .failure(.unavailable)
            }
            let console = ConsoleCapture()
            console.install(in: context)
            // The handler replaces JavaScriptCore's default, which would only stash the exception
            // in `context.exception`, and it keeps the first one: later exceptions are usually
            // consequences of it.
            context.exceptionHandler = { _, exception in
                if console.exception == nil {
                    console.exception = describe(exception)
                }
            }
            context.evaluateScript(script, withSourceURL: URL(string: "yt-dlp-challenge-solver.js"))
            if let exception = console.exception {
                return .failure(exception)
            }
            return .success(console.output)
        }
    }

    private static func describe(_ exception: JSValue?) -> JavaScriptRunnerError {
        let message = exception?.toString() ?? "Unknown JavaScript error"
        guard let line = exception?.objectForKeyedSubscript("line"), line.isNumber else {
            return .exception(message: message, line: nil)
        }
        return .exception(message: message, line: Int(line.toInt32()))
    }
}

/// Collects console output for one run. Used only on that run's thread.
private final class ConsoleCapture {
    var output = JavaScriptOutput()
    var exception: JavaScriptRunnerError?

    func install(in context: JSContext) {
        guard let console = JSValue(newObjectIn: context) else { return }
        // The blocks read their arguments from `JSContext.currentArguments()` rather than
        // capturing the context, which would create a retain cycle through the global object.
        let standard: @convention(block) () -> Void = { [self] in
            output.standardOutput.append(Self.line(from: JSContext.currentArguments()))
        }
        let diagnostic: @convention(block) () -> Void = { [self] in
            output.standardError.append(Self.line(from: JSContext.currentArguments()))
        }
        console.setObject(standard, forKeyedSubscript: "log" as NSString)
        console.setObject(standard, forKeyedSubscript: "info" as NSString)
        console.setObject(diagnostic, forKeyedSubscript: "warn" as NSString)
        console.setObject(diagnostic, forKeyedSubscript: "error" as NSString)
        console.setObject(diagnostic, forKeyedSubscript: "debug" as NSString)
        context.setObject(console, forKeyedSubscript: "console" as NSString)
    }

    /// Joins the arguments with spaces, as every console does.
    private static func line(from arguments: [Any]?) -> String {
        (arguments ?? [])
            .map { ($0 as? JSValue)?.toString() ?? "" }
            .joined(separator: " ")
    }
}
