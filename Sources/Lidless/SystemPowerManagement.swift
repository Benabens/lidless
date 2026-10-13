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
    enum Result {
        case succeeded
        /// The user dismissed the password prompt.
        case cancelled
        case failed(String)
    }

    /// `completion` is called on the main actor once the script has run or the prompt is dismissed.
    static func run(_ script: String, prompt: String, completion: @escaping @MainActor (Result) -> Void) {
        let appleScript = SudoersRule.appleScript(running: script, prompt: prompt)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = execute(appleScript)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(result) }
            }
        }
    }

    private static func execute(_ appleScript: String) -> Result {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return .failed(error.localizedDescription)
        }
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return .succeeded }
        // AppleScript reports a dismissed prompt as error -128, "User canceled".
        return message.contains("-128") ? .cancelled : .failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
