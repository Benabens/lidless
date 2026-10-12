import Foundation

/// The one system setting closed-lid mode changes: `pmset -a disablesleep`.
public protocol PowerManagement: Sendable {
    /// Whether sleep is currently disabled system-wide; `nil` if that cannot be read.
    func sleepDisabled() -> Bool?
    /// Returns whether the change went through.
    func setSleepDisabled(_ disabled: Bool) -> Bool
}

public enum PMSet {
    /// Parses the `SleepDisabled` line of `pmset -g`.
    public static func sleepDisabled(inOutputOf output: String) -> Bool? {
        for line in output.split(separator: "\n") {
            let words = line.split(whereSeparator: \.isWhitespace)
            if words.count == 2, words[0] == "SleepDisabled" {
                return words[1] == "1" ? true : words[1] == "0" ? false : nil
            }
        }
        return nil
    }

    /// Exactly the commands the sudoers rule allows, so `sudo -n` never needs a password.
    public static func command(disablingSleep: Bool) -> [String] {
        ["/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", disablingSleep ? "1" : "0"]
    }
}

/// Turns the reconciler's wish into `disablesleep` changes, remembering through a marker file
/// that Lidless made the change so that it only ever undoes its own.
public struct LidSleepController: Sendable {
    public enum Result: Equatable, Sendable {
        /// Nothing to do: sleep is not disabled by Lidless.
        case idle
        /// Sleep is disabled, and Lidless is the one that disabled it.
        case engaged
        /// Sleep was re-enabled.
        case released
        /// Sleep was already disabled by someone else; Lidless leaves that setting alone.
        case leftToUser
        /// `pmset` refused (most likely the sudoers rule is missing).
        case failed
    }

    private let powerManagement: any PowerManagement
    private let marker: URL

    public init(powerManagement: any PowerManagement, marker: URL) {
        self.powerManagement = powerManagement
        self.marker = marker
    }

    /// Whether `disablesleep` is currently set because Lidless set it.
    public var ownsTheSetting: Bool {
        FileManager.default.fileExists(atPath: marker.path)
    }

    public func apply(disableLidSleep: Bool) -> Result {
        disableLidSleep ? engage() : release()
    }

    private func engage() -> Result {
        let alreadyDisabled = powerManagement.sleepDisabled() == true
        if ownsTheSetting {
            if alreadyDisabled { return .engaged }
            return powerManagement.setSleepDisabled(true) ? .engaged : .failed
        }
        if alreadyDisabled { return .leftToUser }

        // Marker first: if Lidless dies right after pmset, the next launch still knows to undo it.
        do {
            try FileManager.default.createDirectory(
                at: marker.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data().write(to: marker)
        } catch {
            return .failed
        }
        guard powerManagement.setSleepDisabled(true) else {
            try? FileManager.default.removeItem(at: marker)
            return .failed
        }
        return .engaged
    }

    private func release() -> Result {
        guard ownsTheSetting else { return .idle }
        guard powerManagement.setSleepDisabled(false) else { return .failed }
        try? FileManager.default.removeItem(at: marker)
        return .released
    }
}

/// A shell script that outlives the app: if Lidless dies while sleep is disabled (crash, force
/// quit), it re-enables sleep so the Mac is never left awake with its lid closed for nothing.
public enum LidWatchdog {
    public static func script(
        watching pid: Int32,
        marker: String,
        restoreCommand: String = PMSet.command(disablingSleep: false).joined(separator: " "),
        pollInterval: Double = 2
    ) -> String {
        let quotedMarker = HookConfig.shellQuoted(marker)
        return """
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep \(pollInterval); done
        [ -e \(quotedMarker) ] || exit 0
        \(restoreCommand) && /bin/rm -f \(quotedMarker)
        """
    }
}
