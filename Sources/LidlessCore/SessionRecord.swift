import Foundation

public enum SessionState: String, Codable, Sendable {
    /// The agent is in the middle of a turn.
    case working
    /// The agent is waiting for its user.
    case idle
}

/// What Lidless knows about one agent session. One JSON file per record, written by `lidless-hook`.
public struct SessionRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var agent: Agent
    /// PID of the agent process; the session is considered gone when it dies.
    public var pid: Int32
    /// Start time of that process, so a recycled PID is not mistaken for the agent.
    public var processStart: Date?
    public var state: SessionState
    public var cwd: String?
    /// When the current turn began. `nil` while idle.
    public var workingSince: Date?
    /// When the last turn ended. `nil` while working, or if the session never worked.
    public var idleSince: Date?
    /// Time of the last hook event, used to spot sessions that went silent.
    public var updatedAt: Date

    public init(
        id: String,
        agent: Agent,
        pid: Int32,
        processStart: Date?,
        state: SessionState,
        cwd: String?,
        workingSince: Date?,
        idleSince: Date?,
        updatedAt: Date
    ) {
        self.id = id
        self.agent = agent
        self.pid = pid
        self.processStart = processStart
        self.state = state
        self.cwd = cwd
        self.workingSince = workingSince
        self.idleSince = idleSince
        self.updatedAt = updatedAt
    }
}

extension SessionRecord {
    /// Mid-turn but silent for `timeout`: probably interrupted, which agents do not report.
    /// A `timeout` of 0 means sessions never stall.
    public func isStalled(at now: Date, timeout: TimeInterval) -> Bool {
        state == .working && timeout > 0 && now.timeIntervalSince(updatedAt) >= timeout
    }
}

/// A session record paired with whether its agent process is still running.
public struct ObservedSession: Equatable, Sendable {
    public var record: SessionRecord
    public var isAlive: Bool

    public init(record: SessionRecord, isAlive: Bool) {
        self.record = record
        self.isAlive = isAlive
    }
}
