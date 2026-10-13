import Foundation
import Testing
import LidlessCore

@Suite("Typing a custom timer duration")
struct DurationTextTests {
    @Test(arguments: [
        ("45", 45), ("90", 90), ("1h30", 90), ("1h 30", 90), ("1 h 30 min", 90), ("1:30", 90),
        ("2h", 120), ("2 hours", 120), ("90m", 90), ("90 min", 90), ("20 minutes", 20),
        ("1.5h", 90), ("1,5 h", 90), ("  2 H 15  ", 135), ("0:45", 45), ("24h", 1440), ("1", 1),
    ])
    func understandsMinutesAndHours(text: String, minutes: Int) {
        #expect(DurationText.parse(text) == TimeInterval(minutes * 60))
    }

    @Test(arguments: ["", "  ", "abc", "0", "0h", "-5", "25h", "1441", "1:75", "1h90", "h", "1h30m10s", "3 days"])
    func refusesWhatItCannotReadOrWillNotHonour(text: String) {
        #expect(DurationText.parse(text) == nil)
    }
}
