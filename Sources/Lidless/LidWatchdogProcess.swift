import Foundation
import LidlessCore

/// Runs the dead man's switch: a detached shell that turns sleep back on if this app dies or
/// freezes while closed-lid mode has it disabled.
@MainActor
final class LidWatchdogProcess {
    private let marker: URL
    private var process: Process?

    init(marker: URL) {
        self.marker = marker
    }

    func start() {
        guard process?.isRunning != true else { return }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", LidWatchdog.script(
            watching: ProcessInfo.processInfo.processIdentifier, marker: marker.path
        )]
        shell.standardInput = FileHandle.nullDevice
        shell.standardOutput = FileHandle.nullDevice
        shell.standardError = FileHandle.nullDevice
        try? shell.run()
        process = shell
    }

    func stop() {
        if process?.isRunning == true { process?.terminate() }
        process = nil
    }
}
