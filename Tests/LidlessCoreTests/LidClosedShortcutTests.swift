import Foundation
import Testing
import LidlessCore

@Suite("One click: lid closed for 30 minutes")
struct LidClosedShortcutTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    private func state(
        hold: ManualHold? = nil, ruleInstalled: Bool = true, obstacle: LidDisarmReason? = nil
    ) -> LidClosedShortcut.State {
        LidClosedShortcut.state(hold: hold, ruleInstalled: ruleInstalled, obstacle: obstacle)
    }

    @Test func aClickAsksForThirtyMinutesWithTheLidClosed() {
        #expect(LidClosedShortcut.hold(startingAt: now) == ManualHold(until: at(30 * 60), withLidClosed: true))
    }

    @Test func isReadyWhenNothingHoldsTheLid() {
        #expect(state() == .ready)
        // A plain timer does not hold the lid: the shortcut still offers to.
        #expect(state(hold: ManualHold(until: at(600))) == .ready)
    }

    @Test func showsWhatIsLeftWhileALidClosedHoldRuns() {
        #expect(state(hold: LidClosedShortcut.hold(startingAt: now)) == .running(until: at(30 * 60)))
        // Whatever started it: a two-hour timer from the submenu counts just the same.
        #expect(state(hold: ManualHold(until: at(7200), withLidClosed: true)) == .running(until: at(7200)))
        #expect(state(hold: ManualHold(until: nil, withLidClosed: true)) == .running(until: nil))
    }

    @Test func aRunningHoldCanAlwaysBeStopped() {
        let running = ManualHold(until: at(600), withLidClosed: true)
        #expect(state(hold: running, obstacle: .lowBattery) == .running(until: at(600)))
        #expect(state(hold: running, ruleInstalled: false) == .running(until: at(600)))
    }

    @Test func sendsToSetupUntilTheSudoersRuleIsInstalled() {
        #expect(state(ruleInstalled: false) == .needsSetup)
        #expect(state(ruleInstalled: false, obstacle: .overheating) == .needsSetup)
    }

    @Test(arguments: [LidDisarmReason.lowBattery, .overheating, .onBattery])
    func saysWhatStandsInTheWay(obstacle: LidDisarmReason) {
        #expect(state(obstacle: obstacle) == .unavailable(obstacle))
    }

    // The shortcut adds no mechanism of its own: its hold goes through the reconciler like any other.
    private func reconcile(_ hold: ManualHold, at seconds: TimeInterval, battery: Int = 80, thermal: ThermalPressure = .nominal) -> Outcome {
        Reconciler.reconcile(ReconcilerInput(
            now: at(seconds), sessions: [], power: PowerState(isOnAC: false, batteryPercent: battery),
            thermal: thermal, settings: LidlessSettings(), switches: Switches(manualHold: hold), state: EngineState()
        ))
    }

    @Test func holdsTheLidOnBatteryWithNoAgentAtAll() {
        let outcome = reconcile(LidClosedShortcut.hold(startingAt: now), at: 60)
        #expect(outcome.keepAwake == true)
        #expect(outcome.disableLidSleep == true)
    }

    @Test func givesSleepBackWhenTheThirtyMinutesAreUp() {
        let outcome = reconcile(LidClosedShortcut.hold(startingAt: now), at: 30 * 60)
        #expect(outcome.timerExpired == true)
        #expect(outcome.disableLidSleep == false)
        #expect(outcome.keepAwake == false)
    }

    @Test func obeysTheBatteryAndHeatGuards() {
        let hold = LidClosedShortcut.hold(startingAt: now)
        let lowBattery = reconcile(hold, at: 60, battery: 19)
        #expect(lowBattery.disableLidSleep == false)
        #expect(lowBattery.timerLidStopReason == .lowBattery)

        let hot = reconcile(hold, at: 60, thermal: .serious)
        #expect(hot.disableLidSleep == false)
        #expect(hot.timerLidStopReason == .overheating)
    }
}
