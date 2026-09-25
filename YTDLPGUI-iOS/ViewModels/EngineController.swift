import CoreMedia
import Observation
import SwiftUI
import VideoToolbox

/// The state of the embedded yt-dlp engine, for the UI. The iOS counterpart of `Toolchain`.
///
/// Where the macOS app looks for tools on disk, this starts the interpreter bundled with the app
/// and reports what it is built from. Starting takes a moment (Python and yt-dlp are imported on
/// a background thread), so the rest of the app waits on `start()` rather than on launch.
@MainActor
@Observable
final class EngineController {

    enum State: Equatable {
        case notStarted
        case starting
        case ready(EngineInfo)
        case failed(String)
    }

    enum UpdateState: Equatable {
        case idle
        case checking
        case upToDate(version: String)
        case available(EngineUpdateInfo)
        case installing
        /// Installed; takes effect at the next launch.
        case installed(version: String)
        case failed(String)
    }

    private(set) var state: State = .notStarted
    private(set) var updateState: UpdateState = .idle

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    var info: EngineInfo? {
        if case .ready(let info) = state { return info }
        return nil
    }

    /// Why the engine couldn't start, when it couldn't.
    var failureMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    /// What this device's engine can do, for argument building.
    private(set) var capabilities = EmbeddedEngineCapabilities()

    /// Whether an installed update is waiting for the app to restart.
    private(set) var isRestartRequired = false

    private let runtime: any EngineRuntime
    @ObservationIgnored private var startTask: Task<Void, Never>?

    /// - Parameters:
    ///   - temporaryDirectory: Where partial downloads are kept (`--paths temp:`).
    ///   - allowsAV1: Whether AV1 may be downloaded; by default, whether this device decodes AV1
    ///     in hardware. Software decoding of AV1 drains the battery and stutters above 1080p, so
    ///     an AV1 file would be worse than the H.264 one it replaced.
    init(engine: YTDLPEngine = .shared, temporaryDirectory: URL? = nil, allowsAV1: Bool? = nil) {
        runtime = engine
        capabilities = EmbeddedEngineCapabilities(
            allowsAV1: allowsAV1 ?? Self.deviceDecodesAV1InHardware(),
            temporaryDirectory: temporaryDirectory
        )
    }

    /// For tests: drives the controller with any runtime.
    init(runtime: any EngineRuntime, temporaryDirectory: URL? = nil, allowsAV1: Bool = false) {
        self.runtime = runtime
        capabilities = EmbeddedEngineCapabilities(allowsAV1: allowsAV1, temporaryDirectory: temporaryDirectory)
    }

    static func deviceDecodesAV1InHardware() -> Bool {
        VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
    }

    // MARK: - Starting

    /// Starts the engine if it isn't running. Safe to call repeatedly: callers that arrive while
    /// it is starting wait for the same attempt, and a failed attempt can be retried.
    func start() async {
        if isReady { return }
        if let startTask {
            await startTask.value
            return
        }

        state = .starting
        let task = Task {
            do {
                let info = try await runtime.start()
                state = .ready(info)
            } catch {
                state = .failed(error.localizedDescription)
            }
            isRestartRequired = runtime.isRestartRequired
        }
        startTask = task
        await task.value
        startTask = nil
    }

    /// Starts the engine if needed and reports whether downloads can run.
    func startIfNeeded() async -> Bool {
        await start()
        return isReady
    }

    // MARK: - Updating yt-dlp

    func checkForUpdates() async {
        guard !isUpdateInFlight else { return }
        updateState = .checking
        guard await startIfNeeded() else {
            updateState = .failed(failureMessage ?? "The download engine isn't running.")
            return
        }
        do {
            let update = try await runtime.checkForUpdate()
            updateState = update.isNewer
                ? .available(update)
                : .upToDate(version: update.currentVersion)
        } catch {
            updateState = .failed("Couldn't check for updates: \(error.localizedDescription)")
        }
    }

    /// Downloads, verifies and installs the newest yt-dlp. It takes effect at the next launch,
    /// because the running interpreter has already imported the current copy.
    func installUpdate() async {
        guard !isUpdateInFlight else { return }
        updateState = .installing
        guard await startIfNeeded() else {
            updateState = .failed(failureMessage ?? "The download engine isn't running.")
            return
        }
        do {
            let version = try await runtime.installLatestUpdate()
            updateState = .installed(version: version)
        } catch {
            updateState = .failed("The update couldn't be installed: \(error.localizedDescription)")
        }
        isRestartRequired = runtime.isRestartRequired
    }

    /// Removes an installed update so the copy of yt-dlp bundled with the app is used from the
    /// next launch.
    func revertToBundledVersion() {
        guard !isUpdateInFlight else { return }
        do {
            try runtime.revertToBundledVersion()
            updateState = .idle
        } catch {
            updateState = .failed("The bundled version couldn't be restored: \(error.localizedDescription)")
        }
        isRestartRequired = runtime.isRestartRequired
    }

    private var isUpdateInFlight: Bool {
        updateState == .checking || updateState == .installing
    }
}
