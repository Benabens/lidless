import AppKit
import LidlessCore
import ServiceManagement

/// Glue between the pure reconciler and the Mac: gathers the inputs, runs a pass, applies the
/// outcome, and publishes what the menu and the settings window show.
@MainActor
final class AppModel: ObservableObject {
    static let reconcileInterval: TimeInterval = 10

    @Published var settings: LidlessSettings {
        didSet {
            guard settings != oldValue else { return }
            SettingsStorage.save(settings)
            reconcile()
        }
    }

    @Published private(set) var outcome: Outcome
    @Published private(set) var power: PowerState
    /// Why closed-lid mode last switched itself off, or why it could not be switched on.
    @Published private(set) var lidNotice: String?
    /// Sleep is currently disabled with the lid closed.
    @Published private(set) var lidModeActive = false

    @Published private(set) var integrationStatus: [Agent: AgentIntegration.Status] = [:]
    @Published private(set) var integrationErrors: [Agent: String] = [:]
    @Published private(set) var codexHasInlineHooks = false

    @Published private(set) var sudoersRuleInstalled = false
    @Published private(set) var sudoersRuleError: String?
    @Published private(set) var sudoersRuleBusy = false

    @Published private(set) var opensAtLogin = false
    @Published private(set) var loginItemError: String?

    /// "Also with Lid Closed": applies to the running hold, or to the next one started. Never
    /// remembered beyond that.
    @Published private(set) var holdWithLidClosed = false
    @Published var showsTimerInMenuBar = UserDefaults.standard.bool(forKey: "showsTimerInMenuBar") {
        didSet {
            UserDefaults.standard.set(showsTimerInMenuBar, forKey: "showsTimerInMenuBar")
            onUpdate?()
        }
    }

    /// Called after every pass so the status item can refresh.
    var onUpdate: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let paths = LidlessPaths()
    private let store: SessionStore
    private let lidSleep: LidSleepController
    private let assertion = SleepAssertion()
    private let powerMonitor = PowerMonitor()
    private let watcher = DirectoryWatcher()
    private let watchdog: LidWatchdogProcess

    private var switches = Switches()
    private var engineState = EngineState()
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var thermalObserver: NSObjectProtocol?
    private var pendingReconcile = false
    /// The failed-restore notification is posted once, not on every retry.
    private var reportedRestoreFailure = false

    init() {
        store = SessionStore(directory: paths.sessionsDirectory)
        lidSleep = LidSleepController(powerManagement: SystemPowerManagement(), marker: paths.lidSleepMarker)
        watchdog = LidWatchdogProcess(marker: paths.lidSleepMarker)
        settings = SettingsStorage.load()
        power = PowerMonitor.currentState()
        outcome = Reconciler.reconcile(ReconcilerInput(
            now: Date(), sessions: [], power: PowerMonitor.currentState(),
            settings: LidlessSettings(), switches: Switches(), state: EngineState()
        ))
    }

    // MARK: - Lifecycle

