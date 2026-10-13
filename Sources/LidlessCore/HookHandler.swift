import Foundation

/// What an agent hook tells Lidless, whatever the agent calls it.
public enum HookEvent: String, CaseIterable, Sendable {
    /// A session opened (or was resumed, or compacted).
    case start
    /// The user submitted a prompt: a turn begins.
    case prompt
    /// The agent is doing something mid-turn, typically calling a tool.
    case activity
    /// The turn ended; the agent waits for its user.
    case stop
    /// The session closed.
    case end
}

public struct HookContext: Sendable {
    public var agent: Agent
    /// The agent's own session ID, when it provides one.
    public var sessionKey: String?
    public var pid: Int32
    public var processStart: Date?
    public var cwd: String?
    public var now: Date

    public init(agent: Agent, sessionKey: String?, pid: Int32, processStart: Date?, cwd: String?, now: Date) {
        self.agent = agent
        self.sessionKey = sessionKey
        self.pid = pid
        self.processStart = processStart
        self.cwd = cwd
        self.now = now
    }
}

/// Applies hook events to the session files.
public struct HookHandler: Sendable {
    public let store: SessionStore
    /// Mid-turn activity is persisted at most this often; tool calls can come in bursts.
    public let heartbeatInterval: TimeInterval

    public init(store: SessionStore, heartbeatInterval: TimeInterval = 15) {
        self.store = store
        self.heartbeatInterval = heartbeatInterval
    }

    /// Returns the session as it now stands, or `nil` once it is forgotten.
    @discardableResult
    public func handle(_ event: HookEvent, context: HookContext) throws -> SessionRecord? {
        let id = SessionRecord.identifier(agent: context.agent, sessionKey: context.sessionKey, pid: context.pid)
        if event == .end {
            store.remove(id: id)
            return nil
        }

        // A record left by another process means the session was resumed elsewhere: start over.
        let existing = store.load(id: id).flatMap { $0.pid == context.pid ? $0 : nil }
        var record = existing ?? SessionRecord(
            id: id,
            agent: context.agent,
            pid: context.pid,
            processStart: context.processStart,
            state: .idle,
            cwd: context.cwd,
            workingSince: nil,
            idleSince: nil,
            updatedAt: context.now
        )

        switch event {
        case .start, .end:
            // Session start also fires mid-turn (after a compaction): leave the state alone.
            break
        case .prompt:
            record.state = .working
            record.workingSince = context.now
            record.idleSince = nil
        case .activity:
            if record.state == .working, let existing,
               context.now.timeIntervalSince(existing.updatedAt) < heartbeatInterval {
                return existing
            }
            if record.state != .working {
                record.state = .working
                record.workingSince = context.now
                record.idleSince = nil
            }
        case .stop:
            if record.state == .working || record.idleSince == nil {
                record.idleSince = context.now
            }
            record.state = .idle
            record.workingSince = nil
        }

        record.cwd = context.cwd ?? record.cwd
        record.updatedAt = context.now
        try store.save(record)
        return record
    }
}

/// The part of an agent's hook payload (JSON on stdin) that Lidless cares about.
public struct HookPayload: Equatable, Sendable {
    public var sessionID: String?
    public var cwd: String?

    public init(sessionID: String?, cwd: String?) {
        self.sessionID = sessionID
        self.cwd = cwd
    }

    /// Never fails: a payload Lidless cannot read just carries no information.
    public static func parse(_ data: Data) -> HookPayload {
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            func string(_ key: String) -> String? {
                (object[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
            }
            return HookPayload(sessionID: string("session_id"), cwd: string("cwd"))
        }
        // Not valid JSON, most likely cut short: the fields we need come first, so scan for them.
        let text = String(decoding: data, as: UTF8.self)
        return HookPayload(sessionID: scan(text, for: "session_id"), cwd: scan(text, for: "cwd"))
    }

    /// The first `"key": "value"` in `text`, with the value's JSON escapes resolved.
    private static func scan(_ text: String, for key: String) -> String? {
        let pattern = "\"\(key)\"\\s*:\\s*(\"(?:[^\"\\\\]|\\\\.)*\")"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text),
              let value = try? JSONSerialization.jsonObject(
                  with: Data(text[range].utf8), options: .fragmentsAllowed
              ) as? String
        else { return nil }
        return value.isEmpty ? nil : value
    }
}
