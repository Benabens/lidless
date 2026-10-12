import Darwin
import Foundation

public struct ProcessSnapshot: Equatable, Sendable {
    public var pid: Int32
    public var parentPID: Int32
    public var name: String
    public var startTime: Date?

    public init(pid: Int32, parentPID: Int32, name: String, startTime: Date?) {
        self.pid = pid
        self.parentPID = parentPID
        self.name = name
        self.startTime = startTime
    }
}

public enum ProcessTree {
    /// Processes that merely relay the hook command; the agent sits somewhere above them.
    static let relays: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh", "env", "timeout"]

    /// The agent that fired a hook, given the hook's parent. Agents run hook commands through a
    /// shell, so the parent is often `sh`; climb until something that is not a relay.
    public static func agentProcess(parentOfHook: Int32, lookup: (Int32) -> ProcessSnapshot?) -> Int32 {
        var candidate = parentOfHook
        for _ in 0..<16 {
            guard let snapshot = lookup(candidate), relays.contains(snapshot.name) else { break }
            guard snapshot.parentPID > 1 else { break }
            candidate = snapshot.parentPID
        }
        return candidate
    }
}

public enum ProcessProbe {
    public static func snapshot(of pid: Int32) -> ProcessSnapshot? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        // A zombie still answers, but it is not running anything.
        guard info.pbi_status != UInt32(SZOMB) else { return nil }

        var name = withUnsafeBytes(of: info.pbi_name) { cString($0) }
        if name.isEmpty { name = withUnsafeBytes(of: info.pbi_comm) { cString($0) } }
        let start = Date(
            timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
        )
        return ProcessSnapshot(pid: pid, parentPID: Int32(info.pbi_ppid), name: name, startTime: start)
    }

    /// Whether `pid` still is the process that started at `startedAt`. Without a start time this
    /// degrades to a plain existence check.
    public static func isAlive(pid: Int32, startedAt: Date?) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 else { return false }
        // kill(0) also succeeds for a zombie and for a recycled PID: look closer.
        guard let current = snapshot(of: pid) else { return false }
        guard let startedAt, let currentStart = current.startTime else { return true }
        // Recorded start times go through whole-second JSON dates.
        return abs(currentStart.timeIntervalSince(startedAt)) < 2
    }

    private static func cString(_ bytes: UnsafeRawBufferPointer) -> String {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}
