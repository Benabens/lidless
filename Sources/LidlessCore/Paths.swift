import Foundation

/// Where Lidless keeps its files.
public struct LidlessPaths: Sendable {
    public let supportDirectory: URL

    /// `LIDLESS_SUPPORT_DIR` overrides the default location, for tests and sandboxes.
    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        if let override = environment["LIDLESS_SUPPORT_DIR"], !override.isEmpty {
            supportDirectory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            supportDirectory = home.appendingPathComponent("Library/Application Support/Lidless", isDirectory: true)
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
