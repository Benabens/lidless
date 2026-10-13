import Darwin
import Foundation

public enum AgentIntegrationError: Error, Equatable, CustomStringConvertible {
    /// The agent has no configuration directory in this home: it is not installed.
    case agentNotFound(Agent)
    case notUTF8(String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case let .agentNotFound(agent): "\(agent.displayName) does not seem to be installed."
        case let .notUTF8(path): "\(path) is not a UTF-8 text file."
        case let .writeFailed(detail): "Could not write the configuration (\(detail))."
        }
    }
}

/// Lidless's hooks in one agent's configuration file, for a given home directory.
public struct AgentIntegration: Sendable {
    public enum Status: Equatable, Sendable {
        case agentNotFound
        case notInstalled
        /// Lidless hooks are present but need refreshing (the hook moved, or an entry is missing).
        case outdated
        case installed
        /// The configuration exists but Lidless will not touch it (not strict JSON, odd shape).
        case unreadable

        /// Lidless's hooks are in the configuration, up to date or not.
        public var isConnected: Bool {
            self == .installed || self == .outdated
        }
    }

    public let agent: Agent
    public let configDirectory: URL
    public let configFile: URL

    public init(agent: Agent, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.agent = agent
        switch agent {
        case .claude:
            configDirectory = home.appendingPathComponent(".claude", isDirectory: true)
            configFile = configDirectory.appendingPathComponent("settings.json")
        case .codex:
            // Codex reads hooks from hooks.json as well as from [hooks] tables in config.toml.
            // The JSON file can be merged safely; config.toml is left alone.
            configDirectory = home.appendingPathComponent(".codex", isDirectory: true)
            configFile = configDirectory.appendingPathComponent("hooks.json")
        case .gemini:
            configDirectory = home.appendingPathComponent(".gemini", isDirectory: true)
            configFile = configDirectory.appendingPathComponent("settings.json")
        }
    }

    /// The configuration as it last was without Lidless in it.
    public var backupFile: URL {
        URL(fileURLWithPath: configFile.path + ".lidless.bak")
    }

    private var spec: AgentHookSpec { .spec(for: agent) }

    private var agentIsInstalled: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: configDirectory.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    public func status(hookPath: String) -> Status {
        guard agentIsInstalled else { return .agentNotFound }
        let text: String?
        do {
            text = try currentText()
        } catch {
            return .unreadable
        }
        switch HookConfig.state(of: spec, hookPath: hookPath, in: text) {
        case .notInstalled: return .notInstalled
        case .outdated: return .outdated
        case .installed: return .installed
        case .unreadable: return .unreadable
        }
    }

    /// Adds (or refreshes) Lidless's hooks. The file is left untouched if anything looks off.
    public func install(hookPath: String) throws {
        guard agentIsInstalled else { throw AgentIntegrationError.agentNotFound(agent) }
        let original = try currentText()
        let updated = try HookConfig.installing(spec, hookPath: hookPath, into: original)
        guard updated != original else { return }

        if let original, !HookConfig.containsLidlessHooks(in: original) {
            try write(original, to: backupFile, mode: currentMode())
        }
        try write(updated, to: target, mode: currentMode())
    }

    /// Removes Lidless's hooks and nothing else.
    public func uninstall() throws {
        guard let original = try currentText() else { return }
        let cleaned = try HookConfig.uninstalling(from: original)
        guard cleaned != original else { return }

        if let backup = unchangedBackup(matching: cleaned) {
            // Nothing but Lidless happened to the file: give back the very bytes it had.
            try write(backup, to: target, mode: currentMode())
        } else if let cleaned {
            try write(cleaned, to: target, mode: currentMode())
        } else if isSymbolicLink {
            // Somebody manages this file from elsewhere: empty it rather than break their link.
            try write("{}\n", to: target, mode: currentMode())
        } else {
            // Lidless created this file: leave no trace.
            try FileManager.default.removeItem(at: configFile)
        }
    }

    /// The backup, if adding and removing Lidless is all that separates it from the current
    /// file. Rewriting normalises a hand-formatted file's layout, and only the backup remembers
    /// what it looked like.
    private func unchangedBackup(matching cleaned: String?) -> String? {
        guard let backup = try? String(contentsOf: backupFile, encoding: .utf8) else { return nil }
        do {
            let roundTrip = try HookConfig.uninstalling(
                from: HookConfig.installing(spec, hookPath: "/\(HookConfig.executableName)", into: backup)
            )
            return roundTrip == cleaned ? backup : nil
        } catch {
            return nil
        }
    }

    /// Codex warns at startup when hooks.json and inline `[hooks]` tables coexist.
    public var hasInlineCodexHooks: Bool {
        guard agent == .codex,
              let toml = try? String(contentsOf: configDirectory.appendingPathComponent("config.toml"), encoding: .utf8)
        else { return false }
        return toml.split(separator: "\n").contains { line in
            let trimmed = line.drop { $0 == " " || $0 == "\t" || $0 == "[" }
            return line.drop { $0 == " " || $0 == "\t" }.hasPrefix("[")
                && (trimmed.hasPrefix("hooks.") || trimmed.hasPrefix("hooks]"))
        }
    }

    // MARK: - File access

    /// Where the bytes really live: a symlinked configuration is edited in place, not replaced.
    /// Followed by hand because a link to a file that does not exist yet must be honoured too.
    private var target: URL {
        var url = configFile
        for _ in 0..<8 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { break }
            url = URL(fileURLWithPath: destination, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
        }
        return url
    }

    private var isSymbolicLink: Bool {
        (try? configFile.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
    }

    /// `nil` when the file does not exist.
    private func currentText() throws -> String? {
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        let data = try Data(contentsOf: target)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AgentIntegrationError.notUTF8(target.path)
        }
        return text
    }

    /// Settings files can hold credentials, so new files are private and existing modes are kept.
    private func currentMode() -> mode_t {
        let attributes = try? FileManager.default.attributesOfItem(atPath: target.path)
        return (attributes?[.posixPermissions] as? NSNumber).map { mode_t($0.uint16Value) } ?? 0o600
    }

    /// Writes to a sibling temporary file with the final permissions, then renames over `url`.
    private func write(_ text: String, to url: URL, mode: mode_t) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).lidless-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard descriptor >= 0 else {
            throw AgentIntegrationError.writeFailed(String(cString: strerror(errno)))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            // open(2) applies the umask; the mode has to match the original exactly.
            guard fchmod(descriptor, mode) == 0 else {
                throw AgentIntegrationError.writeFailed(String(cString: strerror(errno)))
            }
            try handle.write(contentsOf: Data(text.utf8))
            try handle.synchronize()
            try handle.close()
            guard rename(temporary.path, url.path) == 0 else {
                throw AgentIntegrationError.writeFailed(String(cString: strerror(errno)))
            }
        } catch {
            unlink(temporary.path)
            throw error
        }
    }
}
