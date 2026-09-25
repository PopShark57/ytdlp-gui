import Synchronization

/// Hands the first of several racing outcomes to a waiting continuation, exactly once.
///
/// Used where a result, a timeout and a cancellation can all arrive, from different threads and
/// in any order, including before anyone has started waiting. The losers are ignored.
final class FirstOutcome<Value: Sendable>: Sendable {

    private enum State {
        case pending(CheckedContinuation<Value, any Error>?)
        /// An outcome arrived before `wait` did.
        case settled(Result<Value, any Error>)
        case delivered
    }

    private let state = Mutex<State>(.pending(nil))

    /// Suspends until the first outcome is settled.
    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let early: Result<Value, any Error>? = state.withLock { state in
                switch state {
                case .pending:
                    state = .pending(continuation)
                    return nil
                case .settled(let result):
                    state = .delivered
                    return result
                case .delivered:
                    return .failure(CancellationError())
                }
            }
            if let early {
                continuation.resume(with: early)
            }
        }
    }

    /// Settles the outcome, unless another one got there first.
    func settle(_ result: Result<Value, any Error>) {
        let waiting: CheckedContinuation<Value, any Error>? = state.withLock { state in
            switch state {
            case .pending(let continuation?):
                state = .delivered
                return continuation
            case .pending(nil):
                state = .settled(result)
                return nil
            case .settled, .delivered:
                return nil
            }
        }
        waiting?.resume(with: result)
    }
}
