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

        let timer = Timer(timeInterval: Self.reconcileInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        reconcile()
    }

    /// Leaves the Mac exactly as Lidless found it.
    func shutdown() {
        timer?.invalidate()
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

        var result = pass()
        var lidResult = lidSleep.apply(disableLidSleep: result.disableLidSleep)
        var notice = result.lidDisarmReason.map { "Closed-lid mode turned itself off: \(explain($0))." }
        if let reason = result.lidDisarmReason, reason != .workFinished {
            // A safety rule cut the run short while nobody was looking.
            let explanation = explain(reason)
            UserNotifier.post(
                title: "Closed-lid mode turned off",
                body: explanation.prefix(1).uppercased() + explanation.dropFirst() + "."
            )
        }

        if result.disableLidSleep, lidResult == .failed {
            // pmset refused, so there is nothing to arm: switch it off and decide again.
            switches.lidArmed = false
            result = pass()
            lidResult = lidSleep.apply(disableLidSleep: false)
            notice = "Closed-lid mode could not change the sleep setting. Check the rule in Settings."
        } else if lidResult == .failed {
            // Sleep is still disabled and Lidless cannot undo it: the one thing the user must know.
            notice = "Lidless could not turn sleep back on. Run “sudo pmset -a disablesleep 0” in Terminal."
        }

        result.staleSessionIDs.forEach(store.remove)
        assertion.set(
            held: result.keepAwake,
            reason: result.status == .manual ? "Lidless: kept awake by the user" : "Lidless: a coding agent is working"
        )
        if lidSleep.ownsTheSetting { watchdog.start() } else { watchdog.stop() }

        switches = result.switches
        engineState = result.state
        if let notice { lidNotice = notice }

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

    // MARK: - Switches

    var keepAwakeAnyway: Bool { switches.keepAwakeAnyway }
    var lidArmed: Bool { switches.lidArmed }

    func toggleKeepAwakeAnyway() {
        switches.keepAwakeAnyway.toggle()
        reconcile()
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
        if switches.lidArmed { UserNotifier.requestPermission() }
        lidNotice = nil
        reconcile()
    }

    // MARK: - Agent integrations

    func refreshIntegrations() {
        var statuses: [Agent: AgentIntegration.Status] = [:]
        for agent in Agent.allCases {
            statuses[agent] = AgentIntegration(agent: agent).status(hookPath: paths.installedHook.path)
        }
        integrationStatus = statuses
        codexHasInlineHooks = AgentIntegration(agent: .codex).hasInlineCodexHooks

        // An agent is followed exactly when Lidless's hooks are in its configuration.
        let tracked = Set(statuses.filter(\.value.isConnected).keys)
        if settings.trackedAgents != tracked { settings.trackedAgents = tracked }
    }

    func setIntegration(_ agent: Agent, enabled: Bool) {
        let integration = AgentIntegration(agent: agent)
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
        // Disarm first: without the rule Lidless could no longer turn sleep back on.
        if switches.lidArmed { toggleLidArmed() }
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
