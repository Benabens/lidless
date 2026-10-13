import Foundation

/// Memory the reconciler carries from one pass to the next.
public struct EngineState: Equatable, Sendable {
    /// Start of the current uninterrupted stretch of wakefulness.
    public var awakeSince: Date?
    /// Set when the safety cap released the Mac. Whatever was already asking for wakefulness at
    /// that moment is ignored until it ends, so a stuck session cannot re-acquire the hold.
    public var capTrippedAt: Date?
    /// Closed-lid mode has been active since it was armed, so the end of work should disarm it.
    public var lidEngaged: Bool
    /// The last moment a session was working. The grace period counts from here, which keeps it
    /// running after the session's record is gone (session closed, process exited).
    public var lastWorkAt: Date?
    /// When the previous pass ran. A long gap means the Mac slept in between.
    public var lastPassAt: Date?

    public init(
        awakeSince: Date? = nil,
        capTrippedAt: Date? = nil,
        lidEngaged: Bool = false,
        lastWorkAt: Date? = nil,
        lastPassAt: Date? = nil
    ) {
        self.awakeSince = awakeSince
        self.capTrippedAt = capTrippedAt
        self.lidEngaged = lidEngaged
        self.lastWorkAt = lastWorkAt
        self.lastPassAt = lastPassAt
    }
}

public struct ReconcilerInput: Sendable {
    public var now: Date
    public var sessions: [ObservedSession]
    public var power: PowerState
    public var thermal: ThermalPressure
    public var settings: LidlessSettings
    public var switches: Switches
    public var state: EngineState

    public init(
        now: Date,
        sessions: [ObservedSession],
        power: PowerState,
        thermal: ThermalPressure = .nominal,
        settings: LidlessSettings,
        switches: Switches,
        state: EngineState
    ) {
        self.now = now
        self.sessions = sessions
        self.power = power
        self.thermal = thermal
        self.settings = settings
        self.switches = switches
        self.state = state
    }
}

/// Why Lidless declines to keep the Mac awake although something asks for it.
public enum SuppressReason: Equatable, Sendable {
    case onBattery
    case lowBattery
    case capReached
}

/// Why closed-lid mode switched itself off.
public enum LidDisarmReason: Equatable, Sendable {
    case workFinished
    /// Unplugged while "only on power adapter" is on.
    case onBattery
    case lowBattery
    case overheating
    case capReached
}

public enum Status: Equatable, Sendable {
    /// Nothing asks for wakefulness: the Mac sleeps as usual.
    case idle
    case working(count: Int)
    /// Every agent finished; staying awake until the grace period runs out.
    case grace(until: Date)
    /// Only "Keep Awake Anyway" holds the Mac awake.
    case manual
    case suppressed(SuppressReason)
}

public struct Outcome: Equatable, Sendable {
    /// Hold the "prevent idle system sleep" assertion.
    public var keepAwake: Bool
    /// Also keep the Mac awake with its lid closed (`pmset disablesleep 1`).
    public var disableLidSleep: Bool
    /// Set on the pass where closed-lid mode disarms itself.
    public var lidDisarmReason: LidDisarmReason?
    public var status: Status
    /// The switches after this pass: the reconciler turns them off when a safety rule fires.
    public var switches: Switches
    /// Live sessions of tracked agents, in menu order.
    public var sessions: [SessionRecord]
    /// Records to delete: the process is gone, or the session sat idle for `idleRetention`.
    public var staleSessionIDs: [String]
    public var state: EngineState
}

/// Decides, from a snapshot of the world, whether the Mac should be kept awake.
/// Pure: same input, same outcome. It changes nothing itself; the caller applies the outcome.
public enum Reconciler {
    /// Idle sessions are forgotten after this long. A later event simply records them again.
    public static let idleRetention: TimeInterval = 24 * 3600
    /// Passes run every few seconds; a gap this long means the Mac was asleep in between.
    public static let sleepGap: TimeInterval = 60

