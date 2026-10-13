import Foundation
import Testing
import LidlessCore

/// Stands in for `pmset`: records what Lidless asked for instead of changing the Mac.
private final class FakePowerManagement: PowerManagement, @unchecked Sendable {
    var sleepDisabledValue: Bool?
    var commandsSucceed = true
    private(set) var calls: [Bool] = []

    init(sleepDisabled: Bool? = false) {
        sleepDisabledValue = sleepDisabled
    }

    func sleepDisabled() -> Bool? { sleepDisabledValue }

    func setSleepDisabled(_ disabled: Bool) -> Bool {
        calls.append(disabled)
        guard commandsSucceed else { return false }
        sleepDisabledValue = disabled
        return true
    }
}

@Suite("Closed-lid sleep is only ever undone by whoever disabled it")
struct LidSleepControllerTests {
    let directory: TemporaryDirectory
    let marker: URL

    init() throws {
        directory = try TemporaryDirectory()
        marker = directory.file("support/lid-sleep-disabled")
    }

    private var markerExists: Bool { FileManager.default.fileExists(atPath: marker.path) }

    @Test func engagingDisablesSleepAndLeavesAMarker() {
        let pmset = FakePowerManagement()
        let result = LidSleepController(powerManagement: pmset, marker: marker).apply(disableLidSleep: true)

        #expect(result == .engaged)
        #expect(pmset.calls == [true])
        #expect(markerExists)
    }

    @Test func releasingRestoresSleepAndRemovesTheMarker() {
        let pmset = FakePowerManagement()
        let controller = LidSleepController(powerManagement: pmset, marker: marker)
        _ = controller.apply(disableLidSleep: true)

        #expect(controller.apply(disableLidSleep: false) == .released)
        #expect(pmset.calls == [true, false])
        #expect(!markerExists)
    }

    @Test func stayingEngagedDoesNotRunPmsetAgain() {
        let pmset = FakePowerManagement()
        let controller = LidSleepController(powerManagement: pmset, marker: marker)
        _ = controller.apply(disableLidSleep: true)

        #expect(controller.apply(disableLidSleep: true) == .engaged)
        #expect(pmset.calls == [true])
    }

    @Test func stayingEngagedRefreshesTheHeartbeatTheWatchdogReads() throws {
        let pmset = FakePowerManagement()
        let controller = LidSleepController(powerManagement: pmset, marker: marker)
        _ = controller.apply(disableLidSleep: true)
        let longAgo = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: marker.path)

        _ = controller.apply(disableLidSleep: true)

        let touched = try #require(FileManager.default.attributesOfItem(atPath: marker.path)[.modificationDate] as? Date)
        #expect(touched.timeIntervalSinceNow > -60)
    }

    @Test func reappliesIfSomethingResetTheSettingBehindItsBack() {
        let pmset = FakePowerManagement()
        let controller = LidSleepController(powerManagement: pmset, marker: marker)
        _ = controller.apply(disableLidSleep: true)
        pmset.sleepDisabledValue = false

        #expect(controller.apply(disableLidSleep: true) == .engaged)
        #expect(pmset.calls == [true, true])
    }

    @Test func neverTouchesTheSettingWhenThereIsNothingToUndo() {
        let pmset = FakePowerManagement()
        let result = LidSleepController(powerManagement: pmset, marker: marker).apply(disableLidSleep: false)

        #expect(result == .idle)
        #expect(pmset.calls.isEmpty)
    }

    @Test func aSettingTheUserMadeThemselvesIsLeftAlone() {
        // The user ran `pmset disablesleep 1` on their own: not Lidless's to manage or to undo.
        let pmset = FakePowerManagement(sleepDisabled: true)
        let controller = LidSleepController(powerManagement: pmset, marker: marker)

        #expect(controller.apply(disableLidSleep: true) == .leftToUser)
        #expect(!markerExists)
        #expect(controller.apply(disableLidSleep: false) == .idle)
        #expect(pmset.calls.isEmpty)
        #expect(pmset.sleepDisabledValue == true)
    }

    @Test func aMarkerLeftByACrashIsCleanedUpAtLaunch() throws {
        try directory.write("", to: "support/lid-sleep-disabled")
        let pmset = FakePowerManagement(sleepDisabled: true)

        let result = LidSleepController(powerManagement: pmset, marker: marker).apply(disableLidSleep: false)

        #expect(result == .released)
        #expect(pmset.calls == [false])
        #expect(!markerExists)
    }

    @Test func failingToDisableSleepLeavesNoMarker() {
        let pmset = FakePowerManagement()
        pmset.commandsSucceed = false

        let result = LidSleepController(powerManagement: pmset, marker: marker).apply(disableLidSleep: true)

        #expect(result == .failed)
        #expect(!markerExists)
    }

    @Test func failingToRestoreSleepKeepsTheMarkerSoItIsRetried() {
        let pmset = FakePowerManagement()
        let controller = LidSleepController(powerManagement: pmset, marker: marker)
        _ = controller.apply(disableLidSleep: true)
        pmset.commandsSucceed = false

        #expect(controller.apply(disableLidSleep: false) == .failed)
        #expect(markerExists)

        pmset.commandsSucceed = true
        #expect(controller.apply(disableLidSleep: false) == .released)
        #expect(!markerExists)
    }
}

