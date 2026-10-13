import AppKit
import LidlessCore
import ServiceManagement

/// Glue between the pure reconciler and the Mac: gathers the inputs, runs a pass, applies the
/// effects, and publishes what the menu and the settings window show.
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

    @Published private(set) var helperRuleInstalled = false
    @Published private(set) var helperError: String?
    @Published private(set) var helperBusy = false

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

    private var switches = Switches()
    private var engineState = EngineState()
    private var timer: Timer?
    private var watchdog: Process?
    private var wakeObserver: NSObjectProtocol?
    private var pendingReconcile = false

    init() {
        store = SessionStore(directory: paths.sessionsDirectory)
        lidSleep = LidSleepController(powerManagement: SystemPowerManagement(), marker: paths.lidSleepMarker)
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

        provisionHook()
        refreshIntegrations()
        refreshHelperRule()
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
        assertion.set(held: false, reason: "")
        _ = lidSleep.apply(disableLidSleep: false)
        stopWatchdog()
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
        var result = Reconciler.reconcile(ReconcilerInput(
            now: Date(),
            sessions: observed,
            power: currentPower,
            settings: settings,
            switches: switches,
            state: engineState
        ))
        result.staleSessionIDs.forEach(store.remove)

        assertion.set(
            held: result.keepAwake,
            reason: result.status == .manual ? "Lidless: kept awake by the user" : "Lidless: a coding agent is working"
        )

        var notice = result.lidDisarmReason.map(describe)
        let lidResult = lidSleep.apply(disableLidSleep: result.disableLidSleep)
        if result.disableLidSleep, lidResult == .failed {
            // Without the sudoers rule there is nothing to arm: say so instead of pretending.
            result.switches.lidArmed = false
            result.state.lidEngaged = false
            result.disableLidSleep = false
            notice = "Closed-lid mode could not change the sleep setting. Check the rule in Settings."
        }
        if !result.disableLidSleep, lidResult == .failed {
            // Sleep is still disabled and Lidless cannot undo it: the one thing the user must know.
            notice = "Lidless could not turn sleep back on. Run “sudo pmset -a disablesleep 0” in Terminal."
        }
        if lidResult == .engaged { startWatchdog() } else if !lidSleep.ownsTheSetting { stopWatchdog() }

        switches = result.switches
        engineState = result.state
        if let notice { lidNotice = notice }

        let active = result.disableLidSleep && (lidResult == .engaged || lidResult == .leftToUser)
        if lidModeActive != active { lidModeActive = active }
        if power != currentPower { power = currentPower }
        if outcome != result { outcome = result }
        onUpdate?()
    }

    private func describe(_ reason: LidDisarmReason) -> String {
        switch reason {
        case .workFinished: "Closed-lid mode turned itself off: every agent finished."
        case .onBattery: "Closed-lid mode turned itself off: the Mac is on battery."
        case .lowBattery: "Closed-lid mode turned itself off: battery below \(settings.batteryFloor)%."
        case .capReached: "Closed-lid mode turned itself off: the awake limit was reached."
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
        if !power.isOnAC { return "Needs the power adapter" }
        if let percent = power.batteryPercent, percent < settings.batteryFloor {
            return "Battery below \(settings.batteryFloor)%"
        }
        return nil
    }

    func toggleLidArmed() {
        if switches.lidArmed {
            switches.lidArmed = false
        } else {
            guard helperRuleInstalled else {
                onOpenSettings?()
                return
            }
            switches.lidArmed = true
            engineState.lidEngaged = false
        }
        lidNotice = nil
        reconcile()
    }

    // MARK: - Dead man's switch

    private func startWatchdog() {
        guard watchdog?.isRunning != true else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", LidWatchdog.script(
            watching: ProcessInfo.processInfo.processIdentifier, marker: paths.lidSleepMarker.path
        )]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        watchdog = process
    }

    private func stopWatchdog() {
        if watchdog?.isRunning == true { watchdog?.terminate() }
        watchdog = nil
    }

    // MARK: - Agent integrations

    /// Agents call a copy of `lidless-hook` kept outside the bundle, so moving or rebuilding the
    /// app never leaves their hooks pointing at nothing.
    private func provisionHook() {
        guard let bundled = Bundle.main.executableURL?
            .deletingLastPathComponent().appendingPathComponent("lidless-hook"),
            FileManager.default.isExecutableFile(atPath: bundled.path)
        else { return }
        let destination = paths.installedHook
        guard !FileManager.default.contentsEqual(atPath: bundled.path, andPath: destination.path) else { return }

        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".lidless-hook-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: bundled, to: staging)
            // An agent may be running the old copy right now; rename swaps it atomically.
            guard rename(staging.path, destination.path) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
        }
    }

    func refreshIntegrations() {
        var statuses: [Agent: AgentIntegration.Status] = [:]
        for agent in Agent.allCases {
            statuses[agent] = AgentIntegration(agent: agent).status(hookPath: paths.installedHook.path)
        }
        integrationStatus = statuses
        codexHasInlineHooks = AgentIntegration(agent: .codex).hasInlineCodexHooks

        // An agent is followed exactly when Lidless's hooks are in its configuration.
        let tracked = Set(statuses.filter { $0.value == .installed || $0.value == .outdated }.keys)
        if settings.trackedAgents != tracked { settings.trackedAgents = tracked }
    }

    func setIntegration(_ agent: Agent, enabled: Bool) {
        let integration = AgentIntegration(agent: agent)
        do {
            if enabled {
                provisionHook()
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

    func refreshHelperRule() {
        helperRuleInstalled = FileManager.default.fileExists(atPath: SudoersRule.path)
    }

    func installHelperRule() {
        runPrivileged(
            SudoersRule.installScript(user: NSUserName(), uid: getuid()),
            prompt: "Lidless wants to add a rule that lets it turn closed-lid sleep off and back on without asking for your password."
        )
    }

    func removeHelperRule() {
        if switches.lidArmed { toggleLidArmed() }
        runPrivileged(
            SudoersRule.uninstallScript,
            prompt: "Lidless wants to remove its closed-lid sleep rule."
        )
    }

    private func runPrivileged(_ script: String, prompt: String) {
        guard !helperBusy else { return }
        helperBusy = true
        helperError = nil
        AdministratorPrompt.run(script, prompt: prompt) { [weak self] failure in
            guard let self else { return }
            helperBusy = false
            // An empty message means the user cancelled the password prompt.
            if let failure, !failure.isEmpty { helperError = failure }
            refreshHelperRule()
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
