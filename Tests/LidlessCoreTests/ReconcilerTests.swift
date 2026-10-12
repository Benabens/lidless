import Foundation
import Testing
import LidlessCore

/// Fixed origin so every test reads as "seconds since the scenario started".
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

private func session(
    _ id: String = "s1",
    agent: Agent = .claude,
    working since: TimeInterval? = nil,
    idle idleSince: TimeInterval? = nil,
    lastEvent: TimeInterval? = nil,
    alive: Bool = true
) -> ObservedSession {
    let updated = lastEvent ?? since ?? idleSince ?? 0
    return ObservedSession(
        record: SessionRecord(
            id: id,
            agent: agent,
            pid: 4242,
            processStart: nil,
            state: since != nil ? .working : .idle,
            cwd: "/tmp/project",
            startedAt: t0,
            workingSince: since.map(at),
            idleSince: idleSince.map(at),
            updatedAt: at(updated)
        ),
        isAlive: alive
    )
}

private func reconcile(
    at seconds: TimeInterval,
    _ sessions: [ObservedSession] = [],
    power: PowerState = PowerState(isOnAC: true, batteryPercent: 100),
    settings: LidlessSettings = LidlessSettings(),
    switches: Switches = Switches(),
    state: EngineState = EngineState()
) -> Outcome {
    Reconciler.reconcile(
        ReconcilerInput(
            now: at(seconds),
            sessions: sessions,
            power: power,
            settings: settings,
            switches: switches,
            state: state
        )
    )
}

@Suite("Reconciler — when to keep the Mac awake")
struct ReconcilerDemandTests {
    @Test func sleepsNormallyWhenNoAgentIsRunning() {
        let outcome = reconcile(at: 0)
        #expect(outcome.keepAwake == false)
        #expect(outcome.status == .idle)
    }

    @Test func staysAwakeWhileAnAgentIsWorking() {
        let outcome = reconcile(at: 30, [session(working: 0)])
        #expect(outcome.keepAwake == true)
        #expect(outcome.status == .working(count: 1))
    }

    @Test func countsEveryWorkingSession() {
        let outcome = reconcile(at: 30, [
            session("a", working: 0),
            session("b", agent: .codex, working: 10),
            session("c", agent: .gemini, idle: 0),
        ])
        #expect(outcome.status == .working(count: 2))
    }

    @Test func staysAwakeDuringTheGracePeriodAfterTheLastTurn() {
        var settings = LidlessSettings()
        settings.gracePeriod = 120
        let outcome = reconcile(at: 100 + 119, [session(idle: 100)], settings: settings)
        #expect(outcome.keepAwake == true)
        #expect(outcome.status == .grace(until: at(220)))
    }

    @Test func letsTheMacSleepOnceTheGracePeriodIsOver() {
        var settings = LidlessSettings()
        settings.gracePeriod = 120
        let outcome = reconcile(at: 100 + 120, [session(idle: 100)], settings: settings)
        #expect(outcome.keepAwake == false)
        #expect(outcome.status == .idle)
    }

    @Test func aSessionThatNeverWorkedGrantsNoGrace() {
        let outcome = reconcile(at: 1, [session(idle: nil)])
        #expect(outcome.keepAwake == false)
    }

    @Test func ignoresAndReportsSessionsWhoseProcessDied() {
        let outcome = reconcile(at: 30, [session("ghost", working: 0, alive: false)])
        #expect(outcome.keepAwake == false)
        #expect(outcome.deadSessionIDs == ["ghost"])
        #expect(outcome.sessions.isEmpty)
    }

    @Test func ignoresAgentsTheUserDoesNotTrack() {
        var settings = LidlessSettings()
        settings.trackedAgents = [.claude]
        let outcome = reconcile(at: 30, [session("cx", agent: .codex, working: 0)], settings: settings)
        #expect(outcome.keepAwake == false)
        #expect(outcome.sessions.isEmpty)
        #expect(outcome.deadSessionIDs.isEmpty)
    }