@Suite("Reading pmset")
struct PMSetTests {
    @Test func readsTheSleepDisabledFlag() {
        let disabled = """
        System-wide power settings:
         SleepDisabled\t\t1
        Currently in use:
         standby              1
         sleep                1 (sleep prevented by powerd)
        """
        #expect(PMSet.sleepDisabled(inOutputOf: disabled) == true)
        #expect(PMSet.sleepDisabled(inOutputOf: disabled.replacingOccurrences(of: "\t\t1", with: "\t\t0")) == false)
    }

    @Test func anOutputWithoutTheFlagIsUnknownNotFalse() {
        #expect(PMSet.sleepDisabled(inOutputOf: "Currently in use:\n sleep 1\n") == nil)
        #expect(PMSet.sleepDisabled(inOutputOf: "") == nil)
    }

    @Test func onlyEverRunsTheTwoCommandsTheSudoersRuleAllows() {
        #expect(PMSet.command(disablingSleep: true) == ["/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "1"])
        #expect(PMSet.command(disablingSleep: false) == ["/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "0"])
    }
}

@Suite("The sudoers rule")
struct SudoersRuleTests {
    /// The rule without its comment lines.
    private func directives(_ rule: String) -> [Substring] {
        rule.split(separator: "\n").filter { !$0.hasPrefix("# ") }
    }

