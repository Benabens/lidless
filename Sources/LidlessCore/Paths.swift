import Foundation

/// Where Lidless keeps its files.
public struct LidlessPaths: Sendable {
    public let supportDirectory: URL
    /// The home directory whose agent configurations Lidless reads and edits.
    public let agentsHome: URL

    /// Two overrides exist for tests and for trying the app without touching anything real:
    /// `LIDLESS_SUPPORT_DIR` moves Lidless's own files, `LIDLESS_HOME` the agents' home.
    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        if let override = environment["LIDLESS_SUPPORT_DIR"], !override.isEmpty {
            supportDirectory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            supportDirectory = home.appendingPathComponent("Library/Application Support/Lidless", isDirectory: true)
        }
        if let override = environment["LIDLESS_HOME"], !override.isEmpty {
            agentsHome = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            agentsHome = home
        }
    }

    /// One JSON file per agent session.
    public var sessionsDirectory: URL {
        supportDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    /// The copy of `lidless-hook` the agents call. It lives outside the app bundle so the hooks
    /// keep working wherever the app is moved.
    public var installedHook: URL {
        supportDirectory.appendingPathComponent("bin/lidless-hook")
    }

    /// Exists while `disablesleep` is set because Lidless set it.
    public var lidSleepMarker: URL {
        supportDirectory.appendingPathComponent("lid-sleep-disabled")
    }
}
