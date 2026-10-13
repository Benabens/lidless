import Foundation
import IOKit.pwr_mgt

/// The IOKit power assertion that keeps the system from idle-sleeping. The display may still
/// turn off: only system sleep is blocked.
@MainActor
final class SleepAssertion {
    private var assertionID = IOPMAssertionID(0)
    private(set) var isHeld = false

    func set(held: Bool, reason: String) {
        guard held != isHeld else { return }
        if held {
            var newID = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &newID
            )
            guard result == kIOReturnSuccess else { return }
            assertionID = newID
            isHeld = true
        } else {
            IOPMAssertionRelease(assertionID)
            assertionID = IOPMAssertionID(0)
            isHeld = false
        }
    }
}