    @Test func allowsExactlyTheTwoPmsetCommandsForOneUser() {
        let rule = SudoersRule.contents(user: "ben", uid: 501)
        #expect(directives(rule) == [
            "ben ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1",
        ])
        #expect(rule.hasSuffix("\n"))
    }

    @Test(arguments: ["", "ALL", "%admin", "o'neil", "a b", "x,y", "root\nALL ALL=(ALL) NOPASSWD: ALL", "#0", "ben!"])
    func aUserNameThatCouldChangeTheMeaningOfTheRuleIsReplacedByTheNumericID(name: String) {
        // A bare "#501" at the start of a line reads like a comment, hence the alias.
        #expect(directives(SudoersRule.contents(user: name, uid: 501)) == [
            "User_Alias LIDLESS_USER = #501",
            "LIDLESS_USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1",
        ])
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/sbin/visudo")))
    func visudoAcceptsTheRule() throws {
        let directory = try TemporaryDirectory()
        for rule in [SudoersRule.contents(user: "ben", uid: 501), SudoersRule.contents(user: "", uid: 501)] {
            let file = try directory.write(rule, to: "lidless")
            let visudo = Process()
            visudo.executableURL = URL(fileURLWithPath: "/usr/sbin/visudo")
            visudo.arguments = ["-cf", file.path]
            visudo.standardOutput = FileHandle.nullDevice
            visudo.standardError = FileHandle.nullDevice
            try visudo.run()
            visudo.waitUntilExit()
            #expect(visudo.terminationStatus == 0)
        }
    }

    @Test func theInstallerValidatesBeforeTheRuleGoesLive() {
        let script = SudoersRule.installScript(user: "ben", uid: 501)
        let validate = try! #require(script.range(of: "/usr/sbin/visudo -cf"))
        let goLive = try! #require(script.range(of: "/bin/mv -f"))
        #expect(validate.lowerBound < goLive.lowerBound)
        #expect(script.contains("/private/etc/sudoers.d/lidless"))
        #expect(script.contains("/usr/sbin/chown root:wheel"))
        #expect(script.contains("/bin/chmod 0440"))
        // The staging file has a dot in its name: sudo ignores such files in sudoers.d.
        #expect(script.contains("/private/etc/sudoers.d/.lidless.tmp"))
    }

    @Test func theUninstallerRemovesOnlyItsOwnFile() {
        #expect(SudoersRule.uninstallScript == "/bin/rm -f /private/etc/sudoers.d/lidless")
    }

    @Test func wrapsAShellScriptForAnAdministratorPrompt() {
        let appleScript = SudoersRule.appleScript(running: #"echo "a\b" 'c'"#, prompt: #"Lidless "needs" this"#)
        #expect(appleScript == #"do shell script "echo \"a\\b\" 'c'" with prompt "Lidless \"needs\" this" with administrator privileges"#)
    }
}

@Suite("Dead man's switch")
struct LidWatchdogTests {
    private func run(_ script: String) throws -> Process {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", script]
        try shell.run()
        return shell
    }

    @Test func restoresSleepWhenTheAppDisappearsWithoutCleaningUp() throws {
        let directory = try TemporaryDirectory()
        let marker = try directory.write("", to: "lid-sleep-disabled")
        let restored = directory.file("restored")
        let app = try run("sleep 0.3")

        let watchdog = try run(LidWatchdog.script(
            watching: app.processIdentifier, marker: marker.path,
            restoreCommand: "/usr/bin/touch '\(restored.path)'", pollInterval: 0.1
        ))
        watchdog.waitUntilExit()

        #expect(!app.isRunning)
        #expect(FileManager.default.fileExists(atPath: restored.path))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func restoresSleepWhenTheAppHangsWithoutDying() throws {
        // A frozen app stops refreshing the marker; nobody would turn sleep back on.
        let directory = try TemporaryDirectory()
        let marker = try directory.write("", to: "lid-sleep-disabled")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -600)], ofItemAtPath: marker.path
        )
        let restored = directory.file("restored")
        let app = try run("sleep 5")
        defer { app.terminate() }

        let watchdog = try run(LidWatchdog.script(
            watching: app.processIdentifier, marker: marker.path,
            restoreCommand: "/usr/bin/touch '\(restored.path)'", pollInterval: 0.1, staleAfter: 120
        ))
        watchdog.waitUntilExit()

        #expect(app.isRunning)
        #expect(FileManager.default.fileExists(atPath: restored.path))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func doesNothingWhenTheAppAlreadyCleanedUp() throws {
        let directory = try TemporaryDirectory()
        let restored = directory.file("restored")
        let app = try run("sleep 0.2")

        let watchdog = try run(LidWatchdog.script(
            watching: app.processIdentifier, marker: directory.file("no-marker").path,
            restoreCommand: "/usr/bin/touch '\(restored.path)'", pollInterval: 0.1
        ))
        watchdog.waitUntilExit()

        #expect(!FileManager.default.fileExists(atPath: restored.path))
    }

    @Test func byDefaultItRunsTheSameCommandTheSudoersRuleAllows() {
        let script = LidWatchdog.script(watching: 4242, marker: "/tmp/it's here/marker")
        #expect(script.contains("/bin/kill -0 4242"))
        #expect(script.contains("/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0"))
        #expect(script.contains(#"'/tmp/it'\''s here/marker'"#))
    }
}
