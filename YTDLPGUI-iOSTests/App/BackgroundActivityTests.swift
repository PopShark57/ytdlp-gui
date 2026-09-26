import SwiftUI
import Testing
@testable import YTDLPGUI_iOS

/// The screen stays awake only while downloads run with the app in front, and only when the
/// setting asks for it.
@MainActor
@Suite("Background activity")
struct BackgroundActivityTests {

    /// Records what the activity asks of the idle timer.
    private final class IdleTimer {
        var changes: [Bool] = []
        var isDisabled: Bool { changes.last ?? false }
    }

    private func makeActivity(_ env: AppTestEnvironment, idleTimer: IdleTimer) -> BackgroundActivity {
        BackgroundActivity(
            settings: env.settings,
            setIdleTimerDisabled: { idleTimer.changes.append($0) },
            requestsBackgroundTime: false
        )
    }

    private func running(_ active: Int, queued: Int = 0) -> QueueActivity {
        QueueActivity(activeCount: active, queuedCount: queued, currentTitle: "Clip")
    }

    @Test("The screen stays awake while downloads run in the foreground")
    func awakeWhileRunning() throws {
        let env = try AppTestEnvironment()
        env.settings.keepScreenAwake = true
        let idleTimer = IdleTimer()
        let activity = makeActivity(env, idleTimer: idleTimer)

        // Waiting downloads alone don't keep it awake.
        activity.update(running(0, queued: 2))
        #expect(!idleTimer.isDisabled)

        activity.update(running(1, queued: 1))
        #expect(idleTimer.isDisabled)
        // Progress ticks don't touch the idle timer again.
        activity.update(running(1, queued: 1))
        activity.update(running(2))
        #expect(idleTimer.changes == [true])

        // Draining the queue lets the screen lock again.
        activity.update(.idle)
        #expect(!idleTimer.isDisabled)
        #expect(idleTimer.changes == [true, false])
    }

    @Test("Leaving the foreground lets the screen lock; coming back keeps it awake again")
    func followsScenePhase() throws {
        let env = try AppTestEnvironment()
        env.settings.keepScreenAwake = true
        let idleTimer = IdleTimer()
        let activity = makeActivity(env, idleTimer: idleTimer)
        activity.update(running(1))
        #expect(idleTimer.isDisabled)

        activity.scenePhaseChanged(.inactive)
        #expect(!idleTimer.isDisabled)
        activity.scenePhaseChanged(.background)
        #expect(!idleTimer.isDisabled)
        activity.scenePhaseChanged(.active)
        #expect(idleTimer.isDisabled)

        // Coming back to an empty queue doesn't.
        activity.update(.idle)
        activity.scenePhaseChanged(.background)
        activity.scenePhaseChanged(.active)
        #expect(!idleTimer.isDisabled)
    }

    @Test("With the setting off, the screen locks as usual")
    func settingOff() throws {
        let env = try AppTestEnvironment()
        env.settings.keepScreenAwake = false
        let idleTimer = IdleTimer()
        let activity = makeActivity(env, idleTimer: idleTimer)
        activity.update(running(2))
        activity.scenePhaseChanged(.active)
        #expect(idleTimer.changes.isEmpty)
    }

    @Test("The queue reports its activity to the app's background handling")
    func queueDrivesActivity() async throws {
        let env = try AppTestEnvironment()
        env.settings.keepScreenAwake = true
        let model = env.makeAppModel()
        var reported: [QueueActivity] = []
        model.queue.onActivityChange = { reported.append($0) }

        let item = model.queue.enqueue(url: "https://example.com/a", options: DownloadOptions()).item
        let job = try #require(try await waitForJobs(1, on: env.downloader).first)
        #expect(reported.last?.activeCount == 1)
        job.succeed()
        try await waitUntil("completion") { item.state == .completed }
        try await waitUntil("idle reported") { reported.last?.isBusy == false }
    }
}