    public static func reconcile(_ input: ReconcilerInput) -> Outcome {
        let settings = input.settings
        let now = input.now
        var state = input.state
        var switches = input.switches

        // Time asleep is not time kept awake: sleeping ends the stretch the cap measures.
        if let lastPass = state.lastPassAt, now.timeIntervalSince(lastPass) > sleepGap {
            state.awakeSince = nil
        }
        state.lastPassAt = now

        let isStale = { (session: ObservedSession) in
            !session.isAlive || (session.record.state == .idle
                && now.timeIntervalSince(session.record.updatedAt) >= idleRetention)
        }
        let staleSessionIDs = input.sessions.filter(isStale).map(\.record.id)
        let live = input.sessions
            .filter { !isStale($0) && settings.trackedAgents.contains($0.record.agent) }
            .map(\.record)

        // After the cap trips, only what began later counts.
        let trippedAt = state.capTrippedAt
        let isAfterCap = { (instant: Date) in trippedAt.map { instant > $0 } ?? true }

        let active = live.filter { $0.state == .working && !$0.isStalled(at: now, timeout: settings.stallTimeout) }
        let working = active.filter { isAfterCap($0.workingSince ?? $0.updatedAt) }

        // The grace period runs from the last moment of work: now if someone is working, else
        // the end of the most recent turn.
        let turnEnds = live.compactMap { $0.state == .idle ? $0.idleSince : nil }.map { min($0, now) }
        let lastWork = ([state.lastWorkAt] + turnEnds + [working.isEmpty ? nil : now]).compactMap { $0 }.max()
        state.lastWorkAt = lastWork
        let graceEnd = lastWork.map { $0.addingTimeInterval(settings.gracePeriod) }.flatMap { $0 > now ? $0 : nil }
        let graceUntil = lastWork.flatMap { isAfterCap($0) ? graceEnd : nil }

        // The cap stays tripped for as long as something from before it still asks.
        let capStillApplies = trippedAt != nil && (working.count < active.count || (graceEnd != nil && graceUntil == nil))
        if !capStillApplies { state.capTrippedAt = nil }

        var status: Status
        if !working.isEmpty {
            status = .working(count: working.count)
        } else if let graceUntil {
            status = .grace(until: graceUntil)
        } else if switches.keepAwakeAnyway {
            status = .manual
        } else if capStillApplies {
            status = .suppressed(.capReached)
        } else {
            status = .idle
        }

        var keepAwake = false
        var capTrippedNow = false
        switch status {
        case .working, .grace, .manual:
            if let reason = powerSuppression(input.power, settings: settings) {
                status = .suppressed(reason)
            } else {
                let since = state.awakeSince ?? now
                if now.timeIntervalSince(since) >= settings.maxAwakeDuration {
                    state.capTrippedAt = now
                    capTrippedNow = true
                    switches.keepAwakeAnyway = false
                    status = .suppressed(.capReached)
                } else {
                    state.awakeSince = since
                    keepAwake = true
                }
            }
        case .idle, .suppressed:
            break
        }
        if !keepAwake { state.awakeSince = nil }

        // Closed-lid mode follows the agents only: "Keep Awake Anyway" never engages it. Real
        // work engages it; the grace period merely keeps it engaged.
        var disableLidSleep = false
        var lidDisarmReason: LidDisarmReason?
        if switches.lidArmed {
            if let obstacle = lidObstacle(power: input.power, settings: settings, thermal: input.thermal) {
                lidDisarmReason = obstacle
            } else if capTrippedNow {
                lidDisarmReason = .capReached
            } else if !working.isEmpty || (state.lidEngaged && graceUntil != nil) {
                disableLidSleep = true
                state.lidEngaged = true
            } else if state.lidEngaged {
                lidDisarmReason = .workFinished
            }
            if lidDisarmReason != nil { switches.lidArmed = false }
        }
        if !switches.lidArmed { state.lidEngaged = false }

        return Outcome(
            keepAwake: keepAwake,
            disableLidSleep: disableLidSleep,
            lidDisarmReason: lidDisarmReason,
            status: status,
            switches: switches,
            sessions: live.sorted(by: menuOrder),
            staleSessionIDs: staleSessionIDs,
            state: state
        )
    }

    /// What rules closed-lid mode out right now, whoever is working. `nil` when it may be armed.
    /// Battery power alone is no obstacle: a Mac closed in a bag, unplugged, is what the mode is
    /// for. Heat and a low battery are, plugged in or not.
    public static func lidObstacle(
        power: PowerState, settings: LidlessSettings, thermal: ThermalPressure
    ) -> LidDisarmReason? {
        if thermal >= .serious { return .overheating }
        if settings.acOnly, !power.isOnAC { return .onBattery }
        if let percent = power.batteryPercent, percent < settings.batteryFloor { return .lowBattery }
        return nil
    }

    private static func powerSuppression(_ power: PowerState, settings: LidlessSettings) -> SuppressReason? {
        guard !power.isOnAC else { return nil }
        if settings.acOnly { return .onBattery }
        if let percent = power.batteryPercent, percent < settings.batteryFloor { return .lowBattery }
        return nil
    }

    /// Working sessions first, then whichever was active most recently.
    private static func menuOrder(_ a: SessionRecord, _ b: SessionRecord) -> Bool {
        if (a.state == .working) != (b.state == .working) { return a.state == .working }
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        return a.id < b.id
    }
}
