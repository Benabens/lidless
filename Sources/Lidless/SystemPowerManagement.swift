import Foundation
import LidlessCore

/// Runs a command and waits for it. Only used for short, non-interactive system tools.
enum Shell {
    struct Output {
        var status: Int32
        var text: String
    }

    static func run(_ command: [String]) -> Output? {
        guard let executable = command.first else { return nil }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, text: String(decoding: data, as: UTF8.self))
    }
}

/// `pmset`, for real. Changing `disablesleep` goes through `sudo -n`, which only succeeds once
/// the sudoers rule is installed; it never prompts.
struct SystemPowerManagement: PowerManagement {
    func sleepDisabled() -> Bool? {
        Shell.run(["/usr/bin/pmset", "-g"]).flatMap { PMSet.sleepDisabled(inOutputOf: $0.text) }
    }

    func setSleepDisabled(_ disabled: Bool) -> Bool {
        Shell.run(PMSet.command(disablingSleep: disabled))?.status == 0
    }
}

/// Runs a shell script as root through the standard macOS administrator prompt.
enum AdministratorPrompt {
    /// `completion` is called on the main actor with `nil` on success, or what went wrong.
    static func run(_ script: String, prompt: String, completion: @escaping @MainActor (String?) -> Void) {
        let appleScript = SudoersRule.appleScript(running: script, prompt: prompt)
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", appleScript]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errors
            var failure: String?
            do {
                try process.run()
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    // -128 is "User canceled": not an error worth reporting.
                    failure = message.contains("-128") ? "" : message.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } catch {
                failure = error.localizedDescription
            }
            let result = failure
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(result) }
            }
        }
    }
}
