import AppKit
import LidlessCore

/// The menu bar icon and its menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var shownIcon: StatusIconState?

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        refresh()
    }

    /// Updates the icon. The menu itself is rebuilt each time it opens.
    func refresh() {
        let icon = iconState
        if icon != shownIcon {
            statusItem.button?.image = StatusIcon.image(for: icon)
            shownIcon = icon
        }
        statusItem.button?.toolTip = statusLine
        statusItem.button?.setAccessibilityLabel("Lidless")
        statusItem.button?.setAccessibilityValue(statusLine)
    }

    private var iconState: StatusIconState {
        if model.lidArmed { return .lid }
        return model.outcome.keepAwake ? .awake : .asleep
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Session files may have changed since the last pass; the menu must not show stale rows.
        model.reconcile()
        menu.removeAllItems()

        menu.addItem(info(statusLine))
        if model.lidModeActive {
            menu.addItem(info("Closed-lid mode is active: you can close the lid."))
        }
        if let notice = model.lidNotice {
            menu.addItem(info(notice))
        }

        menu.addItem(.separator())
        addSessions(to: menu)

        menu.addItem(.separator())
        let keepAwake = action("Keep Awake Anyway", #selector(toggleKeepAwake))
        keepAwake.state = model.keepAwakeAnyway ? .on : .off
        describe(keepAwake, "Even when no agent is working")
        menu.addItem(keepAwake)
        menu.addItem(lidItem())

        menu.addItem(.separator())
        let settings = action("Settings…", #selector(openSettings))
        settings.keyEquivalent = ","
        menu.addItem(settings)

        menu.addItem(.separator())
        let quit = action("Quit Lidless", #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func addSessions(to menu: NSMenu) {
        let sessions = model.outcome.sessions
        guard !sessions.isEmpty else {
            let hasAgents = !model.settings.trackedAgents.isEmpty
            menu.addItem(info(hasAgents ? "No agent sessions" : "No agents connected yet"))
            if !hasAgents {
                menu.addItem(action("Connect an Agent…", #selector(openSettings)))
            }
            return
        }

        let limit = 8
        let now = Date()
        for session in sessions.prefix(limit) {
            menu.addItem(sessionItem(session, now: now))
        }
        if sessions.count > limit {
            menu.addItem(info("\(sessions.count - limit) more"))
        }
    }

    private func sessionItem(_ session: SessionRecord, now: Date) -> NSMenuItem {
        let folder = session.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
        let name = folder.map { "\(session.agent.displayName) — \($0)" } ?? session.agent.displayName
        let (detail, isWorking) = activity(of: session, now: now)

        let item: NSMenuItem
        if #available(macOS 14.4, *) {
            item = action(name, #selector(revealSession(_:)))
            item.subtitle = detail
        } else {
            item = action("\(name) · \(detail)", #selector(revealSession(_:)))
        }
        item.representedObject = session.cwd
        item.isEnabled = session.cwd != nil
        item.toolTip = session.cwd.map { "Show \($0) in Finder" }

        // Filled and green while working, hollow and grey while idle: shape carries it too.
        let symbol = isWorking ? "circle.fill" : "circle"
        let colour: NSColor = isWorking ? .systemGreen : .tertiaryLabelColor
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: isWorking ? "Working" : "Idle")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [colour])))
        return item
    }

    private func activity(of session: SessionRecord, now: Date) -> (text: String, isWorking: Bool) {
        switch session.state {
        case .working:
            if session.isStalled(at: now, timeout: model.settings.stallTimeout) {
                return ("No activity for \(Self.duration(from: session.updatedAt, to: now))", false)
            }
            return ("Working for \(Self.duration(from: session.workingSince ?? session.updatedAt, to: now))", true)
        case .idle:
            return ("Idle for \(Self.duration(from: session.idleSince ?? session.updatedAt, to: now))", false)
        }
    }

    private func lidItem() -> NSMenuItem {
        guard model.sudoersRuleInstalled else {
            let setUp = action("Set Up Closed-Lid Mode…", #selector(openSettings))
            describe(setUp, "One-time setup in Settings")
            return setUp
        }
        let item = action("Closed-Lid Mode", #selector(toggleLid))
        item.state = model.lidArmed ? .on : .off
        if model.lidArmed {
            describe(item, model.lidModeActive ? "Active until the agents finish" : "Armed: starts when an agent works")
        } else if let obstacle = model.lidArmingObstacle {
            item.isEnabled = false
            describe(item, obstacle)
        } else {
            describe(item, "Agents keep working with the lid closed")
        }
        return item
    }

    // MARK: - Text

    private var statusLine: String {
        switch model.outcome.status {
        case .idle:
            return "Idle: your Mac can sleep"
        case let .working(count):
            return count == 1 ? "Awake: 1 agent working" : "Awake: \(count) agents working"
        case let .grace(until):
            let remaining = until.timeIntervalSinceNow
            return remaining < 60 ? "Awake for less than a minute more"
                : "Awake for \(Self.duration(seconds: remaining)) more"
        case .manual:
            return "Awake: kept on by you"
        case .suppressed(.onBattery):
            return "Paused: on battery power"
        case .suppressed(.lowBattery):
            return "Paused: battery below \(model.settings.batteryFloor)%"
        case .suppressed(.capReached):
            return "Paused: awake limit reached"
        }
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        return formatter
    }()

    private static func duration(from start: Date, to end: Date) -> String {
        duration(seconds: end.timeIntervalSince(start))
    }

    private static func duration(seconds: TimeInterval) -> String {
        guard seconds >= 60 else { return "under a minute" }
        return durationFormatter.string(from: seconds) ?? "a while"
    }

    // MARK: - Items

    /// A line of information: not clickable, and never the target of a key equivalent.
    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    /// Explains an item where the system can show it: as a subtitle when available, and always
    /// as a tooltip.
    private func describe(_ item: NSMenuItem, _ text: String) {
        item.toolTip = text
        if #available(macOS 14.4, *) {
            item.subtitle = text
        }
    }

    // MARK: - Actions

    @objc private func toggleKeepAwake() {
        model.toggleKeepAwakeAnyway()
    }

    @objc private func toggleLid() {
        model.toggleLidArmed()
    }

    @objc private func openSettings() {
        model.onOpenSettings?()
    }

    @objc private func revealSession(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
