import Foundation
import JavaScriptCore
import Synchronization
import os

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
    /// Too many earlier runs were still going, abandoned or not, for this one to start within
    /// its time limit.
    case busy
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
        case .busy:
            "The YouTube challenge solver couldn't start, because earlier runs are still going. Try again in a moment."
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

    private static let logger = AppLog.javaScript

    /// Limits how many scripts evaluate at once, abandoned ones included.
    let slots: JavaScriptEvaluationSlots

    init(slots: JavaScriptEvaluationSlots = .shared) {
        self.slots = slots
    }

    /// Evaluates `script` and returns what it wrote to the console.
    ///
    /// JavaScriptCore has no public API for interrupting a running script from outside. The
    /// script therefore runs on a thread of its own, and when `timeout` passes, or the calling
    /// task is cancelled, the caller gets an error straight away while that thread is abandoned
    /// to finish by itself, freeing its virtual machine when it does. The solver scripts are
    /// pinned by hash and trusted, so the time limit is a safety net against a pathological
    /// player, not a sandbox.
    ///
    /// Abandoned scripts still hold a slot (see `JavaScriptEvaluationSlots`), so they can't pile
    /// up. When every slot is taken the run waits for one, within the same time limit, and
    /// otherwise fails with `.busy`; yt-dlp then reports the challenge as unsolved.
    func run(_ script: String, timeout: Duration = defaultTimeout) async throws -> JavaScriptOutput {
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start.advanced(by: timeout)
        let limitInSeconds = Int(Self.seconds(in: timeout).rounded(.up))
        try await acquireSlot(before: deadline, clock: clock)

        let outcome = FirstOutcome<JavaScriptOutput>()
        let slots = slots
        return try await withTaskCancellationHandler {
            guard !Task.isCancelled else {
                slots.release()
                throw JavaScriptRunnerError.cancelled
            }
            EngineThread.detach(named: "YTDLP GUI JavaScript") {
                let result = Self.evaluate(script)
                slots.release()
                if !outcome.settle(result.mapError { $0 }) {
                    Self.logger.notice("An abandoned challenge-solver run ended after \((clock.now - start).formatted(), privacy: .public).")
                }
            }
            let remaining = max(Self.seconds(in: deadline - clock.now), 0)
            let timer = DispatchWorkItem {
                if outcome.settle(.failure(JavaScriptRunnerError.timedOut(seconds: limitInSeconds))) {
                    Self.logger.notice("Abandoned a challenge-solver run at its \(limitInSeconds, privacy: .public) s limit; it keeps running until it ends. Runs going: \(slots.running, privacy: .public).")
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + remaining, execute: timer)
            defer { timer.cancel() }
            return try await outcome.value()
        } onCancel: {
            outcome.settle(.failure(JavaScriptRunnerError.cancelled))
        }
    }

    /// Takes a slot, waiting for one to free up until `deadline`.
    private func acquireSlot(before deadline: ContinuousClock.Instant, clock: ContinuousClock) async throws {
        while !slots.tryAcquire() {
            guard clock.now < deadline else {
                Self.logger.error("A challenge-solver run couldn't start: \(slots.capacity, privacy: .public) runs are still going.")
                throw JavaScriptRunnerError.busy
            }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                throw JavaScriptRunnerError.cancelled
            }
        }
    }

    private static func seconds(in duration: Duration) -> Double {
        max(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18, 0)
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

/// Counts the solver scripts evaluating right now, including ones whose caller stopped waiting,
/// and limits them.
///
/// JavaScriptCore can't interrupt a script, so a run that times out keeps its thread (a 16 MB
/// stack) and its virtual machine, which holds the multi-megabyte player, until the script ends.
/// Without a limit, a slow device where solving nears the time limit would start one more
/// interpreter with every retry, each making the others slower still.
final class JavaScriptEvaluationSlots: Sendable {

    /// Two, plus one for every two cores: enough for the downloads that can run at once
    /// (`AppSettings.concurrencyRange` tops out at four), never so many that abandoned runs
    /// starve the device.
    static let shared = JavaScriptEvaluationSlots(capacity: 2 + ProcessInfo.processInfo.activeProcessorCount / 2)

    let capacity: Int
    private let count = Mutex(0)

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// Scripts evaluating now, abandoned or not.
    var running: Int {
        count.withLock { $0 }
    }

    /// Takes a slot if one is free.
    func tryAcquire() -> Bool {
        count.withLock { running in
            guard running < capacity else { return false }
            running += 1
            return true
        }
    }

    /// Frees a slot, when a script has ended.
    func release() {
        count.withLock { running in
            running = max(0, running - 1)
        }
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
