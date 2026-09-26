import Observation
import SwiftUI

/// The app's passing status message ("Link copied.", "Added 3 downloads to the queue."), shown
/// as a toast over every tab by `RootView`.
///
/// Owned by `AppModel` and handed to whatever reports something, so the Queue and History screens
/// don't depend on the Download screen's view model to say so.
@MainActor
@Observable
final class StatusCenter {

    /// The message showing now, if any.
    private(set) var message: String?

    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    /// How long a message stays up.
    static let displayDuration: Duration = .seconds(4)

    /// Shows `message`, replacing any other, for `displayDuration`.
    func show(_ message: String) {
        self.message = message
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: Self.displayDuration)
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        message = nil
    }
}
