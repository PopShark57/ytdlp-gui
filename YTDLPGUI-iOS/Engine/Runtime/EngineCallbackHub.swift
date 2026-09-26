import Foundation
import os
import Synchronization

/// One running analysis or download, as seen by the callbacks that feed it.
///
/// Everything a job reports passes through its own lock, which is what makes the end of a
/// download stream trustworthy: once `finish` has run, a late event from a straggling yt-dlp
/// worker thread is dropped instead of arriving after the result.
final class EngineJob: Sendable {

    enum Destination: Sendable {
        /// A download's stream, which receives every event.
        case download(AsyncStream<EngineJobUpdate>.Continuation)
        /// An analysis, which only reports its log lines.
        case analysis(@Sendable (EngineLogLevel, String) -> Void)
    }

    /// The job ID as the host sees it.
    let id: String

    /// `nil` once the job has finished.
    private let destination: Mutex<Destination?>
    private let cancellation = Mutex(false)

    init(id: UUID, destination: Destination) {
        self.id = id.uuidString
        self.destination = Mutex(destination)
    }

    var isCancellationRequested: Bool { cancellation.withLock { $0 } }

    /// Marks the job as cancelled. Returns `false` if it already was.
    func requestCancellation() -> Bool {
        cancellation.withLock { requested in
            defer { requested = true }
            return !requested
        }
    }

    /// Passes an event on. Runs on the Python thread that emitted it, under the job's lock; an
    /// analysis's log handler must therefore not call back into this job synchronously, other
    /// than to cancel it.
    func deliver(_ event: EngineEvent) {
        destination.withLock { destination in
            switch destination {
            case .download(let continuation)?:
                continuation.yield(.event(event))
            case .analysis(let onLog)?:
                if case .log(let level, let line) = event {
                    onLog(level, line)
                }
            case nil:
                break
            }
        }
    }

    /// Stops delivering events. For an analysis, whose result travels as a return value.
    func close() {
        destination.withLock { $0 = nil }
    }

    /// Ends the job: a download's stream gets `result` and finishes; nothing is delivered after.
    func finish(with result: EngineJobResult) {
        destination.withLock { destination in
            if case .download(let continuation)? = destination {
                continuation.yield(.finished(result))
                continuation.finish()
            }
            destination = nil
        }
    }
}

/// Where the C bridge's callbacks land.
///
/// C function pointers can't capture context, so the bridge's emit and request callbacks are
/// context-free trampolines that find their destination here, by job ID. There is one hub per
/// process, like the interpreter it serves.
final class EngineCallbackHub: Sendable {

    static let shared = EngineCallbackHub()

    private let jobs = Mutex<[String: EngineJob]>([:])
    private let router: Mutex<EngineRequestRouter?>
    /// Tasks answering requests, by job ID, so that cancelling a job also stops its media work.
    private let requestTasks = Mutex<[String: [UUID: Task<Void, Never>]]>([:])
    private let logger = AppLog.engine

    init(router: EngineRequestRouter? = nil) {
        self.router = Mutex(router)
    }

    /// Sets what answers requests from now on.
    func install(_ router: EngineRequestRouter) {
        self.router.withLock { $0 = router }
    }

    // MARK: - Jobs

    /// Starts routing callbacks for `job`. Returns `false` if a job with the same ID is running.
    func register(_ job: EngineJob) -> Bool {
        jobs.withLock { jobs in
            guard jobs[job.id] == nil else { return false }
            jobs[job.id] = job
            return true
        }
    }

    func unregister(_ job: EngineJob) {
        jobs.withLock { jobs in
            if jobs[job.id] === job {
                jobs[job.id] = nil
            }
        }
    }

    func job(withID id: String) -> EngineJob? {
        jobs.withLock { $0[id] }
    }

    func isRegistered(_ job: EngineJob) -> Bool {
        jobs.withLock { $0[job.id] === job }
    }

    // MARK: - Events

    /// Delivers one event to its job. Events for jobs that have finished, or were never known,
    /// are dropped: nobody is listening for them any more.
    func deliver(eventJSON: Data, toJob id: String) {
        guard let job = job(withID: id) else { return }
        guard let event = EngineEventDecoder.decode(eventJSON) else {
            logger.debug("Skipped an engine event the app doesn't understand")
            return
        }
        job.deliver(event)
    }

    // MARK: - Requests

    /// Answers a request, blocking the calling thread until the answer is ready.
    ///
    /// The router is async (media work runs on AVFoundation's own queues) while the bridge's
    /// callback is synchronous, so a task does the work and a semaphore waits for it. Blocking is
    /// safe because the caller is always a Python thread (an engine thread or one yt-dlp started),
    /// never one of the cooperative pool's threads the task needs, and nothing on the way hops
    /// to the main actor. A request answers even for an unknown job, since a post-processor
    /// waiting on it would otherwise wait forever.
    func answerRequest(_ request: Data, forJob id: String) -> Data {
        let job = job(withID: id)
        if job?.isCancellationRequested == true {
            return Self.cancelledAnswer
        }
        guard let router = router.withLock({ $0 }) else {
            return Self.notReadyAnswer
        }

        let answer = AnswerSlot()
        let finished = DispatchSemaphore(value: 0)
        let task = Task.detached(priority: .userInitiated) {
            answer.store(await router.answer(request))
            finished.signal()
        }
        let token = UUID()
        requestTasks.withLock { $0[id, default: [:]][token] = task }
        // `cancel(jobID:)` sets the flag before it cancels the job's request tasks, so either it
        // saw this task or this check sees the flag.
        if job?.isCancellationRequested == true {
            task.cancel()
        }
        finished.wait()
        requestTasks.withLock { tasks in
            tasks[id]?[token] = nil
            if tasks[id]?.isEmpty == true {
                tasks[id] = nil
            }
        }
        return answer.value ?? Self.notReadyAnswer
    }

    /// Cancels the Swift work behind any requests `id` is waiting on. The media processor and the
    /// JavaScript runner both stop promptly when their task is cancelled.
    func cancelRequests(forJob id: String) {
        let tasks = requestTasks.withLock { $0[id].map { Array($0.values) } ?? [] }
        for task in tasks {
            task.cancel()
        }
    }

    private static let cancelledAnswer = Data(#"{"ok":false,"error":"Cancelled.","unsupported":false}"#.utf8)
    private static let notReadyAnswer = Data(#"{"ok":false,"error":"The app wasn't ready to answer the download engine.","unsupported":false}"#.utf8)
}

/// Carries an answer from the task that computes it to the thread waiting for it.
private final class AnswerSlot: Sendable {
    private let data = Mutex<Data?>(nil)

    func store(_ answer: Data) {
        data.withLock { $0 = answer }
    }

    var value: Data? { data.withLock { $0 } }
}