    @Test func listsWorkingSessionsFirstThenMostRecent() {
        let outcome = reconcile(at: 500, [
            session("old-idle", idle: 100),
            session("recent-idle", idle: 400),
            session("busy", working: 50),
        ])
        #expect(outcome.sessions.map(\.id) == ["busy", "recent-idle", "old-idle"])
    }
}

@Suite("Reconciler — never keep the Mac hot for nothing")
struct ReconcilerSafetyTests {
    @Test func aWorkingSessionThatWentSilentIsTreatedAsIdle() {
        var settings = LidlessSettings()
        settings.stallTimeout = 30 * 60
        let silent = session(working: 0, lastEvent: 60)
        #expect(reconcile(at: 60 + 30 * 60 - 1, [silent], settings: settings).keepAwake == true)

        let outcome = reconcile(at: 60 + 30 * 60, [silent], settings: settings)
        #expect(outcome.keepAwake == false)
        #expect(outcome.status == .idle)
    }

    @Test func theStallTimeoutCanBeTurnedOff() {
        var settings = LidlessSettings()
        settings.stallTimeout = 0
        settings.maxAwakeDuration = 100 * 3600
        let outcome = reconcile(at: 5 * 3600, [session(working: 0, lastEvent: 60)], settings: settings)
        #expect(outcome.keepAwake == true)
    }

    @Test func keepAwakeAnywayHoldsWithoutAnyAgent() {
        let outcome = reconcile(at: 0, switches: Switches(keepAwakeAnyway: true))
        #expect(outcome.keepAwake == true)
        #expect(outcome.status == .manual)
    }

    @Test func acOnlyReleasesOnBatteryAndResumesWhenPluggedBackIn() {
        var settings = LidlessSettings()
        settings.acOnly = true
        let onBattery = reconcile(
            at: 30, [session(working: 0)],
            power: PowerState(isOnAC: false, batteryPercent: 90), settings: settings
        )
        #expect(onBattery.keepAwake == false)
        #expect(onBattery.status == .suppressed(.onBattery))

        let pluggedIn = reconcile(
            at: 40, [session(working: 0)],
            power: PowerState(isOnAC: true, batteryPercent: 90), settings: settings, state: onBattery.state
        )
        #expect(pluggedIn.keepAwake == true)
    }

    @Test func releasesOnBatteryBelowTheFloor() {
        var settings = LidlessSettings()
        settings.batteryFloor = 20
        let low = reconcile(
            at: 30, [session(working: 0)],
            power: PowerState(isOnAC: false, batteryPercent: 19), settings: settings
        )
        #expect(low.keepAwake == false)
        #expect(low.status == .suppressed(.lowBattery))

        let atFloor = reconcile(
            at: 30, [session(working: 0)],
            power: PowerState(isOnAC: false, batteryPercent: 20), settings: settings
        )
        #expect(atFloor.keepAwake == true)
    }

    @Test func aLowBatteryThatIsChargingDoesNotStopTheIdleAssertion() {
        let outcome = reconcile(at: 30, [session(working: 0)], power: PowerState(isOnAC: true, batteryPercent: 5))
        #expect(outcome.keepAwake == true)
    }

    @Test func macsWithoutABatteryAreNeverSuppressed() {
        var settings = LidlessSettings()
        settings.acOnly = true
        let outcome = reconcile(
            at: 30, [session(working: 0)],
            power: PowerState(isOnAC: true, batteryPercent: nil), settings: settings
        )
        #expect(outcome.keepAwake == true)
    }

    @Test func remembersWhenTheCurrentStretchOfWakefulnessBegan() {
        let first = reconcile(at: 10, [session(working: 0)])
        #expect(first.state.awakeSince == at(10))

        let later = reconcile(at: 500, [session(working: 0, lastEvent: 490)], state: first.state)
        #expect(later.state.awakeSince == at(10))

        let asleep = reconcile(at: 600, [], state: later.state)
        #expect(asleep.state.awakeSince == nil)
    }

