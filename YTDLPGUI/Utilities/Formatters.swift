import Foundation

/// A mutex-protected box.
///
/// Foundation's formatters are not `Sendable` and not documented as thread-safe, but they are
/// expensive enough that creating one per progress tick is wasteful. Sharing one behind a lock
/// gets both correctness and reuse.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withValue<Result>(_ body: (Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(value)
    }
}

/// Shared, pre-configured formatters used throughout the UI.
enum Format {

    // MARK: - Byte counts

    private static let byteFormatter = Locked<ByteCountFormatter>({
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.isAdaptive = true
        return formatter
    }())

    /// `"12.4 MB"`. Returns `nil` for missing or negative values.
    static func bytes(_ value: Int64?) -> String? {
        guard let value, value >= 0 else { return nil }
        return byteFormatter.withValue { $0.string(fromByteCount: value) }
    }

    /// `"1.2 MB/s"`. Returns `nil` for missing or non-positive rates.
    static func speed(_ bytesPerSecond: Double?) -> String? {
        guard let bytesPerSecond, bytesPerSecond > 0, bytesPerSecond.isFinite else { return nil }
        guard let amount = bytes(Int64(bytesPerSecond)) else { return nil }
        return "\(amount)/s"
    }

    /// `"3.2 MB of 41.8 MB"`, or just the downloaded amount when the total is unknown.
    static func transferred(downloaded: Int64?, total: Int64?) -> String? {
        switch (bytes(downloaded), bytes(total)) {
        case let (.some(done), .some(all)): "\(done) of \(all)"
        case let (.some(done), .none): done
        case let (.none, .some(all)): all
        case (.none, .none): nil
        }
    }

    // MARK: - Durations

    private static let approximateFormatter = Locked<DateComponentsFormatter>({
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }())

    /// Clock-style media length: `"4:21"` or `"1:04:21"`.
    static func duration(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }

    /// Human ETA: `"about 2 min"`, `"12s"`.
    static func eta(_ seconds: Int?) -> String? {
        guard let seconds, seconds >= 0 else { return nil }
        if seconds == 0 { return "finishing" }
        return approximateFormatter.withValue { $0.string(from: TimeInterval(seconds)) }
    }

    /// Elapsed time in the same style as `eta`.
    static func elapsed(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        return approximateFormatter.withValue { $0.string(from: seconds) } ?? "0s"
    }

    /// Long-form duration for the media info card, e.g. `"1 hr 4 min"`.
    static func longDuration(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return approximateFormatter.withValue { $0.string(from: seconds) }
    }

    // MARK: - Percentages

    private static let percentFormatter = Locked<NumberFormatter>({
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 0
        return formatter
    }())

    /// `"48.2%"` from a 0...1 fraction.
    static func percent(_ fraction: Double?) -> String? {
        guard let fraction, fraction.isFinite else { return nil }
        let clamped = min(max(fraction, 0), 1)
        return percentFormatter.withValue { $0.string(from: NSNumber(value: clamped)) }
    }

    // MARK: - Dates

    private static let relativeDateFormatter = Locked<RelativeDateTimeFormatter>({
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }())

    private static let absoluteDateFormatter = Locked<DateFormatter>({
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }())

    private static let mediumDateFormatter = Locked<DateFormatter>({
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }())

    /// `"2 hr ago"` for recent dates, an absolute date beyond a week.
    static func relativeDate(_ date: Date, reference: Date = Date()) -> String {
        if reference.timeIntervalSince(date) < 7 * 24 * 60 * 60 {
            return relativeDateFormatter.withValue { $0.localizedString(for: date, relativeTo: reference) }
        }
        return absoluteDateFormatter.withValue { $0.string(from: date) }
    }

    static func absoluteDate(_ date: Date) -> String {
        absoluteDateFormatter.withValue { $0.string(from: date) }
    }

    static func mediumDate(_ date: Date) -> String {
        mediumDateFormatter.withValue { $0.string(from: date) }
    }

    /// Parses yt-dlp's `upload_date` field, which is a bare `YYYYMMDD` string.
    static func parseUploadDate(_ raw: String?) -> Date? {
        guard let raw, raw.count == 8, raw.allSatisfy(\.isNumber) else { return nil }
        var components = DateComponents()
        components.year = Int(raw.prefix(4))
        components.month = Int(raw.dropFirst(4).prefix(2))
        components.day = Int(raw.suffix(2))
        return Calendar(identifier: .gregorian).date(from: components)
    }

    // MARK: - Counts

    private static let decimalFormatter = Locked<NumberFormatter>({
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }())

    /// `"403,947,630"`.
    static func count(_ value: Int?) -> String? {
        guard let value, value >= 0 else { return nil }
        return decimalFormatter.withValue { $0.string(from: NSNumber(value: value)) }
    }

    /// Compact count for dense UI: `"404M"`, `"19.3M"`, `"12K"`.
    static func compactCount(_ value: Int?) -> String? {
        guard let value, value >= 0 else { return nil }
        switch value {
        case 1_000_000_000...:
            return String(format: "%.1fB", Double(value) / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.1fM", Double(value) / 1_000_000)
        case 10_000...:
            return String(format: "%.0fK", Double(value) / 1_000)
        default:
            return count(value)
        }
    }
}
