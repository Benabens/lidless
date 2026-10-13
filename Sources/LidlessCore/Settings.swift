import Foundation

/// User-tunable behaviour. Durations are in seconds.
public struct LidlessSettings: Equatable, Sendable {
    public var trackedAgents: Set<Agent>
    /// How long to stay awake after the last turn ends, so back-to-back turns do not race sleep.
    public var gracePeriod: TimeInterval
    /// Only keep the Mac awake while it is plugged in.
    public var acOnly: Bool
    /// Below this battery percentage Lidless stops keeping the Mac awake.
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

/// The two switches the user flips from the menu. The reconciler may flip them back off.
public struct Switches: Equatable, Sendable {
    public var keepAwakeAnyway: Bool
    public var lidArmed: Bool

    public init(keepAwakeAnyway: Bool = false, lidArmed: Bool = false) {
        self.keepAwakeAnyway = keepAwakeAnyway
        self.lidArmed = lidArmed
    }
}