    @Test func theSafetyCapReleasesEverythingAndTurnsOffKeepAwakeAnyway() {
        var settings = LidlessSettings()
        settings.maxAwakeDuration = 6 * 3600
        settings.stallTimeout = 0
        var state = EngineState()
        state.awakeSince = at(0)

        let outcome = reconcile(
            at: 6 * 3600, [session(working: 0)],
            settings: settings, switches: Switches(keepAwakeAnyway: true), state: state
        )
        #expect(outcome.keepAwake == false)
        #expect(outcome.status == .suppressed(.capReached))
        #expect(outcome.switches.keepAwakeAnyway == false)
        #expect(outcome.state.awakeSince == nil)
    }

    @Test func afterTheCapASessionStillInTheSameTurnDoesNotWakeTheMacAgain() {
        var settings = LidlessSettings()
        settings.maxAwakeDuration = 3600
        settings.stallTimeout = 0
        var state = EngineState()
        state.awakeSince = at(0)
        let stuck = session(working: 0)

        let tripped = reconcile(at: 3600, [stuck], settings: settings, state: state)
        let next = reconcile(at: 3610, [stuck], settings: settings, state: tripped.state)
        #expect(next.keepAwake == false)
        #expect(next.status == .suppressed(.capReached))
    }

    @Test func afterTheCapAFreshTurnIsHonouredAgain() {
        var settings = LidlessSettings()
        settings.maxAwakeDuration = 3600
        settings.stallTimeout = 0
        var state = EngineState()
        state.awakeSince = at(0)

        let tripped = reconcile(at: 3600, [session(working: 0)], settings: settings, state: state)
        let fresh = reconcile(at: 4000, [session(working: 3900)], settings: settings, state: tripped.state)
        #expect(fresh.keepAwake == true)
        #expect(fresh.status == .working(count: 1))
        #expect(fresh.state.awakeSince == at(4000))
    }

    @Test func theCapIsForgottenOnceTheStuckSessionStops() {
        var settings = LidlessSettings()
        settings.maxAwakeDuration = 3600
        settings.stallTimeout = 0
        settings.gracePeriod = 0
        var state = EngineState()
        state.awakeSince = at(0)

        let tripped = reconcile(at: 3600, [session(working: 0)], settings: settings, state: state)
        let stopped = reconcile(at: 3700, [session(idle: 3650)], settings: settings, state: tripped.state)
        #expect(stopped.status == .idle)
        #expect(stopped.state == EngineState())
    }
}

@Suite("Reconciler — closed-lid mode")
struct ReconcilerLidTests {
    private let armed = Switches(lidArmed: true)

    @Test func neverTouchesLidSleepUnlessArmed() {
        let outcome = reconcile(at: 30, [session(working: 0)])
        #expect(outcome.disableLidSleep == false)
        #expect(outcome.lidDisarmReason == nil)
    }

    @Test func armedWithAWorkingAgentOnACDisablesLidSleep() {
        let outcome = reconcile(at: 30, [session(working: 0)], switches: armed)
        #expect(outcome.disableLidSleep == true)
        #expect(outcome.keepAwake == true)
        #expect(outcome.switches.lidArmed == true)
    }

    @Test func armedBeforeAnyAgentWorksJustWaits() {
        let outcome = reconcile(at: 30, [session(idle: nil)], switches: armed)
        #expect(outcome.disableLidSleep == false)
        #expect(outcome.switches.lidArmed == true)
        #expect(outcome.lidDisarmReason == nil)
    }

    @Test func staysEngagedThroughTheGracePeriod() {
        let engaged = reconcile(at: 30, [session(working: 0)], switches: armed)
        let grace = reconcile(at: 100, [session(idle: 90)], switches: engaged.switches, state: engaged.state)
        #expect(grace.disableLidSleep == true)
        #expect(grace.switches.lidArmed == true)
    }

