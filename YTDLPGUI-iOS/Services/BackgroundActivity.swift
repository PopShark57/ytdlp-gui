import BackgroundTasks
import SwiftUI
import UIKit
import os

/// What the queue is doing, as far as background execution and the idle timer care.
struct QueueActivity: Equatable, Sendable {
    var activeCount = 0
    var queuedCount = 0
    /// Downloads that finished (in any way) since the queue was last idle.
    var finishedCount = 0
    /// Progress of everything since the queue was last idle, 0...1: finished downloads count
    /// as whole, running ones by their fraction, waiting ones as nothing.
    var fractionCompleted: Double = 0
    /// The download to name in system UI, usually the first one running.
    var currentTitle: String?

    static let idle = QueueActivity()

    var isBusy: Bool { activeCount > 0 || queuedCount > 0 }
    var totalCount: Int { activeCount + queuedCount + finishedCount }
}

/// Keeps downloads running when the person leaves the app, and the screen awake while they watch.
///
/// iOS suspends a backgrounded app within seconds, which would freeze every download mid-file.
///
/// - On iOS 26 and later, a download started in the foreground submits a
///   `BGContinuedProcessingTaskRequest`. The system then lets the queue keep running, showing its
///   progress in system UI; if it ever has to stop the work, running downloads are cancelled
///   cleanly so they resume from their partial files later.
/// - Earlier systems get the standard short extension from `beginBackgroundTask` when the app
///   leaves the foreground with work in progress.
@MainActor
final class BackgroundActivity {

    /// Must match the wildcard entry in `BGTaskSchedulerPermittedIdentifiers` (Info.plist).
    static let taskIdentifierPrefix = "io.github.ytdlpgui.YTDLPGUI.iOS.downloads"

    /// Called when the system is about to stop background work. The queue cancels running
    /// downloads there, keeping their partial files, so they can resume later.
    var onExpiration: (() -> Void)?

    private let settings: AppSettings
    private let setIdleTimerDisabled: (Bool) -> Void
    /// Off in tests, which run outside an app that could be given background time.
    private let requestsBackgroundTime: Bool
    private let logger = Logger(subsystem: "io.github.ytdlpgui.YTDLPGUI.iOS", category: "background")

    private var phase: ScenePhase = .active
    private var activity = QueueActivity.idle
    private var isIdleTimerDisabled = false
    private var legacyTask: UIBackgroundTaskIdentifier = .invalid

    /// The iOS 26 continued-processing session, typed loosely so this class can exist on iOS 18.
    private var continuedSession: AnyObject?
    /// Set when the system refused a continued-processing request for the current batch, so it
    /// isn't asked again on every progress tick. Cleared when the queue goes idle.
    private var continuedProcessingUnavailable = false

    init(
        settings: AppSettings,
        setIdleTimerDisabled: ((Bool) -> Void)? = nil,
        requestsBackgroundTime: Bool = true
    ) {
        self.settings = settings
        self.requestsBackgroundTime = requestsBackgroundTime
        self.setIdleTimerDisabled = setIdleTimerDisabled ?? { disabled in
            UIApplication.shared.isIdleTimerDisabled = disabled
        }
    }

    // MARK: - Inputs

    /// Called by the queue whenever its state or progress changes.
    func update(_ activity: QueueActivity) {
        let wasBusy = self.activity.isBusy
        self.activity = activity
        applyIdleTimer()

        guard activity.isBusy else {
            if wasBusy { queueDrained() }
            return
        }
        guard requestsBackgroundTime else { return }

        if #available(iOS 26.0, *) {
            if continuedSession == nil, phase == .active, !continuedProcessingUnavailable {
                submitContinuedProcessing()
            }
            (continuedSession as? ContinuedProcessingSession)?.report(activity)
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        self.phase = phase
        applyIdleTimer()

        switch phase {
        case .background:
            if requestsBackgroundTime, activity.isBusy, !isContinuedProcessingRunning {
                beginLegacyTask()
            }
        case .active:
            // In the foreground the app runs anyway; holding the extension would only use up
            // the time the system allows for the next trip to the background.
            endLegacyTask()
        default:
            break
        }
    }

    // MARK: - Idle timer

    private func applyIdleTimer() {
        let disable = settings.keepScreenAwake && activity.activeCount > 0 && phase == .active
        guard disable != isIdleTimerDisabled else { return }
        isIdleTimerDisabled = disable
        setIdleTimerDisabled(disable)
    }

    // MARK: - Finishing