    func start() {
        // A previous run may have died with sleep disabled: put it back before anything else.
        _ = lidSleep.apply(disableLidSleep: false)

        HookProvisioner.provision(to: paths.installedHook)
        refreshIntegrations()
        refreshSudoersRule()
        refreshLoginItem()

        watcher.start(watching: paths.sessionsDirectory) { [weak self] in
            self?.scheduleReconcile()
        }
        powerMonitor.onChange = { [weak self] in self?.reconcile() }
        powerMonitor.start()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }

        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }

        reconcile()
    }

    /// The periodic pass only runs while time alone can change the outcome (an agent working, a
    /// grace period, a timer) or sleep is disabled. Otherwise Lidless sits on its event sources
    /// (session files, power, heat, wake) and never wakes the CPU on its own.
    private func setPolling(_ needed: Bool) {
        if needed, timer == nil {
            let timer = Timer(timeInterval: Self.reconcileInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcile() }
            }
            // Generous on purpose: lets macOS fire it together with other wake-ups.
            timer.tolerance = 3
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !needed, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }

    /// Leaves the Mac exactly as Lidless found it.
    func shutdown() {
        setPolling(false)
        watcher.stop()
        powerMonitor.stop()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
        assertion.set(held: false, reason: "")
        _ = lidSleep.apply(disableLidSleep: false)
        watchdog.stop()
    }

    // MARK: - Reconciliation

    /// Session files often change several times in a burst; one pass is enough.
    private func scheduleReconcile() {
        guard !pendingReconcile else { return }
        pendingReconcile = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingReconcile = false
                self?.reconcile()
            }
        }
    }

    func reconcile() {
        watcher.ensureWatching()
        let observed = store.loadAll().map { record in
            ObservedSession(
                record: record,
                isAlive: ProcessProbe.isAlive(pid: record.pid, startedAt: record.processStart)
            )
        }
        let currentPower = PowerMonitor.currentState()
        let thermal = ThermalPressure.current
        func pass() -> Outcome {
            Reconciler.reconcile(ReconcilerInput(
                now: Date(), sessions: observed, power: currentPower, thermal: thermal,
                settings: settings, switches: switches, state: engineState
            ))
        }

        let hadHold = switches.manualHold != nil
        let hadOpenEndedHold = hadHold && switches.manualHold?.until == nil
        var result = pass()
        var lidResult = lidSleep.apply(disableLidSleep: result.disableLidSleep)

        var couldNotDisableSleep = false
        if result.disableLidSleep, lidResult == .failed {
            // pmset refused, so nothing can hold the lid: switch both lid options off and decide
            // again, rather than asking pmset over and over.
            couldNotDisableSleep = true
            switches.lidArmed = false
            switches.manualHold?.withLidClosed = false
            result = pass()
            lidResult = lidSleep.apply(disableLidSleep: false)
        }
        // Sleep is still disabled and Lidless cannot undo it: the one thing the user must know.
        let couldNotRestoreSleep = !result.disableLidSleep && lidResult == .failed

        // One message per pass, the most important first, in the menu and as a notification.
        var message: (title: String, body: String, notify: Bool)?
        if couldNotRestoreSleep {
            message = ("Sleep is still off", "Lidless could not turn sleep back on. Run “sudo pmset -a disablesleep 0” in Terminal.", !reportedRestoreFailure)
        } else if couldNotDisableSleep {
            message = ("Lid closed: not possible", "Lidless could not change the sleep setting. Check the rule in Settings.", true)
        } else if hadOpenEndedHold, result.switches.manualHold == nil, !result.timerExpired {
            // Only the awake limit ends an open-ended hold without the user's doing.
            message = ("Keep-awake ended", capitalized(explain(.capReached)) + ".", true)
        } else if let reason = result.lidDisarmReason {
            // A finished run needs no notification; a safety rule cutting it short does.
            message = ("Closed-lid mode turned off", capitalized(explain(reason)) + ".", reason != .workFinished)
        } else if let reason = result.timerLidStopReason {
            message = ("The timer no longer holds with the lid closed", capitalized(explain(reason)) + ".", true)
        } else if result.timerExpired {
            let agentsWorking = if case .working = result.status { true } else { false }
            UserNotifier.post(
                title: "Keep-awake timer ended",
                body: agentsWorking ? "Lidless is back to following your agents." : "Your Mac can sleep again."
            )
        }
        reportedRestoreFailure = couldNotRestoreSleep
        if let message {
            lidNotice = "\(message.title). \(message.body)"
            if message.notify { UserNotifier.post(title: message.title, body: message.body) }
        }

        // "Also with Lid Closed" follows the hold: a guard that switches it off unchecks it, and
        // it does not outlive the hold, so every lid-closed timer is a deliberate choice.
        if let hold = result.switches.manualHold {
            if holdWithLidClosed != hold.withLidClosed { holdWithLidClosed = hold.withLidClosed }
        } else if hadHold, holdWithLidClosed {
            holdWithLidClosed = false
        }

        result.staleSessionIDs.forEach(store.remove)
        let heldByAgents = if case .manual = result.status { false } else { true }
        assertion.set(
            held: result.keepAwake,
            reason: heldByAgents ? "Lidless: a coding agent is working" : "Lidless: kept awake by the user"
        )
        if lidSleep.ownsTheSetting { watchdog.start() } else { watchdog.stop() }
        // While sleep is disabled the pass must keep running: it refreshes the watchdog's
        // heartbeat and retries a restore that failed.
        setPolling(result.needsPolling || lidSleep.ownsTheSetting)

        switches = result.switches
        engineState = result.state

        let active = result.disableLidSleep && (lidResult == .engaged || lidResult == .leftToUser)
        if lidModeActive != active { lidModeActive = active }
        if power != currentPower { power = currentPower }
        if outcome != result { outcome = result }
        onUpdate?()
    }

    /// Why closed-lid mode switched itself off, as the end of a sentence.
    private func explain(_ reason: LidDisarmReason) -> String {
        switch reason {
        case .workFinished: "every agent finished"
        case .onBattery: "the Mac went on battery and “Only on power adapter” is on"
        case .lowBattery: "the battery dropped below \(settings.batteryFloor)%"
        case .overheating: "the Mac was getting too hot"
        case .capReached: "the awake limit was reached"
        }
    }

    private func capitalized(_ sentence: String) -> String {
        sentence.prefix(1).uppercased() + sentence.dropFirst()
    }

    // MARK: - Switches

    var manualHold: ManualHold? { switches.manualHold }
    var lidArmed: Bool { switches.lidArmed }

    /// Keeps the Mac awake for `duration`, or until stopped when `nil`, whatever the agents do.
    func startHold(for duration: TimeInterval?) {
        switches.manualHold = ManualHold(
            until: duration.map { Date().addingTimeInterval($0) },
            withLidClosed: holdWithLidClosed && sudoersRuleInstalled
        )
        UserNotifier.requestPermission()
        lidNotice = nil
        reconcile()
    }

    func stopHold() {
        switches.manualHold = nil
        holdWithLidClosed = false
        reconcile()
    }

    /// "Also with Lid Closed". Needs the sudoers rule, like closed-lid mode itself.
    func toggleHoldWithLidClosed() {
        guard holdWithLidClosed || sudoersRuleInstalled else {
            onOpenSettings?()
            return
        }
        holdWithLidClosed.toggle()
        switches.manualHold?.withLidClosed = holdWithLidClosed
        if holdWithLidClosed { prepareForDisablingSleep() }
        reconcile()
    }

    /// The first time the user lets Lidless disable sleep, make sure Lidless comes back after a
    /// restart: sleep stays disabled across a reboot until Lidless runs again to restore it.
    private func prepareForDisablingSleep() {
        UserNotifier.requestPermission()
        let key = "didEnableLoginItemForLidMode"
        guard Bundle.main.bundleIdentifier != nil, !UserDefaults.standard.bool(forKey: key) else { return }
        let wasOn = opensAtLogin
        if !wasOn { setOpensAtLogin(true) }
        // If macOS refused, this is tried again next time rather than given up on.
        guard opensAtLogin else { return }
        UserDefaults.standard.set(true, forKey: key)
        if !wasOn {
            lidNotice = "Lidless now opens at login, so it can always turn sleep back on after a restart. Change this in Settings."
        }
    }

    /// Why closed-lid mode cannot be armed right now, if it cannot.
    var lidArmingObstacle: String? {
        switch Reconciler.lidObstacle(power: power, settings: settings, thermal: .current) {
        case .onBattery: "“Only on power adapter” is on"
        case .lowBattery: "Battery below \(settings.batteryFloor)%"
        case .overheating: "The Mac is too hot right now"
        default: nil
        }
    }

    func toggleLidArmed() {
        guard switches.lidArmed || sudoersRuleInstalled else {
            onOpenSettings?()
            return
        }
        switches.lidArmed.toggle()
        lidNotice = nil
        if switches.lidArmed { prepareForDisablingSleep() }
        reconcile()
    }

    // MARK: - Agent integrations

    func refreshIntegrations() {
        var statuses: [Agent: AgentIntegration.Status] = [:]
        for agent in Agent.allCases {
            statuses[agent] = integration(for: agent).status(hookPath: paths.installedHook.path)
        }
        integrationStatus = statuses
        codexHasInlineHooks = integration(for: .codex).hasInlineCodexHooks

        // An agent is followed exactly when Lidless's hooks are in its configuration.
        let tracked = Set(statuses.filter(\.value.isConnected).keys)
        if settings.trackedAgents != tracked { settings.trackedAgents = tracked }
    }

    func integration(for agent: Agent) -> AgentIntegration {
        AgentIntegration(agent: agent, home: paths.agentsHome)
    }

    func setIntegration(_ agent: Agent, enabled: Bool) {
        let integration = integration(for: agent)
        do {
            if enabled {
                HookProvisioner.provision(to: paths.installedHook)
                try integration.install(hookPath: paths.installedHook.path)
            } else {
                try integration.uninstall()
            }
            integrationErrors[agent] = nil
        } catch {
            integrationErrors[agent] = "\(error)"
        }
        refreshIntegrations()
        reconcile()
    }

    // MARK: - Sudoers rule

    func refreshSudoersRule() {
        sudoersRuleInstalled = FileManager.default.fileExists(atPath: SudoersRule.path)
    }

    func installSudoersRule() {
        runAsAdministrator(
            SudoersRule.installScript(user: NSUserName(), uid: getuid()),
            prompt: "Lidless wants to add a rule that lets it turn closed-lid sleep off and back on without asking for your password."
        )
    }

    func removeSudoersRule() {
        // Give sleep back first, for both lid options: without the rule Lidless never could again.
        switches.lidArmed = false
        switches.manualHold?.withLidClosed = false
        holdWithLidClosed = false
        reconcile()
        guard !lidSleep.ownsTheSetting else {
            sudoersRuleError = "Lidless could not turn sleep back on, so the rule stays for now. Run “sudo pmset -a disablesleep 0” in Terminal, then try again."
            return
        }
        runAsAdministrator(
            SudoersRule.uninstallScript,
            prompt: "Lidless wants to remove its closed-lid sleep rule."
        )
    }

    private func runAsAdministrator(_ script: String, prompt: String) {
        guard !sudoersRuleBusy else { return }
        sudoersRuleBusy = true
        sudoersRuleError = nil
        AdministratorPrompt.run(script, prompt: prompt) { [weak self] result in
            guard let self else { return }
            sudoersRuleBusy = false
            if case let .failed(message) = result { sudoersRuleError = message }
            refreshSudoersRule()
            onUpdate?()
        }
    }

    // MARK: - Open at login

    func refreshLoginItem() {
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = "macOS did not accept the change: \(error.localizedDescription)"
        }
        refreshLoginItem()
    }
}

/// The settings the user can change, kept in the app's defaults.
enum SettingsStorage {
    private static var defaults: UserDefaults { .standard }

    static func load() -> LidlessSettings {
        var settings = LidlessSettings()
        if let value = defaults.object(forKey: "gracePeriod") as? Double { settings.gracePeriod = value }
        if let value = defaults.object(forKey: "acOnly") as? Bool { settings.acOnly = value }
        if let value = defaults.object(forKey: "batteryFloor") as? Int { settings.batteryFloor = value }
        if let value = defaults.object(forKey: "maxAwakeDuration") as? Double { settings.maxAwakeDuration = value }
        if let value = defaults.object(forKey: "stallTimeout") as? Double { settings.stallTimeout = value }
        return settings
    }

    static func save(_ settings: LidlessSettings) {
        defaults.set(settings.gracePeriod, forKey: "gracePeriod")
        defaults.set(settings.acOnly, forKey: "acOnly")
        defaults.set(settings.batteryFloor, forKey: "batteryFloor")
        defaults.set(settings.maxAwakeDuration, forKey: "maxAwakeDuration")
        defaults.set(settings.stallTimeout, forKey: "stallTimeout")
    }
}
