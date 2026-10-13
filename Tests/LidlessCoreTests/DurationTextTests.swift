import Foundation
import Testing
import LidlessCore

@Suite("Typing a custom timer duration")
struct DurationTextTests {
    @Test(arguments: [
        ("45", 45), ("90", 90), ("1h30", 90), ("1h 30", 90), ("1 h 30 min", 90), ("1:30", 90),
        ("2h", 120), ("2 hours", 120), ("90m", 90), ("90 min", 90), ("20 minutes", 20),
        ("1.5h", 90), ("1,5 h", 90), ("  2 H 15  ", 135), ("0:45", 45), ("24h", 1440), ("1", 1),
        ("1:30:00", 90), ("2 hrs 5 mins", 125),
    ])
    func understandsMinutesAndHours(text: String, minutes: Int) {
        #expect(DurationText.parse(text) == TimeInterval(minutes * 60))
    }

    @Test func acceptsFractionsOfAMinute() {
        #expect(DurationText.parse("1.5") == 90)
        #expect(DurationText.parse("1,5 min") == 90)
        #expect(DurationText.parse("90.5m") == 5430)
        #expect(DurationText.parse("0:01:30") == 90)
    }

    // "1 30" is not "130 minutes": two numbers with nothing between them say nothing clear.
    @Test(arguments: [
        "", "  ", "abc", "0", "0h", "-5", "25h", "1441", "1:75", "1h90", "h", "1h30m10s", "3 days",
        "1 30", "2 15", "1 000", "1.5h30", "1:30:75", "0.5", "1..5", "1h h",
    ])
    func refusesWhatItCannotReadOrWillNotHonour(text: String) {
        #expect(DurationText.parse(text) == nil)
    }
}
