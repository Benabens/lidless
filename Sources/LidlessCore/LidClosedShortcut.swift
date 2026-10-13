import Foundation

/// The menu's one-click shortcut: keep the Mac awake with the lid closed for half an hour, agents
/// or not. It is only a way in: the hold it starts is an ordinary timer with its lid option on,
/// so it runs under the same guards as any other.
public enum LidClosedShortcut {
    public static let duration: TimeInterval = 30 * 60

    public enum State: Equatable, Sendable {
        /// The sudoers rule is missing: a click leads to the setup.
        case needsSetup
        /// Something rules the lid out right now (battery, heat, power adapter only).
        case unavailable(LidDisarmReason)
        /// A click starts the 30 minutes.
        case ready
        /// A hold already keeps the lid, whoever started it: a click stops it. `until` is `nil`
        /// for an open-ended hold.
        case running(until: Date?)
    }

    public static func hold(startingAt now: Date) -> ManualHold {
        ManualHold(until: now.addingTimeInterval(duration), withLidClosed: true)
    }

    /// What the menu item should offer. A running hold comes first: it must always be stoppable.
    public static func state(hold: ManualHold?, ruleInstalled: Bool, obstacle: LidDisarmReason?) -> State {
        if let hold, hold.withLidClosed { return .running(until: hold.until) }
        guard ruleInstalled else { return .needsSetup }
        if let obstacle { return .unavailable(obstacle) }
        return .ready
    }
}
