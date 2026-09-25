import Foundation
import Synchronization

/// The process's embedded CPython interpreter, reached through `PythonBridge.c`.
///
/// CPython can be initialised only once per process, and not again after a failed attempt, so
/// this is process-wide state rather than something each `YTDLPEngine` owns. Every function
/// here blocks, some for as long as a download lasts: call them on an `EngineThread`.
enum PythonRuntime {

    private enum Phase {
        case notStarted
        case running
        case failed(String)
    }

    private static let phase = Mutex(Phase.notStarted)

    /// Whether the interpreter is up. Lock-free, so it is safe to ask from the main thread even
    /// while another thread is in the middle of starting Python.
    static var isRunning: Bool { ytg_is_initialized() }

    /// Starts the interpreter unless it is already running. A failure is permanent: later calls
    /// throw the same error without trying again.
    ///
    /// Only the first successful call's paths take effect.
    static func start(pythonHome: URL, modulePaths: [URL], bytecodeCache: URL?) throws {
        try phase.withLock { phase in
            switch phase {
            case .running:
                return
            case .failed(let message):
                throw EngineError.startupFailed(message)
            case .notStarted:
                installCallbacks()
                if let failure = initialize(pythonHome: pythonHome, modulePaths: modulePaths, bytecodeCache: bytecodeCache) {
                    phase = .failed(failure)
                    throw EngineError.startupFailed(failure)
                }
                phase = .running
            }
        }
    }

    /// Runs one host command and returns its JSON reply. Blocks until the host returns, which
    /// for a download means until it has finished.
    static func call(_ command: String, payload: Data) -> Data {
        let reply = ytg_call(command, String(decoding: payload, as: UTF8.self))
        defer { ytg_free(reply) }
        return Data(bytes: reply, count: strlen(reply))
    }

    // MARK: - Bridge

    private static func initialize(pythonHome: URL, modulePaths: [URL], bytecodeCache: URL?) -> String? {
        let paths = modulePaths.map { strdup($0.path(percentEncoded: false)) }
        defer { paths.forEach { free($0) } }
        let pathPointers = paths.map { $0.map { UnsafePointer($0) } }

        let failure = pathPointers.withUnsafeBufferPointer { buffer in
            ytg_initialize(
                pythonHome.path(percentEncoded: false),
                buffer.baseAddress,
                Int32(clamping: buffer.count),
                bytecodeCache?.path(percentEncoded: false)
            )
        }
        guard let failure else { return nil }
        defer { ytg_free(failure) }
        return String(cString: failure)
    }

    /// Points the bridge's C callbacks at the process-wide `EngineCallbackHub`. The closures
    /// capture nothing, which is what lets Swift pass them as C function pointers.
    private static func installCallbacks() {
        ytg_set_callbacks(
            { jobID, eventJSON, _ in
                EngineCallbackHub.shared.deliver(
                    eventJSON: Data(bytes: eventJSON, count: strlen(eventJSON)),
                    toJob: String(cString: jobID)
                )
            },
            { jobID, requestJSON, _ in
                let answer = EngineCallbackHub.shared.answerRequest(
                    Data(bytes: requestJSON, count: strlen(requestJSON)),
                    forJob: String(cString: jobID)
                )
                // The bridge takes ownership and frees it with `free`.
                return strdup(String(decoding: answer, as: UTF8.self))
            },
            nil
        )
    }
}