    private func queueDrained() {
        if #available(iOS 26.0, *) {
            (continuedSession as? ContinuedProcessingSession)?.complete(success: true)
        }
        continuedSession = nil
        continuedProcessingUnavailable = false
        endLegacyTask()
    }

    private func expire() {
        logger.info("Background time is ending; pausing running downloads.")
        onExpiration?()
    }

    // MARK: - Continued processing (iOS 26 and later)

    private var isContinuedProcessingRunning: Bool {
        guard #available(iOS 26.0, *) else { return false }
        return (continuedSession as? ContinuedProcessingSession)?.isRunning ?? false
    }

    @available(iOS 26.0, *)
    private func submitContinuedProcessing() {
        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let identifier = "\(Self.taskIdentifierPrefix).\(unique)"
        let session = ContinuedProcessingSession(identifier: identifier)
        session.onExpiration = { [weak self] in
            self?.continuedSession = nil
            self?.expire()
        }

        let text = ContinuedProcessingSession.text(for: activity)
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: text.title, subtitle: text.subtitle)
        // Asking to be queued would let the system start the work after it no longer matters.
        // Failing fast instead falls back to the ordinary background-task extension.
        request.strategy = .fail

        // Continued-processing handlers are exempt from the register-before-launch-finishes rule,
        // and each submission uses a fresh identifier, which may only be registered once.
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak session] task in
            MainActor.assumeIsolated {
                guard let session, let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                session.begin(task)
            }
        }
        guard registered else {
            logger.error("The continued-processing identifier isn't permitted by Info.plist.")
            continuedProcessingUnavailable = true
            return
        }

        do {
            try BGTaskScheduler.shared.submit(request)
            continuedSession = session
            session.report(activity)
        } catch {
            // Expected in the Simulator and when the person has turned off background activity.
            logger.info("Continued processing unavailable: \(error.localizedDescription, privacy: .public)")
            continuedProcessingUnavailable = true
        }
    }

    // MARK: - Background task extension (all versions)

    private func beginLegacyTask() {
        guard legacyTask == .invalid else { return }
        legacyTask = UIApplication.shared.beginBackgroundTask(withName: "Downloads") { [weak self] in
            MainActor.assumeIsolated {
                self?.expire()
                self?.endLegacyTask()
            }
        }
    }

    private func endLegacyTask() {
        guard legacyTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(legacyTask)
        legacyTask = .invalid
    }
}

/// One submitted continued-processing task: reports the queue's progress to it, and finishes it.
@available(iOS 26.0, *)
@MainActor
private final class ContinuedProcessingSession {

    let identifier: String
    var onExpiration: (() -> Void)?

    private var task: BGContinuedProcessingTask?
    private var lastActivity = QueueActivity.idle
    private var isFinished = false

    /// Fine enough that the system sees steady movement, which it uses to tell a stalled task
    /// from a working one.
    private static let progressUnits: Int64 = 1_000

    init(identifier: String) {
        self.identifier = identifier
    }

    var isRunning: Bool { task != nil && !isFinished }

    func begin(_ task: BGContinuedProcessingTask) {
        guard !isFinished else {
            task.setTaskCompleted(success: true)
            return
        }
        self.task = task
        task.progress.totalUnitCount = Self.progressUnits
        // Called on an arbitrary queue; everything it touches lives on the main actor.
        task.expirationHandler = { @Sendable [weak self] in
            Task { @MainActor in self?.expire() }
        }
        report(lastActivity)
    }

    func report(_ activity: QueueActivity) {
        lastActivity = activity
        guard let task, !isFinished else { return }
        let completed = Int64((activity.fractionCompleted * Double(Self.progressUnits)).rounded())
        task.progress.completedUnitCount = min(max(completed, task.progress.completedUnitCount), Self.progressUnits)
        let text = Self.text(for: activity)
        if task.title != text.title || task.subtitle != text.subtitle {
            task.updateTitle(text.title, subtitle: text.subtitle)
        }
    }

    func complete(success: Bool) {
        guard !isFinished else { return }
        isFinished = true
        task?.progress.completedUnitCount = Self.progressUnits
        task?.setTaskCompleted(success: success)
        task = nil
    }

    private func expire() {
        guard !isFinished else { return }
        onExpiration?()
        complete(success: false)
    }

    static func text(for activity: QueueActivity) -> (title: String, subtitle: String) {
        let remaining = activity.activeCount + activity.queuedCount
        let title: String
        if remaining <= 1, let current = activity.currentTitle {
            title = "Downloading “\(current)”"
        } else {
            title = "Downloading \(remaining) items"
        }

        var parts: [String] = []
        if activity.totalCount > 1 {
            parts.append("\(activity.finishedCount) of \(activity.totalCount) done")
        }
        if let percent = Format.percent(activity.fractionCompleted) {
            parts.append(percent)
        }
        return (title, parts.isEmpty ? "Starting…" : parts.joined(separator: " · "))
    }
}
