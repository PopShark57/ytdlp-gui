import Foundation
import Testing
@testable import YTDLPGUI_iOS

/// Settings › Engine: starting the engine, and checking for, installing and undoing yt-dlp
/// updates.
@MainActor
@Suite("Engine controller")
struct EngineControllerTests {

    private func makeController(_ runtime: FakeEngineRuntime) -> EngineController {
        EngineController(runtime: runtime)
    }

    @Test("Starting reports the engine's versions, once")
    func start() async {
        let runtime = FakeEngineRuntime()
        let controller = makeController(runtime)
        #expect(controller.state == .notStarted)

        await controller.start()
        await controller.start()
        #expect(controller.state == .ready(FakeEngineRuntime.info))
        #expect(controller.isReady)
        #expect(runtime.startCount == 1)
    }

    @Test("A failed start says why, and can be retried")
    func failedStart() async {
        let runtime = FakeEngineRuntime()
        runtime.failStarts(with: .startupFailed("Python couldn't be found."))
        let controller = makeController(runtime)

        await controller.start()
        #expect(controller.failureMessage?.contains("Python couldn't be found.") == true)
        #expect(!controller.isReady)

        runtime.failStarts(with: nil)
        #expect(await controller.startIfNeeded())
        #expect(runtime.startCount == 2)
    }

    @Test("Checking for updates finds a newer release, or says it's up to date")
    func checkForUpdates() async {
        let runtime = FakeEngineRuntime()
        let controller = makeController(runtime)

        await controller.checkForUpdates()
        #expect(controller.updateState == .available(EngineUpdateInfo(
            currentVersion: FakeEngineRuntime.info.ytdlpVersion,
            latestVersion: "2026.9.1",
            isNewer: true
        )))

        runtime.offerUpdate(FakeEngineRuntime.info.ytdlpVersion)
        await controller.checkForUpdates()
        #expect(controller.updateState == .upToDate(version: FakeEngineRuntime.info.ytdlpVersion))
    }

    @Test("Installing an update asks for a restart; going back to the bundled version follows the runtime")
    func installAndRevert() async {
        let runtime = FakeEngineRuntime()
        let controller = makeController(runtime)
        await controller.start()
        #expect(!controller.isRestartRequired)

        await controller.installUpdate()
        #expect(controller.updateState == .installed(version: "2026.9.1"))
        #expect(controller.isRestartRequired)

        controller.revertToBundledVersion()
        #expect(controller.updateState == .idle)
        #expect(controller.isRestartRequired == runtime.isRestartRequired)
        #expect(!controller.isRestartRequired)
    }

    @Test("Taps while an install runs are ignored")
    func repeatedTapsWhileInstalling() async throws {
        let runtime = FakeEngineRuntime()
        runtime.delayInstalls(by: .milliseconds(300))
        let controller = makeController(runtime)
        await controller.start()

        let install = Task { await controller.installUpdate() }
        try await waitUntil("installing") { controller.updateState == .installing }

        await controller.installUpdate()
        await controller.checkForUpdates()
        controller.revertToBundledVersion()
        #expect(controller.updateState == .installing)

        await install.value
        #expect(controller.updateState == .installed(version: "2026.9.1"))
        #expect(runtime.installCount == 1)
    }
}
