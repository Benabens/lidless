import AppKit
import LidlessCore

/// The menu bar icon and its menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    /// The "Keep Awake For" presets, in seconds.
    private static let timerPresets: [(title: String, duration: TimeInterval)] = [
        ("15 Minutes", 15 * 60), ("30 Minutes", 30 * 60), ("1 Hour", 3600), ("2 Hours", 2 * 3600), ("4 Hours", 4 * 3600),
    ]

    private let model: AppModel
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var shownIcon: StatusIconState?

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = .monospacedDigitSystemFont(
            ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular
        )
        refresh()
    }

    /// Updates the icon and the optional countdown. The menu is rebuilt each time it opens.
    func refresh() {
        let icon = iconState
        if icon != shownIcon {
            statusItem.button?.image = StatusIcon.image(for: icon)
            shownIcon = icon
        }
        let countdown = model.showsTimerInMenuBar ? compactCountdown : ""
        if statusItem.button?.title != countdown { statusItem.button?.title = countdown }
        statusItem.button?.toolTip = statusLine
        statusItem.button?.setAccessibilityLabel("Lidless")
        statusItem.button?.setAccessibilityValue([statusLine, timerLine].compactMap { $0 }.joined(separator: ". "))
    }

    private var iconState: StatusIconState {
        if model.lidArmed || model.manualHold?.withLidClosed == true { return .lid }
        return model.outcome.keepAwake ? .awake : .asleep
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Session files may have changed since the last pass; the menu must not show stale rows.
        model.reconcile()
        menu.removeAllItems()

        menu.addItem(info(statusLine))
        if let timerLine {
            menu.addItem(info(timerLine))
        }
        if model.lidModeActive {
            menu.addItem(info("Sleep is off: you can close the lid."))
        }
        if let notice = model.lidNotice {
            menu.addItem(info(notice))
        }

        menu.addItem(.separator())
        addSessions(to: menu)

        menu.addItem(.separator())
        menu.addItem(timerItem())
        if model.manualHold != nil {
            menu.addItem(action("Stop Keeping Awake", #selector(stopHold)))
        }
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

    /// "Keep Awake For ▸": a timer that holds the Mac awake whether or not an agent is working.
    private func timerItem() -> NSMenuItem {
        let hold = model.manualHold
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        for preset in Self.timerPresets {
            let item = action(preset.title, #selector(startTimer(_:)))
            item.representedObject = preset.duration
            submenu.addItem(item)
        }
        let openEnded = action("Until I Turn It Off", #selector(startOpenEndedHold))
        openEnded.state = (hold != nil && hold?.until == nil) ? .on : .off
        submenu.addItem(openEnded)
        submenu.addItem(action("Custom…", #selector(askForCustomDuration)))

        submenu.addItem(.separator())
        submenu.addItem(holdLidItem())

        submenu.addItem(.separator())
        let stop = action("Stop", #selector(stopHold))
        stop.isEnabled = hold != nil
        submenu.addItem(stop)

        let item = NSMenuItem(title: "Keep Awake For", action: nil, keyEquivalent: "")
        item.submenu = submenu
        item.state = hold != nil ? .on : .off
        return item
    }

    private func holdLidItem() -> NSMenuItem {
        let item = action("Also with Lid Closed", #selector(toggleHoldLid))
        item.state = model.holdWithLidClosed ? .on : .off
        if !model.sudoersRuleInstalled {
            describe(item, "One-time setup in Settings")
        } else if !model.holdWithLidClosed, let obstacle = model.lidArmingObstacle {
            item.isEnabled = false
            describe(item, obstacle)
        } else {
            describe(item, "Until the timer ends, the battery gets low or the Mac gets hot")
        }
        return item
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
        case let .manual(until):
            return until == nil ? "Awake until you turn it off" : "Awake: timer running"
        case .suppressed(.onBattery):
            return "Paused: on battery power"
        case .suppressed(.lowBattery):
            return "Paused: battery below \(model.settings.batteryFloor)%"
        case .suppressed(.capReached):
            return "Paused: awake limit reached"
        }
    }

    /// The user's hold, when the status line does not already say it all: how long is left.
    private var timerLine: String? {
        guard let hold = model.manualHold else { return nil }
        let lid = hold.withLidClosed ? ", lid closed too" : ""
        guard let until = hold.until else {
            if case .manual = model.outcome.status { return hold.withLidClosed ? "Lid closed too" : nil }
            return "Also kept awake until you turn it off\(lid)"
        }
        // Rounded up, like the countdown: a timer just started for 45 minutes has 45 left.
        let remaining = (until.timeIntervalSinceNow / 60).rounded(.up) * 60
        return remaining <= 60 ? "Timer: less than a minute left\(lid)"
            : "Timer: \(Self.duration(seconds: remaining)) left\(lid)"
    }

    /// The countdown shown next to the icon: `1h 05m`, `42m`, `<1m`. Empty without a timer.
    private var compactCountdown: String {
        guard let until = model.manualHold?.until else { return "" }
        let minutes = Int((until.timeIntervalSinceNow / 60).rounded(.up))
        if minutes <= 1 { return "<1m" }
        return minutes >= 60 ? "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m" : "\(minutes)m"
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

    @objc private func startTimer(_ sender: NSMenuItem) {
        guard let duration = sender.representedObject as? TimeInterval else { return }
        model.startHold(for: duration)
    }

    @objc private func startOpenEndedHold() {
        model.startHold(for: nil)
    }

    /// Asks for a free-form duration, and asks again, saying why, when it cannot be read.
    @objc private func askForCustomDuration() {
        let hint = "Minutes, or hours and minutes: 45, 1h30, 2:15. Up to 24 hours."
        var message = hint
        var typed = ""
        while true {
            let alert = NSAlert()
            alert.messageText = "Keep awake for how long?"
            alert.informativeText = message
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            field.placeholderString = "1h30"
            field.stringValue = typed
            alert.accessoryView = field
            alert.addButton(withTitle: "Start")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field

            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            typed = field.stringValue
            if let duration = DurationText.parse(typed) {
                model.startHold(for: duration)
                return
            }
            message = "Lidless could not read “\(typed)” as a duration. \(hint)"
        }
    }

    @objc private func toggleHoldLid() {
        model.toggleHoldWithLidClosed()
    }

    @objc private func stopHold() {
        model.stopHold()
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
