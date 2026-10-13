import Foundation

/// User-tunable behaviour. Durations are in seconds.
public struct LidlessSettings: Equatable, Sendable {
    public var trackedAgents: Set<Agent>
    /// How long to stay awake after the last turn ends, so back-to-back turns do not race sleep.
    public var gracePeriod: TimeInterval
    /// Only keep the Mac awake while it is plugged in. Off by default: running on battery, lid
    /// closed, is the main use.
    public var acOnly: Bool
    /// Below this battery percentage Lidless stops keeping the Mac awake, lid open or closed.
    public var batteryFloor: Int
    /// Hard ceiling on one uninterrupted stretch of wakefulness.
    public var maxAwakeDuration: TimeInterval
    /// A working session that sends no event for this long is treated as idle. `0` disables it.
    public var stallTimeout: TimeInterval

    public init(
        trackedAgents: Set<Agent> = Set(Agent.allCases),
        gracePeriod: TimeInterval = 2 * 60,
        acOnly: Bool = false,
        batteryFloor: Int = 20,
        maxAwakeDuration: TimeInterval = 6 * 3600,
        stallTimeout: TimeInterval = 30 * 60
    ) {
        self.trackedAgents = trackedAgents
        self.gracePeriod = gracePeriod
        self.acOnly = acOnly
        self.batteryFloor = batteryFloor
        self.maxAwakeDuration = maxAwakeDuration
        self.stallTimeout = stallTimeout
    }
}

public struct PowerState: Equatable, Sendable {
    public var isOnAC: Bool
    /// `nil` on Macs without a battery.
    public var batteryPercent: Int?

    public init(isOnAC: Bool, batteryPercent: Int?) {
        self.isOnAC = isOnAC
        self.batteryPercent = batteryPercent
    }
}

/// How hot the Mac is running, as macOS reports it.
public enum ThermalPressure: Int, Comparable, Sendable {
    case nominal
    case fair
    /// Fans at full speed, performance being cut back.
    case serious
    /// The Mac needs to cool down now.
    case critical

    public static func < (lhs: ThermalPressure, rhs: ThermalPressure) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The user asked for the Mac to stay awake whatever the agents do: a timer, or an open-ended hold.
public struct ManualHold: Equatable, Sendable {
    /// When the hold ends. `nil`: until the user turns it off.
    public var until: Date?
    /// Also keep the Mac awake with its lid closed, under the same guards as closed-lid mode.
    public var withLidClosed: Bool

    public init(until: Date?, withLidClosed: Bool = false) {
        self.until = until
        self.withLidClosed = withLidClosed
    }
}

/// What the user set from the menu. The reconciler may switch any of it back off.
public struct Switches: Equatable, Sendable {
    public var manualHold: ManualHold?
    /// Closed-lid mode for agents is armed.
    public var lidArmed: Bool

    public init(manualHold: ManualHold? = nil, lidArmed: Bool = false) {
        self.manualHold = manualHold
        self.lidArmed = lidArmed
    }
}
