import Foundation

/// Runs blocking engine work on a thread of its own, never on Swift's cooperative pool.
///
/// A yt-dlp call blocks its thread for as long as a download lasts. The cooperative pool has
/// only as many threads as the device has cores, so parking even a few downloads there would
/// stall every other task in the app. Each call therefore gets a dedicated `Thread`, and the
/// awaiting task is suspended rather than blocked until it finishes.
enum EngineThread {

    /// Stack size for every engine thread.
    ///
    /// This is a crash fix, not a tuning knob. Secondary threads get 512 KB by default, and
    /// CPython's evaluation loop, the `re` compiler working through yt-dlp's regex-heavy
    /// extractors, and JavaScriptCore parsing YouTube's multi-megabyte player all recurse deep
    /// enough to overflow it. A native stack overflow kills the whole app instead of raising an
    /// error. 16 MB is what CPython itself gives the threads it starts on Apple platforms, and
    /// it is address space only until pages are touched.
    static let stackSize = 16 << 20

    /// Starts `work` on a new engine thread and returns immediately.
    static func detach(
        named name: String,
        qualityOfService: QualityOfService = .userInitiated,
        _ work: @escaping @Sendable () -> Void
    ) {
        let thread = Thread(block: work)
        thread.name = name
        thread.stackSize = stackSize
        thread.qualityOfService = qualityOfService
        thread.start()
    }

    /// Runs `work` on a new engine thread and suspends the caller until it returns.
    static func run<Value: Sendable>(
        named name: String,
        qualityOfService: QualityOfService = .userInitiated,
        _ work: @escaping @Sendable () -> Value
    ) async -> Value {
        await withCheckedContinuation { continuation in
            detach(named: name, qualityOfService: qualityOfService) {
                continuation.resume(returning: work())
            }
        }
    }
}
