import Foundation

/// Reads a timer duration the way people type one: `45`, `90 min`, `1h30`, `1:30`, `1.5h`.
public enum DurationText {
    /// Shortest and longest timer Lidless accepts.
    public static let range: ClosedRange<TimeInterval> = 60...(24 * 3600)

    /// The duration in seconds, or `nil` when the text is not a duration or falls outside `range`.
    /// A bare number means minutes.
    public static func parse(_ text: String) -> TimeInterval? {
        let compact = text.lowercased().filter { !$0.isWhitespace }.replacingOccurrences(of: ",", with: ".")
        guard let minutes = minutes(in: compact) else { return nil }
        let seconds = (minutes * 60).rounded()
        return range.contains(seconds) ? seconds : nil
    }

    private static func minutes(in text: String) -> Double? {
        if let match = text.wholeMatch(of: /(\d+)(?:m|min|mins|minute|minutes)?/) {
            return Double(match.1)
        }
        if let match = text.wholeMatch(of: /(\d+):(\d{1,2})/) {
            return combine(hours: Double(match.1), minutes: Double(match.2))
        }
        if let match = text.wholeMatch(of: /(\d+(?:\.\d+)?)(?:h|hr|hrs|hour|hours)(?:(\d+)(?:m|min|mins|minute|minutes)?)?/) {
            return combine(hours: Double(match.1), minutes: match.2.map { Double($0) } ?? 0)
        }
        return nil
    }

    private static func combine(hours: Double?, minutes: Double?) -> Double? {
        guard let hours, let minutes, minutes < 60 else { return nil }
        return hours * 60 + minutes
    }
}
