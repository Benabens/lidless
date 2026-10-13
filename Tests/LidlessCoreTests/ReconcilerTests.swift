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
            workingSince: since.map(at),
            idleSince: idleSince.map(at),
            updatedAt: at(updated)
        ),
        isAlive: alive
    )
}

/// One reconciler pass. Unless told otherwise the previous pass happened 10 seconds earlier, as it
/// does in the running app.
private func reconcile(
    at seconds: TimeInterval,
    _ sessions: [ObservedSession] = [],
    power: PowerState = PowerState(isOnAC: true, batteryPercent: 100),
    settings: LidlessSettings = LidlessSettings(),
    switches: Switches = Switches(),
    state: EngineState = EngineState(),
    thermal: ThermalPressure = .nominal,
    sincePreviousPass: TimeInterval = 10
) -> Outcome {
    var state = state
    state.lastPassAt = at(seconds - sincePreviousPass)
    return Reconciler.reconcile(
        ReconcilerInput(
            now: at(seconds),
            sessions: sessions,
            power: power,
            thermal: thermal,
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

    @Test func theGracePeriodOutlivesTheSessionItself() {
        // A scripted loop of one-shot agent runs: each run ends its session, or simply exits.
        var settings = LidlessSettings()
        settings.gracePeriod = 120
        let working = reconcile(at: 100, [session(working: 0, lastEvent: 95)], settings: settings)

        let sessionClosed = reconcile(at: 110, [], settings: settings, state: working.state)
        #expect(sessionClosed.keepAwake == true)
        #expect(sessionClosed.status == .grace(until: at(220)))

        let processDied = reconcile(
            at: 110, [session(working: 0, lastEvent: 95, alive: false)], settings: settings, state: working.state
        )
        #expect(processDied.keepAwake == true)

        let later = reconcile(at: 220, [], settings: settings, state: sessionClosed.state)
        #expect(later.keepAwake == false)
    }

    @Test func aSessionThatNeverWorkedGrantsNoGrace() {
        let outcome = reconcile(at: 1, [session(idle: nil)])
        #expect(outcome.keepAwake == false)
    }

    @Test func ignoresAndReportsSessionsWhoseProcessDied() {
        let outcome = reconcile(at: 30, [session("ghost", working: 0, alive: false)])
        #expect(outcome.keepAwake == false)
        #expect(outcome.staleSessionIDs == ["ghost"])
        #expect(outcome.sessions.isEmpty)
    }

    @Test func forgetsSessionsThatHaveBeenIdleForADay() {
        // Not every agent announces the end of a session; idle records must not pile up.
        let outcome = reconcile(at: 24 * 3600, [session("left-open", idle: 0), session("recent", idle: 23 * 3600)])
        #expect(outcome.staleSessionIDs == ["left-open"])
        #expect(outcome.sessions.map(\.id) == ["recent"])
    }

    @Test func ignoresAgentsTheUserDoesNotTrack() {
        var settings = LidlessSettings()
        settings.trackedAgents = [.claude]
        let outcome = reconcile(at: 30, [session("cx", agent: .codex, working: 0)], settings: settings)
        #expect(outcome.keepAwake == false)
        #expect(outcome.sessions.isEmpty)
        #expect(outcome.staleSessionIDs.isEmpty)
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
    @Test func outOfTheBoxBatteryPowerIsAllowedDownToTwentyPercent() {
        let defaults = LidlessSettings()
        #expect(defaults.acOnly == false)
        #expect(defaults.batteryFloor == 20)
        #expect(defaults.maxAwakeDuration == 6 * 3600)
        #expect(defaults.stallTimeout == 30 * 60)
    }

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

    @Test func anOpenEndedHoldKeepsTheMacAwakeWithoutAnyAgent() {
        let outcome = reconcile(at: 0, switches: Switches(manualHold: ManualHold(until: nil)))
        #expect(outcome.keepAwake == true)
        #expect(outcome.status == .manual(until: nil))
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

        let later = reconcile(at: 20, [session(working: 0, lastEvent: 15)], state: first.state)
        #expect(later.state.awakeSince == at(10))

        let asleep = reconcile(at: 30, [], settings: LidlessSettings(gracePeriod: 0), state: later.state)
        #expect(asleep.state.awakeSince == nil)
    }

    @Test func timeSpentAsleepDoesNotCountTowardsTheCap() {
        // The lid was closed overnight in the middle of a turn; the session resumes on wake.
        var settings = LidlessSettings()
        settings.maxAwakeDuration = 6 * 3600
        settings.stallTimeout = 0
        let evening = reconcile(at: 100, [session(working: 0)], settings: settings)

        let morning = reconcile(
            at: 9 * 3600, [session(working: 0)],
            settings: settings, state: evening.state, sincePreviousPass: 9 * 3600 - 100
        )
        #expect(morning.keepAwake == true)
        #expect(morning.state.awakeSince == at(9 * 3600))
    }

    @Test func aCapReachedDuringTheGracePeriodIsNotUndoneOnTheNextPass() {
        var settings = LidlessSettings()
        settings.maxAwakeDuration = 3600
        settings.gracePeriod = 900
        var state = EngineState()
        state.awakeSince = at(0)

        let tripped = reconcile(at: 3600, [session(idle: 3500)], settings: settings, state: state)
        #expect(tripped.keepAwake == false)

        let next = reconcile(at: 3610, [session(idle: 3500)], settings: settings, state: tripped.state)
        #expect(next.keepAwake == false)
        #expect(next.status == .suppressed(.capReached))

        // Once that grace period would have ended anyway, nothing is held against the future.
        let over = reconcile(at: 3500 + 900, [session(idle: 3500)], settings: settings, state: next.state)
        #expect(over.status == .idle)
        #expect(over.state.capTrippedAt == nil)
    }

    @Test func theSafetyCapReleasesEverythingIncludingAnOpenEndedHold() {
        var settings = LidlessSettings()
        settings.maxAwakeDuration = 6 * 3600
        settings.stallTimeout = 0
        var state = EngineState()
        state.awakeSince = at(0)

        let outcome = reconcile(
            at: 6 * 3600, [session(working: 0)],
            settings: settings, switches: Switches(manualHold: ManualHold(until: nil)), state: state
        )
        #expect(outcome.keepAwake == false)
        #expect(outcome.status == .suppressed(.capReached))
        #expect(outcome.switches.manualHold == nil)
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
        #expect(stopped.state.capTrippedAt == nil)
        #expect(stopped.state.awakeSince == nil)
    }
}

@Suite("Reconciler — closed-lid mode")
struct ReconcilerLidTests {
    private let armed = Switches(lidArmed: true)

    private let onBattery = PowerState(isOnAC: false, batteryPercent: 80)
    private let pluggedIn = PowerState(isOnAC: true, batteryPercent: 80)

    @Test func nothingStandsInTheWayOfArmingOnBattery() {
        let settings = LidlessSettings(batteryFloor: 20)
        #expect(Reconciler.lidObstacle(power: onBattery, settings: settings, thermal: .nominal) == nil)
        #expect(Reconciler.lidObstacle(power: pluggedIn, settings: settings, thermal: .fair) == nil)
        #expect(Reconciler.lidObstacle(power: PowerState(isOnAC: true, batteryPercent: nil), settings: settings, thermal: .nominal) == nil)
    }

    @Test func saysWhatStandsInTheWayOfArming() {
        let settings = LidlessSettings(batteryFloor: 20)
        let low = PowerState(isOnAC: false, batteryPercent: 19)
        #expect(Reconciler.lidObstacle(power: low, settings: settings, thermal: .nominal) == .lowBattery)
        #expect(Reconciler.lidObstacle(power: PowerState(isOnAC: true, batteryPercent: 19), settings: settings, thermal: .nominal) == .lowBattery)
        #expect(Reconciler.lidObstacle(power: onBattery, settings: settings, thermal: .serious) == .overheating)
        #expect(Reconciler.lidObstacle(power: pluggedIn, settings: settings, thermal: .critical) == .overheating)

        let powerAdapterOnly = LidlessSettings(acOnly: true, batteryFloor: 20)
        #expect(Reconciler.lidObstacle(power: onBattery, settings: powerAdapterOnly, thermal: .nominal) == .onBattery)
        #expect(Reconciler.lidObstacle(power: pluggedIn, settings: powerAdapterOnly, thermal: .nominal) == nil)
    }

    @Test func worksOnBatteryFromTheStart() {
        // The main use: close the lid, unplugged, and put the Mac in a bag while agents run.
        let outcome = reconcile(at: 30, [session(working: 0)], power: onBattery, switches: armed)
        #expect(outcome.disableLidSleep == true)
        #expect(outcome.keepAwake == true)
        #expect(outcome.switches.lidArmed == true)
        #expect(outcome.lidDisarmReason == nil)
    }

    @Test func unpluggingDoesNotInterruptClosedLidMode() {
        let engaged = reconcile(at: 30, [session(working: 0)], power: pluggedIn, switches: armed)
        let unplugged = reconcile(
            at: 40, [session(working: 0, lastEvent: 35)],
            power: onBattery, switches: engaged.switches, state: engaged.state
        )
        #expect(unplugged.disableLidSleep == true)
        #expect(unplugged.switches.lidArmed == true)
        #expect(unplugged.lidDisarmReason == nil)
    }

    @Test func onBatteryItStillDisarmsOnceEveryAgentIsDone() {
        var settings = LidlessSettings()
        settings.gracePeriod = 120
        let engaged = reconcile(at: 30, [session(working: 0)], power: onBattery, settings: settings, switches: armed)
        let done = reconcile(
            at: 90 + 120, [session(idle: 90)],
            power: onBattery, settings: settings, switches: engaged.switches, state: engaged.state
        )
        #expect(done.disableLidSleep == false)
        #expect(done.switches.lidArmed == false)
        #expect(done.lidDisarmReason == .workFinished)
    }

    @Test func onBatteryItDisarmsBelowTheBatteryFloor() {
        var settings = LidlessSettings()
        settings.batteryFloor = 20
        let engaged = reconcile(at: 30, [session(working: 0)], power: onBattery, settings: settings, switches: armed)
        #expect(engaged.disableLidSleep == true)

        let drained = reconcile(
            at: 40, [session(working: 0, lastEvent: 35)],
            power: PowerState(isOnAC: false, batteryPercent: 19),
            settings: settings, switches: engaged.switches, state: engaged.state
        )
        #expect(drained.disableLidSleep == false)
        #expect(drained.switches.lidArmed == false)
        #expect(drained.lidDisarmReason == .lowBattery)
        // Nothing keeps a Mac with a low battery awake at all.
        #expect(drained.keepAwake == false)
    }

    @Test func withOnlyOnPowerAdapterUnpluggingDisarms() {
        // Off by default; for whoever never wants the Mac awake in a bag.
        var settings = LidlessSettings()
        settings.acOnly = true
        let engaged = reconcile(at: 30, [session(working: 0)], power: pluggedIn, settings: settings, switches: armed)
        #expect(engaged.disableLidSleep == true)

        let unplugged = reconcile(
            at: 40, [session(working: 0, lastEvent: 35)],
            power: onBattery, settings: settings, switches: engaged.switches, state: engaged.state
        )
        #expect(unplugged.disableLidSleep == false)
        #expect(unplugged.switches.lidArmed == false)
        #expect(unplugged.lidDisarmReason == .onBattery)
    }

    @Test(arguments: [ThermalPressure.serious, .critical])
    func disarmsWhenTheMacGetsHot(thermal: ThermalPressure) {
        let engaged = reconcile(at: 30, [session(working: 0)], power: onBattery, switches: armed)
        let hot = reconcile(
            at: 40, [session(working: 0, lastEvent: 35)],
            power: onBattery, switches: engaged.switches, state: engaged.state, thermal: thermal
        )
        #expect(hot.disableLidSleep == false)
        #expect(hot.switches.lidArmed == false)
        #expect(hot.lidDisarmReason == .overheating)
    }

    @Test(arguments: [ThermalPressure.nominal, .fair])
    func aWarmMacIsFine(thermal: ThermalPressure) {
        let outcome = reconcile(at: 30, [session(working: 0)], power: onBattery, switches: armed, thermal: thermal)
        #expect(outcome.disableLidSleep == true)
        #expect(outcome.lidDisarmReason == nil)
    }

    @Test func heatOnlyStopsClosedLidModeNotTheOrdinaryAssertion() {
        // With the lid open, a hot Mac under load is normal and its user is right there.
        let outcome = reconcile(at: 30, [session(working: 0)], thermal: .critical)
        #expect(outcome.keepAwake == true)
        #expect(outcome.status == .working(count: 1))
    }

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

    @Test func disarmsAfterTheGracePeriodWhenTheAgentProcessDies() {
        var settings = LidlessSettings()
        settings.gracePeriod = 120
        let engaged = reconcile(at: 30, [session(working: 0)], settings: settings, switches: armed)
        let justDied = reconcile(
            at: 40, [session(working: 0, alive: false)],
            settings: settings, switches: engaged.switches, state: engaged.state
        )
        #expect(justDied.disableLidSleep == true)

        let gone = reconcile(at: 30 + 120, [], settings: settings, switches: justDied.switches, state: justDied.state)
        #expect(gone.disableLidSleep == false)
        #expect(gone.lidDisarmReason == .workFinished)
    }

    @Test func armingDuringALeftoverGracePeriodWaitsForRealWork() {
        // The last turn ended a moment ago; the user arms the switch before starting the next run.
        var settings = LidlessSettings()
        settings.gracePeriod = 120
        let leftover = [session(idle: 100)]

        let justArmed = reconcile(at: 130, leftover, settings: settings, switches: armed)
        #expect(justArmed.disableLidSleep == false)
        #expect(justArmed.switches.lidArmed == true)

        let graceOver = reconcile(at: 230, leftover, settings: settings, switches: justArmed.switches, state: justArmed.state)
        #expect(graceOver.switches.lidArmed == true)
        #expect(graceOver.lidDisarmReason == nil)

        let working = reconcile(
            at: 300, [session(working: 290)], settings: settings, switches: graceOver.switches, state: graceOver.state
        )
        #expect(working.disableLidSleep == true)
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

    @Test func aHoldWithoutItsLidOptionDoesNotEngageTheAgentsLidSwitch() {
        let outcome = reconcile(at: 0, switches: Switches(manualHold: ManualHold(until: nil), lidArmed: true))
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

@Suite("Reconciler — keep awake for a while, agents or not")
struct ReconcilerTimerTests {
    private let onBattery = PowerState(isOnAC: false, batteryPercent: 80)

    private func timer(until seconds: TimeInterval?, lidClosed: Bool = false) -> Switches {
        Switches(manualHold: ManualHold(until: seconds.map(at), withLidClosed: lidClosed))
    }

    @Test func aTimerKeepsTheMacAwakeWithoutAnyAgent() {
        let outcome = reconcile(at: 10, switches: timer(until: 900))
        #expect(outcome.keepAwake == true)
        #expect(outcome.status == .manual(until: at(900)))
        #expect(outcome.timerExpired == false)
    }

    @Test func theTimerEndsOnItsOwnAndSaysSoOnce() {
        let running = reconcile(at: 890, switches: timer(until: 900))
        let ended = reconcile(at: 900, switches: running.switches, state: running.state)
        #expect(ended.keepAwake == false)
        #expect(ended.status == .idle)
        #expect(ended.switches.manualHold == nil)
        #expect(ended.timerExpired == true)

        let after = reconcile(at: 910, switches: ended.switches, state: ended.state)
        #expect(after.timerExpired == false)
    }

    @Test func whenTheTimerEndsAnAgentStillWorkingKeepsTheMacAwake() {
        let ended = reconcile(at: 100, [session(working: 50, lastEvent: 95)], switches: timer(until: 100))
        #expect(ended.timerExpired == true)
        #expect(ended.keepAwake == true)
        #expect(ended.status == .working(count: 1))
    }

    @Test func aTimerIsItsOwnLimitAndIgnoresTheAwakeCap() {
        // The cap guards against wakefulness nobody decided on. A four-hour timer was decided on.
        var settings = LidlessSettings()
        settings.maxAwakeDuration = 3600
        var state = EngineState()
        state.awakeSince = at(0)

        let outcome = reconcile(at: 2 * 3600, settings: settings, switches: timer(until: 4 * 3600), state: state)
        #expect(outcome.keepAwake == true)
        #expect(outcome.switches.manualHold != nil)
        #expect(outcome.state.capTrippedAt == nil)
    }

    @Test func aTimerDoesNotShieldTheAgentsFromTheCap() {
        // A long timer must not let a stuck agent keep closed-lid mode going past the limit.
        var settings = LidlessSettings()
        settings.maxAwakeDuration = 3600
        settings.stallTimeout = 0
        var state = EngineState()
        state.awakeSince = at(0)
        state.lidEngaged = true
        let switches = Switches(manualHold: ManualHold(until: at(24 * 3600)), lidArmed: true)

        let outcome = reconcile(at: 3600, [session(working: 0)], settings: settings, switches: switches, state: state)
        #expect(outcome.lidDisarmReason == .capReached)
        #expect(outcome.disableLidSleep == false)
        #expect(outcome.switches.lidArmed == false)
        // The timer itself goes on: that is what the user asked for.
        #expect(outcome.keepAwake == true)
        #expect(outcome.status == .manual(until: at(24 * 3600)))
        #expect(outcome.switches.manualHold != nil)

        let later = reconcile(at: 3610, [session(working: 0)], settings: settings, switches: outcome.switches, state: outcome.state)
        #expect(later.status == .manual(until: at(24 * 3600)))
    }

    @Test func theCapCountsTheAgentsTimeNotTheTimers() {
        var settings = LidlessSettings()
        settings.maxAwakeDuration = 3600
        settings.stallTimeout = 0
        let hold = timer(until: 5 * 3600)
        let timerOnly = reconcile(at: 2 * 3600, settings: settings, switches: hold)
        #expect(timerOnly.state.awakeSince == nil)

        // An agent starts two hours into the timer: its own hour starts now.
        let agentStarts = reconcile(
            at: 2 * 3600 + 10, [session(working: 2 * 3600 + 5)],
            settings: settings, switches: timerOnly.switches, state: timerOnly.state
        )
        #expect(agentStarts.state.awakeSince == at(2 * 3600 + 10))
        #expect(agentStarts.status == .working(count: 1))
    }

    @Test func powerAdapterOnlyAppliesToTheTimerToo() {
        var settings = LidlessSettings()
        settings.acOnly = true
        let outcome = reconcile(at: 10, power: onBattery, settings: settings, switches: timer(until: 900))
        #expect(outcome.keepAwake == false)
        #expect(outcome.status == .suppressed(.onBattery))
        #expect(outcome.switches.manualHold != nil)
    }

    @Test func aPlainTimerLeavesLidSleepAlone() {
        let outcome = reconcile(at: 10, switches: timer(until: 900))
        #expect(outcome.disableLidSleep == false)
    }

    @Test func aTimerCanAlsoHoldWithTheLidClosedOnBatteryIncluded() {
        let outcome = reconcile(at: 10, power: onBattery, switches: timer(until: 900, lidClosed: true))
        #expect(outcome.keepAwake == true)
        #expect(outcome.disableLidSleep == true)
        #expect(outcome.timerLidStopReason == nil)
    }

    @Test func whenALidClosedTimerEndsSleepComesBack() {
        let running = reconcile(at: 890, switches: timer(until: 900, lidClosed: true))
        #expect(running.disableLidSleep == true)

        let ended = reconcile(at: 900, switches: running.switches, state: running.state)
        #expect(ended.disableLidSleep == false)
        #expect(ended.timerExpired == true)
    }

    @Test func aLowBatteryTurnsTheTimersLidOptionOff() {
        let low = PowerState(isOnAC: false, batteryPercent: 19)
        let outcome = reconcile(at: 10, power: low, switches: timer(until: 900, lidClosed: true))
        #expect(outcome.disableLidSleep == false)
        #expect(outcome.timerLidStopReason == .lowBattery)
        #expect(outcome.switches.manualHold?.withLidClosed == false)
        #expect(outcome.keepAwake == false)
    }

    @Test func heatTurnsTheTimersLidOptionOffButTheTimerGoesOn() {
        let outcome = reconcile(at: 10, switches: timer(until: 900, lidClosed: true), thermal: .serious)
        #expect(outcome.disableLidSleep == false)
        #expect(outcome.timerLidStopReason == .overheating)
        #expect(outcome.switches.manualHold == ManualHold(until: at(900), withLidClosed: false))
        #expect(outcome.keepAwake == true)
    }

    @Test func theCapEndsAnOpenEndedLidClosedHoldAndSaysWhy() {
        var settings = LidlessSettings()
        settings.maxAwakeDuration = 3600
        var state = EngineState()
        state.awakeSince = at(0)

        let outcome = reconcile(at: 3600, settings: settings, switches: timer(until: nil, lidClosed: true), state: state)
        #expect(outcome.disableLidSleep == false)
        #expect(outcome.switches.manualHold == nil)
        #expect(outcome.timerLidStopReason == .capReached)
    }

    @Test func untilITurnItOffWithTheLidClosedStopsAtTheSixHourLimitOutOfTheBox() {
        // The one hold with no end of its own, in a closed bag: the awake limit is its backstop.
        let hold = timer(until: nil, lidClosed: true)
        var state = EngineState()
        state.awakeSince = at(0)

        let justBefore = reconcile(at: 6 * 3600 - 10, power: onBattery, switches: hold, state: state)
        #expect(justBefore.keepAwake == true)
        #expect(justBefore.disableLidSleep == true)

        let atTheLimit = reconcile(at: 6 * 3600, power: onBattery, switches: justBefore.switches, state: justBefore.state)
        #expect(atTheLimit.keepAwake == false)
        #expect(atTheLimit.disableLidSleep == false)
        #expect(atTheLimit.switches.manualHold == nil)
        #expect(atTheLimit.timerLidStopReason == .capReached)
    }

    @Test func thatLimitIsTheOneSetInSettings() {
        var settings = LidlessSettings()
        settings.maxAwakeDuration = 2 * 3600
        var state = EngineState()
        state.awakeSince = at(0)

        let outcome = reconcile(at: 2 * 3600, settings: settings, switches: timer(until: nil, lidClosed: true), state: state)
        #expect(outcome.disableLidSleep == false)
        #expect(outcome.switches.manualHold == nil)
    }

    @Test func theTimersLidOptionAndTheAgentsSwitchAreIndependent() {
        // The timer ends; the armed switch keeps the lid-closed run of a working agent going.
        let switches = Switches(manualHold: ManualHold(until: at(100), withLidClosed: true), lidArmed: true)
        let ended = reconcile(at: 100, [session(working: 50, lastEvent: 95)], switches: switches)
        #expect(ended.timerExpired == true)
        #expect(ended.disableLidSleep == true)
        #expect(ended.switches.lidArmed == true)
    }
}

@Suite("Reconciler — only poll while something can change by itself")
struct ReconcilerPollingTests {
    @Test func nothingToWatchMeansNoPolling() {
        #expect(reconcile(at: 0).needsPolling == false)
        #expect(reconcile(at: 1000, [session(idle: 100)]).needsPolling == false)
        #expect(reconcile(at: 1000, [session(idle: nil)], switches: Switches(lidArmed: true)).needsPolling == false)
    }

    @Test func pollsWhileAnAgentWorksAndThroughTheGracePeriod() {
        #expect(reconcile(at: 30, [session(working: 0)]).needsPolling == true)
        #expect(reconcile(at: 150, [session(idle: 100)]).needsPolling == true)
    }

    @Test func pollsWhileATimerRuns() {
        let hold = Switches(manualHold: ManualHold(until: at(900)))
        #expect(reconcile(at: 10, switches: hold).needsPolling == true)
        #expect(reconcile(at: 900, switches: hold).needsPolling == false)
    }

    @Test func aSilentSessionIsNotWorthPollingFor() {
        var settings = LidlessSettings()
        settings.stallTimeout = 30 * 60
        let outcome = reconcile(at: 3 * 3600, [session(working: 0, lastEvent: 60)], settings: settings)
        #expect(outcome.needsPolling == false)
    }

    @Test func oneMorePassAfterTheCapEndsAHoldSoTheStatusDoesNotGoStale() {
        var settings = LidlessSettings()
        settings.maxAwakeDuration = 3600
        var state = EngineState()
        state.awakeSince = at(0)

        let tripped = reconcile(
            at: 3600, settings: settings, switches: Switches(manualHold: ManualHold(until: nil)), state: state
        )
        #expect(tripped.status == .suppressed(.capReached))
        #expect(tripped.needsPolling == true)

        let next = reconcile(at: 3610, settings: settings, switches: tripped.switches, state: tripped.state)
        #expect(next.status == .idle)
        #expect(next.needsPolling == false)
    }

    @Test func keepsPollingWhileTheCapHoldsAStuckSessionBack() {
        var settings = LidlessSettings()
        settings.maxAwakeDuration = 3600
        settings.stallTimeout = 0
        var state = EngineState()
        state.awakeSince = at(0)
        let tripped = reconcile(at: 3600, [session(working: 0)], settings: settings, state: state)
        #expect(tripped.needsPolling == true)
    }
}
