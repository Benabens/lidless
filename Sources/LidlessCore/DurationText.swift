import Foundation

/// Reads a timer duration the way people type one: `45`, `90 min`, `1h30`, `1:30`, `1.5h`.
public enum DurationText {
    /// Shortest and longest timer Lidless accepts.
    public static let range: ClosedRange<TimeInterval> = 60...(24 * 3600)

    /// The duration in seconds, or `nil` when the text is not a duration or falls outside `range`.
    /// A bare number means minutes. Anything ambiguous, like `1 30`, is refused rather than guessed.
    public static func parse(_ text: String) -> TimeInterval? {
        let cleaned = text.lowercased()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        guard let seconds = seconds(in: cleaned)?.rounded(), range.contains(seconds) else { return nil }
        return seconds
    }

    private static func seconds(in text: String) -> Double? {
        // 45 · 90m · 1.5 min
        if let match = text.wholeMatch(of: /(\d+(?:\.\d+)?)\s*(?:m|min|mins|minute|minutes)?/) {
            return Double(match.1).map { $0 * 60 }
        }
        // 1:30 · 1:30:00
        if let match = text.wholeMatch(of: /(\d+):(\d{1,2})(?::(\d{1,2}))?/) {
            guard let hours = Double(match.1), let minutes = Double(match.2), minutes < 60 else { return nil }
            let seconds = match.3.flatMap { Double($0) } ?? 0
            return seconds < 60 ? hours * 3600 + minutes * 60 + seconds : nil
        }
        // 2h · 1h30 · 1 h 30 min
        if let match = text.wholeMatch(of: /(\d+)\s*(?:h|hr|hrs|hour|hours)\s*(?:(\d+)\s*(?:m|min|mins|minute|minutes)?)?/) {
            guard let hours = Double(match.1) else { return nil }
            let minutes = match.2.flatMap { Double($0) } ?? 0
            return minutes < 60 ? hours * 3600 + minutes * 60 : nil
        }
        // 1.5h, on its own: a fraction of an hour followed by minutes says nothing clear.
        if let match = text.wholeMatch(of: /(\d+\.\d+)\s*(?:h|hr|hrs|hour|hours)/) {
            return Double(match.1).map { $0 * 3600 }
        }
        return nil
    }
}