    @Test func disarmsItselfOnceEveryAgentIsDone() {
        var settings = LidlessSettings()
        settings.gracePeriod = 120
        let engaged = reconcile(at: 30, [session(working: 0)], settings: settings, switches: armed)
        let done = reconcile(
            at: 90 + 120, [session(idle: 90)],
            settings: settings, switches: engaged.switches, state: engaged.state
        )
        #expect(done.disableLidSleep == false)
        #expect(done.switches.lidArmed == false)
        #expect(done.lidDisarmReason == .workFinished)
    }

    @Test func disarmsWhenTheAgentProcessDies() {
        let engaged = reconcile(at: 30, [session(working: 0)], switches: armed)
        let gone = reconcile(
            at: 40, [session(working: 0, alive: false)],
            switches: engaged.switches, state: engaged.state
        )
        #expect(gone.disableLidSleep == false)
        #expect(gone.lidDisarmReason == .workFinished)
    }

    @Test func disarmsTheMomentTheMacGoesOnBattery() {
        let engaged = reconcile(at: 30, [session(working: 0)], switches: armed)
        let unplugged = reconcile(
            at: 31, [session(working: 0)],
            power: PowerState(isOnAC: false, batteryPercent: 95),
            switches: engaged.switches, state: engaged.state
        )
        #expect(unplugged.disableLidSleep == false)
        #expect(unplugged.switches.lidArmed == false)
        #expect(unplugged.lidDisarmReason == .onBattery)
    }

    @Test func disarmsBelowTheBatteryFloorEvenWhilePluggedIn() {
        var settings = LidlessSettings()
        settings.batteryFloor = 20
        let outcome = reconcile(
            at: 30, [session(working: 0)],
            power: PowerState(isOnAC: true, batteryPercent: 19), settings: settings, switches: armed
        )
        #expect(outcome.disableLidSleep == false)
        #expect(outcome.switches.lidArmed == false)
        #expect(outcome.lidDisarmReason == .lowBattery)
        // The ordinary idle assertion is unaffected: the Mac is charging.
        #expect(outcome.keepAwake == true)
    }

    @Test func disarmsWhenTheSafetyCapIsReached() {
        var settings = LidlessSettings()
        settings.maxAwakeDuration = 3600
        settings.stallTimeout = 0
        let engaged = reconcile(at: 0, [session(working: 0)], settings: settings, switches: armed)
        let capped = reconcile(
            at: 3600, [session(working: 0)],
            settings: settings, switches: engaged.switches, state: engaged.state
        )
        #expect(capped.disableLidSleep == false)
        #expect(capped.switches.lidArmed == false)
        #expect(capped.lidDisarmReason == .capReached)
    }

    @Test func keepAwakeAnywayAloneDoesNotEngageLidMode() {
        let outcome = reconcile(at: 0, switches: Switches(keepAwakeAnyway: true, lidArmed: true))
        #expect(outcome.keepAwake == true)
        #expect(outcome.disableLidSleep == false)
        #expect(outcome.switches.lidArmed == true)
    }

    @Test func reArmingAfterAFinishedRunWaitsForNewWork() {
        var settings = LidlessSettings()
        settings.gracePeriod = 0
        let engaged = reconcile(at: 30, [session(working: 0)], settings: settings, switches: armed)
        let done = reconcile(
            at: 100, [session(idle: 90)],
            settings: settings, switches: engaged.switches, state: engaged.state
        )
        #expect(done.switches.lidArmed == false)

        let reArmed = reconcile(at: 110, [session(idle: 90)], settings: settings, switches: armed, state: done.state)
        #expect(reArmed.switches.lidArmed == true)
        #expect(reArmed.disableLidSleep == false)
        #expect(reArmed.lidDisarmReason == nil)
    }
}
