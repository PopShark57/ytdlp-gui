import AppKit
import Foundation
import Observation

/// Mirrors the queue's state into the system: the Dock tile and the sleep assertion.
///
/// Both follow the queue rather than the window, so they keep working when the window is closed
/// and the app lives in the menu bar.
///
/// - The Dock icon shows how many downloads are running or waiting, and a progress bar while
///   anything with a known size is transferring.
/// - While downloads run, the Mac is kept from idle-sleeping (the display may still sleep), so a
///   long batch left overnight isn't stopped halfway by the energy saver.
@MainActor
final class QueueActivityMonitor {

    private struct Snapshot: Equatable {
        var pending: Int
        var isRunning: Bool
        /// Rounded to whole percent so the tile is redrawn at most a hundred times per batch.
        var percent: Int?
    }

    private let queue: DownloadQueue
    private let settings: AppSettings
    private var observation: Task<Void, Never>?
    private var activity: (any NSObjectProtocol)?
    private var lastSnapshot: Snapshot?
    private lazy var progressTile = DockProgressTileView()

    init(queue: DownloadQueue, settings: AppSettings) {
        self.queue = queue
        self.settings = settings
    }

    /// Starts following the queue. Needs `NSApp`, so it's called once the first window exists.
    func start() {
        guard observation == nil else { return }
        let changes = Observations { [queue, settings] in
            let fraction = queue.aggregateProgress
            return (
                Snapshot(
                    pending: queue.activeCount + queue.queuedCount,
                    isRunning: queue.activeCount > 0,
                    percent: fraction.map { Int(($0 * 100).rounded()) }
                ),
                settings.preventsSleepWhileDownloading
            )
        }
        observation = Task { [weak self] in
            for await (snapshot, preventsSleep) in changes {
                self?.apply(snapshot, preventsSleep: preventsSleep)
            }
        }
    }

    func stop() {
        observation?.cancel()
        observation = nil
        endActivity()
        NSApp.dockTile.badgeLabel = nil
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
    }

    // MARK: - Applying

    private func apply(_ snapshot: Snapshot, preventsSleep: Bool) {
        if snapshot.isRunning && preventsSleep { beginActivity() } else { endActivity() }

        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot

        let tile = NSApp.dockTile
        tile.badgeLabel = snapshot.pending > 0 ? snapshot.pending.formatted() : nil
        if let percent = snapshot.percent, snapshot.isRunning {
            progressTile.fraction = Double(percent) / 100
            if tile.contentView !== progressTile { tile.contentView = progressTile }
        } else if tile.contentView != nil {
            tile.contentView = nil
        }
        tile.display()
    }

    private func beginActivity() {
        guard activity == nil else { return }
        // `.userInitiated` includes `.idleSystemSleepDisabled`, and also tells App Nap to leave
        // the process (and the main-actor code reading its children's output) at full speed.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated],
            reason: "Downloading media"
        )
    }

    private func endActivity() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }
}

/// The app icon with a progress bar along its bottom edge, drawn into the Dock tile.
private final class DockProgressTileView: NSView {

    var fraction: Double = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)

        let inset = bounds.width * 0.14
        let height = max(bounds.height * 0.085, 6)
        let track = NSRect(
            x: bounds.minX + inset,
            y: bounds.minY + bounds.height * 0.1,
            width: bounds.width - inset * 2,
            height: height
        )
        let radius = height / 2

        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        let clamped = min(max(fraction, 0), 1)
        guard clamped > 0 else { return }
        let inner = track.insetBy(dx: 1.5, dy: 1.5)
        var fill = inner
        fill.size.width = max(inner.height, inner.width * clamped)
        let innerRadius = inner.height / 2
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: innerRadius, yRadius: innerRadius).fill()
    }
}
