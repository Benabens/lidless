import Foundation

/// Memory the reconciler carries from one pass to the next.
public struct EngineState: Equatable, Sendable {
    /// Start of the current uninterrupted stretch of wakefulness.
    public var awakeSince: Date?
    /// Set when the safety cap released the Mac. Turns that were already running at that moment
    /// are ignored until they end, so a stuck session cannot immediately re-acquire the hold.
    public var capTrippedAt: Date?
    /// Closed-lid mode has been active since it was armed, so the end of work should disarm it.
    public var lidEngaged: Bool

    public init(awakeSince: Date? = nil, capTrippedAt: Date? = nil, lidEngaged: Bool = false) {
        self.awakeSince = awakeSince
        self.capTrippedAt = capTrippedAt
        self.lidEngaged = lidEngaged
    }
}

public struct ReconcilerInput: Sendable {
    public var now: Date
    public var sessions: [ObservedSession]
    public var power: PowerState
    public var settings: LidlessSettings
    public var switches: Switches
    public var state: EngineState

    public init(
        now: Date,
        sessions: [ObservedSession],
        power: PowerState,
        settings: LidlessSettings,
        switches: Switches,
        state: EngineState
    ) {
        self.now = now
        self.sessions = sessions
        self.power = power
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
    case onBattery
    case lowBattery
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
    /// Records whose process is gone; their files can be deleted.
    public var deadSessionIDs: [String]
    public var state: EngineState
}

/// Decides, from a snapshot of the world, whether the Mac should be kept awake.
/// Pure: same input, same outcome. All side effects live in the app.
public enum Reconciler {
    public static func reconcile(_ input: ReconcilerInput) -> Outcome {
        let settings = input.settings
        let now = input.now
        var state = input.state
        var switches = input.switches

        let deadSessionIDs = input.sessions.filter { !$0.isAlive }.map(\.record.id)
        let live = input.sessions
            .filter { $0.isAlive && settings.trackedAgents.contains($0.record.agent) }
            .map(\.record)

        // Who is really working: not stalled, and not a turn the safety cap already gave up on.
        var working = live.filter { $0.state == .working && !isStalled($0, now: now, settings: settings) }
        var capStillApplies = false
        if let trippedAt = state.capTrippedAt {
            let fresh = working.filter { ($0.workingSince ?? $0.updatedAt) > trippedAt }
            capStillApplies = fresh.count < working.count
            working = fresh
            if !capStillApplies { state.capTrippedAt = nil }
        }

        let graceUntil = live
            .compactMap { $0.state == .idle ? $0.idleSince : nil }
            .map { $0.addingTimeInterval(settings.gracePeriod) }
            .max()
            .flatMap { $0 > now ? $0 : nil }

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

        // Closed-lid mode follows the agents only: "Keep Awake Anyway" never engages it.
        var disableLidSleep = false
        var lidDisarmReason: LidDisarmReason?
        if switches.lidArmed {
            if !input.power.isOnAC {
                lidDisarmReason = .onBattery
            } else if let percent = input.power.batteryPercent, percent < settings.batteryFloor {
                lidDisarmReason = .lowBattery
            } else if capTrippedNow {
                lidDisarmReason = .capReached
            } else if !working.isEmpty || graceUntil != nil {
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
            deadSessionIDs: deadSessionIDs,
            state: state
        )
    }

    private static func isStalled(_ session: SessionRecord, now: Date, settings: LidlessSettings) -> Bool {
        settings.stallTimeout > 0 && now.timeIntervalSince(session.updatedAt) >= settings.stallTimeout
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
